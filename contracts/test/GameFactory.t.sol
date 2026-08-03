// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GameFactory} from "../src/GameFactory.sol";
import {GameDeployer} from "../src/GameDeployer.sol";
import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {ICrispVotingPlugin} from "../src/interfaces/ICrispVotingPlugin.sol";
import {MockFeeToken, MockPlugin} from "./mocks/Mocks.sol";

/// @notice Lobbies created and funded by one person, free for everyone else to join.
contract GameFactoryTest is Test {
    uint64 internal constant CAMPAIGN = 1 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint64 internal constant LOBBY_TIMEOUT = 1 days;
    uint256 internal constant FEE = 1e6;
    uint256 internal constant FUNDING = 100e6;
    uint256 internal constant ENTRY_FEE = 5e6;

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

        for (uint256 i; i < 8; ++i) {
            players.push(address(uint160(0x2000 + i)));
        }
    }

    function _config(uint256 entryFee, uint8 minPlayers) internal pure returns (SurvivalGame.Config memory) {
        return SurvivalGame.Config({
            campaignDuration: CAMPAIGN,
            ballotDuration: BALLOT,
            tallyGrace: GRACE,
            teamCount: 2,
            minMembersPerTeam: 1,
            minPlayers: minPlayers,
            lobbyTimeout: LOBBY_TIMEOUT,
            mergeAt: 4,
            finalists: 2,
            maxMissedCheckIns: 0,
            entryFee: entryFee
        });
    }

    /// @dev The creator's side of creating a lobby: hold the funding, approve the factory, create.
    function _create(SurvivalGame.Config memory config, uint256 funding, string memory name)
        internal
        returns (SurvivalGame game)
    {
        fee.mint(creator, funding);
        vm.startPrank(creator);
        fee.approve(address(factory), funding);
        game = factory.create(config, name, funding);
        vm.stopPrank();
    }

    /// @dev The ordinary case: free to join, paid for by whoever started it.
    function _create(uint8 minPlayers) internal returns (SurvivalGame game) {
        return _create(_config(0, minPlayers), FUNDING, "Test");
    }

    function _join(SurvivalGame game, uint256 index, uint8 team, uint256 entryFee) internal {
        address player = players[index];
        if (entryFee != 0) {
            fee.mint(player, entryFee);
            vm.prank(player);
            fee.approve(address(game), entryFee);
        }
        vm.prank(player);
        game.join(team);
    }

    // ─── Creation ────────────────────────────────────────────────────────────────────────────

    function test_create_producesAPlayableLobby() public {
        SurvivalGame game = _create(4);

        assertEq(factory.gameCount(), 1);
        assertEq(factory.games(0), address(game));
        assertEq(game.owner(), creator, "the creator owns the game, not the factory");

        // The badges must have been handed over, or the lobby cannot seat anyone.
        assertEq(RosterToken(address(game.lifeToken())).owner(), address(game));
        assertEq(RosterToken(address(game.juryToken())).owner(), address(game));

        _join(game, 0, 1, 0);
        assertEq(game.aliveCount(), 1);
    }

    /// @dev The whole point of funding at creation: a player needs nothing but gas. No token
    ///      balance, no approval, no decision about how much a game is worth to them.
    function test_create_creatorFundsThePotAndPlayersJoinFree() public {
        SurvivalGame game = _create(4);

        assertEq(game.pot(), FUNDING, "the pot is live from the moment the lobby exists");
        assertEq(fee.balanceOf(address(game)), FUNDING);
        assertEq(fee.balanceOf(creator), 0);
        assertEq(fee.allowance(address(factory), address(game)), 0, "no allowance is left behind");

        _join(game, 0, 1, 0);
        _join(game, 1, 2, 0);

        assertEq(game.pot(), FUNDING, "joining costs nothing, so the pot does not move");
        assertEq(fee.balanceOf(players[0]), 0);
    }

    /// @dev Lobbies must not collide: each gets its own badges, so one game's roster cannot appear
    ///      in another's balances.
    function test_create_lobbiesGetDistinctBadges() public {
        SurvivalGame a = _create(4);
        SurvivalGame b = _create(4);

        assertTrue(address(a.lifeToken()) != address(b.lifeToken()));
        assertTrue(address(a.juryToken()) != address(b.juryToken()));
        assertEq(factory.gameCount(), 2);
    }

    /// @dev An impossible round shape must fail at creation rather than produce a lobby nobody can
    ///      play. The game's own constructor is the authority; this only checks it is reached.
    function test_create_rejectsAnImpossibleConfig() public {
        SurvivalGame.Config memory bad = _config(0, 4);
        bad.minPlayers = 1; // at or below finalists

        fee.mint(creator, FUNDING);
        vm.startPrank(creator);
        fee.approve(address(factory), FUNDING);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        factory.create(bad, "Bad", FUNDING);
        vm.stopPrank();
    }

    /// @dev A lobby nobody funds cannot open a round, so the factory refuses to make one. The
    ///      creator is the only source now that joining is free.
    function test_create_rejectsAnUnfundedLobby() public {
        vm.prank(creator);
        vm.expectRevert(GameFactory.FundingRequired.selector);
        factory.create(_config(0, 4), "Free", 0);
    }

    /// @dev The funding is pulled, not promised: no approval means no lobby, rather than a lobby
    ///      that claims a pot it never received.
    function test_create_rejectsFundingItCannotCollect() public {
        fee.mint(creator, FUNDING);
        vm.prank(creator); // no approve
        vm.expectRevert();
        factory.create(_config(0, 4), "Broke", FUNDING);
    }

    function test_latest_returnsNewestFirstAndPages() public {
        SurvivalGame a = _create(4);
        SurvivalGame b = _create(4);
        SurvivalGame c = _create(4);

        address[] memory page = factory.latest(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], address(c), "newest first");
        assertEq(page[1], address(b));

        address[] memory second = factory.latest(2, 2);
        assertEq(second.length, 1);
        assertEq(second[0], address(a));

        assertEq(factory.latest(9, 2).length, 0, "an offset past the end is empty, not a revert");
    }

    // ─── Entry fees ──────────────────────────────────────────────────────────────────────────

    /// @dev A creator may still ask players to stake on top — the factory does not require it, but
    ///      the game supports it, and a staked lobby's refund path has to keep working.
    function test_entryFee_stillTopsUpThePotWhenTheCreatorAsksForOne() public {
        SurvivalGame game = _create(_config(ENTRY_FEE, 4), FUNDING, "Staked");

        _join(game, 0, 1, ENTRY_FEE);
        _join(game, 1, 2, ENTRY_FEE);

        assertEq(game.pot(), FUNDING + ENTRY_FEE * 2);
    }

    // ─── Cancelling ──────────────────────────────────────────────────────────────────────────

    /// @dev With the creator funding it, a lobby that never fills strands their money rather than
    ///      the players'. Cancelling frees it, and `sweep` is how they get it back.
    function test_cancel_returnsTheCreatorsFunding() public {
        SurvivalGame game = _create(4);
        _join(game, 0, 1, 0);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        game.cancelLobby();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Cancelled));
        assertEq(game.pot(), FUNDING, "nothing was staked, so nothing is owed to players");

        vm.prank(creator);
        game.sweep(creator);
        assertEq(fee.balanceOf(creator), FUNDING);
    }

    /// @dev A staked lobby refunds the players first; only what the creator put in is sweepable.
    function test_cancel_refundsEveryPlayerBeforeTheCreator() public {
        SurvivalGame game = _create(_config(ENTRY_FEE, 4), FUNDING, "Staked");
        _join(game, 0, 1, ENTRY_FEE);
        _join(game, 1, 2, ENTRY_FEE);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        game.cancelLobby();

        assertEq(game.pot(), FUNDING, "refunds leave the pot; the funding stays");

        vm.prank(players[0]);
        game.claimRefund();
        assertEq(fee.balanceOf(players[0]), ENTRY_FEE);

        // Claiming twice takes nothing more.
        vm.prank(players[0]);
        vm.expectRevert(SurvivalGame.NothingToRefund.selector);
        game.claimRefund();

        // The other player's refund is untouched by the first claim.
        vm.prank(players[1]);
        game.claimRefund();
        assertEq(fee.balanceOf(players[1]), ENTRY_FEE);

        // And the sweep cannot reach either of them.
        vm.prank(creator);
        game.sweep(creator);
        assertEq(fee.balanceOf(creator), FUNDING, "only the funding, not the entry fees");
    }

    function test_cancel_rejectedBeforeTheTimeout() public {
        SurvivalGame game = _create(4);
        _join(game, 0, 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(SurvivalGame.LobbyStillOpen.selector, game.lobbyOpenedAt() + LOBBY_TIMEOUT)
        );
        game.cancelLobby();
    }

    /// @dev Once the floor is reached there is nothing to rescue: anyone can start the game instead,
    ///      so cancelling would be a way to destroy a viable lobby rather than to save a dead one.
    function test_cancel_rejectedOnceTheLobbyCouldStart() public {
        // A floor of three: the smallest that clears `finalists` for this shape.
        SurvivalGame game = _create(3);
        _join(game, 0, 1, 0);
        _join(game, 1, 2, 0);
        _join(game, 2, 1, 0);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.LobbyIncomplete.selector, 3, 3));
        game.cancelLobby();
    }

    /// @dev A creator cannot strand a lobby by doing nothing, because cancelling does not need them
    ///      either. It matters more now that the money at risk is theirs: anyone can release it,
    ///      but only they can collect it.
    function test_cancel_isPermissionlessLikeStarting() public {
        SurvivalGame game = _create(4);
        _join(game, 0, 1, 0);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        vm.prank(address(0xDEAD)); // a stranger, not the creator or a player
        game.cancelLobby();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Cancelled));

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        game.sweep(address(0xDEAD));
    }

    function test_cancel_rejectedWhenTheTimeoutIsDisabled() public {
        SurvivalGame.Config memory cfg = _config(0, 4);
        cfg.lobbyTimeout = 0;
        SurvivalGame game = _create(cfg, FUNDING, "NoTimeout");

        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(SurvivalGame.LobbyTimeoutDisabled.selector);
        game.cancelLobby();
    }
}
