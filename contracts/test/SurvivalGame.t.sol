// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {ICRISP} from "../src/interfaces/ICRISP.sol";
import {IInterfold} from "../src/interfaces/IInterfold.sol";
import {IImmunitySource} from "../src/interfaces/IImmunitySource.sol";
import {MockFeeToken, MockInterfold, MockCRISP, MockImmunitySource} from "./mocks/Mocks.sol";

contract SurvivalGameTest is Test {
    SurvivalGame internal game;
    RosterToken internal life;
    RosterToken internal jury;
    MockFeeToken internal fee;
    MockInterfold internal interfold;
    MockCRISP internal crisp;

    address internal owner = address(0xA11CE);

    uint64 internal constant CAMPAIGN = 20 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint256 internal constant QUOTE = 10 ether;
    uint256 internal constant ENTRY_FEE = 100 ether;

    address[] internal players;

    function setUp() public {
        fee = new MockFeeToken();
        interfold = new MockInterfold(fee, QUOTE);
        crisp = new MockCRISP();

        _deployGame(5, 2, 0);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────────────────

    function _deployGame(uint8 rosterSize, uint8 finalists, uint8 maxMissedCheckIns) internal {
        vm.startPrank(owner);
        life = new RosterToken("Life", "LIFE", owner);
        jury = new RosterToken("Jury", "JURY", owner);

        game = new SurvivalGame(
            SurvivalGame.InitParams({
                owner: owner,
                interfold: IInterfold(address(interfold)),
                crispProgram: address(crisp),
                lifeToken: life,
                juryToken: jury,
                committeeSize: IInterfold.CommitteeSize.Micro,
                paramSet: 0,
                computeProviderParams: hex"",
                config: SurvivalGame.Config({
                    campaignDuration: CAMPAIGN,
                    ballotDuration: BALLOT,
                    tallyGrace: GRACE,
                    rosterSize: rosterSize,
                    finalists: finalists,
                    maxMissedCheckIns: maxMissedCheckIns,
                    entryFee: ENTRY_FEE
                })
            })
        );

        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));
        vm.stopPrank();

        delete players;
        for (uint256 i; i < rosterSize; ++i) {
            players.push(address(uint160(0x1000 + i)));
        }
    }

    function _fillLobby() internal {
        for (uint256 i; i < players.length; ++i) {
            fee.mint(players[i], ENTRY_FEE);
            vm.startPrank(players[i]);
            fee.approve(address(game), ENTRY_FEE);
            game.join();
            vm.stopPrank();
        }
    }

    function _start() internal {
        _fillLobby();
        game.startGame();
    }

    /// @dev Moves to just past the settle deadline for the current round.
    function _warpToSettle() internal {
        (,,, uint64 closesAt,,) = game.getRound(game.currentRoundId());
        vm.warp(closesAt + GRACE);
    }

    /// @dev Sets a tally that gives `target` a clear majority, then settles.
    function _settleAgainst(address target) internal {
        uint256 roundId = game.currentRoundId();
        (uint256 e3Id,,,,,) = game.getRound(roundId);
        address[] memory candidates = game.candidatesOf(roundId);

        uint256[] memory counts = new uint256[](candidates.length);
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i] == target) counts[i] = 3;
        }

        crisp.setTally(e3Id, counts);
        _warpToSettle();
        game.settleRound();
    }

    // ─── Lobby ───────────────────────────────────────────────────────────────────────────────

    function test_join_mintsLifeAndCollectsFee() public {
        fee.mint(players[0], ENTRY_FEE);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE);
        game.join();
        vm.stopPrank();

        assertEq(life.balanceOf(players[0]), life.UNIT());
        assertEq(game.pot(), ENTRY_FEE);
        assertEq(game.aliveCount(), 1);
    }

    function test_join_selfDelegatesSoVotingPowerIsImmediate() public {
        fee.mint(players[0], ENTRY_FEE);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE);
        game.join();
        vm.stopPrank();

        // Without auto-delegation this would be zero and the player would silently have no weight.
        assertEq(life.getVotes(players[0]), life.UNIT());
    }

    function test_join_revertsOnDoubleJoin() public {
        fee.mint(players[0], ENTRY_FEE * 2);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE * 2);
        game.join();
        vm.expectRevert(SurvivalGame.AlreadyJoined.selector);
        game.join();
        vm.stopPrank();
    }

    function test_join_revertsWhenLobbyFull() public {
        _fillLobby();

        address extra = address(0xBEEF);
        fee.mint(extra, ENTRY_FEE);
        vm.startPrank(extra);
        fee.approve(address(game), ENTRY_FEE);
        vm.expectRevert(SurvivalGame.LobbyFull.selector);
        game.join();
        vm.stopPrank();
    }

    function test_startGame_revertsWhenRosterIncomplete() public {
        fee.mint(players[0], ENTRY_FEE);
        vm.startPrank(players[0]);
        fee.approve(address(game), ENTRY_FEE);
        game.join();
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.RosterIncomplete.selector, 1, 5));
        game.startGame();
    }

    // ─── Round opening ───────────────────────────────────────────────────────────────────────

    function test_startGame_opensFirstRoundWithFullRoster() public {
        _start();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Playing));
        assertEq(game.roundCount(), 1);
        assertEq(game.candidatesOf(0).length, 5);
        assertEq(game.votersOf(0).length, 5);
    }

    function test_openRound_encodesOneCreditConstantBallot() public {
        _start();

        (address token, uint256 threshold, uint256 numOptions, ICRISP.CreditMode mode, uint256 credits) =
            abi.decode(interfold.lastCustomParams(), (address, uint256, uint256, ICRISP.CreditMode, uint256));

        assertEq(token, address(life));
        assertEq(threshold, 0);
        assertEq(numOptions, 5, "one option per candidate");
        assertEq(uint8(mode), uint8(ICRISP.CreditMode.CONSTANT));
        assertEq(credits, 1, "one player, one vote");
    }

    function test_openRound_inputWindowIsTheBallotWindow() public {
        uint256 startedAt = block.timestamp;
        _start();

        assertEq(interfold.lastInputWindow(0), startedAt + CAMPAIGN);
        assertEq(interfold.lastInputWindow(1), startedAt + CAMPAIGN + BALLOT);
    }

    function test_openRound_paysQuoteFromPot() public {
        _start();
        assertEq(game.pot(), ENTRY_FEE * 5 - QUOTE);
    }

    function test_openRound_revertsWhenPotCannotCoverTheQuote() public {
        interfold.setQuote(ENTRY_FEE * 5 + 1);
        _fillLobby();

        vm.expectRevert(
            abi.encodeWithSelector(SurvivalGame.InsufficientPot.selector, ENTRY_FEE * 5 + 1, ENTRY_FEE * 5)
        );
        game.startGame();
    }

    function test_openRound_revertsWhilePreviousRoundUnsettled() public {
        _start();
        vm.expectRevert(SurvivalGame.PreviousRoundUnsettled.selector);
        game.openRound();
    }

    /// @dev The circuit cannot prove a ballot with more than MAX_CANDIDATES options, and the
    ///      on-chain CRISP program only checks the lower bound — so the game must refuse to open
    ///      such a round rather than discover it when the first voter tries to prove.
    function test_constructor_rejectsRosterAboveCircuitBound() public {
        vm.startPrank(owner);
        RosterToken l = new RosterToken("Life", "LIFE", owner);
        RosterToken j = new RosterToken("Jury", "JURY", owner);

        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        new SurvivalGame(
            SurvivalGame.InitParams({
                owner: owner,
                interfold: IInterfold(address(interfold)),
                crispProgram: address(crisp),
                lifeToken: l,
                juryToken: j,
                committeeSize: IInterfold.CommitteeSize.Micro,
                paramSet: 0,
                computeProviderParams: hex"",
                config: SurvivalGame.Config({
                    campaignDuration: CAMPAIGN,
                    ballotDuration: BALLOT,
                    tallyGrace: GRACE,
                    rosterSize: 11,
                    finalists: 2,
                    maxMissedCheckIns: 0,
                    entryFee: ENTRY_FEE
                })
            })
        );
        vm.stopPrank();
    }

    // ─── The census hook ─────────────────────────────────────────────────────────────────────

    function test_getCensus_returnsTheRoundVoters() public {
        _start();
        (uint256 e3Id,,,,,) = game.getRound(0);

        address[] memory census = game.getCensus(e3Id);
        assertEq(census.length, 5);
        for (uint256 i; i < census.length; ++i) {
            assertEq(census[i], players[i]);
        }
    }

    function test_getCensus_isEmptyForUnknownE3() public view {
        assertEq(game.getCensus(999).length, 0);
    }

    /// @dev The whole point of the census hook: an eliminated player must stop being eligible.
    function test_getCensus_dropsEliminatedPlayers() public {
        _start();
        _settleAgainst(players[2]);
        game.openRound();

        (uint256 e3Id,,,,,) = game.getRound(1);
        address[] memory census = game.getCensus(e3Id);

        assertEq(census.length, 4);
        for (uint256 i; i < census.length; ++i) {
            assertTrue(census[i] != players[2], "eliminated player still eligible");
        }
    }

    // ─── Settlement ──────────────────────────────────────────────────────────────────────────

    function test_settleRound_eliminatesHighestPolling() public {
        _start();
        _settleAgainst(players[3]);

        assertEq(game.aliveCount(), 4);
        assertEq(life.balanceOf(players[3]), 0, "life not burned");
        assertEq(jury.balanceOf(players[3]), jury.UNIT(), "jury badge not minted");
        assertEq(life.getVotes(players[3]), 0, "eliminated player retains voting power");

        (,,,,, address outcome) = game.getRound(0);
        assertEq(outcome, players[3]);
    }

    function test_settleRound_revertsBeforeTallyIsDue() public {
        _start();
        (,,, uint64 closesAt,,) = game.getRound(0);
        vm.warp(closesAt + GRACE - 1);

        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.TallyNotDue.selector, closesAt + GRACE));
        game.settleRound();
    }

    function test_settleRound_revertsOnTallyLengthMismatch() public {
        _start();
        (uint256 e3Id,,,,,) = game.getRound(0);

        uint256[] memory counts = new uint256[](3);
        crisp.setTally(e3Id, counts);
        _warpToSettle();

        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.TallyLengthMismatch.selector, 5, 3));
        game.settleRound();
    }

    function test_settleRound_cannotSettleTwice() public {
        _start();
        _settleAgainst(players[1]);

        vm.expectRevert(SurvivalGame.RoundAlreadySettled.selector);
        game.settleRound();
    }

    /// @dev No votes means no mandate. Eliminating on an all-zero tally would pick a victim by
    ///      array order, which is arbitrary and exploitable by whoever controls join order.
    function test_settleRound_voidsWhenNobodyVoted() public {
        _start();
        (uint256 e3Id,,,,,) = game.getRound(0);

        crisp.setTally(e3Id, new uint256[](5));
        _warpToSettle();
        game.settleRound();

        assertEq(game.aliveCount(), 5, "nobody should be eliminated on an empty tally");
        (,,,,, address outcome) = game.getRound(0);
        assertEq(outcome, address(0));
    }

    function test_settleRound_voidRoundCanBeFollowedByANewRound() public {
        _start();
        (uint256 e3Id,,,,,) = game.getRound(0);
        crisp.setTally(e3Id, new uint256[](5));
        _warpToSettle();
        game.settleRound();

        game.openRound();
        assertEq(game.roundCount(), 2);
        assertEq(game.candidatesOf(1).length, 5);
    }

    // ─── Ties ────────────────────────────────────────────────────────────────────────────────

    function test_settleRound_breaksTiesDeterministically() public {
        _start();
        (uint256 e3Id,,,,,) = game.getRound(0);

        uint256[] memory counts = new uint256[](5);
        counts[1] = 2;
        counts[3] = 2;
        crisp.setTally(e3Id, counts);
        _warpToSettle();

        // The rule is fixed by the tally itself, so the outcome is reproducible: recompute it the
        // same way the contract does and assert the contract agrees.
        uint256 pick = uint256(keccak256(abi.encode(e3Id, counts))) % 2;
        address expected = pick == 0 ? players[1] : players[3];

        game.settleRound();

        (,,,,, address outcome) = game.getRound(0);
        assertEq(outcome, expected);
        assertEq(game.aliveCount(), 4);
    }

    function test_settleRound_tieAlwaysPicksFromTheTiedSet() public {
        _start();
        (uint256 e3Id,,,,,) = game.getRound(0);

        uint256[] memory counts = new uint256[](5);
        counts[0] = 4;
        counts[2] = 4;
        counts[4] = 1; // not tied for the lead
        crisp.setTally(e3Id, counts);
        _warpToSettle();
        game.settleRound();

        (,,,,, address outcome) = game.getRound(0);
        assertTrue(outcome == players[0] || outcome == players[2], "picked outside the tied set");
    }

    // ─── Immunity ────────────────────────────────────────────────────────────────────────────

    function test_immunity_removesPlayerFromCandidatesButNotVoters() public {
        MockImmunitySource source = new MockImmunitySource();
        source.set(0, players[2]);

        vm.prank(owner);
        game.setImmunitySource(IImmunitySource(address(source)));
        _start();

        address[] memory candidates = game.candidatesOf(0);
        assertEq(candidates.length, 4, "immune player should not be a candidate");
        for (uint256 i; i < candidates.length; ++i) {
            assertTrue(candidates[i] != players[2]);
        }

        assertEq(game.votersOf(0).length, 5, "immune player still votes");
    }

    function test_immunity_shrinksNumOptions() public {
        MockImmunitySource source = new MockImmunitySource();
        source.set(0, players[0]);

        vm.prank(owner);
        game.setImmunitySource(IImmunitySource(address(source)));
        _start();

        (,, uint256 numOptions,,) =
            abi.decode(interfold.lastCustomParams(), (address, uint256, uint256, ICRISP.CreditMode, uint256));
        assertEq(numOptions, 4);
    }

    // ─── Campaign ────────────────────────────────────────────────────────────────────────────

    function test_post_emitsForVotersDuringCampaign() public {
        _start();

        vm.expectEmit(true, true, false, true);
        emit SurvivalGame.Posted(0, players[0], "QmCid");
        vm.prank(players[0]);
        game.post("QmCid");
    }

    function test_post_revertsOnceBallotOpens() public {
        _start();
        (,, uint64 opensAt,,,) = game.getRound(0);
        vm.warp(opensAt);

        vm.prank(players[0]);
        vm.expectRevert(SurvivalGame.NotInCampaign.selector);
        game.post("QmCid");
    }

    function test_post_revertsForNonPlayers() public {
        _start();
        vm.prank(address(0xDEAD));
        vm.expectRevert(SurvivalGame.NotAPlayer.selector);
        game.post("QmCid");
    }

    // ─── Forfeits ────────────────────────────────────────────────────────────────────────────

    /// @dev Liveness has to be an explicit public signal: ballots are secret and mask votes make
    ///      slot activity meaningless, so the contract genuinely cannot observe who abstained.
    function test_checkIn_recordsLiveness() public {
        _start();
        vm.prank(players[0]);
        game.checkIn();
        assertEq(game.lastCheckIn(players[0]), 1, "stored as round + 1");
    }

    function test_checkIn_revertsForEliminatedPlayers() public {
        _start();
        _settleAgainst(players[4]);
        game.openRound();

        vm.prank(players[4]);
        vm.expectRevert(SurvivalGame.NotAlive.selector);
        game.checkIn();
    }

    function test_forfeit_cullsPlayersWhoNeverCheckIn() public {
        _deployGame(5, 2, 1);
        _start();

        // Everyone except players[4] keeps checking in. Rounds are settled void so the only thing
        // that can remove a player is the forfeit rule itself.
        for (uint256 round; round < 3; ++round) {
            for (uint256 i; i < 4; ++i) {
                if (life.balanceOf(players[i]) != 0) {
                    vm.prank(players[i]);
                    game.checkIn();
                }
            }

            uint256 roundId = game.currentRoundId();
            (uint256 e3Id,,,,,) = game.getRound(roundId);
            crisp.setTally(e3Id, new uint256[](game.candidatesOf(roundId).length));
            _warpToSettle();
            game.settleRound();

            if (game.stage() == SurvivalGame.Stage.Playing) game.openRound();
        }

        assertEq(life.balanceOf(players[4]), 0, "absent player should have forfeited");
        for (uint256 i; i < 4; ++i) {
            assertEq(life.balanceOf(players[i]), life.UNIT(), "present player was culled");
        }
    }

    function test_forfeit_neverDropsBelowFinalistCount() public {
        _deployGame(3, 2, 1);
        _start();

        // Nobody ever checks in; forfeits must still stop at the finalist floor.
        for (uint256 round; round < 4; ++round) {
            uint256 roundId = game.currentRoundId();
            (uint256 e3Id,,,,,) = game.getRound(roundId);
            crisp.setTally(e3Id, new uint256[](game.candidatesOf(roundId).length));
            _warpToSettle();
            game.settleRound();

            if (game.stage() != SurvivalGame.Stage.Playing) break;
            game.openRound();
        }

        assertGe(game.aliveCount(), 2, "forfeits dropped the roster below the finalist floor");
    }

    // ─── Endgame ─────────────────────────────────────────────────────────────────────────────

    function test_game_reachesJuryPhaseAtFinalistCount() public {
        _start();
        _settleAgainst(players[0]);
        game.openRound();
        _settleAgainst(players[1]);
        game.openRound();
        _settleAgainst(players[2]);

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Jury));
        assertEq(game.aliveCount(), 2);
        assertEq(game.jurors().length, 3);
    }

    function test_juryRound_votersAreTheGraveyardAndCandidatesTheFinalists() public {
        _start();
        _settleAgainst(players[0]);
        game.openRound();
        _settleAgainst(players[1]);
        game.openRound();
        _settleAgainst(players[2]);

        game.openRound();
        uint256 roundId = game.currentRoundId();

        assertEq(game.candidatesOf(roundId).length, 2, "finalists are the candidates");
        assertEq(game.votersOf(roundId).length, 3, "the graveyard is the jury");

        (address token,,,,) =
            abi.decode(interfold.lastCustomParams(), (address, uint256, uint256, ICRISP.CreditMode, uint256));
        assertEq(token, address(jury), "jury round should reference the jury roster");
    }

    function test_juryRound_declaresWinnerAndPaysThePot() public {
        _start();
        _settleAgainst(players[0]);
        game.openRound();
        _settleAgainst(players[1]);
        game.openRound();
        _settleAgainst(players[2]);
        game.openRound();

        uint256 roundId = game.currentRoundId();
        (uint256 e3Id,,,,,) = game.getRound(roundId);
        address[] memory finalists = game.candidatesOf(roundId);

        uint256[] memory counts = new uint256[](2);
        counts[1] = 3; // the jury picks finalists[1]
        crisp.setTally(e3Id, counts);
        _warpToSettle();

        uint256 expectedPrize = game.pot();
        game.settleRound();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Ended));
        assertEq(game.winner(), finalists[1]);
        assertEq(fee.balanceOf(finalists[1]), expectedPrize, "winner not paid");
        assertEq(game.pot(), 0);
    }

    /// @dev The jury vote picks a winner; it must not burn the loser's badge as an elimination.
    function test_juryRound_doesNotEliminateTheRunnerUp() public {
        _start();
        _settleAgainst(players[0]);
        game.openRound();
        _settleAgainst(players[1]);
        game.openRound();
        _settleAgainst(players[2]);
        game.openRound();

        uint256 roundId = game.currentRoundId();
        (uint256 e3Id,,,,,) = game.getRound(roundId);
        address[] memory finalists = game.candidatesOf(roundId);

        uint256[] memory counts = new uint256[](2);
        counts[0] = 2;
        crisp.setTally(e3Id, counts);
        _warpToSettle();
        game.settleRound();

        assertEq(life.balanceOf(finalists[1]), life.UNIT(), "runner-up should keep their badge");
        assertEq(game.aliveCount(), 2);
    }

    // ─── Aborts ──────────────────────────────────────────────────────────────────────────────

    function test_abortRound_allowsReopeningAfterAFailedE3() public {
        _start();
        _warpToSettle();

        vm.prank(owner);
        game.abortRound();

        game.openRound();
        assertEq(game.roundCount(), 2);
        assertEq(game.aliveCount(), 5, "abort must not eliminate anyone");
    }

    function test_abortRound_onlyOwner() public {
        _start();
        _warpToSettle();

        vm.prank(players[0]);
        vm.expectRevert();
        game.abortRound();
    }
}
