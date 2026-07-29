// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {PublicImmunityVote} from "../src/PublicImmunityVote.sol";
import {IImmunitySource} from "../src/interfaces/IImmunitySource.sol";
import {IInterfold} from "../src/interfaces/IInterfold.sol";
import {MockFeeToken, MockInterfold, MockCRISP} from "./mocks/Mocks.sol";

contract PublicImmunityVoteTest is Test {
    SurvivalGame internal game;
    RosterToken internal life;
    RosterToken internal jury;
    PublicImmunityVote internal immunity;
    MockFeeToken internal fee;
    MockInterfold internal interfold;
    MockCRISP internal crisp;

    address internal owner = address(0xA11CE);
    address[] internal players;

    uint64 internal constant CAMPAIGN = 20 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint256 internal constant QUOTE = 10 ether;
    uint256 internal constant ENTRY_FEE = 100 ether;

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
                    rosterSize: 5,
                    finalists: 2,
                    maxMissedCheckIns: 0,
                    entryFee: ENTRY_FEE
                })
            })
        );

        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));

        immunity = new PublicImmunityVote(game, life);
        game.setImmunitySource(IImmunitySource(address(immunity)));
        vm.stopPrank();

        for (uint256 i; i < 5; ++i) {
            players.push(address(uint160(0x1000 + i)));
        }

        for (uint256 i; i < players.length; ++i) {
            fee.mint(players[i], ENTRY_FEE);
            vm.startPrank(players[i]);
            fee.approve(address(game), ENTRY_FEE);
            game.join();
            vm.stopPrank();
        }
    }

    function _vote(address voter, address candidate) internal {
        vm.prank(voter);
        immunity.voteForImmunity(candidate);
    }

    function test_pendingRound_isTheNextRoundToOpen() public view {
        assertEq(immunity.pendingRound(), 0);
    }

    function test_majorityGrantsImmunity() public {
        _vote(players[0], players[3]);
        _vote(players[1], players[3]);
        _vote(players[2], players[4]);

        assertEq(immunity.immuneFor(0), players[3]);
    }

    /// @dev A tie protects nobody: handing out immunity no majority voted for would be worse than
    ///      an indecisive round.
    function test_tieGrantsNobodyImmunity() public {
        _vote(players[0], players[3]);
        _vote(players[1], players[4]);

        assertEq(immunity.immuneFor(0), address(0));
    }

    function test_noVotesGrantsNobodyImmunity() public view {
        assertEq(immunity.immuneFor(0), address(0));
    }

    function test_voteCanBeChangedBeforeTheRoundOpens() public {
        _vote(players[0], players[3]);
        _vote(players[1], players[3]);
        assertEq(immunity.immuneFor(0), players[3]);

        // players[1] switches sides, producing a tie.
        _vote(players[1], players[4]);
        assertEq(immunity.immuneFor(0), address(0));
        assertEq(immunity.votesFor(0, players[3]), 1);
        assertEq(immunity.votesFor(0, players[4]), 1);
    }

    function test_repeatedIdenticalVoteIsANoop() public {
        _vote(players[0], players[3]);
        _vote(players[0], players[3]);
        assertEq(immunity.votesFor(0, players[3]), 1);
    }

    function test_onlyAlivePlayersMayVote() public {
        address outsider = address(0xDEAD);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PublicImmunityVote.NotAlive.selector, outsider));
        immunity.voteForImmunity(players[0]);
    }

    function test_cannotProtectSomeoneNotInTheGame() public {
        vm.prank(players[0]);
        vm.expectRevert(
            abi.encodeWithSelector(PublicImmunityVote.CandidateNotAlive.selector, address(0xDEAD))
        );
        immunity.voteForImmunity(address(0xDEAD));
    }

    // ─── Integration with the game ───────────────────────────────────────────────────────────

    function test_immunePlayerIsRemovedFromTheBallot() public {
        _vote(players[0], players[3]);
        _vote(players[1], players[3]);

        game.startGame();

        address[] memory candidates = game.candidatesOf(0);
        assertEq(candidates.length, 4, "immune player should not be a candidate");
        for (uint256 i; i < candidates.length; ++i) {
            assertTrue(candidates[i] != players[3], "immune player is still eliminable");
        }

        assertEq(game.votersOf(0).length, 5, "immune player must still vote");
    }

    function test_immunityDoesNotCarryToTheNextRound() public {
        _vote(players[0], players[3]);
        _vote(players[1], players[3]);
        game.startGame();
        assertEq(game.candidatesOf(0).length, 4);

        // Settle round 0 against someone else, then open round 1 with no new immunity votes.
        (uint256 e3Id,,,,,) = game.getRound(0);
        address[] memory candidates = game.candidatesOf(0);
        uint256[] memory counts = new uint256[](candidates.length);
        counts[0] = 3;
        crisp.setTally(e3Id, counts);

        (,,, uint64 closesAt,,) = game.getRound(0);
        vm.warp(closesAt + GRACE);
        game.settleRound();

        game.openRound();
        // Four alive, nobody protected this time — everyone is a candidate.
        assertEq(game.candidatesOf(1).length, 4);
    }

    /// @dev The elected player may be voted out before the round they were protected for opens.
    ///      The game must fall back to no immunity rather than pinning a dead candidate.
    function test_immunityIgnoredIfElectedPlayerIsAlreadyGone() public {
        game.startGame();

        // Elect players[4] for round 1 while round 0 is still running.
        _vote(players[0], players[4]);
        _vote(players[1], players[4]);
        assertEq(immunity.immuneFor(1), players[4]);

        // ...but players[4] is eliminated in round 0.
        (uint256 e3Id,,,,,) = game.getRound(0);
        address[] memory candidates = game.candidatesOf(0);
        uint256[] memory counts = new uint256[](candidates.length);
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i] == players[4]) counts[i] = 4;
        }
        crisp.setTally(e3Id, counts);

        (,,, uint64 closesAt,,) = game.getRound(0);
        vm.warp(closesAt + GRACE);
        game.settleRound();
        assertEq(life.balanceOf(players[4]), 0);

        game.openRound();
        assertEq(game.candidatesOf(1).length, 4, "a dead player's immunity must not shrink the ballot");
    }
}
