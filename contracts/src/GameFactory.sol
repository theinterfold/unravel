// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SurvivalGame} from "./SurvivalGame.sol";
import {GameDeployer} from "./GameDeployer.sol";
import {RosterToken} from "./RosterToken.sol";
import {PublicImmunityVote} from "./PublicImmunityVote.sol";
import {GraveyardMark} from "./GraveyardMark.sol";
import {SecretAllegiance} from "./SecretAllegiance.sol";
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
    using SafeERC20 for IERC20;

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
        uint256 funding,
        uint8 minPlayers,
        address lifeToken,
        address juryToken
    );

    /// @notice The side contracts created alongside a lobby. Emitted separately from
    ///         `LobbyCreated` so that event's shape — which the frontend's lobby list decodes —
    ///         does not change.
    event SideshowsDeployed(
        address indexed game, address indexed immunity, address graveyard, address allegiance
    );

    /// @notice The side contracts a lobby gets alongside the game itself.
    /// @dev Recorded rather than derived: none of them is reachable from `SurvivalGame`, which
    ///      knows only about its immunity source, and making the frontend reconstruct two addresses
    ///      from logs to render a panel is a worse trade than one mapping.
    struct Sideshows {
        PublicImmunityVote immunity;
        GraveyardMark graveyard;
        SecretAllegiance allegiance;
    }

    /// @notice game => the contracts deployed with it.
    mapping(address => Sideshows) public sideshowsOf;

    error ZeroAddress();
    /// @notice A lobby with an empty pot can never open a round, so the creator has to fill it.
    error FundingRequired();

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
    ///      here rather than producing a lobby nobody can play. The funding is checked on top of
    ///      that, because an empty pot is valid as a config and unplayable as a lobby.
    ///
    /// @param config The round shape and the lobby timeout.
    /// @param name A short label for the badges, so a player's wallet distinguishes one game's LIFE
    ///        from another's.
    /// @param funding Fee tokens to seed the pot with, pulled from the caller. Must be approved to
    ///        this factory first — the game does not exist yet, so it cannot be the spender.
    /// @return game The new game.
    function create(SurvivalGame.Config calldata config, string calldata name, uint256 funding)
        external
        returns (SurvivalGame game)
    {
        // The pot pays for the game as well as the winner: every round's E3 fee comes out of it, so
        // a lobby with nothing in it fills, gets started, and reverts on the first round.
        //
        // The creator pays, not the players. Making everyone stake to join turns a game you can
        // invite someone into over a link into one they have to fund and approve a token for
        // first, and that is the step where people leave. `config.entryFee` still exists for a
        // game deployed directly, but a lobby is the creator's to stand.
        //
        // Enforced here rather than in `SurvivalGame`, because a directly-deployed game may
        // legitimately be funded later by whoever runs it. That is an operator choice; a lobby
        // anyone can create is not.
        if (funding == 0) revert FundingRequired();

        RosterToken life = new RosterToken(string.concat(name, " Life"), "LIFE", address(this));
        RosterToken jury = new RosterToken(string.concat(name, " Jury"), "JURY", address(this));

        // Deployed owned by this factory, not the creator, purely so `setImmunitySource` below can
        // be called — it is `onlyOwner`, and the immunity contract cannot exist until the game has
        // an address to point at. Ownership is handed to the creator at the end of this call, so
        // the factory holds it for a few lines and never across a transaction boundary.
        game = deployer.deploy(
            SurvivalGame.InitParams({
                owner: address(this),
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

        // The public counterweight to the secret ballot: every round the living vote, in the open
        // and under their own names, for who cannot be eliminated — while the ballot that decides
        // who *is* eliminated stays sealed. Wired here rather than left to the creator because a
        // lobby without it is a strictly worse game, and "remember to call setImmunitySource" is
        // not a thing anyone remembers.
        PublicImmunityVote immunity = new PublicImmunityVote(game, life);
        game.setImmunitySource(immunity);

        // Neither of these touches the game — they read it and hold their own state. Deployed here
        // so a lobby arrives complete: a mechanic that needs a second transaction to enable is a
        // mechanic most lobbies will not have.
        GraveyardMark graveyard = new GraveyardMark(game, jury);
        SecretAllegiance allegiance = new SecretAllegiance(game, feeToken);
        sideshowsOf[address(game)] =
            Sideshows({immunity: immunity, graveyard: graveyard, allegiance: allegiance});

        // Routed through the factory because `fund` pulls from its own caller, and the game had no
        // address to approve until a moment ago. The creator approves this factory instead.
        feeToken.safeTransferFrom(msg.sender, address(this), funding);
        feeToken.forceApprove(address(game), funding);
        game.fund(funding);

        // Last, so everything above could run as owner. From here the creator's powers are the
        // narrow ones documented above: abandon a stuck round, sweep leftover funding.
        game.transferOwnership(msg.sender);

        games.push(address(game));

        emit LobbyCreated(
            address(game),
            msg.sender,
            games.length - 1,
            funding,
            config.minPlayers,
            address(life),
            address(jury)
        );
        emit SideshowsDeployed(
            address(game), address(immunity), address(graveyard), address(allegiance)
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
