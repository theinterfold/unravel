// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.27;

/// @title IImmunitySource
/// @notice Supplies the player, if any, who cannot be eliminated in a given round.
///
/// @dev Deliberately a separate contract from the game. The elimination ballot is private by
///      construction; immunity is meant to be the *public*, attributable counterweight to it, and
///      keeping it behind this interface lets that public mechanism be swapped — an Aragon
///      TokenVoting proposal, a sponsor pick, or nothing at all — without touching the state
///      machine that runs the secret ballot.
///
///      An immune player is removed from the ballot's candidate list for that round, which also
///      shrinks `numOptions`. They still vote.
interface IImmunitySource {
    /// @notice Returns the player immune from elimination in `round`, or the zero address if none.
    /// @dev MUST be settled and immutable by the time the round's ballot opens; the game pins the
    ///      candidate list at that point and a later change would desynchronise the option indices
    ///      from the ciphertexts already cast against them.
    /// @param round The round number being opened.
    /// @return The immune player, or `address(0)` for no immunity this round.
    function immuneFor(uint256 round) external view returns (address);
}
