// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GameFactory} from "../src/GameFactory.sol";
import {GameDeployer} from "../src/GameDeployer.sol";
import {SurvivalGame} from "../src/SurvivalGame.sol";
import {PublicImmunityVote} from "../src/PublicImmunityVote.sol";
import {GraveyardMark} from "../src/GraveyardMark.sol";
import {SecretAllegiance} from "../src/SecretAllegiance.sol";
import {ICrispVotingPlugin} from "../src/interfaces/ICrispVotingPlugin.sol";
import {MockFeeToken, MockPlugin} from "./mocks/Mocks.sol";

/// @notice The three mechanics that give the game something to be about: a public protection vote
///         against the secret ballot, something for the dead to do, and one hidden motive each.
contract SideshowsTest is Test {
    uint64 internal constant CAMPAIGN = 1 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint256 internal constant FEE = 1e6;
    uint256 internal constant FUNDING = 500e6;

    GameFactory internal factory;
    MockFeeToken internal fee;
    MockPlugin internal plugin;

    address internal creator = address(0xC1);
    address[] internal players;

    function setUp() public {
        fee = new MockFeeToken();
        plugin = new MockPlugin(IERC20(address(fee)), FEE);
        factory =
            new GameFactory(new GameDeployer(), ICrispVotingPlugin(address(plugin)), IERC20(address(fee)));
        for (uint256 i; i < 6; ++i) {
            players.push(address(uint160(0x3000 + i)));
        }
    }

    function _config(uint8 minPlayers) internal pure returns (SurvivalGame.Config memory) {
        return SurvivalGame.Config({
            campaignDuration: CAMPAIGN,
            ballotDuration: BALLOT,
            tallyGrace: GRACE,
            teamCount: 2,
            minMembersPerTeam: 1,
            minPlayers: minPlayers,
            lobbyTimeout: 1 days,
            mergeAt: 3,
            finalists: 2,
            maxMissedCheckIns: 0,
            entryFee: 0
        });
    }

    function _create() internal returns (SurvivalGame game, GameFactory.Sideshows memory side) {
        fee.mint(creator, FUNDING);
        vm.startPrank(creator);
        fee.approve(address(factory), FUNDING);
        game = factory.create(_config(4), "Side", FUNDING);
        vm.stopPrank();

        (PublicImmunityVote i, GraveyardMark g, SecretAllegiance a) =
            factory.sideshowsOf(address(game));
        side = GameFactory.Sideshows({immunity: i, graveyard: g, allegiance: a});
    }

    function _join(SurvivalGame game, uint256 index, uint8 team) internal {
        vm.prank(players[index]);
        game.join(team);
    }

    // ─── Deployment ──────────────────────────────────────────────────────────────────────────

    /// @dev A lobby has to arrive complete. A mechanic that needs a second transaction is one most
    ///      lobbies will not have.
    function test_create_wiresAllThreeSideshows() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();

        assertEq(address(game.immunitySource()), address(side.immunity), "immunity source set");
        assertEq(address(side.immunity.game()), address(game));
        assertEq(address(side.graveyard.game()), address(game));
        assertEq(address(side.allegiance.game()), address(game));

        // The factory owns the game only for the length of `create`.
        assertEq(game.owner(), creator, "ownership handed back to the creator");
    }

    // ─── Immunity ────────────────────────────────────────────────────────────────────────────

    function test_immunity_protectsTheMostVotedPlayer() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);
        _join(game, 3, 2);

        vm.prank(players[0]);
        side.immunity.voteForImmunity(players[2]);
        vm.prank(players[1]);
        side.immunity.voteForImmunity(players[2]);
        vm.prank(players[2]);
        side.immunity.voteForImmunity(players[0]);

        assertEq(side.immunity.immuneFor(0), players[2]);
    }

    /// @dev Immunity is a bonus, so an indecisive public protects nobody rather than having a tie
    ///      broken on their behalf.
    function test_immunity_tieProtectsNobody() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);

        vm.prank(players[0]);
        side.immunity.voteForImmunity(players[1]);
        vm.prank(players[1]);
        side.immunity.voteForImmunity(players[0]);

        assertEq(side.immunity.immuneFor(0), address(0));
    }

    function test_immunity_changingYourVoteMovesTheCount() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);

        vm.startPrank(players[0]);
        side.immunity.voteForImmunity(players[1]);
        side.immunity.voteForImmunity(players[2]);
        vm.stopPrank();

        assertEq(side.immunity.votesFor(0, players[1]), 0, "old candidate decremented");
        assertEq(side.immunity.votesFor(0, players[2]), 1);
    }

    function test_immunity_onlyTheLivingVoteAndOnlyForTheLiving() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(PublicImmunityVote.NotAlive.selector, address(0xDEAD)));
        side.immunity.voteForImmunity(players[0]);

        vm.prank(players[0]);
        vm.expectRevert(
            abi.encodeWithSelector(PublicImmunityVote.CandidateNotAlive.selector, address(0xBEEF))
        );
        side.immunity.voteForImmunity(address(0xBEEF));
    }

    // ─── Graveyard ───────────────────────────────────────────────────────────────────────────

    /// @dev The living cannot mark. The point is to give the dead something to do, not to add a
    ///      second channel for the people who already have one.
    function test_graveyard_onlyJurorsMayMark() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);
        _join(game, 3, 2);
        game.startGame();

        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSelector(GraveyardMark.NotAJuror.selector, players[0]));
        side.graveyard.mark(players[1]);
    }

    function test_graveyard_hasNoRoundBeforeTheGameStarts() public {
        (, GameFactory.Sideshows memory side) = _create();
        vm.expectRevert(GraveyardMark.NoRoundYet.selector);
        side.graveyard.currentRound();
    }

    // ─── Allegiance ──────────────────────────────────────────────────────────────────────────

    function test_allegiance_correctPickSharesThePool() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);
        _join(game, 3, 2);

        bytes32 salt = keccak256("s");
        vm.prank(players[0]);
        side.allegiance.commit(keccak256(abi.encode(players[3], salt)));
        vm.prank(players[1]);
        side.allegiance.commit(keccak256(abi.encode(players[0], salt)));

        // Anyone can fund; here the creator does.
        fee.mint(creator, 100e6);
        vm.startPrank(creator);
        fee.approve(address(side.allegiance), 100e6);
        side.allegiance.fund(100e6);
        vm.stopPrank();

        _endGameWithWinner(game, players[3]);

        vm.prank(players[0]);
        side.allegiance.reveal(players[3], salt);
        vm.prank(players[1]);
        side.allegiance.reveal(players[0], salt);

        assertEq(side.allegiance.winnerCount(), 1, "only the correct pick counts");

        vm.prank(players[0]);
        side.allegiance.claim();
        assertEq(fee.balanceOf(players[0]), 100e6);

        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSelector(SecretAllegiance.NotAWinner.selector, players[1]));
        side.allegiance.claim();
    }

    /// @dev A pick you can change is a running prediction, not a commitment — it would let a player
    ///      hedge into whoever is visibly winning.
    function test_allegiance_commitsAreOncePerPlayerAndLobbyOnly() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);
        _join(game, 3, 2);

        vm.prank(players[0]);
        side.allegiance.commit(keccak256("a"));

        vm.prank(players[0]);
        vm.expectRevert(SecretAllegiance.AlreadyCommitted.selector);
        side.allegiance.commit(keccak256("b"));

        game.startGame();

        vm.prank(players[1]);
        vm.expectRevert(SecretAllegiance.LobbyClosed.selector);
        side.allegiance.commit(keccak256("c"));
    }

    function test_allegiance_wrongSaltIsRejected() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);
        _join(game, 3, 2);

        vm.prank(players[0]);
        side.allegiance.commit(keccak256(abi.encode(players[3], keccak256("right"))));

        _endGameWithWinner(game, players[3]);

        vm.prank(players[0]);
        vm.expectRevert(SecretAllegiance.BadReveal.selector);
        side.allegiance.reveal(players[3], keccak256("wrong"));
    }

    /// @dev Unclaimed money must not strand. Nobody backing the winner is the ordinary case.
    function test_allegiance_sweepAfterTheRevealWindow() public {
        (SurvivalGame game, GameFactory.Sideshows memory side) = _create();
        _join(game, 0, 1);
        _join(game, 1, 2);
        _join(game, 2, 1);
        _join(game, 3, 2);

        fee.mint(creator, 50e6);
        vm.startPrank(creator);
        fee.approve(address(side.allegiance), 50e6);
        side.allegiance.fund(50e6);
        vm.stopPrank();

        _endGameWithWinner(game, players[3]);

        // Nobody committed, so nobody can ever reveal. The deadline still has to arrive, which is
        // the whole point of deriving it from the final round rather than from a call that reverts.
        uint64 deadline = side.allegiance.revealDeadline();
        vm.expectRevert(abi.encodeWithSelector(SecretAllegiance.RevealStillOpen.selector, deadline));
        side.allegiance.sweep(creator);

        vm.warp(uint256(deadline) + 1);
        side.allegiance.sweep(creator);
        assertEq(fee.balanceOf(creator), 50e6);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────────────────

    /// @dev Drives the game to Ended with a chosen winner by settling rounds through the mock
    ///      plugin. Mirrors what the real committee would produce, without the committee.
    function _endGameWithWinner(SurvivalGame game, address wanted) internal {
        game.startGame();

        while (game.stage() != SurvivalGame.Stage.Ended) {
            uint256 proposalId = _proposalId(game);
            uint64 closesAt = _closesAt(game);
            uint256 options = _optionCount(game);

            // Eliminate whoever is not `wanted`; in the jury round, crown them.
            uint256 target = _indexOfSomeoneOtherThan(game, wanted, options);
            uint256[] memory counts = new uint256[](options);
            counts[target] = 1;
            plugin.setTally(proposalId, counts);

            vm.warp(closesAt + 1);
            game.settleRound();
            if (game.stage() != SurvivalGame.Stage.Ended) game.openRound();
        }
        assertEq(game.winner(), wanted, "helper drove the game to the intended winner");
    }

    function _proposalId(SurvivalGame game) internal view returns (uint256 id) {
        (, id,,,,,,,) = game.getRound(game.roundCount() - 1);
    }

    function _closesAt(SurvivalGame game) internal view returns (uint64 at) {
        (,,,,, at,,,) = game.getRound(game.roundCount() - 1);
    }

    function _kind(SurvivalGame game) internal view returns (SurvivalGame.RoundKind kind) {
        (kind,,,,,,,,) = game.getRound(game.roundCount() - 1);
    }

    function _optionCount(SurvivalGame game) internal view returns (uint256) {
        uint256 id = game.roundCount() - 1;
        if (_kind(game) == SurvivalGame.RoundKind.Tribal) return game.candidateTeamsOf(id).length;
        return game.candidatesOf(id).length;
    }

    function _indexOfSomeoneOtherThan(SurvivalGame game, address wanted, uint256 options)
        internal
        view
        returns (uint256)
    {
        uint256 id = game.roundCount() - 1;
        SurvivalGame.RoundKind kind = _kind(game);

        if (kind == SurvivalGame.RoundKind.Jury) {
            address[] memory finalists = game.candidatesOf(id);
            for (uint256 i; i < finalists.length; ++i) {
                if (finalists[i] == wanted) return i;
            }
            return 0;
        }
        if (kind == SurvivalGame.RoundKind.Tribal) {
            uint8[] memory teams = game.candidateTeamsOf(id);
            for (uint256 i; i < teams.length; ++i) {
                if (teams[i] != game.teamOf(wanted)) return i;
            }
            return 0;
        }
        address[] memory candidates = game.candidatesOf(id);
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i] != wanted) return i;
        }
        return options - 1;
    }
}
