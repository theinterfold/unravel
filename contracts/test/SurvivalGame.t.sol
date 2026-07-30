// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {ICrispVotingPlugin} from "../src/interfaces/ICrispVotingPlugin.sol";
import {IImmunitySource} from "../src/interfaces/IImmunitySource.sol";
import {MockFeeToken, MockPlugin, MockImmunitySource} from "./mocks/Mocks.sol";

contract SurvivalGameTest is Test {
    SurvivalGame internal game;
    RosterToken internal life;
    RosterToken internal jury;
    MockFeeToken internal fee;
    MockPlugin internal plugin;

    address internal owner = address(0xA11CE);

    uint64 internal constant CAMPAIGN = 20 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint256 internal constant FEE = 1 ether;
    uint256 internal constant ENTRY_FEE = 100 ether;

    uint8 internal constant TEAMS = 3;
    uint8 internal constant PER_TEAM = 3;
    uint8 internal constant MERGE_AT = 4;
    uint8 internal constant FINALISTS = 2;

    address[] internal players;

    function setUp() public {
        fee = new MockFeeToken();
        plugin = new MockPlugin(IERC20(address(fee)), FEE);
        _deploy(TEAMS, PER_TEAM, MERGE_AT, FINALISTS, 0);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────────────────

    function _deploy(uint8 teams, uint8 perTeam, uint8 mergeAt, uint8 finalists, uint8 maxMissed) internal {
        _deployWithFee(teams, perTeam, mergeAt, finalists, maxMissed, ENTRY_FEE);
    }

    function _deployWithFee(
        uint8 teams,
        uint8 perTeam,
        uint8 mergeAt,
        uint8 finalists,
        uint8 maxMissed,
        uint256 entryFee
    ) internal {
        vm.startPrank(owner);
        life = new RosterToken("Life", "LIFE", owner);
        jury = new RosterToken("Jury", "JURY", owner);
        game = new SurvivalGame(_params(teams, perTeam, mergeAt, finalists, maxMissed, entryFee));
        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));
        vm.stopPrank();

        delete players;
        for (uint256 i; i < uint256(teams) * uint256(perTeam); ++i) {
            players.push(address(uint160(0x1000 + i)));
        }
    }

    /// @dev Built separately so a revert test can arm `expectRevert` immediately before the
    ///      `SurvivalGame` constructor. Arming it before a helper that also deploys the tokens would
    ///      catch `new RosterToken` instead, which never reverts — the test would fail while the
    ///      contract behaved correctly.
    function _params(
        uint8 teams,
        uint8 perTeam,
        uint8 mergeAt,
        uint8 finalists,
        uint8 maxMissed,
        uint256 entryFee
    ) internal view returns (SurvivalGame.InitParams memory) {
        return SurvivalGame.InitParams({
            owner: owner,
            plugin: ICrispVotingPlugin(address(plugin)),
            feeToken: IERC20(address(fee)),
            lifeToken: life,
            juryToken: jury,
            config: SurvivalGame.Config({
                campaignDuration: CAMPAIGN,
                ballotDuration: BALLOT,
                tallyGrace: GRACE,
                teamCount: teams,
                membersPerTeam: perTeam,
                // Existing tests all assume a full lobby is required. Early-start behaviour is
                // covered separately via `_paramsWithMin`.
                minPlayers: teams * perTeam,
                mergeAt: mergeAt,
                finalists: finalists,
                maxMissedCheckIns: maxMissed,
                entryFee: entryFee
            })
        });
    }

    /// @dev Redeploys the game with a lobby floor, re-minting the tokens it owns.
    function _deployWithMin(uint8 teams, uint8 perTeam, uint8 mergeAt, uint8 finalists, uint8 minPlayers)
        internal
    {
        vm.startPrank(owner);
        life = new RosterToken("Life", "LIFE", owner);
        jury = new RosterToken("Jury", "JURY", owner);
        SurvivalGame.InitParams memory p = _paramsWithMin(teams, perTeam, mergeAt, finalists, minPlayers);
        p.lifeToken = life;
        p.juryToken = jury;
        game = new SurvivalGame(p);
        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));
        vm.stopPrank();

        // These games have no entry fee, so nothing flows into the pot from joining — and every
        // round's E3 fee is paid from the pot. Fund it directly.
        fee.mint(owner, FEE * 10);
        vm.startPrank(owner);
        fee.approve(address(game), FEE * 10);
        game.fund(FEE * 10);
        vm.stopPrank();

        delete players;
        for (uint256 i; i < uint256(teams) * uint256(perTeam); ++i) {
            players.push(address(uint160(0x1000 + i)));
        }
    }

    /// @dev `_params` with an explicit lobby floor, for the early-start tests.
    function _paramsWithMin(uint8 teams, uint8 perTeam, uint8 mergeAt, uint8 finalists, uint8 minPlayers)
        internal
        view
        returns (SurvivalGame.InitParams memory)
    {
        SurvivalGame.InitParams memory params = _params(teams, perTeam, mergeAt, finalists, 0, 0);
        params.config.minPlayers = minPlayers;
        return params;
    }

    /// @dev Seats `count` players, spreading them across teams the way `_fillLobby` would.
    function _seat(uint256 count, uint8 perTeam) internal {
        for (uint256 i; i < count; ++i) {
            vm.prank(players[i]);
            game.join(uint8(i / perTeam) + 1);
        }
    }

    /// @dev Seats `count` players all onto one team, to exercise the single-team start.
    function _seatOneTeam(uint256 count, uint8 team) internal {
        for (uint256 i; i < count; ++i) {
            vm.prank(players[i]);
            game.join(team);
        }
    }

    /// @dev Fills every team in order: player i joins team (i / perTeam) + 1.
    function _fillLobby(uint8 perTeam) internal {
        for (uint256 i; i < players.length; ++i) {
            fee.mint(players[i], ENTRY_FEE);
            vm.startPrank(players[i]);
            fee.approve(address(game), ENTRY_FEE);
            game.join(uint8(i / perTeam) + 1);
            vm.stopPrank();
        }
    }

    function _start() internal {
        _fillLobby(PER_TEAM);
        game.startGame();
    }

    function _warpToSettle() internal {
        (,,,,, uint64 closesAt,,,) = game.getRound(game.currentRoundId());
        vm.warp(closesAt + GRACE);
    }

    /// @dev Settles the current round with all votes on one option index.
    function _settleOn(uint256 optionIndex) internal {
        uint256 roundId = game.currentRoundId();
        (, uint256 proposalId,,,,,,,) = game.getRound(roundId);
        uint256 n = _optionCount(roundId);

        uint256[] memory counts = new uint256[](n);
        counts[optionIndex] = 3;
        plugin.setTally(proposalId, counts);
        _warpToSettle();
        game.settleRound();
    }

    function _optionCount(uint256 roundId) internal view returns (uint256) {
        (SurvivalGame.RoundKind kind,,,,,,,,) = game.getRound(roundId);
        return kind == SurvivalGame.RoundKind.Tribal
            ? game.candidateTeamsOf(roundId).length
            : game.candidatesOf(roundId).length;
    }

    function _kind(uint256 roundId) internal view returns (SurvivalGame.RoundKind kind) {
        (kind,,,,,,,,) = game.getRound(roundId);
    }

    // ─── Lobby and teams ─────────────────────────────────────────────────────────────────────

    function test_join_assignsTeamAndMintsLife() public {
        fee.mint(players[0], ENTRY_FEE);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE);
        game.join(2);
        vm.stopPrank();

        assertEq(game.teamOf(players[0]), 2);
        assertEq(game.membersOf(2).length, 1);
        assertEq(life.balanceOf(players[0]), life.UNIT());
        assertEq(life.getVotes(players[0]), life.UNIT(), "auto-delegated on mint");
    }

    function test_join_rejectsInvalidTeam() public {
        fee.mint(players[0], ENTRY_FEE);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.InvalidTeam.selector, uint8(0)));
        game.join(0);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.InvalidTeam.selector, TEAMS + 1));
        game.join(TEAMS + 1);
        vm.stopPrank();
    }

    function test_join_rejectsFullTeam() public {
        for (uint256 i; i < PER_TEAM; ++i) {
            fee.mint(players[i], ENTRY_FEE);
            vm.startPrank(players[i]);
            fee.approve(address(game), ENTRY_FEE);
            game.join(1);
            vm.stopPrank();
        }

        address extra = players[PER_TEAM];
        fee.mint(extra, ENTRY_FEE);
        vm.startPrank(extra);
        fee.approve(address(game), ENTRY_FEE);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.TeamFull.selector, uint8(1)));
        game.join(1);
        vm.stopPrank();
    }

    // ─── Starting under-full ─────────────────────────────────────────────────────────────────

    /// @dev The point of `minPlayers`: a lobby that has reached its floor plays, rather than being
    ///      held hostage by whoever has not shown up.
    function test_startGame_atTheFloorWithEmptySeats() public {
        _deployWithMin(4, 3, 6, 2, 5);
        _seat(5, 3);

        game.startGame();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Playing));
        assertEq(game.aliveCount(), 5);
        assertEq(game.roundCount(), 1);
    }

    function test_startGame_belowTheFloorReverts() public {
        _deployWithMin(4, 3, 6, 2, 5);
        _seat(4, 3);

        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.LobbyIncomplete.selector, 4, 5));
        game.startGame();
    }

    /// @dev Seats stay open until someone starts, so joining above the floor is still allowed.
    function test_startGame_aboveTheFloorIsAllowed() public {
        _deployWithMin(4, 3, 6, 2, 5);
        _seat(7, 3);

        game.startGame();

        assertEq(game.aliveCount(), 7);
    }

    /// @dev The shape of a round is derived, never assumed. With everyone on one team there is only
    ///      one alive team, so the first round must be individual rather than an unprovable
    ///      one-option tribal ballot.
    function test_startGame_singleTeamOpensAnIndividualRound() public {
        _deployWithMin(4, 3, 6, 2, 3);
        _seatOneTeam(3, 1);

        game.startGame();

        (SurvivalGame.RoundKind kind,,,,,,,,) = game.getRound(0);
        assertEq(uint8(kind), uint8(SurvivalGame.RoundKind.Individual));
        assertEq(game.candidatesOf(0).length, 3);
    }

    /// @dev Above the merge threshold with two teams populated, the first round is tribal — two
    ///      options — and whichever team loses has a single member who goes without a council round.
    function test_startGame_twoPopulatedTeamsStillTribal() public {
        _deployWithMin(4, 3, 3, 2, 4);
        vm.prank(players[0]);
        game.join(1);
        vm.prank(players[1]);
        game.join(2);
        vm.prank(players[2]);
        game.join(1);
        vm.prank(players[3]);
        game.join(2);

        game.startGame();

        (SurvivalGame.RoundKind kind,,,,,,,,) = game.getRound(0);
        assertEq(uint8(kind), uint8(SurvivalGame.RoundKind.Tribal));
        assertEq(game.candidateTeamsOf(0).length, 2);
    }

    /// @dev The interaction worth knowing about: `mergeAt` is checked before team count, so a floor
    ///      at or below `mergeAt` means the game is post-merge from its very first round and no
    ///      tribal or council round ever happens. That is coherent — a handful of players is not
    ///      four tribes — but it makes the team configuration decorative, so it is pinned here
    ///      rather than left to be rediscovered.
    function test_startGame_atOrBelowMergeSkipsTribesEntirely() public {
        _deployWithMin(4, 3, 6, 2, 4);
        _seat(4, 3);

        game.startGame();

        (SurvivalGame.RoundKind kind,,,,,,,,) = game.getRound(0);
        assertEq(uint8(kind), uint8(SurvivalGame.RoundKind.Individual));
    }

    /// @dev A floor at or below the finalist count would start a game that is already over.
    function test_constructor_rejectsFloorAtOrBelowFinalists() public {
        SurvivalGame.InitParams memory p = _paramsWithMin(4, 3, 6, 2, 2);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(p);
    }

    function test_constructor_rejectsFloorAboveTheLobby() public {
        SurvivalGame.InitParams memory p = _paramsWithMin(4, 3, 6, 2, 13);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(p);
    }

    function test_startGame_requiresEveryTeamFull() public {
        fee.mint(players[0], ENTRY_FEE);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE);
        game.join(1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.LobbyIncomplete.selector, 1, 9));
        game.startGame();
    }

    /// @dev Both team count and team size are ballot option counts, so both are bounded by the
    ///      circuit's MAX_OPTIONS. Exceeding either would produce an unprovable round.
    function test_constructor_rejectsTeamCountAboveCircuitBound() public {
        SurvivalGame.InitParams memory p = _params(11, 2, 4, 2, 0, ENTRY_FEE);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(p);
    }

    function test_constructor_rejectsTeamSizeAboveCircuitBound() public {
        SurvivalGame.InitParams memory p = _params(2, 11, 4, 2, 0, ENTRY_FEE);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(p);
    }

    function test_constructor_rejectsMergeAtBelowFinalists() public {
        SurvivalGame.InitParams memory p = _params(3, 3, 1, 2, 0, ENTRY_FEE);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(p);
    }

    function test_constructor_rejectsSingleTeam() public {
        SurvivalGame.InitParams memory p = _params(1, 4, 3, 2, 0, ENTRY_FEE);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(p);
    }

    // ─── Tribal round ────────────────────────────────────────────────────────────────────────

    function test_firstRoundIsTribalOverTeams() public {
        _start();

        assertEq(uint8(_kind(0)), uint8(SurvivalGame.RoundKind.Tribal));
        assertEq(game.candidateTeamsOf(0).length, TEAMS, "one option per surviving team");
        assertEq(game.candidatesOf(0).length, 0, "tribal ballots have no player options");
        assertEq(game.votersOf(0).length, 9, "everyone alive votes");
    }

    function test_tribalBallotIsOneCreditConstant() public {
        _start();

        (
            uint256 allowFailureMap,
            uint256 numOptions,
            uint256 creditMode,
            uint256 credits,
            uint256 electorate
        ) = abi.decode(plugin.lastData(), (uint256, uint256, uint256, uint256, uint256));

        assertEq(allowFailureMap, 0);
        assertEq(numOptions, TEAMS);
        assertEq(creditMode, 0, "CreditMode.CONSTANT");
        assertEq(credits, 1, "one player, one vote");
        assertEq(electorate, 9, "declared electorate lets the plugin compute quorum");
    }

    function test_tribalSendsTeamToCouncil() public {
        _start();
        uint8[] memory teams = game.candidateTeamsOf(0);
        _settleOn(1); // condemn the second listed team

        (,,,,,,, address outcome, uint8 target) = game.getRound(0);
        assertEq(target, teams[1]);
        assertEq(outcome, address(0), "a tribal round eliminates nobody by itself");
        assertEq(game.aliveCount(), 9);
    }

    function test_councilFollowsTribalAndOnlyThatTeamVotes() public {
        _start();
        uint8[] memory teams = game.candidateTeamsOf(0);
        _settleOn(1);
        game.openRound();

        assertEq(uint8(_kind(1)), uint8(SurvivalGame.RoundKind.Council));
        address[] memory members = game.membersOf(teams[1]);
        assertEq(game.candidatesOf(1).length, members.length);
        assertEq(game.votersOf(1).length, members.length, "only the condemned team votes");

        // The whole point of the two-stage round: a majority cannot pick the victim directly.
        assertEq(game.votersOf(1).length, PER_TEAM);
        assertLt(game.votersOf(1).length, game.aliveCount());
    }

    function test_councilEliminatesFromThatTeamOnly() public {
        _start();
        uint8[] memory teams = game.candidateTeamsOf(0);
        _settleOn(1);
        game.openRound();

        address[] memory candidates = game.candidatesOf(1);
        _settleOn(0);

        (,,,,,,, address outcome,) = game.getRound(1);
        assertEq(outcome, candidates[0]);
        assertEq(game.teamOf(candidates[0]), teams[1], "victim came from the condemned team");
        assertEq(game.aliveCount(), 8);
        assertEq(life.balanceOf(candidates[0]), 0);
        assertEq(jury.balanceOf(candidates[0]), jury.UNIT());
        assertEq(game.membersOf(teams[1]).length, PER_TEAM - 1);
    }

    /// @dev A one-member team has nobody to deliberate over, and a one-option ballot is unprovable.
    function test_singleMemberTeamIsEliminatedWithoutACouncil() public {
        _deploy(3, 1, 2, 2, 0);
        _fillLobby(1);
        game.startGame();

        uint8[] memory teams = game.candidateTeamsOf(0);
        address doomed = game.membersOf(teams[0])[0];
        _settleOn(0);

        (,,,,,,, address outcome,) = game.getRound(0);
        assertEq(outcome, doomed, "resolved inside the tribal round");
        assertEq(game.aliveCount(), 2);

        // No council convenes, because there is nothing to decide.
        game.openRound();
        assertTrue(_kind(1) != SurvivalGame.RoundKind.Council);
    }

    // ─── Merge ───────────────────────────────────────────────────────────────────────────────

    function test_teamsDissolveAtMergeThreshold() public {
        _start();

        // Grind down to the merge threshold.
        while (game.aliveCount() > MERGE_AT) {
            uint256 roundId = game.currentRoundId();
            if (_kind(roundId) == SurvivalGame.RoundKind.Tribal) {
                _settleOn(0);
                (,,,,,,, address outcome,) = game.getRound(roundId);
                if (outcome == address(0)) {
                    game.openRound();
                    _settleOn(0);
                }
            } else {
                _settleOn(0);
            }
            if (game.stage() != SurvivalGame.Stage.Playing) break;
            game.openRound();
        }

        assertEq(game.aliveCount(), MERGE_AT);
        assertEq(uint8(_kind(game.currentRoundId())), uint8(SurvivalGame.RoundKind.Individual));
        assertEq(game.candidatesOf(game.currentRoundId()).length, MERGE_AT, "everyone is a candidate");
        assertEq(game.votersOf(game.currentRoundId()).length, MERGE_AT, "everyone votes");
    }

    /// @dev Teams also stop mattering when only one is left, even above the merge threshold.
    function test_lastTeamStandingSwitchesToIndividual() public {
        _deploy(2, 5, 3, 2, 0);
        _fillLobby(5);
        game.startGame();

        uint8[] memory teams = game.candidateTeamsOf(0);
        // Wipe out team `teams[0]` entirely.
        for (uint256 i; i < 5; ++i) {
            uint256 roundId = game.currentRoundId();
            if (_kind(roundId) == SurvivalGame.RoundKind.Tribal) {
                uint8[] memory options = game.candidateTeamsOf(roundId);
                uint256 idx = options[0] == teams[0] ? 0 : 1;
                _settleOn(idx);
                (,,,,,,, address outcome,) = game.getRound(roundId);
                if (outcome == address(0)) {
                    game.openRound();
                    _settleOn(0);
                }
            } else {
                _settleOn(0);
            }
            if (game.stage() != SurvivalGame.Stage.Playing) break;
            game.openRound();
        }

        assertEq(game.membersOf(teams[0]).length, 0, "team wiped out");
        assertEq(uint8(_kind(game.currentRoundId())), uint8(SurvivalGame.RoundKind.Individual));
    }

    // ─── Census ──────────────────────────────────────────────────────────────────────────────

    function test_census_isEveryoneForTribal() public {
        _start();
        (,, uint256 e3Id,,,,,,) = game.getRound(0);
        assertEq(game.getCensus(e3Id).length, 9);
    }

    /// @dev The census is per-round-type, not just "the living" — this is the property that makes
    ///      the two-stage round meaningful rather than decorative.
    function test_census_isOnlyTheCondemnedTeamForCouncil() public {
        _start();
        _settleOn(1);
        game.openRound();

        (,, uint256 e3Id,,,,,,) = game.getRound(1);
        address[] memory census = game.getCensus(e3Id);
        assertEq(census.length, PER_TEAM);

        uint8 target = game.teamOf(census[0]);
        for (uint256 i; i < census.length; ++i) {
            assertEq(game.teamOf(census[i]), target, "census confined to one team");
        }
    }

    function test_census_isEmptyForUnknownE3() public view {
        assertEq(game.getCensus(9999).length, 0);
    }

    // ─── Settlement rules ────────────────────────────────────────────────────────────────────

    function test_settle_voidsWhenNobodyVoted() public {
        _start();
        (, uint256 proposalId,,,,,,,) = game.getRound(0);
        plugin.setTally(proposalId, new uint256[](TEAMS));
        _warpToSettle();
        game.settleRound();

        assertEq(game.aliveCount(), 9);
        (,,,,,,, address outcome, uint8 target) = game.getRound(0);
        assertEq(outcome, address(0));
        assertEq(target, 0, "a void tribal round condemns nobody");
    }

    /// @dev A void tribal round must not leave a council round convening against team 0.
    function test_settle_voidTribalIsFollowedByAnotherTribal() public {
        _start();
        (, uint256 proposalId,,,,,,,) = game.getRound(0);
        plugin.setTally(proposalId, new uint256[](TEAMS));
        _warpToSettle();
        game.settleRound();

        game.openRound();
        assertEq(uint8(_kind(1)), uint8(SurvivalGame.RoundKind.Tribal));
    }

    function test_settle_revertsBeforeTallyIsDue() public {
        _start();
        (,,,,, uint64 closesAt,,,) = game.getRound(0);
        vm.warp(closesAt + GRACE - 1);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.TallyNotDue.selector, closesAt + GRACE));
        game.settleRound();
    }

    function test_settle_revertsOnTallyLengthMismatch() public {
        _start();
        (, uint256 proposalId,,,,,,,) = game.getRound(0);
        plugin.setTally(proposalId, new uint256[](2));
        _warpToSettle();
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.TallyLengthMismatch.selector, TEAMS, 2));
        game.settleRound();
    }

    function test_settle_cannotSettleTwice() public {
        _start();
        _settleOn(0);
        vm.expectRevert(SurvivalGame.RoundAlreadySettled.selector);
        game.settleRound();
    }

    function test_settle_breaksTiesFromTheTiedSet() public {
        _start();
        (, uint256 proposalId,, uint256 e3Id,,,,,) = game.getRound(0);
        e3Id = 0; // first round's E3
        uint8[] memory teams = game.candidateTeamsOf(0);

        uint256[] memory counts = new uint256[](TEAMS);
        counts[0] = 2;
        counts[2] = 2;
        plugin.setTally(proposalId, counts);
        _warpToSettle();
        game.settleRound();

        (,,,,,,,, uint8 target) = game.getRound(0);
        assertTrue(target == teams[0] || target == teams[2], "picked from the tied set");
    }

    // ─── Fees ────────────────────────────────────────────────────────────────────────────────

    function test_openRound_paysTheFeeFromThePot() public {
        _start();
        assertEq(game.pot(), ENTRY_FEE * 9 - FEE);
    }

    /// @dev Free entry leaves nothing to pay the Interfold fee with, and the plugin pulls that fee
    ///      from the game. Failing at round-open is the honest place for it: the alternative is a
    ///      lobby that fills and then cannot start.
    function test_openRound_revertsWithAnEmptyPot() public {
        _deployWithFee(3, 3, 4, 2, 0, 0);
        for (uint256 i; i < players.length; ++i) {
            vm.prank(players[i]);
            game.join(uint8(i / PER_TEAM) + 1);
        }

        assertEq(game.pot(), 0);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.InsufficientPot.selector, 1, 0));
        game.startGame();
    }

    function test_fund_topsUpThePot() public {
        _deployWithFee(3, 3, 4, 2, 0, 0);
        for (uint256 i; i < players.length; ++i) {
            vm.prank(players[i]);
            game.join(uint8(i / PER_TEAM) + 1);
        }

        fee.mint(owner, 10 ether);
        vm.startPrank(owner);
        fee.approve(address(game), 10 ether);
        game.fund(10 ether);
        vm.stopPrank();

        game.startGame();
        assertEq(game.pot(), 10 ether - FEE);
    }

    // ─── Endgame ─────────────────────────────────────────────────────────────────────────────

    function test_juryVoteDeclaresWinnerAndPaysThePot() public {
        _deploy(2, 2, 2, 2, 0);
        _fillLobby(2);
        game.startGame();

        // Two teams of two: grind to two survivors.
        while (game.stage() == SurvivalGame.Stage.Playing) {
            uint256 roundId = game.currentRoundId();
            _settleOn(0);
            (,,,,,,, address outcome,) = game.getRound(roundId);
            if (_kind(roundId) == SurvivalGame.RoundKind.Tribal && outcome == address(0)) {
                game.openRound();
                _settleOn(0);
            }
            if (game.stage() != SurvivalGame.Stage.Playing) break;
            game.openRound();
        }

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Jury));
        assertEq(game.aliveCount(), 2);

        game.openRound();
        uint256 juryRound = game.currentRoundId();
        assertEq(uint8(_kind(juryRound)), uint8(SurvivalGame.RoundKind.Jury));
        assertEq(game.candidatesOf(juryRound).length, 2, "the finalists are the options");
        assertEq(game.votersOf(juryRound).length, 2, "the graveyard votes");

        address[] memory finalists = game.candidatesOf(juryRound);
        uint256 prize = game.pot();
        _settleOn(1);

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Ended));
        assertEq(game.winner(), finalists[1]);
        assertEq(fee.balanceOf(finalists[1]), prize);
        assertEq(life.balanceOf(finalists[0]), life.UNIT(), "runner-up keeps their badge");
    }

    // ─── Campaign and liveness ───────────────────────────────────────────────────────────────

    function test_post_onlyVotersDuringCampaign() public {
        _start();
        vm.prank(players[0]);
        game.post("QmCid");

        vm.prank(address(0xDEAD));
        vm.expectRevert(SurvivalGame.NotAVoter.selector);
        game.post("QmCid");
    }

    /// @dev In a council round the electorate narrows, so who may post narrows with it.
    function test_post_restrictedToTheCouncilTeam() public {
        _start();
        _settleOn(1);
        game.openRound();

        address[] memory voters = game.votersOf(1);
        vm.prank(voters[0]);
        game.post("QmInside");

        address outsider;
        for (uint256 i; i < players.length; ++i) {
            if (game.teamOf(players[i]) != game.teamOf(voters[0])) {
                outsider = players[i];
                break;
            }
        }
        vm.prank(outsider);
        vm.expectRevert(SurvivalGame.NotAVoter.selector);
        game.post("QmOutside");
    }

    function test_checkIn_recordsLiveness() public {
        _start();
        vm.prank(players[0]);
        game.checkIn();
        assertEq(game.lastCheckIn(players[0]), 1, "stored as round + 1");
    }

    // ─── Aborts ──────────────────────────────────────────────────────────────────────────────

    function test_abortRound_clearsTheCouncilTarget() public {
        _start();
        _warpToSettle();
        vm.prank(owner);
        game.abortRound();

        game.openRound();
        assertEq(uint8(_kind(1)), uint8(SurvivalGame.RoundKind.Tribal), "no council off an abandoned round");
        assertEq(game.aliveCount(), 9, "abort eliminates nobody");
    }

    function test_abortRound_onlyOwner() public {
        _start();
        _warpToSettle();
        vm.prank(players[0]);
        vm.expectRevert();
        game.abortRound();
    }
}
