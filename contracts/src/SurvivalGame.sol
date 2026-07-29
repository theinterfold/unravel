// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IInterfold} from "./interfaces/IInterfold.sol";
import {IE3Program} from "./interfaces/IE3.sol";
import {ICRISP} from "./interfaces/ICRISP.sol";
import {IImmunitySource} from "./interfaces/IImmunitySource.sol";
import {RosterToken} from "./RosterToken.sol";

/// @title SurvivalGame
/// @notice A social survival game whose eliminations are decided by secret ballot.
///
/// @dev One round is one E3. Each round runs three windows off a single set of timestamps:
///
///      ```
///      openedAt ────── campaign ──────▶ ballotOpensAt ── ballot ──▶ ballotClosesAt ── grace ──▶ settle
///        public posts, alliances          encrypted votes, re-votes      committee decrypts
///      ```
///
///      The campaign window exists for two reasons at once: it is where the social game happens,
///      and it is where committee sortition and the DKG run. The crypto latency is therefore free
///      rather than dead time — but it also means `campaignDuration` has a floor imposed by the
///      network, not just by taste.
///
///      Ballots are one-credit: `CreditMode.CONSTANT` with `credits = 1`, so a voter can put their
///      single credit on exactly one candidate (the circuit enforces `total <= balance`). Only
///      aggregate counts are ever revealed — the chain learns "3 for Alice, 2 for Bob", never who
///      cast what. That is what lets a player campaign for one outcome in public and vote for
///      another in private, which is the entire game.
///
///      The eligible voter set is served to the CRISP coordination server through
///      `getCensus(e3Id)`, so eligibility is exactly this contract's own roster rather than
///      something reconstructed from token transfer logs.
contract SurvivalGame is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on ballot candidates, mirroring `MAX_OPTIONS` in the CRISP circuit
    ///         (`circuits/lib/src/constants.nr`). Exceeding it produces a round whose votes cannot
    ///         be proven, so it is enforced here at round-open rather than discovered at proving
    ///         time — the on-chain CRISP program only checks the lower bound.
    uint256 public constant MAX_CANDIDATES = 10;

    /// @notice Every voter receives exactly one credit, making this one-player-one-vote.
    uint256 internal constant CREDITS_PER_VOTER = 1;

    /// @notice Candidate list index used to mean "no candidate".
    uint256 internal constant NO_INDEX = type(uint256).max;

    enum Stage {
        Lobby,
        Playing,
        Jury,
        Ended
    }

    struct Config {
        /// @notice Public campaign window. Also covers sortition + DKG, so it has a network floor.
        uint64 campaignDuration;
        /// @notice Encrypted voting window; becomes the E3 input window.
        uint64 ballotDuration;
        /// @notice Slack after the ballot closes before the tally is expected on-chain.
        uint64 tallyGrace;
        /// @notice Players required to start. Must be in 3..=MAX_CANDIDATES.
        uint8 rosterSize;
        /// @notice Survivors left when eliminations stop and the jury votes. Must be >= 2.
        uint8 finalists;
        /// @notice Consecutive missed check-ins before a player forfeits. 0 disables forfeits.
        uint8 maxMissedCheckIns;
        /// @notice Fee-token cost to join. May be 0.
        uint256 entryFee;
    }

    struct Round {
        uint256 e3Id;
        uint64 openedAt;
        uint64 ballotOpensAt;
        uint64 ballotClosesAt;
        bool settled;
        /// @notice Set on settle: eliminated player (elimination round) or winner (jury round).
        address outcome;
        /// @notice Ballot option index -> player. Pinned at open; immutable for the round.
        address[] candidates;
        /// @notice The eligible voter set for this round.
        address[] voters;
    }

    // ─── Immutable wiring ────────────────────────────────────────────────────────────────────

    IInterfold public immutable interfold;
    /// @notice The CRISP E3 program: validates round params and decodes the decrypted tally.
    address public immutable crispProgram;
    IERC20 public immutable feeToken;
    /// @notice Held by survivors. Burned on elimination.
    RosterToken public immutable lifeToken;
    /// @notice Minted on elimination. The jury that picks the winner.
    RosterToken public immutable juryToken;

    IInterfold.CommitteeSize internal immutable committeeSize;
    uint8 internal immutable paramSet;

    // ─── State ───────────────────────────────────────────────────────────────────────────────

    Config public config;
    Stage public stage;
    bytes internal computeProviderParams;

    /// @notice Optional public counterweight to the private ballot. Zero address disables it.
    IImmunitySource public immunitySource;

    /// @notice Players still holding a LIFE badge, in join order.
    address[] public alive;
    /// @notice Eliminated players, in elimination order. The jury.
    address[] public graveyard;
    /// @notice Winner of the jury vote. Set when `stage == Ended`.
    address public winner;

    Round[] internal rounds;
    /// @notice e3Id -> round index + 1 (0 means unknown), so `getCensus` can resolve a round.
    mapping(uint256 => uint256) internal roundByE3Id;

    /// @notice Last round in which a player checked in. Liveness is public on purpose: the ballot
    ///         is secret, so abstention is undetectable and cannot be the basis for a forfeit.
    mapping(address => uint256) public lastCheckIn;
    mapping(address => bool) public isPlayer;
    /// @notice Guards `pot` against fee-token donations being counted as prize money.
    uint256 public pot;

    // ─── Events ──────────────────────────────────────────────────────────────────────────────

    event PlayerJoined(address indexed player, uint256 entryFee);
    event GameStarted(uint256 rosterSize, uint256 potAmount);
    event RoundOpened(
        uint256 indexed round,
        uint256 indexed e3Id,
        uint64 ballotOpensAt,
        uint64 ballotClosesAt,
        address[] candidates,
        address[] voters
    );
    event Posted(uint256 indexed round, address indexed player, string cid);
    event CheckedIn(uint256 indexed round, address indexed player);
    event PlayerEliminated(uint256 indexed round, address indexed player, uint256[] counts);
    event PlayerForfeited(uint256 indexed round, address indexed player);
    event RoundVoid(uint256 indexed round, uint256 indexed e3Id);
    event RoundAborted(uint256 indexed round, uint256 indexed e3Id);
    event JuryPhaseReached(address[] finalists);
    event WinnerDeclared(address indexed player, uint256 prize);
    event ImmunitySourceUpdated(address indexed source);

    // ─── Errors ──────────────────────────────────────────────────────────────────────────────

    error WrongStage(Stage expected, Stage actual);
    error ZeroAddress();
    error InvalidConfig();
    error AlreadyJoined();
    error LobbyFull();
    error NotAPlayer();
    error NotAlive();
    error RosterIncomplete(uint256 have, uint256 need);
    error PreviousRoundUnsettled();
    error TooManyCandidates(uint256 count);
    error TooFewCandidates(uint256 count);
    error InsufficientPot(uint256 needed, uint256 available);
    error NotInCampaign();
    error BallotStillOpen(uint64 until);
    error TallyNotDue(uint64 until);
    error RoundAlreadySettled();
    error TallyLengthMismatch(uint256 expected, uint256 actual);
    error NoRounds();
    error NothingToWithdraw();

    // ─── Construction ────────────────────────────────────────────────────────────────────────

    struct InitParams {
        address owner;
        IInterfold interfold;
        address crispProgram;
        RosterToken lifeToken;
        RosterToken juryToken;
        IInterfold.CommitteeSize committeeSize;
        uint8 paramSet;
        bytes computeProviderParams;
        Config config;
    }

    constructor(InitParams memory params) Ownable(params.owner) {
        if (
            address(params.interfold) == address(0) || params.crispProgram == address(0)
                || address(params.lifeToken) == address(0) || address(params.juryToken) == address(0)
        ) revert ZeroAddress();

        Config memory cfg = params.config;
        // `finalists >= 2` because a jury needs at least two names to choose between, and
        // `rosterSize > finalists` because otherwise there is nothing to eliminate. The upper
        // bound is the circuit's, and the lower bound on durations keeps windows well-ordered.
        if (
            cfg.finalists < 2 || cfg.rosterSize <= cfg.finalists || cfg.rosterSize > MAX_CANDIDATES
                || cfg.campaignDuration == 0 || cfg.ballotDuration == 0
        ) revert InvalidConfig();

        interfold = params.interfold;
        crispProgram = params.crispProgram;
        lifeToken = params.lifeToken;
        juryToken = params.juryToken;
        committeeSize = params.committeeSize;
        paramSet = params.paramSet;
        computeProviderParams = params.computeProviderParams;
        config = cfg;
        feeToken = IERC20(params.interfold.feeToken());
        stage = Stage.Lobby;
    }

    // ─── Lobby ───────────────────────────────────────────────────────────────────────────────

    /// @notice Joins the game, paying the entry fee into the pot and receiving a LIFE badge.
    function join() external {
        if (stage != Stage.Lobby) revert WrongStage(Stage.Lobby, stage);
        if (isPlayer[msg.sender]) revert AlreadyJoined();
        if (alive.length >= config.rosterSize) revert LobbyFull();

        uint256 fee = config.entryFee;
        if (fee != 0) {
            feeToken.safeTransferFrom(msg.sender, address(this), fee);
            pot += fee;
        }

        isPlayer[msg.sender] = true;
        alive.push(msg.sender);
        lifeToken.mint(msg.sender);

        emit PlayerJoined(msg.sender, fee);
    }

    /// @notice Starts the game once the roster is full and opens round 0.
    /// @dev Permissionless: the roster being full is an objective condition, and leaving the start
    ///      to a privileged caller would let them stall a funded game indefinitely.
    function startGame() external {
        if (stage != Stage.Lobby) revert WrongStage(Stage.Lobby, stage);
        if (alive.length != config.rosterSize) revert RosterIncomplete(alive.length, config.rosterSize);

        stage = Stage.Playing;
        emit GameStarted(alive.length, pot);
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

        (address[] memory candidates, address[] memory voters) = _rosterFor(roundId);

        if (candidates.length > MAX_CANDIDATES) revert TooManyCandidates(candidates.length);
        // The circuit requires at least two options; a one-candidate ballot is also meaningless.
        if (candidates.length < 2) revert TooFewCandidates(candidates.length);

        uint64 ballotOpensAt = uint64(block.timestamp) + config.campaignDuration;
        uint64 ballotClosesAt = ballotOpensAt + config.ballotDuration;

        uint256 e3Id = _requestE3(candidates.length, ballotOpensAt, ballotClosesAt);

        rounds.push();
        Round storage round = rounds[roundId];
        round.e3Id = e3Id;
        round.openedAt = uint64(block.timestamp);
        round.ballotOpensAt = ballotOpensAt;
        round.ballotClosesAt = ballotClosesAt;
        round.candidates = candidates;
        round.voters = voters;

        roundByE3Id[e3Id] = roundId + 1;

        emit RoundOpened(roundId, e3Id, ballotOpensAt, ballotClosesAt, candidates, voters);
    }

    /// @dev Elimination rounds: everyone alive votes, everyone alive except the immune player is a
    ///      candidate. Jury round: the graveyard votes, the finalists are the candidates.
    function _rosterFor(uint256 roundId)
        internal
        view
        returns (address[] memory candidates, address[] memory voters)
    {
        if (stage == Stage.Jury) return (alive, graveyard);

        voters = alive;

        address immune =
            address(immunitySource) == address(0) ? address(0) : immunitySource.immuneFor(roundId);
        if (immune == address(0) || !_isAlive(immune)) return (alive, voters);

        candidates = new address[](alive.length - 1);
        uint256 cursor;
        for (uint256 i; i < alive.length; ++i) {
            if (alive[i] != immune) candidates[cursor++] = alive[i];
        }
    }

    function _requestE3(uint256 numOptions, uint64 ballotOpensAt, uint64 ballotClosesAt)
        internal
        returns (uint256 e3Id)
    {
        IInterfold.E3RequestParams memory params =
            _buildRequestParams(numOptions, ballotOpensAt, ballotClosesAt);

        uint256 fee = interfold.getE3Quote(params);
        if (fee > pot) revert InsufficientPot(fee, pot);
        unchecked {
            pot -= fee;
        }

        feeToken.forceApprove(address(interfold), fee);
        (e3Id,) = interfold.request(params);
    }

    function _buildRequestParams(uint256 numOptions, uint64 ballotOpensAt, uint64 ballotClosesAt)
        internal
        view
        returns (IInterfold.E3RequestParams memory)
    {
        // The token here only names the eligibility source for requesters that do not serve their
        // own census; this contract does, via `getCensus`. It is still set to the round's roster
        // token so the round is self-describing to anything reading `customParams`.
        address rosterToken = stage == Stage.Jury ? address(juryToken) : address(lifeToken);

        bytes memory customParams = abi.encode(
            rosterToken,
            uint256(0), // balance threshold: unused under CONSTANT credits
            numOptions,
            ICRISP.CreditMode.CONSTANT,
            CREDITS_PER_VOTER
        );

        return IInterfold.E3RequestParams({
            committeeSize: committeeSize,
            inputWindow: [uint256(ballotOpensAt), uint256(ballotClosesAt)],
            e3Program: IE3Program(crispProgram),
            paramSet: paramSet,
            computeProviderParams: computeProviderParams,
            customParams: customParams,
            proofAggregationEnabled: false
        });
    }

    // ─── The census hook ─────────────────────────────────────────────────────────────────────

    /// @notice The eligible voter set for an E3, read by the CRISP coordination server.
    /// @dev This is what makes elimination actually eliminate. Reconstructing eligibility from
    ///      token-holder logs is both approximate and, on a local devnet, not available at all;
    ///      the roster is authoritative here and costs one `eth_call`.
    ///
    ///      Returns *voters*, not candidates — the two differ in the jury round, where the
    ///      graveyard votes on the finalists. Candidates come from `candidatesOf`.
    function getCensus(uint256 e3Id) external view returns (address[] memory) {
        uint256 slot = roundByE3Id[e3Id];
        if (slot == 0) return new address[](0);
        return rounds[slot - 1].voters;
    }

    // ─── Campaign ────────────────────────────────────────────────────────────────────────────

    /// @notice Publishes a campaign message (an IPFS CID) for the current round.
    /// @dev Attributable and public by design: it is the commitment surface the secret ballot is
    ///      played against. Content lives off-chain; only the pointer is recorded.
    function post(string calldata cid) external {
        uint256 roundId = _currentRoundId();
        if (block.timestamp >= rounds[roundId].ballotOpensAt) revert NotInCampaign();
        if (!_isVoter(roundId, msg.sender)) revert NotAPlayer();

        emit Posted(roundId, msg.sender, cid);
    }

    /// @notice Records liveness for the current round.
    /// @dev Forfeits cannot key off abstention: ballots are secret and mask votes make slot
    ///      activity meaningless, so the chain genuinely cannot tell who voted. Check-in is the
    ///      public liveness signal instead, and it leaks nothing about the ballot.
    function checkIn() external {
        uint256 roundId = _currentRoundId();
        if (!_isAlive(msg.sender)) revert NotAlive();

        lastCheckIn[msg.sender] = roundId + 1;
        emit CheckedIn(roundId, msg.sender);
    }

    /// @dev Culls players who have missed `maxMissedCheckIns` consecutive check-ins, but never
    ///      below the finalist count — a forfeit must not be able to end the game by itself.
    function _applyForfeits(uint256 roundId) internal {
        uint8 limit = config.maxMissedCheckIns;
        if (limit == 0 || roundId <= limit) return;

        uint256 floorCount = config.finalists;
        for (uint256 i = alive.length; i > 0; --i) {
            if (alive.length <= floorCount) return;

            address player = alive[i - 1];
            // `lastCheckIn` stores round + 1, so 0 means "never checked in".
            uint256 seen = lastCheckIn[player];
            uint256 missed = seen == 0 ? roundId : roundId - (seen - 1);
            if (missed > limit) {
                _eliminate(player);
                emit PlayerForfeited(roundId, player);
            }
        }
    }

    // ─── Settlement ──────────────────────────────────────────────────────────────────────────

    /// @notice Settles the current round from the decrypted tally.
    /// @dev Permissionless: the tally is already public and the outcome is a pure function of it,
    ///      so there is nothing for a caller to influence.
    function settleRound() external {
        uint256 roundId = _currentRoundId();
        Round storage round = rounds[roundId];

        if (round.settled) revert RoundAlreadySettled();
        uint64 due = round.ballotClosesAt + config.tallyGrace;
        if (block.timestamp < due) revert TallyNotDue(due);

        uint256[] memory counts = ICRISP(crispProgram).decodeTally(round.e3Id);
        if (counts.length != round.candidates.length) {
            revert TallyLengthMismatch(round.candidates.length, counts.length);
        }

        (uint256 index, uint256 total) = _resolveWinningIndex(round.e3Id, counts);

        round.settled = true;

        // Nobody voted: there is no mandate to eliminate anyone. The round is void and the next
        // one re-runs with the same roster rather than picking a victim arbitrarily.
        if (total == 0) {
            emit RoundVoid(roundId, round.e3Id);
            return;
        }

        address chosen = round.candidates[index];
        round.outcome = chosen;

        if (stage == Stage.Jury) {
            winner = chosen;
            stage = Stage.Ended;
            uint256 prize = pot;
            pot = 0;
            if (prize != 0) feeToken.safeTransfer(chosen, prize);
            emit WinnerDeclared(chosen, prize);
            return;
        }

        _eliminate(chosen);
        emit PlayerEliminated(roundId, chosen, counts);

        if (alive.length == config.finalists) {
            stage = Stage.Jury;
            emit JuryPhaseReached(alive);
        }
    }

    /// @dev Returns the index of the highest-polling candidate and the total votes cast.
    ///
    ///      Ties are frequent at small rosters, so they get a defined rule rather than an
    ///      accident of iteration order: the winner is drawn from the tied set using the tally
    ///      itself as the entropy. Because the counts are fixed by the time this runs, the draw is
    ///      deterministic and verifiable, and no proposer or player can grind it — unlike
    ///      `block.prevrandao`, which the block producer influences.
    function _resolveWinningIndex(uint256 e3Id, uint256[] memory counts)
        internal
        pure
        returns (uint256 index, uint256 total)
    {
        uint256 highest;
        uint256 tied;

        for (uint256 i; i < counts.length; ++i) {
            total += counts[i];
            if (counts[i] > highest) {
                highest = counts[i];
                tied = 1;
            } else if (counts[i] == highest && highest != 0) {
                ++tied;
            }
        }

        if (total == 0) return (NO_INDEX, 0);
        if (tied == 1) {
            for (uint256 i; i < counts.length; ++i) {
                if (counts[i] == highest) return (i, total);
            }
        }

        uint256 pick = uint256(keccak256(abi.encode(e3Id, counts))) % tied;
        for (uint256 i; i < counts.length; ++i) {
            if (counts[i] == highest) {
                if (pick == 0) return (i, total);
                --pick;
            }
        }

        revert("unreachable");
    }

    /// @notice Abandons a round whose E3 never produced a tally, so the game can re-open it.
    /// @dev The E3 fee for the failed round is not recovered here; `IE3RefundManager` pays the
    ///      requester and claiming it is a separate, permissionless step.
    function abortRound() external onlyOwner {
        uint256 roundId = _currentRoundId();
        Round storage round = rounds[roundId];

        if (round.settled) revert RoundAlreadySettled();
        uint64 due = round.ballotClosesAt + config.tallyGrace;
        if (block.timestamp < due) revert TallyNotDue(due);

        round.settled = true;
        emit RoundAborted(roundId, round.e3Id);
    }

    // ─── Treasury ────────────────────────────────────────────────────────────────────────────

    /// @notice Funds the pot, which pays E3 fees each round and the winner's prize at the end.
    function fund(uint256 amount) external {
        feeToken.safeTransferFrom(msg.sender, address(this), amount);
        pot += amount;
    }

    /// @notice Recovers leftover pot after the game has ended.
    function sweep(address to) external onlyOwner {
        if (stage != Stage.Ended) revert WrongStage(Stage.Ended, stage);
        uint256 amount = pot;
        if (amount == 0) revert NothingToWithdraw();
        pot = 0;
        feeToken.safeTransfer(to, amount);
    }

    /// @notice Sets the optional public immunity mechanism. Zero address disables it.
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

    /// @notice Ballot option index -> player, for the given round.
    function candidatesOf(uint256 roundId) external view returns (address[] memory) {
        return rounds[roundId].candidates;
    }

    function votersOf(uint256 roundId) external view returns (address[] memory) {
        return rounds[roundId].voters;
    }

    function getRound(uint256 roundId)
        external
        view
        returns (
            uint256 e3Id,
            uint64 openedAt,
            uint64 ballotOpensAt,
            uint64 ballotClosesAt,
            bool settled,
            address outcome
        )
    {
        Round storage round = rounds[roundId];
        return
            (
                round.e3Id,
                round.openedAt,
                round.ballotOpensAt,
                round.ballotClosesAt,
                round.settled,
                round.outcome
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

    // ─── Internals ───────────────────────────────────────────────────────────────────────────

    function _currentRoundId() internal view returns (uint256) {
        if (rounds.length == 0) revert NoRounds();
        return rounds.length - 1;
    }

    function _isAlive(address account) internal view returns (bool) {
        return lifeToken.balanceOf(account) != 0;
    }

    function _isVoter(uint256 roundId, address account) internal view returns (bool) {
        address[] storage voters = rounds[roundId].voters;
        for (uint256 i; i < voters.length; ++i) {
            if (voters[i] == account) return true;
        }
        return false;
    }

    /// @dev Burning LIFE and minting JURY in one step keeps the two rosters exactly complementary,
    ///      which is what lets the jury round reuse the same census machinery.
    function _eliminate(address player) internal {
        for (uint256 i; i < alive.length; ++i) {
            if (alive[i] == player) {
                alive[i] = alive[alive.length - 1];
                alive.pop();
                break;
            }
        }

        lifeToken.burn(player);
        juryToken.mint(player);
        graveyard.push(player);
    }
}
