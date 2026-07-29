// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {IImmunitySource} from "./interfaces/IImmunitySource.sol";
import {SurvivalGame} from "./SurvivalGame.sol";
import {RosterToken} from "./RosterToken.sol";

/// @title PublicImmunityVote
/// @notice The public, attributable counterweight to the secret elimination ballot.
///
/// @dev Each round, players vote **in the open, under their own address** for the one player who
///      cannot be eliminated. The same players, in the same round, cast a secret ballot to send
///      someone home. The gap between the two is the game: you must protect someone on the record
///      while knifing someone in private, and everyone can see the first half.
///
///      Deliberately not an Aragon TokenVoting plugin. TokenVoting decides Yes/No/Abstain on a
///      proposal; immunity is an N-way election, which would need one proposal per candidate per
///      round. This votes directly against the same `ERC20Votes` roster token an Aragon plugin
///      would have used, so the game can still be owned and funded by a DAO — the DAO just is not
///      the right place to run the election itself.
///
///      **Timing.** Immunity for round N must be settled before round N opens, because the game
///      pins the candidate list at that moment and a later change would desynchronise ballot
///      option indices from ciphertexts already cast. So votes accumulate for the *next* round and
///      freeze when it opens.
contract PublicImmunityVote is IImmunitySource {
    SurvivalGame public immutable game;
    RosterToken public immutable lifeToken;

    /// @notice round => voter => the player they voted to protect.
    mapping(uint256 => mapping(address => address)) public ballotOf;
    /// @notice round => candidate => votes received.
    mapping(uint256 => mapping(address => uint256)) public votesFor;

    event ImmunityVoteCast(uint256 indexed round, address indexed voter, address indexed candidate);

    error NotAlive(address account);
    error CandidateNotAlive(address candidate);
    error RoundAlreadyOpen(uint256 round);

    constructor(SurvivalGame game_, RosterToken lifeToken_) {
        game = game_;
        lifeToken = lifeToken_;
    }

    /// @notice The round currently accepting immunity votes — the next one to open.
    function pendingRound() public view returns (uint256) {
        return game.roundCount();
    }

    /// @notice Votes to protect `candidate` in the next round. Changeable until that round opens.
    /// @dev Public and attributable on purpose. This is the promise a player can be held to,
    ///      precisely because the elimination ballot is the promise they cannot.
    function voteForImmunity(address candidate) external {
        if (lifeToken.balanceOf(msg.sender) == 0) revert NotAlive(msg.sender);
        if (lifeToken.balanceOf(candidate) == 0) revert CandidateNotAlive(candidate);

        uint256 round = pendingRound();

        address previous = ballotOf[round][msg.sender];
        if (previous == candidate) return;
        if (previous != address(0)) votesFor[round][previous] -= 1;

        ballotOf[round][msg.sender] = candidate;
        votesFor[round][candidate] += 1;

        emit ImmunityVoteCast(round, msg.sender, candidate);
    }

    /// @inheritdoc IImmunitySource
    /// @dev One player, one vote, matching the elimination ballot's one-credit weighting.
    ///
    ///      A tie grants nobody immunity. Immunity is a bonus, and breaking a tie at random would
    ///      hand out protection that no majority actually voted for — better that an indecisive
    ///      public simply fails to protect anyone.
    ///
    ///      Computed by iteration rather than tracked incrementally: the roster is capped at ten,
    ///      so this is cheap, and a stateless read cannot drift out of sync with vote changes.
    function immuneFor(uint256 round) external view returns (address) {
        address[] memory alive = game.alivePlayers();

        address leader;
        uint256 highest;
        bool tied;

        for (uint256 i; i < alive.length; ++i) {
            uint256 count = votesFor[round][alive[i]];
            if (count == 0) continue;

            if (count > highest) {
                highest = count;
                leader = alive[i];
                tied = false;
            } else if (count == highest) {
                tied = true;
            }
        }

        return tied ? address(0) : leader;
    }
}
