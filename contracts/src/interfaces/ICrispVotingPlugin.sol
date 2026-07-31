// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.27;

/// @title ICrispVotingPlugin
/// @notice The slice of the vendored CRISP Aragon voting plugin the game actually uses.
///
/// @dev Deliberately a hand-written subset rather than an import: the plugin lives in a separate
///      Foundry root because Aragon OSx pins OpenZeppelin 4.9.6 while these contracts use 5.1.0.
///      The game only ever needs to create a proposal and read its tally, so a narrow interface
///      keeps the two dependency trees apart entirely.
interface ICrispVotingPlugin {
    /// @notice An action the proposal executes if it passes. Kept empty by the game.
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Creates a proposal, which requests the E3 that carries the ballot.
    /// @dev `_data` is the ABI-encoded custom params:
    ///      `(allowFailureMap, numOptions, creditMode, credits, electorateSize)`.
    ///      The fee is pulled from the caller, so the caller must have approved the plugin.
    /// @return proposalId The created proposal id.
    function createProposal(
        bytes memory metadata,
        Action[] memory actions,
        uint64 startDate,
        uint64 endDate,
        bytes memory data
    ) external returns (uint256 proposalId);

    /// @notice The decoded tally, one count per ballot option.
    /// @dev Wrapped in a struct to match the plugin's ABI exactly. A bare `uint256[]` would encode
    ///      differently — a tuple containing a dynamic array carries an extra offset word — and the
    ///      decode would silently produce garbage.
    struct TallyResults {
        uint256[] counts;
    }

    /// @notice The decoded tally for a proposal, one count per ballot option.
    function getTally(uint256 proposalId) external view returns (TallyResults memory);

    /// @notice The E3 backing a proposal, needed to address the round off-chain.
    function getE3Id(uint256 proposalId) external view returns (uint256);

    /// @notice Who answers `getCensus` for a given E3 — the address that created its proposal.
    /// @dev Recorded by the plugin at creation, so a game answers for its own rounds and nothing
    ///      else. One plugin can therefore serve any number of games.
    function censusProviderOf(uint256 e3Id) external view returns (address);
}
