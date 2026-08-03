// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICrispVotingPlugin} from "./interfaces/ICrispVotingPlugin.sol";
import {IImmunitySource} from "./interfaces/IImmunitySource.sol";
import {RosterToken} from "./RosterToken.sol";

/// @title SurvivalGame
/// @notice A team-based social survival game whose eliminations are decided by secret ballot.
///
/// @dev Each round is one proposal on the CRISP Aragon voting plugin, which requests the E3 that
///      carries the ballot. Ballots themselves never touch this contract or the plugin: voters
///      submit to the CRISP coordination server, which publishes them to the CRISP program. This
///      contract only pins who may vote and on whom, then reads the decrypted tally.
///
///      ```
///      TRIBAL   everyone alive votes which team goes to council        1 E3
///        ↓
///      COUNCIL  that team alone votes which of its own is out          1 E3
///        ↓
///      ...repeat until <= mergeAt survivors, then teams dissolve...
///        ↓
///      INDIVIDUAL  everyone alive votes directly to eliminate          1 E3
///        ↓
///      JURY     the eliminated choose the winner from the finalists    1 E3
///      ```
///
///      **Why teams.** The CRISP circuit caps a ballot at `MAX_OPTIONS = 10`. Applying that bound
///      twice — at most 10 teams, at most 10 members each — supports 100 players while every ballot
///      stays inside it. It also doubles E3s per elimination, and adds the layer that makes teams
///      worth having: you coordinate with your team in public and knife them in private.
///
///      Only aggregate counts are ever revealed. That is what lets a player campaign for one
///      outcome and vote for another, unprovably, which is the entire game.
contract SurvivalGame is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on ballot options, mirroring `MAX_OPTIONS` in the CRISP circuit
    ///         (`circuits/lib/src/constants.nr`). Exceeding it yields a round whose votes cannot be
    ///         proven, so it is enforced here rather than discovered at proving time — the on-chain
    ///         CRISP program only checks the lower bound.
    uint256 public constant MAX_BALLOT_OPTIONS = 10;

    /// @notice Every voter receives exactly one credit, making this one-player-one-vote.
    uint256 internal constant CREDITS_PER_VOTER = 1;

    /// @notice `ICRISP.CreditMode.CONSTANT`, passed through to the plugin as a uint.
    uint256 internal constant CREDIT_MODE_CONSTANT = 0;
    /// @notice `CRISPProgram.CensusMode.BY_REQUESTER`. The game answers `getCensus` for its own
    ///         rounds, so the coordinator must ask rather than derive the electorate from token
    ///         balances — which would enfranchise every LIFE holder in a council or jury round.
    uint256 internal constant CENSUS_MODE_BY_REQUESTER = 1;

    enum Stage {
        Lobby,
        Playing,
        Jury,
        Ended,
        /// @notice The lobby never filled and was abandoned. Entry fees are refundable.
        Cancelled
    }

    /// @notice What a round's ballot decides.
    enum RoundKind {
        /// @notice Everyone alive votes which team goes to council. Options are teams.
        Tribal,
        /// @notice One team votes which of its own members is eliminated. Options are members.
        Council,
        /// @notice Post-merge: everyone alive votes directly to eliminate. Options are players.
        Individual,
        /// @notice The eliminated choose the winner from the finalists. Options are finalists.
        Jury
    }

    struct Config {
        uint64 campaignDuration;
        uint64 ballotDuration;
        uint64 tallyGrace;
        /// @notice Teams in the game. Must be in 2..=MAX_BALLOT_OPTIONS.
        uint8 teamCount;
        /// @notice The fewest members a team may have when the game starts. Must be in
        /// 1..=MAX_BALLOT_OPTIONS. There is no configured ceiling: a team may grow to
        /// MAX_BALLOT_OPTIONS, which is the circuit's limit on a council ballot, not a game rule.
        uint8 minMembersPerTeam;
        /// @notice Players needed before the game may start. Must be in (finalists, teamCount *
        /// MAX_BALLOT_OPTIONS]. Set it equal to the full lobby to require every seat.
        uint8 minPlayers;
        /// @notice How long the lobby may sit unfilled before anyone can cancel it and release the
        /// entry fees. Zero means never — appropriate only when nobody is paying to join.
        uint64 lobbyTimeout;
        /// @notice Survivor count at which teams dissolve. Must be <= MAX_BALLOT_OPTIONS.
        uint8 mergeAt;
        /// @notice Survivors left when eliminations stop and the jury votes. Must be >= 2.
        uint8 finalists;
        uint8 maxMissedCheckIns;
        uint256 entryFee;
    }

    struct Round {
        RoundKind kind;
        uint256 proposalId;
        uint256 e3Id;
        uint64 openedAt;
        uint64 ballotOpensAt;
        uint64 ballotClosesAt;
        bool settled;
        /// @notice Eliminated player, or the winner in a jury round. Zero until settled.
        address outcome;
        /// @notice Council rounds only: the team whose member is being voted out.
        uint8 targetTeam;
        /// @notice Ballot option index -> player. Empty for tribal rounds.
        address[] candidates;
        /// @notice Ballot option index -> team. Tribal rounds only.
        uint8[] candidateTeams;
        /// @notice The eligible voter set for this round.
        address[] voters;
    }

    // ─── Immutable wiring ────────────────────────────────────────────────────────────────────

    /// @notice The CRISP Aragon voting plugin. Creating a proposal on it requests the round's E3.
    ICrispVotingPlugin public immutable plugin;
    IERC20 public immutable feeToken;
    /// @notice Held by survivors. Burned on elimination.
    RosterToken public immutable lifeToken;
    /// @notice Minted on elimination. The jury that picks the winner.
    RosterToken public immutable juryToken;

    // ─── State ───────────────────────────────────────────────────────────────────────────────

    Config public config;
    Stage public stage;

    IImmunitySource public immunitySource;

    /// @notice Players still holding a LIFE badge, in join order.
    address[] public alive;
    /// @notice Eliminated players, in elimination order. The jury.
    address[] public graveyard;
    address public winner;

    /// @notice When the lobby opened, which is what `lobbyTimeout` counts from.
    /// @dev Named for the lobby rather than the game because `Round` has its own `openedAt`, and two
    ///      unrelated things with the same name in one contract is how the wrong one gets read.
    uint64 public immutable lobbyOpenedAt;

    /// @notice Entry fee owed back to a player whose lobby was cancelled.
    /// @dev Pull rather than push. Refunding in a loop inside `cancelLobby` would put the whole
    ///      lobby's money behind one transaction that any single reverting recipient could block —
    ///      and the fee token is chosen by whoever deployed the game, so a token that reverts on
    ///      transfer to some address is not a hypothetical.
    mapping(address => uint256) public refundOf;

    /// @notice Team id (1-based; 0 means "no team") per player.
    mapping(address => uint8) public teamOf;
    /// @notice Surviving members of each team, 1-indexed by team id.
    mapping(uint8 => address[]) internal teamMembers;

    Round[] internal rounds;
    /// @notice e3Id -> round index + 1 (0 means unknown), so `getCensus` can resolve a round.
    mapping(uint256 => uint256) internal roundByE3Id;

    mapping(address => uint256) public lastCheckIn;
    mapping(address => bool) public isPlayer;
    uint256 public pot;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────

    event PlayerJoined(address indexed player, uint8 indexed team, uint256 entryFee);
    event GameStarted(uint256 players, uint256 teams, uint256 potAmount);
    event RoundOpened(
        uint256 indexed round,
        uint256 indexed e3Id,
        RoundKind kind,
        uint64 ballotOpensAt,
        uint64 ballotClosesAt,
        uint256 options
    );
    event TeamSentToCouncil(uint256 indexed round, uint8 indexed team, uint256[] counts);
    event Posted(uint256 indexed round, address indexed player, string cid);
    event CheckedIn(uint256 indexed round, address indexed player);
    event PlayerEliminated(
        uint256 indexed round, address indexed player, uint8 indexed team, uint256[] counts
    );
    event PlayerForfeited(uint256 indexed round, address indexed player);
    event RoundVoid(uint256 indexed round, uint256 indexed e3Id);
    event RoundAborted(uint256 indexed round, uint256 indexed e3Id);
    event Merged(uint256 survivors);
    event JuryPhaseReached(address[] finalists);
    event WinnerDeclared(address indexed player, uint256 prize);
    event ImmunitySourceUpdated(address indexed source);
    event LobbyCancelled(uint256 players, uint256 refundable);
    event RefundClaimed(address indexed player, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────

    error WrongStage(Stage expected, Stage actual);
    error ZeroAddress();
    error InvalidConfig();
    error AlreadyJoined();
    error InvalidTeam(uint8 team);
    error TeamFull(uint8 team, uint256 limit);
    error TeamBelowMinimum(uint8 team, uint256 have, uint256 need);
    error LobbyIncomplete(uint256 have, uint256 need);
    error PreviousRoundUnsettled();
    error TooManyOptions(uint256 count);
    error TooFewOptions(uint256 count);
    error InsufficientPot(uint256 needed, uint256 available);
    error NotInCampaign();
    error NotAVoter();
    error NotAlive();
    error TallyNotDue(uint64 until);
    error BallotStillOpen(uint64 until);
    error TallyNotPublished();
    error RoundAlreadySettled();
    error TallyLengthMismatch(uint256 expected, uint256 actual);
    error NoRounds();
    error NothingToWithdraw();
    error LobbyStillOpen(uint64 until);
    error LobbyTimeoutDisabled();
    error NothingToRefund();

    // ─── Construction ────────────────────────────────────────────────────────────────────────

    struct InitParams {
        address owner;
        ICrispVotingPlugin plugin;
        IERC20 feeToken;
        RosterToken lifeToken;
        RosterToken juryToken;
        Config config;
    }

    constructor(InitParams memory params) Ownable(params.owner) {
        if (
            address(params.plugin) == address(0) || address(params.feeToken) == address(0)
                || address(params.lifeToken) == address(0) || address(params.juryToken) == address(0)
        ) revert ZeroAddress();

        Config memory cfg = params.config;
        // Every bound here exists because violating it produces an unprovable or meaningless ballot:
        // a jury needs two names, teams need two sides, and both team count and team size are ballot
        // option counts so both are capped by the circuit.
        if (
            cfg.finalists < 2 || cfg.teamCount < 2 || cfg.teamCount > MAX_BALLOT_OPTIONS
                || cfg.minMembersPerTeam == 0 || cfg.minMembersPerTeam > MAX_BALLOT_OPTIONS
                || cfg.mergeAt > MAX_BALLOT_OPTIONS || cfg.mergeAt < cfg.finalists
                || cfg.campaignDuration == 0 || cfg.ballotDuration == 0
                || uint256(cfg.teamCount) * MAX_BALLOT_OPTIONS <= cfg.finalists
                // A game that starts already over is not a game, and the first round needs at least
                // two names on the ballot however the players happen to be spread across teams.
                || cfg.minPlayers <= cfg.finalists
                // The floor has to be reachable: every team needs `minMembersPerTeam` before the
                // game may start, so a floor below that sum could never satisfy both rules at once.
                || cfg.minPlayers < uint256(cfg.teamCount) * uint256(cfg.minMembersPerTeam)
                || uint256(cfg.minPlayers) > uint256(cfg.teamCount) * MAX_BALLOT_OPTIONS
        ) revert InvalidConfig();

        plugin = params.plugin;
        feeToken = params.feeToken;
        lifeToken = params.lifeToken;
        juryToken = params.juryToken;
        config = cfg;
        stage = Stage.Lobby;
        lobbyOpenedAt = uint64(block.timestamp);
    }

    // ─── Lobby ───────────────────────────────────────────────────────────────────────────────

    /// @notice Joins a team, paying the entry fee into the pot and receiving a LIFE badge.
    /// @param team The 1-based team id to join.
    function join(uint8 team) external {
        if (stage != Stage.Lobby) revert WrongStage(Stage.Lobby, stage);
        if (isPlayer[msg.sender]) revert AlreadyJoined();
        if (team == 0 || team > config.teamCount) revert InvalidTeam(team);
        // The only ceiling is the circuit's. A council round puts one option per team member on the
        // ballot, so a team larger than MAX_BALLOT_OPTIONS could not be voted on at all — everything
        // below that is the players' business, not the config's.
        if (teamMembers[team].length >= MAX_BALLOT_OPTIONS) revert TeamFull(team, MAX_BALLOT_OPTIONS);

        uint256 fee = config.entryFee;
        if (fee != 0) {
            feeToken.safeTransferFrom(msg.sender, address(this), fee);
            pot += fee;
        }

        isPlayer[msg.sender] = true;
        teamOf[msg.sender] = team;
        alive.push(msg.sender);
        teamMembers[team].push(msg.sender);
        lifeToken.mint(msg.sender);

        emit PlayerJoined(msg.sender, team, fee);
    }

    /// @notice Starts the game once `minPlayers` have joined, and opens the first round.
    ///
    /// @dev Permissionless: a lobby that has reached its floor is an objective condition, and gating
    ///      the start would let a privileged caller stall a funded game indefinitely.
    ///
    ///      Waiting for every seat is the wrong default — it makes the game hostage to the slowest
    ///      joiner, and a lobby that never fills never plays. `minPlayers` is the floor; anyone may
    ///      start at or above it, and seats stay open until someone does. Set `minPlayers` to the
    ///      full lobby to restore the old behaviour.
    ///
    ///      An under-full lobby is safe for every round kind because the shape is derived, never
    ///      assumed: `_nextKind` falls back to an individual round when fewer than two teams have
    ///      anyone alive, and a condemned team of one is eliminated without a council ballot. Both
    ///      paths already existed to handle attrition; starting small only reaches them sooner.
    function startGame() external {
        if (stage != Stage.Lobby) revert WrongStage(Stage.Lobby, stage);
        uint256 need = config.minPlayers;
        if (alive.length < need) revert LobbyIncomplete(alive.length, need);

        // Team size has no ceiling, so nothing stops a lobby piling into one team — and a game whose
        // tribes are empty is not the game that was configured. The minimum is enforced here rather
        // than at `join`, because the first person to join a team would otherwise be unable to.
        uint8 floor_ = config.minMembersPerTeam;
        for (uint8 t = 1; t <= config.teamCount; ++t) {
            uint256 have = teamMembers[t].length;
            if (have < floor_) revert TeamBelowMinimum(t, have, floor_);
        }

        stage = Stage.Playing;
        emit GameStarted(alive.length, config.teamCount, pot);
        _openRound();
    }

    // ─── Rounds ──────────────────────────────────────────────────────────────────────────────

    /// @notice Opens the next round. Permissionless once the previous one has settled.
    function openRound() external {
        if (stage != Stage.Playing && stage != Stage.Jury) revert WrongStage(Stage.Playing, stage);
        if (rounds.length != 0 && !rounds[rounds.length - 1].settled) revert PreviousRoundUnsettled();
        _openRound();
    }

    function _openRound() internal {
        uint256 roundId = rounds.length;
        if (stage == Stage.Playing) _applyForfeits(roundId);

        RoundKind kind = _nextKind();
        rounds.push();
        Round storage round = rounds[roundId];
        round.kind = kind;

        uint256 options;
        if (kind == RoundKind.Tribal) {
            round.candidateTeams = _aliveTeams();
            round.voters = alive;
            options = round.candidateTeams.length;
        } else if (kind == RoundKind.Council) {
            uint8 target = rounds[roundId - 1].targetTeam;
            round.targetTeam = target;
            round.candidates = teamMembers[target];
            // Only the condemned team votes. Letting everyone vote would make the tribal round
            // pointless — the same majority would simply pick the victim directly.
            round.voters = teamMembers[target];
            options = round.candidates.length;
        } else if (kind == RoundKind.Individual) {
            round.candidates = _eliminableAlive(roundId);
            round.voters = alive;
            options = round.candidates.length;
        } else {
            round.candidates = alive;
            round.voters = graveyard;
            options = round.candidates.length;
        }

        if (options > MAX_BALLOT_OPTIONS) revert TooManyOptions(options);
        if (options < 2) revert TooFewOptions(options);

        uint64 ballotOpensAt = uint64(block.timestamp) + config.campaignDuration;
        uint64 ballotClosesAt = ballotOpensAt + config.ballotDuration;

        (uint256 proposalId, uint256 e3Id) =
            _createProposal(roundId, kind, options, ballotOpensAt, ballotClosesAt);

        round.proposalId = proposalId;
        round.e3Id = e3Id;
        round.openedAt = uint64(block.timestamp);
        round.ballotOpensAt = ballotOpensAt;
        round.ballotClosesAt = ballotClosesAt;
        roundByE3Id[e3Id] = roundId + 1;

        emit RoundOpened(roundId, e3Id, kind, ballotOpensAt, ballotClosesAt, options);
    }

    /// @dev Tribal alternates into council; everything else follows from how many survive.
    function _nextKind() internal view returns (RoundKind) {
        if (stage == Stage.Jury) return RoundKind.Jury;

        // A council round only follows a tribal round that actually condemned a team. If the tribal
        // round was void, or its team was reduced to one member and resolved immediately, there is
        // nothing to convene.
        if (rounds.length != 0) {
            Round storage previous = rounds[rounds.length - 1];
            if (
                previous.kind == RoundKind.Tribal && previous.targetTeam != 0
                    && previous.outcome == address(0)
            ) {
                return RoundKind.Council;
            }
        }

        // Teams stop meaning anything once the field is small enough to fit one ballot, or once only
        // one team is left standing.
        if (alive.length <= config.mergeAt || _aliveTeams().length < 2) return RoundKind.Individual;
        return RoundKind.Tribal;
    }

    function _createProposal(
        uint256 roundId,
        RoundKind kind,
        uint256 options,
        uint64 ballotOpensAt,
        uint64 ballotClosesAt
    ) internal returns (uint256 proposalId, uint256 e3Id) {
        // The electorate is declared so the plugin can compute a participation threshold: under
        // constant credits each voter contributes exactly one, so turnout is bounded by the voter
        // count rather than by token supply.
        bytes memory data = abi.encode(
            uint256(0), // allowFailureMap
            options,
            CREDIT_MODE_CONSTANT,
            CREDITS_PER_VOTER,
            rounds[roundId].voters.length,
            CENSUS_MODE_BY_REQUESTER
        );

        // The plugin pulls its Interfold fee from the caller, so the pot has to be approved to it.
        // Approving the exact balance rather than a fixed amount avoids having to quote the fee here.
        uint256 available = pot;
        if (available == 0) revert InsufficientPot(1, 0);
        feeToken.forceApprove(address(plugin), available);

        uint256 balanceBefore = feeToken.balanceOf(address(this));

        proposalId = plugin.createProposal(
            abi.encode(address(this), roundId, kind),
            new ICrispVotingPlugin.Action[](0),
            ballotOpensAt,
            ballotClosesAt,
            data
        );

        // Whatever the plugin actually took is the fee; deriving it from the balance keeps the pot
        // honest without duplicating the quote logic.
        uint256 spent = balanceBefore - feeToken.balanceOf(address(this));
        pot = available - spent;
        feeToken.forceApprove(address(plugin), 0);

        e3Id = plugin.getE3Id(proposalId);
    }

    // ─── The census hook ─────────────────────────────────────────────────────────────────────

    /// @notice The eligible voter set for an E3, read by the CRISP coordination server.
    /// @dev Reached through the plugin's `getCensus` passthrough: the server asks the E3's requester,
    ///      and the requester is the plugin, not this contract.
    ///
    ///      Returns *voters*, not candidates. The two differ in every round type except tribal: a
    ///      council round is voted only by the condemned team, and a jury round only by the dead.
    ///
    ///      MUST be immutable for a given `e3Id` once the round is open. The server reads it at chain
    ///      head — an E3's `requestBlock` is an EIP-6372 timestamp, not a height, so there is nothing
    ///      to pin to — and a census that changed mid-round would validate ballots against a
    ///      different eligibility tree than the one they were proven against. The voter list is
    ///      copied into the round at open and never written again.
    function getCensus(uint256 e3Id) external view returns (address[] memory) {
        uint256 slot = roundByE3Id[e3Id];
        if (slot == 0) return new address[](0);
        return rounds[slot - 1].voters;
    }

    // ─── Campaign ────────────────────────────────────────────────────────────────────────────

    /// @notice Publishes a campaign message (an IPFS CID) for the current round.
    function post(string calldata cid) external {
        uint256 roundId = _currentRoundId();
        if (block.timestamp >= rounds[roundId].ballotOpensAt) revert NotInCampaign();
        if (!_isVoter(roundId, msg.sender)) revert NotAVoter();
        emit Posted(roundId, msg.sender, cid);
    }

    /// @notice Records liveness for the current round.
    /// @dev Forfeits cannot key off abstention: ballots are secret and mask votes make slot activity
    ///      meaningless, so the chain genuinely cannot tell who voted. Check-in is the public signal
    ///      instead, and it leaks nothing about the ballot.
    function checkIn() external {
        uint256 roundId = _currentRoundId();
        if (!_isAlive(msg.sender)) revert NotAlive();
        lastCheckIn[msg.sender] = roundId + 1;
        emit CheckedIn(roundId, msg.sender);
    }

    /// @dev Culls players who have missed `maxMissedCheckIns` consecutive check-ins, never below the
    ///      finalist count — a forfeit must not be able to end the game by itself.
    function _applyForfeits(uint256 roundId) internal {
        uint8 limit = config.maxMissedCheckIns;
        if (limit == 0 || roundId <= limit) return;

        uint256 floorCount = config.finalists;
        for (uint256 i = alive.length; i > 0; --i) {
            if (alive.length <= floorCount) return;
            address player = alive[i - 1];
            uint256 seen = lastCheckIn[player];
            uint256 missed = seen == 0 ? roundId : roundId - (seen - 1);
            if (missed > limit) {
                _eliminate(player);
                emit PlayerForfeited(roundId, player);
            }
        }
    }

    // ─── Settlement ──────────────────────────────────────────────────────────────────────────

    /// @notice Settles the current round from the decrypted tally, as soon as there is one.
    /// @dev Permissionless: the tally is public and the outcome is a pure function of it.
    function settleRound() external {
        uint256 roundId = _currentRoundId();
        Round storage round = rounds[roundId];

        if (round.settled) revert RoundAlreadySettled();

        // Settlement waits on the tally existing, not on a clock. The committee often publishes well
        // inside `tallyGrace`, and making the round sit out the rest of the window served nobody: the
        // counts are final the moment they are decrypted, so there is nothing a later block adds.
        //
        // `tallyGrace` is still meaningful — it is the deadline after which `abortRound` may abandon
        // a round the committee never delivered. A deadline for giving up, rather than a delay
        // before acting.
        if (block.timestamp < round.ballotClosesAt) revert BallotStillOpen(round.ballotClosesAt);

        uint256[] memory counts = plugin.getTally(round.proposalId).counts;
        // An unpublished tally reads as an empty array. Saying so plainly beats reporting a length
        // mismatch against zero, which describes the symptom and not the cause.
        if (counts.length == 0) revert TallyNotPublished();

        uint256 expected =
            round.kind == RoundKind.Tribal ? round.candidateTeams.length : round.candidates.length;
        if (counts.length != expected) revert TallyLengthMismatch(expected, counts.length);

        (uint256 index, uint256 total) = _resolveWinningIndex(round.e3Id, counts);
        round.settled = true;

        // Nobody voted: there is no mandate. The round is void and the next one re-runs rather than
        // picking a victim by array order, which whoever controls join order could exploit.
        if (total == 0) {
            emit RoundVoid(roundId, round.e3Id);
            return;
        }

        if (round.kind == RoundKind.Tribal) {
            uint8 target = round.candidateTeams[index];
            round.targetTeam = target;
            emit TeamSentToCouncil(roundId, target, counts);

            // A team of one has nobody to deliberate over, and a one-option ballot is unprovable —
            // so the condemned member goes directly, with no council round.
            if (teamMembers[target].length == 1) {
                address doomed = teamMembers[target][0];
                round.outcome = doomed;
                _eliminate(doomed);
                emit PlayerEliminated(roundId, doomed, target, counts);
                _advanceStageIfNeeded();
            }
            return;
        }

        address chosen = round.candidates[index];
        round.outcome = chosen;

        if (round.kind == RoundKind.Jury) {
            winner = chosen;
            stage = Stage.Ended;
            uint256 prize = pot;
            pot = 0;
            if (prize != 0) feeToken.safeTransfer(chosen, prize);
            emit WinnerDeclared(chosen, prize);
            return;
        }

        uint8 team = teamOf[chosen];
        _eliminate(chosen);
        emit PlayerEliminated(roundId, chosen, team, counts);
        _advanceStageIfNeeded();
    }

    function _advanceStageIfNeeded() internal {
        if (alive.length == config.finalists) {
            stage = Stage.Jury;
            emit JuryPhaseReached(alive);
        } else if (alive.length == config.mergeAt) {
            emit Merged(alive.length);
        }
    }

    /// @dev The highest-polling index and the total votes cast.
    ///
    ///      Ties are frequent at these sizes, so they get a defined rule rather than an accident of
    ///      iteration order: the winner is drawn from the tied set using the tally itself as entropy.
    ///      The counts are fixed by the time this runs, so the draw is deterministic and verifiable,
    ///      and unlike `block.prevrandao` no block producer can grind it.
    function _resolveWinningIndex(uint256 e3Id, uint256[] memory counts)
        internal
        pure
        returns (uint256 index, uint256 total)
    {
        uint256 highest;
        uint256 tied;

        for (uint256 i = 0; i < counts.length;) {
            total += counts[i];
            if (counts[i] > highest) {
                highest = counts[i];
                tied = 1;
            } else if (counts[i] == highest && highest != 0) {
                ++tied;
            }
            unchecked {
                ++i;
            }
        }

        if (total == 0) return (type(uint256).max, 0);
        if (tied == 1) {
            for (uint256 i = 0; i < counts.length; ++i) {
                if (counts[i] == highest) return (i, total);
            }
        }

        uint256 pick = uint256(keccak256(abi.encode(e3Id, counts))) % tied;
        for (uint256 i = 0; i < counts.length; ++i) {
            if (counts[i] == highest) {
                if (pick == 0) return (i, total);
                --pick;
            }
        }
        revert TooFewOptions(0); // unreachable: a non-zero total guarantees a maximum
    }

    /// @notice Abandons a round whose E3 never produced a tally, so the game can re-open it.
    function abortRound() external onlyOwner {
        uint256 roundId = _currentRoundId();
        Round storage round = rounds[roundId];

        if (round.settled) revert RoundAlreadySettled();
        uint64 due = round.ballotClosesAt + config.tallyGrace;
        if (block.timestamp < due) revert TallyNotDue(due);

        round.settled = true;
        // Clearing the target stops a council round convening off an abandoned tribal round.
        round.targetTeam = 0;
        emit RoundAborted(roundId, round.e3Id);
    }

    /// @notice Abandons a lobby that never filled, releasing entry fees.
    ///
    /// @dev Permissionless, like starting: whether the lobby filled by the deadline is an objective
    ///      fact, and leaving it to the creator would mean a lobby's money is only as recoverable as
    ///      its creator's attention. That is the failure the open-join model creates — nobody can
    ///      take your seats, but nobody is obliged to start either.
    ///
    ///      Only ever callable while the lobby is short of its floor: once `minPlayers` have joined,
    ///      anyone can start the game instead, so there is nothing to rescue.
    function cancelLobby() external {
        if (stage != Stage.Lobby) revert WrongStage(Stage.Lobby, stage);

        uint64 timeout = config.lobbyTimeout;
        if (timeout == 0) revert LobbyTimeoutDisabled();

        uint64 due = lobbyOpenedAt + timeout;
        if (block.timestamp < due) revert LobbyStillOpen(due);
        if (alive.length >= config.minPlayers) revert LobbyIncomplete(alive.length, config.minPlayers);

        stage = Stage.Cancelled;

        uint256 fee = config.entryFee;
        uint256 refundable;
        if (fee != 0) {
            uint256 count = alive.length;
            for (uint256 i = 0; i < count; ++i) {
                refundOf[alive[i]] = fee;
            }
            refundable = fee * count;
            // The refunds are no longer prize money, so they leave the pot. Whatever was funded on
            // top stays, and `sweep` returns it.
            pot -= refundable;
        }

        emit LobbyCancelled(alive.length, refundable);
    }

    /// @notice Claims an entry fee back from a cancelled lobby.
    function claimRefund() external {
        uint256 amount = refundOf[msg.sender];
        if (amount == 0) revert NothingToRefund();

        refundOf[msg.sender] = 0;
        feeToken.safeTransfer(msg.sender, amount);

        emit RefundClaimed(msg.sender, amount);
    }

    // ─── Treasury ────────────────────────────────────────────────────────────────────────────

    function fund(uint256 amount) external {
        feeToken.safeTransferFrom(msg.sender, address(this), amount);
        pot += amount;
    }

    /// @dev Also allowed once a lobby is cancelled, so a creator's own funding is recoverable. The
    ///      pot has already had the refunds deducted by then, so this cannot take players' money.
    function sweep(address to) external onlyOwner {
        if (stage != Stage.Ended && stage != Stage.Cancelled) revert WrongStage(Stage.Ended, stage);
        uint256 amount = pot;
        if (amount == 0) revert NothingToWithdraw();
        pot = 0;
        feeToken.safeTransfer(to, amount);
    }

    function setImmunitySource(IImmunitySource source) external onlyOwner {
        immunitySource = source;
        emit ImmunitySourceUpdated(address(source));
    }

    // ─── Views ───────────────────────────────────────────────────────────────────────────────

    function roundCount() external view returns (uint256) {
        return rounds.length;
    }

    function currentRoundId() external view returns (uint256) {
        return _currentRoundId();
    }

    function candidatesOf(uint256 roundId) external view returns (address[] memory) {
        return rounds[roundId].candidates;
    }

    function candidateTeamsOf(uint256 roundId) external view returns (uint8[] memory) {
        return rounds[roundId].candidateTeams;
    }

    function votersOf(uint256 roundId) external view returns (address[] memory) {
        return rounds[roundId].voters;
    }

    function getRound(uint256 roundId)
        external
        view
        returns (
            RoundKind kind,
            uint256 proposalId,
            uint256 e3Id,
            uint64 openedAt,
            uint64 ballotOpensAt,
            uint64 ballotClosesAt,
            bool settled,
            address outcome,
            uint8 targetTeam
        )
    {
        Round storage r = rounds[roundId];
        return (
            r.kind,
            r.proposalId,
            r.e3Id,
            r.openedAt,
            r.ballotOpensAt,
            r.ballotClosesAt,
            r.settled,
            r.outcome,
            r.targetTeam
        );
    }

    function aliveCount() external view returns (uint256) {
        return alive.length;
    }

    function alivePlayers() external view returns (address[] memory) {
        return alive;
    }

    function jurors() external view returns (address[] memory) {
        return graveyard;
    }

    function membersOf(uint8 team) external view returns (address[] memory) {
        return teamMembers[team];
    }

    /// @notice Teams with at least one surviving member.
    function aliveTeams() external view returns (uint8[] memory) {
        return _aliveTeams();
    }

    // ─── Internals ───────────────────────────────────────────────────────────────────────────

    function _currentRoundId() internal view returns (uint256) {
        if (rounds.length == 0) revert NoRounds();
        return rounds.length - 1;
    }

    function _aliveTeams() internal view returns (uint8[] memory) {
        uint8 count = config.teamCount;
        uint8[] memory buffer = new uint8[](count);
        uint256 found;
        for (uint8 t = 1; t <= count; ++t) {
            if (teamMembers[t].length != 0) buffer[found++] = t;
        }

        uint8[] memory result = new uint8[](found);
        for (uint256 i = 0; i < found; ++i) {
            result[i] = buffer[i];
        }
        return result;
    }

    /// @dev Post-merge candidate list, with the immune player removed if there is one.
    function _eliminableAlive(uint256 roundId) internal view returns (address[] memory) {
        address immune =
            address(immunitySource) == address(0) ? address(0) : immunitySource.immuneFor(roundId);
        if (immune == address(0) || !_isAlive(immune)) return alive;

        address[] memory result = new address[](alive.length - 1);
        uint256 cursor;
        for (uint256 i = 0; i < alive.length; ++i) {
            if (alive[i] != immune) result[cursor++] = alive[i];
        }
        return result;
    }

    function _isAlive(address account) internal view returns (bool) {
        return lifeToken.balanceOf(account) != 0;
    }

    function _isVoter(uint256 roundId, address account) internal view returns (bool) {
        address[] storage voters = rounds[roundId].voters;
        for (uint256 i = 0; i < voters.length; ++i) {
            if (voters[i] == account) return true;
        }
        return false;
    }

    /// @dev Burning LIFE and minting JURY together keeps the two rosters exactly complementary,
    ///      which is what lets the jury round reuse the same census machinery.
    function _eliminate(address player) internal {
        for (uint256 i = 0; i < alive.length; ++i) {
            if (alive[i] == player) {
                alive[i] = alive[alive.length - 1];
                alive.pop();
                break;
            }
        }

        uint8 team = teamOf[player];
        address[] storage members = teamMembers[team];
        for (uint256 i = 0; i < members.length; ++i) {
            if (members[i] == player) {
                members[i] = members[members.length - 1];
                members.pop();
                break;
            }
        }

        lifeToken.burn(player);
        juryToken.mint(player);
        graveyard.push(player);
    }
}
