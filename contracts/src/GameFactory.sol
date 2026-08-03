// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SurvivalGame} from "./SurvivalGame.sol";
import {GameDeployer} from "./GameDeployer.sol";
import {RosterToken} from "./RosterToken.sol";
import {ICrispVotingPlugin} from "./interfaces/ICrispVotingPlugin.sol";

/// @notice Creates lobbies.
///
/// @dev One transaction produces a playable game: the two roster badges, the game itself, and the
///      ownership handover between them. Before this, starting a lobby meant running a deploy
///      script with a private key, which put "start a game" in the hands of whoever operates the
///      repository rather than whoever wants to play.
///
///      Every lobby shares one voting plugin. That is possible because the plugin records a census
///      provider per round rather than globally — each game answers `getCensus` for its own rounds
///      and nothing else. A per-lobby plugin and DAO would otherwise be four contracts a game.
///
///      The badges are not shared. They are `onlyOwner` for mint and burn and the owner is the
///      game, so two games cannot hold the same pair; and a shared badge would also mix one lobby's
///      players into another's balances.
contract GameFactory {
    /// @notice Holds the game's creation code, which does not fit in here alongside the badges'.
    /// @dev See `GameDeployer`: EIP-170 applies per contract, so the three creation codes are split
    ///      across two rather than crammed into one.
    GameDeployer public immutable deployer;

    /// @notice The voting plugin every lobby routes its rounds through.
    ICrispVotingPlugin public immutable plugin;

    /// @notice The token entry fees and E3 fees are denominated in.
    IERC20 public immutable feeToken;

    /// @notice Every lobby ever created, oldest first.
    address[] public games;

    /// @notice Emitted for each new lobby. The frontend lists lobbies from this.
    event LobbyCreated(
        address indexed game,
        address indexed creator,
        uint256 indexed index,
        uint256 entryFee,
        uint8 minPlayers,
        address lifeToken,
        address juryToken
    );

    error ZeroAddress();
    /// @notice A lobby with no buy-in has no pot, and a lobby with no pot can never open a round.
    error BuyInRequired();

    constructor(GameDeployer deployer_, ICrispVotingPlugin plugin_, IERC20 feeToken_) {
        if (
            address(deployer_) == address(0) || address(plugin_) == address(0)
                || address(feeToken_) == address(0)
        ) revert ZeroAddress();
        deployer = deployer_;
        plugin = plugin_;
        feeToken = feeToken_;
    }

    /// @notice Creates a lobby.
    ///
    /// @dev The caller owns the resulting game. Ownership is deliberately narrow — it can abandon a
    ///      round the committee never settled and sweep leftover funding, and that is all. It cannot
    ///      choose who joins, cannot start the game, and cannot stop anyone else starting or
    ///      settling it, because those are the powers that would let a creator hold a funded lobby
    ///      hostage.
    ///
    ///      `SurvivalGame`'s constructor validates the config, so an impossible round shape reverts
    ///      here rather than producing a lobby nobody can play. The buy-in is checked on top of
    ///      that, because a free lobby is valid as a config and unplayable as a lobby.
    ///
    /// @param config The round shape, including the entry fee and the lobby timeout.
    /// @param name A short label for the badges, so a player's wallet distinguishes one game's LIFE
    ///        from another's.
    /// @return game The new game.
    function create(SurvivalGame.Config calldata config, string calldata name)
        external
        returns (SurvivalGame game)
    {
        // The pot pays for the game as well as the winner: every round's E3 fee comes out of it, so
        // a lobby that collects nothing fills, gets started, and reverts on the first round. Nobody
        // is going to fund a stranger's lobby on their behalf, so the buy-in is the only source.
        //
        // Enforced here rather than in `SurvivalGame`, because a directly-deployed game may
        // legitimately be free to enter and funded up front by whoever runs it. That is an operator
        // choice; a lobby anyone can create is not.
        if (config.entryFee == 0) revert BuyInRequired();

        RosterToken life = new RosterToken(string.concat(name, " Life"), "LIFE", address(this));
        RosterToken jury = new RosterToken(string.concat(name, " Jury"), "JURY", address(this));

        game = deployer.deploy(
            SurvivalGame.InitParams({
                owner: msg.sender,
                plugin: plugin,
                feeToken: feeToken,
                lifeToken: life,
                juryToken: jury,
                config: config
            })
        );

        // The game mints and burns badges as players join and are eliminated, and both are
        // `onlyOwner`. Without this the lobby cannot seat anybody.
        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));

        games.push(address(game));

        emit LobbyCreated(
            address(game),
            msg.sender,
            games.length - 1,
            config.entryFee,
            config.minPlayers,
            address(life),
            address(jury)
        );
    }

    /// @notice How many lobbies exist.
    function gameCount() external view returns (uint256) {
        return games.length;
    }

    /// @notice A page of lobbies, newest first.
    /// @dev Paged because the list only grows, and an unbounded `games` copy would eventually stop
    ///      fitting in a single `eth_call`.
    /// @param offset How many of the newest lobbies to skip.
    /// @param limit The most to return.
    function latest(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = games.length;
        if (offset >= total) return new address[](0);

        uint256 remaining = total - offset;
        uint256 size = remaining < limit ? remaining : limit;

        page = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            // `total - 1 - offset` is the newest unskipped entry; walk backwards from there.
            page[i] = games[total - 1 - offset - i];
        }
    }
}
