// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ICRISP} from "../src/ICRISP.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";

/// @notice Pure-logic tests for the executability rules.
///
/// @dev These mirror `_quorumReached` and `_leadingOption` rather than driving the whole plugin,
///      because the interesting behaviour is arithmetic and does not need a DAO, an Interfold or a
///      committee to exercise. The full-plugin path is covered by the devnet harness.
///
///      The reason this file exists at all: upstream refused to execute any proposal with more than
///      three options or constant credits, and the stated reason was that the token-supply quorum
///      denominator is meaningless under constant credits. That is correct — so lifting the
///      restriction means fixing the denominator, not deleting the check. If the denominator were
///      simply left as token supply, a constant-credit ballot would clear or miss quorum for reasons
///      unrelated to turnout.
contract ExecutabilityTest is Test {
    uint256 internal constant RATIO_BASE = 100;

    // ─── Mirrors of the contract logic ───────────────────────────────────────────────────────

    function _quorumConstant(uint256 totalVotes, uint256 electorateSize, uint256 credits, uint256 minParticipation)
        internal
        pure
        returns (bool)
    {
        uint256 electorate = electorateSize * credits;
        if (electorate == 0) return false;
        return totalVotes * RATIO_BASE >= minParticipation * electorate;
    }

    function _quorumCustom(uint256 totalVotes, uint256 scale, uint256 totalVotingPower, uint256 minParticipation)
        internal
        pure
        returns (bool)
    {
        if (totalVotingPower == 0) return false;
        return totalVotes * scale * RATIO_BASE >= minParticipation * totalVotingPower;
    }

    function _leadingOption(uint256[] memory counts) internal pure returns (uint256 index, bool unique) {
        uint256 highest;
        uint256 tied;
        for (uint256 i = 0; i < counts.length; ++i) {
            if (counts[i] > highest) {
                highest = counts[i];
                index = i;
                tied = 1;
            } else if (counts[i] == highest && highest != 0) {
                ++tied;
            }
        }
        unique = highest != 0 && tied == 1;
    }

    // ─── Constant credits: the electorate is the denominator ─────────────────────────────────

    function test_constant_quorumMetOnFullTurnout() public pure {
        // 4 voters, 1 credit each, all voted, 50% required.
        assertTrue(_quorumConstant(4, 4, 1, 50));
    }

    function test_constant_quorumMetExactlyAtThreshold() public pure {
        // 2 of 4 voted, 50% required — the boundary must pass, not just clear.
        assertTrue(_quorumConstant(2, 4, 1, 50));
    }

    function test_constant_quorumMissedBelowThreshold() public pure {
        assertFalse(_quorumConstant(1, 4, 1, 50));
    }

    /// @dev Failing closed matters: without a declared electorate there is no denominator, and any
    ///      default would be a threshold nobody chose.
    function test_constant_undeclaredElectorateCannotPassQuorum() public pure {
        assertFalse(_quorumConstant(100, 0, 1, 1));
    }

    function test_constant_multiCreditElectorateScales() public pure {
        // 10 voters x 3 credits = 30 possible; 15 cast is exactly 50%.
        assertTrue(_quorumConstant(15, 10, 3, 50));
        assertFalse(_quorumConstant(14, 10, 3, 50));
    }

    /// @dev This is the bug the old restriction was guarding against. A 4-voter constant-credit
    ///      ballot with full turnout produces totalVotes = 4. Judged against an 18-decimal token
    ///      supply it fails absurdly — not because turnout was low, but because the two numbers
    ///      are unrelated units.
    function test_constant_tallyAgainstTokenSupplyIsIncoherent() public pure {
        uint256 fullTurnout = 4;
        uint256 tokenSupply = 4 * 1e18;
        uint256 scale = 1e9; // 10 ** (18 / 2)

        assertTrue(_quorumConstant(fullTurnout, 4, 1, 50), "electorate denominator: passes");
        assertFalse(
            _quorumCustom(fullTurnout, scale, tokenSupply, 50), "token-supply denominator: fails on full turnout"
        );
    }

    // ─── Custom credits: unchanged behaviour ─────────────────────────────────────────────────

    function test_custom_scaledTurnoutStillCompared() public pure {
        // 18-dp token, supply 100e18, scale 1e9 => tallies are in 1e9 units.
        // Half the supply voting is 50e18 / 1e9 = 50e9 tally units.
        assertTrue(_quorumCustom(50e9, 1e9, 100e18, 50));
        assertFalse(_quorumCustom(49e9, 1e9, 100e18, 50));
    }

    function test_custom_zeroSupplyCannotPassQuorum() public pure {
        assertFalse(_quorumCustom(1, 1e9, 0, 1));
    }

    // ─── Winning option ──────────────────────────────────────────────────────────────────────

    function test_uniqueLeaderWins() public pure {
        uint256[] memory counts = new uint256[](4);
        counts[2] = 3;
        counts[0] = 1;
        (uint256 index, bool unique) = _leadingOption(counts);
        assertEq(index, 2);
        assertTrue(unique);
    }

    /// @dev A tie is not executable on purpose. The plugin has no basis for picking between tied
    ///      options; a game that needs one broken owns that rule itself.
    function test_tieIsNotExecutable() public pure {
        uint256[] memory counts = new uint256[](4);
        counts[1] = 2;
        counts[3] = 2;
        (, bool unique) = _leadingOption(counts);
        assertFalse(unique);
    }

    function test_threeWayTieIsNotExecutable() public pure {
        uint256[] memory counts = new uint256[](3);
        counts[0] = 1;
        counts[1] = 1;
        counts[2] = 1;
        (, bool unique) = _leadingOption(counts);
        assertFalse(unique);
    }

    function test_emptyTallyHasNoWinner() public pure {
        (, bool unique) = _leadingOption(new uint256[](10));
        assertFalse(unique);
    }

    /// @dev A trailing tie below the lead must not spoil a decisive result.
    function test_tieBelowTheLeadDoesNotBlock() public pure {
        uint256[] memory counts = new uint256[](4);
        counts[0] = 5;
        counts[1] = 2;
        counts[2] = 2;
        (uint256 index, bool unique) = _leadingOption(counts);
        assertEq(index, 0);
        assertTrue(unique);
    }

    function test_leaderAtTheLastIndex() public pure {
        uint256[] memory counts = new uint256[](10);
        counts[9] = 1;
        (uint256 index, bool unique) = _leadingOption(counts);
        assertEq(index, 9);
        assertTrue(unique);
    }

    // ─── The yes/no path is deliberately not argmax ───────────────────────────────────────────

    /// @dev Yes/No/Abstain keeps `counts[0] > counts[1]`. Argmax is not equivalent, and this is the
    ///      case that proves it: abstain polls highest, yet yes still beats no. The original rule
    ///      executes; argmax would not. Preserving it avoids silently redefining existing proposals.
    function test_yesNoAbstain_divergesFromArgmax() public pure {
        uint256[] memory counts = new uint256[](3);
        counts[0] = 3; // yes
        counts[1] = 1; // no
        counts[2] = 5; // abstain

        assertTrue(counts[0] > counts[1], "yes/no rule: executable");

        (uint256 index,) = _leadingOption(counts);
        assertEq(index, 2, "argmax would pick abstain");
    }
}
