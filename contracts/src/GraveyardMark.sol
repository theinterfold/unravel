// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {SurvivalGame} from "./SurvivalGame.sol";
import {RosterToken} from "./RosterToken.sol";

/// @title GraveyardMark
/// @notice The dead point at someone. It does nothing, and that is the point.
///
/// @dev Being voted out currently ends your participation for hours: you sit out every remaining
///      round and reappear once, at the end, to help pick the winner. That is a long time to be in
///      a group chat with nothing to do, and the people it happens to first are the ones who most
///      need a reason to stay.
///
///      So the graveyard gets one public act per round: collectively name a living player. It
///      carries no mechanical weight — it cannot eliminate, protect, or alter a ballot — and it is
///      deliberately kept that way. Give the dead real power and every elimination becomes a
///      recruitment drive, which turns the endgame into whoever built the biggest graveyard bloc.
///      Give them none and they leave. A visible, unenforceable accusation is the middle: it feeds
///      the campaign, the living have to decide whether to care, and nothing about the outcome is
///      decided by people who already lost.
///
///      Votes are per round and change freely. Unlike immunity, nothing pins them at any moment,
///      because nothing downstream reads them — the frontend shows the current standing and that
///      is the whole contract.
contract GraveyardMark {
    SurvivalGame public immutable game;
    RosterToken public immutable juryToken;

    /// @notice round => juror => the player they marked.
    mapping(uint256 => mapping(address => address)) public markOf;
    /// @notice round => candidate => marks received.
    mapping(uint256 => mapping(address => uint256)) public marksFor;

    event Marked(uint256 indexed round, address indexed juror, address indexed candidate);

    error NotAJuror(address account);
    error CandidateNotAlive(address candidate);
    error NoRoundYet();

    constructor(SurvivalGame game_, RosterToken juryToken_) {
        game = game_;
        juryToken = juryToken_;
    }

    /// @notice The round marks currently apply to — the one in play.
    function currentRound() public view returns (uint256) {
        uint256 count = game.roundCount();
        if (count == 0) revert NoRoundYet();
        return count - 1;
    }

    /// @notice Marks a living player for this round. Changeable while the round lasts.
    /// @dev Gated on the JURY badge, so only the eliminated may mark, and only the living may be
    ///      marked — a graveyard marking its own would be noise rather than a signal to the living.
    function mark(address candidate) external {
        if (juryToken.balanceOf(msg.sender) == 0) revert NotAJuror(msg.sender);
        if (game.lifeToken().balanceOf(candidate) == 0) revert CandidateNotAlive(candidate);

        uint256 round = currentRound();

        address previous = markOf[round][msg.sender];
        if (previous == candidate) return;
        if (previous != address(0)) marksFor[round][previous] -= 1;

        markOf[round][msg.sender] = candidate;
        marksFor[round][candidate] += 1;

        emit Marked(round, msg.sender, candidate);
    }

    /// @notice The most-marked living player this round, or zero on a tie or an empty graveyard.
    /// @dev Ties resolve to nobody, matching immunity: an indecisive graveyard says nothing rather
    ///      than something arbitrary.
    function markedIn(uint256 round) external view returns (address marked, uint256 count) {
        address[] memory alive = game.alivePlayers();

        bool tied;
        for (uint256 i; i < alive.length; ++i) {
            uint256 votes = marksFor[round][alive[i]];
            if (votes == 0) continue;

            if (votes > count) {
                count = votes;
                marked = alive[i];
                tied = false;
            } else if (votes == count) {
                tied = true;
            }
        }

        if (tied) return (address(0), count);
    }
}
