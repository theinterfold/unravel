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

/// @notice Lobbies created by anyone, funded by their players, and recoverable when they never fill.
contract GameFactoryTest is Test {
    uint64 internal constant CAMPAIGN = 1 hours;
    uint64 internal constant BALLOT = 3 hours;
    uint64 internal constant GRACE = 1 hours;
    uint64 internal constant LOBBY_TIMEOUT = 1 days;
    uint256 internal constant FEE = 1e6;
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

    function _create(uint256 entryFee, uint8 minPlayers) internal returns (SurvivalGame game) {
        vm.prank(creator);
        game = factory.create(_config(entryFee, minPlayers), "Test");
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
        SurvivalGame game = _create(0, 4);

        assertEq(factory.gameCount(), 1);
        assertEq(factory.games(0), address(game));
        assertEq(game.owner(), creator, "the creator owns the game, not the factory");

        // The badges must have been handed over, or the lobby cannot seat anyone.
        assertEq(RosterToken(address(game.lifeToken())).owner(), address(game));
        assertEq(RosterToken(address(game.juryToken())).owner(), address(game));

        _join(game, 0, 1, 0);
        assertEq(game.aliveCount(), 1);
    }

    /// @dev Lobbies must not collide: each gets its own badges, so one game's roster cannot appear
    ///      in another's balances.
    function test_create_lobbiesGetDistinctBadges() public {
        SurvivalGame a = _create(0, 4);
        SurvivalGame b = _create(0, 4);

        assertTrue(address(a.lifeToken()) != address(b.lifeToken()));
        assertTrue(address(a.juryToken()) != address(b.juryToken()));
        assertEq(factory.gameCount(), 2);
    }

    /// @dev An impossible round shape must fail at creation rather than produce a lobby nobody can
    ///      play. The game's own constructor is the authority; this only checks it is reached.
    function test_create_rejectsAnImpossibleConfig() public {
        SurvivalGame.Config memory bad = _config(0, 4);
        bad.minPlayers = 1; // at or below finalists

        vm.prank(creator);
        vm.expectRevert(SurvivalGame.InvalidConfig.selector);
        factory.create(bad, "Bad");
    }

    function test_latest_returnsNewestFirstAndPages() public {
        SurvivalGame a = _create(0, 4);
        SurvivalGame b = _create(0, 4);
        SurvivalGame c = _create(0, 4);

        address[] memory page = factory.latest(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], address(c), "newest first");
        assertEq(page[1], address(b));

        address[] memory second = factory.latest(2, 2);
        assertEq(second.length, 1);
        assertEq(second[0], address(a));

        assertEq(factory.latest(9, 2).length, 0, "an offset past the end is empty, not a revert");
    }

    // ─── Buy-in ──────────────────────────────────────────────────────────────────────────────

    /// @dev The point of a buy-in: the players fund the pot, so nobody has to put money up front.
    function test_buyIn_playersFundThePot() public {
        SurvivalGame game = _create(ENTRY_FEE, 4);

        _join(game, 0, 1, ENTRY_FEE);
        _join(game, 1, 2, ENTRY_FEE);

        assertEq(game.pot(), ENTRY_FEE * 2);
        assertEq(fee.balanceOf(address(game)), ENTRY_FEE * 2);
    }

    // ─── Cancelling ──────────────────────────────────────────────────────────────────────────

    /// @dev With open joining and a buy-in, the money's risk is not a hostile joiner — it is a lobby
    ///      that simply never fills. Anyone can release it once the timeout passes.
    function test_cancel_refundsEveryPlayer() public {
        SurvivalGame game = _create(ENTRY_FEE, 4);
        _join(game, 0, 1, ENTRY_FEE);
        _join(game, 1, 2, ENTRY_FEE);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        game.cancelLobby();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Cancelled));
        assertEq(game.pot(), 0, "refunds leave the pot");

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
    }

    function test_cancel_rejectedBeforeTheTimeout() public {
        SurvivalGame game = _create(ENTRY_FEE, 4);
        _join(game, 0, 1, ENTRY_FEE);

        vm.expectRevert(
            abi.encodeWithSelector(SurvivalGame.LobbyStillOpen.selector, game.lobbyOpenedAt() + LOBBY_TIMEOUT)
        );
        game.cancelLobby();
    }

    /// @dev Once the floor is reached there is nothing to rescue: anyone can start the game instead,
    ///      so cancelling would be a way to destroy a viable lobby rather than to save a dead one.
    function test_cancel_rejectedOnceTheLobbyCouldStart() public {
        // A floor of three: the smallest that clears `finalists` for this shape.
        SurvivalGame game = _create(ENTRY_FEE, 3);
        _join(game, 0, 1, ENTRY_FEE);
        _join(game, 1, 2, ENTRY_FEE);
        _join(game, 2, 1, ENTRY_FEE);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        vm.expectRevert(abi.encodeWithSelector(SurvivalGame.LobbyIncomplete.selector, 3, 3));
        game.cancelLobby();
    }

    /// @dev A creator cannot strand a funded lobby by doing nothing, because cancelling does not
    ///      need them either.
    function test_cancel_isPermissionlessLikeStarting() public {
        SurvivalGame game = _create(ENTRY_FEE, 4);
        _join(game, 0, 1, ENTRY_FEE);

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        vm.prank(address(0xDEAD)); // a stranger, not the creator or a player
        game.cancelLobby();

        assertEq(uint8(game.stage()), uint8(SurvivalGame.Stage.Cancelled));
    }

    function test_cancel_rejectedWhenTheTimeoutIsDisabled() public {
        SurvivalGame.Config memory cfg = _config(0, 4);
        cfg.lobbyTimeout = 0;
        vm.prank(creator);
        SurvivalGame game = factory.create(cfg, "NoTimeout");

        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(SurvivalGame.LobbyTimeoutDisabled.selector);
        game.cancelLobby();
    }

    /// @dev Sweeping a cancelled lobby must not reach the players' money — the refunds have already
    ///      left the pot, so only the creator's own funding remains.
    function test_sweep_cannotTakeRefundsFromACancelledLobby() public {
        SurvivalGame game = _create(ENTRY_FEE, 4);
        _join(game, 0, 1, ENTRY_FEE);

        // The creator tops the pot up beyond the entry fees.
        fee.mint(creator, FEE);
        vm.startPrank(creator);
        fee.approve(address(game), FEE);
        game.fund(FEE);
        vm.stopPrank();

        vm.warp(block.timestamp + LOBBY_TIMEOUT);
        game.cancelLobby();

        vm.prank(creator);
        game.sweep(creator);
        assertEq(fee.balanceOf(creator), FEE, "only the funding, not the entry fee");

        // The player's refund survived the sweep.
        vm.prank(players[0]);
        game.claimRefund();
        assertEq(fee.balanceOf(players[0]), ENTRY_FEE);
    }
}
