// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {RosterToken} from "../src/RosterToken.sol";

contract RosterTokenTest is Test {
    RosterToken internal token;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new RosterToken("Life", "LIFE", owner);
    }

    function _mint(address to) internal {
        vm.prank(owner);
        token.mint(to);
    }

    function test_mint_grantsUnitAndVotingPower() public {
        _mint(alice);
        assertEq(token.balanceOf(alice), token.UNIT());
        assertEq(token.getVotes(alice), token.UNIT());
    }

    function test_mint_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice);
    }

    function test_mint_revertsForExistingHolder() public {
        _mint(alice);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RosterToken.AlreadyHolder.selector, alice));
        token.mint(alice);
    }

    function test_burn_zeroesBalanceAndVotingPower() public {
        _mint(alice);
        vm.prank(owner);
        token.burn(alice);

        assertEq(token.balanceOf(alice), 0);
        // The census depends on this: a burned badge must leave no residual voting power behind.
        assertEq(token.getVotes(alice), 0);
    }

    function test_burn_revertsForNonHolder() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RosterToken.NotHolder.selector, alice));
        token.burn(alice);
    }

    function test_burn_onlyOwner() public {
        _mint(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.burn(alice);
    }

    /// @dev A transferable badge is a buyable life and a buyable ballot.
    function test_transfer_reverts() public {
        _mint(alice);
        // Read UNIT() up front: it must not be the call that `expectRevert` arms against.
        uint256 unit = token.UNIT();

        vm.prank(alice);
        vm.expectRevert(RosterToken.Soulbound.selector);
        token.transfer(bob, unit);
    }

    function test_transferFrom_reverts() public {
        _mint(alice);
        uint256 unit = token.UNIT();

        vm.prank(alice);
        token.approve(bob, unit);

        vm.prank(bob);
        vm.expectRevert(RosterToken.Soulbound.selector);
        token.transferFrom(alice, bob, unit);
    }

    function test_clock_isTimestampBased() public view {
        assertEq(token.clock(), uint48(block.timestamp));
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    function test_pastVotes_trackHistory() public {
        _mint(alice);
        uint256 mintedAt = block.timestamp;

        vm.warp(mintedAt + 100);
        vm.prank(owner);
        token.burn(alice);
        vm.warp(mintedAt + 200);

        assertEq(token.getPastVotes(alice, mintedAt + 50), token.UNIT());
        assertEq(token.getPastVotes(alice, mintedAt + 150), 0);
    }
}
