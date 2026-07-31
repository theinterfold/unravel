// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

/// @notice Census resolution, isolated from the plugin's dependencies.
///
/// @dev `getCensus` cannot be driven through the real plugin without a DAO, an Interfold and a
///      committee, and the behaviour under test is three lines of lookup — so the resolution order
///      is mirrored here exactly, the same way `executability.t.sol` mirrors the quorum arithmetic.
///
///      What matters is the ordering. A single global provider makes one plugin serve exactly one
///      app: the coordination server asks the E3's requester who may vote, so a second app sharing
///      the plugin silently receives an empty census and falls back to token-holder discovery. That
///      failure is invisible — the round runs, with the wrong electorate.
contract CensusRoutingTest is Test {
    mapping(uint256 => address) internal censusProviderOf;
    address internal censusProvider;

    /// @dev Mirrors `CrispVoting.getCensus`'s provider selection.
    function _resolve(uint256 e3Id) internal view returns (address) {
        address provider = censusProviderOf[e3Id];
        if (provider == address(0)) provider = censusProvider;
        return provider;
    }

    function test_roundsRouteToTheirOwnCreator() public {
        address gameA = address(0xA);
        address gameB = address(0xB);
        censusProviderOf[1] = gameA;
        censusProviderOf[2] = gameB;

        assertEq(_resolve(1), gameA);
        assertEq(_resolve(2), gameB, "a second app must not inherit the first app's electorate");
    }

    /// @dev The whole point: two apps on one plugin, neither seeing the other's roster.
    function test_twoAppsShareOnePluginWithoutCollision() public {
        censusProviderOf[10] = address(0xA);
        censusProviderOf[11] = address(0xB);
        censusProviderOf[12] = address(0xA);

        assertEq(_resolve(10), address(0xA));
        assertEq(_resolve(11), address(0xB));
        assertEq(_resolve(12), address(0xA));
    }

    /// @dev Existing single-app deployments configure the global provider and never set a per-round
    ///      one. They must keep working untouched.
    function test_fallsBackToTheGlobalProvider() public {
        censusProvider = address(0xC0FFEE);
        assertEq(_resolve(99), address(0xC0FFEE));
    }

    /// @dev A round's own provider wins over the global one, so a stale global setting cannot
    ///      silently capture rounds that belong to somebody else.
    function test_perRoundProviderWinsOverGlobal() public {
        censusProvider = address(0xC0FFEE);
        censusProviderOf[7] = address(0xBEEF);
        assertEq(_resolve(7), address(0xBEEF));
    }

    /// @dev Neither configured: the server falls back to its own discovery, which is the documented
    ///      behaviour rather than a failure.
    function test_zeroWhenNothingIsConfigured() public view {
        assertEq(_resolve(5), address(0));
    }
}
