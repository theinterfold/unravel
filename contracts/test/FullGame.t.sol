// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {IInterfold} from "../src/interfaces/IInterfold.sol";
import {MockFeeToken, MockInterfold, MockCRISP} from "./mocks/Mocks.sol";

/// @notice Plays a full ten-player game to a winner.
///
/// @dev The unit tests cover each transition in isolation; this covers the thing they cannot —
///      that the transitions compose. A survival game has one long path through it, and most of
///      the ways it can be wrong (a roster that drifts out of sync with the ballot, a jury built
///      from the wrong set, an off-by-one at the finalist boundary) only show up after several
///      rounds have actually run.
contract FullGameTest is Test {
    SurvivalGame internal game;
    RosterToken internal life;
    RosterToken internal jury;
    MockFeeToken internal fee;
    MockInterfold internal interfold;
    MockCRISP internal crisp;

    address internal owner = address(0xA11CE);
    address[] internal players;

    uint64 internal constant CAMPAIGN = 20 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint256 internal constant QUOTE = 1 ether;
    uint256 internal constant ENTRY_FEE = 100 ether;
    uint8 internal constant ROSTER = 10;

    function setUp() public {
        fee = new MockFeeToken();
        interfold = new MockInterfold(fee, QUOTE);
        crisp = new MockCRISP();

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
                    rosterSize: ROSTER,
                    finalists: 2,
                    maxMissedCheckIns: 0,
                    entryFee: ENTRY_FEE
                })
            })
        );

        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));
        vm.stopPrank();

        for (uint256 i; i < ROSTER; ++i) {
            address player = address(uint160(0x2000 + i));
            players.push(player);

            fee.mint(player, ENTRY_FEE);
            vm.startPrank(player);
            fee.approve(address(game), ENTRY_FEE);
            game.join();
            vm.stopPrank();
        }
    }

    /// @dev Votes out whichever candidate sits at index 0 of the round's ballot, then settles.
    function _eliminateFirstCandidate() internal returns (address eliminated) {
        uint256 roundId = game.currentRoundId();
        (uint256 e3Id,,, uint64 closesAt,,) = game.getRound(roundId);
        address[] memory candidates = game.candidatesOf(roundId);

        uint256[] memory counts = new uint256[](candidates.length);
        counts[0] = candidates.length; // an unambiguous majority

        crisp.setTally(e3Id, counts);
        vm.warp(closesAt + GRACE);
        game.settleRound();

        return candidates[0];
    }

    function test_playsThroughToAWinner() public {
        game.startGame();
        assertEq(game.aliveCount(), ROSTER);

        uint256 eliminations;

        while (game.stage() == SurvivalGame.Stage.Playing) {
            uint256 roundId = game.currentRoundId();

            // Every round, the ballot must offer exactly the surviving players and never exceed
            // what the circuit can prove.
            address[] memory candidates = game.candidatesOf(roundId);
            assertEq(candidates.length, game.aliveCount(), "ballot drifted from the roster");
            assertLe(candidates.length, game.MAX_CANDIDATES(), "ballot exceeded the circuit bound");

            // The census must be exactly the living. This is the property the whole design turns
            // on: an eliminated player who stays eligible keeps voting forever.
            (uint256 e3Id,,,,,) = game.getRound(roundId);
            assertEq(game.getCensus(e3Id).length, game.aliveCount(), "census drifted from the roster");

            address gone = _eliminateFirstCandidate();
            ++eliminations;

            assertEq(life.balanceOf(gone), 0, "loser kept their life");
            assertEq(jury.balanceOf(gone), jury.UNIT(), "loser was not seated on the jury");

            if (game.stage() == SurvivalGame.Stage.Playing) game.openRound();
        }

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Jury));
        assertEq(eliminations, ROSTER - 2, "wrong number of eliminations before the jury phase");
        assertEq(game.aliveCount(), 2);
        assertEq(game.jurors().length, ROSTER - 2);

        // ─── Jury round ───
        game.openRound();
        uint256 juryRound = game.currentRoundId();

        address[] memory finalists = game.candidatesOf(juryRound);
        assertEq(finalists.length, 2, "the jury votes on the two finalists");
        assertEq(game.votersOf(juryRound).length, ROSTER - 2, "the jury is everyone eliminated");

        (uint256 juryE3,,, uint64 juryCloses,,) = game.getRound(juryRound);
        assertEq(game.getCensus(juryE3).length, ROSTER - 2, "jury census is the graveyard, not the living");

        uint256[] memory verdict = new uint256[](2);
        verdict[1] = 5;
        crisp.setTally(juryE3, verdict);
        vm.warp(juryCloses + GRACE);

        uint256 prize = game.pot();
        game.settleRound();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Ended));
        assertEq(game.winner(), finalists[1]);
        assertEq(fee.balanceOf(finalists[1]), prize, "winner was not paid the pot");
        assertEq(game.pot(), 0);

        // The runner-up loses, but is not eliminated — they were never on an elimination ballot.
        assertEq(life.balanceOf(finalists[0]), life.UNIT(), "runner-up lost their badge");
        assertEq(game.aliveCount(), 2);
    }

    /// @dev Entry fees fund the E3s. A game that runs out mid-way cannot open another round, so
    ///      the pot has to outlast the round count by construction.
    function test_potCoversEveryRoundOfAFullGame() public {
        game.startGame();

        uint256 rounds;
        while (game.stage() == SurvivalGame.Stage.Playing) {
            _eliminateFirstCandidate();
            ++rounds;
            if (game.stage() == SurvivalGame.Stage.Playing) game.openRound();
        }
        game.openRound(); // the jury round
        ++rounds;

        assertEq(rounds, ROSTER - 1, "a ten-player game is eight eliminations plus the jury round");
        assertEq(game.pot(), ENTRY_FEE * ROSTER - QUOTE * rounds);
    }
}
