// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RosterToken
/// @notice A soulbound `ERC20Votes` badge representing membership of a set: one unit per member,
///         mintable and burnable only by the owning game contract.
///
/// @dev Deployed twice by the game — once as LIFE (held by surviving players, burned on
///      elimination) and once as JURY (minted on elimination, held by the jury that picks the
///      winner). Membership is therefore expressed as `balanceOf(player) == 1`.
///
///      Three properties matter and each is load-bearing:
///
///      1. **Soulbound.** Transfers between holders revert. A survival game where you can buy
///         someone's life is not a survival game, and a transferable ballot is a buyable ballot.
///         Only mint and burn (transfers to/from the zero address) are permitted.
///
///      2. **Auto-delegated on mint.** `ERC20Votes` grants zero voting power until an account
///         delegates, and players cannot be relied upon to send a `delegate` transaction. Minting
///         self-delegates so voting power tracks the balance from the first block.
///
///      3. **Timestamp clock.** `clock()` returns `block.timestamp` (EIP-6372) to match the
///         Interfold/CRISP tooling, which snapshots voting power at `start_time - 1` — a
///         timestamp, not a block number.
contract RosterToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    /// @notice Every member holds exactly this balance.
    uint256 public constant UNIT = 1e18;

    /// @notice Thrown when a transfer between two non-zero accounts is attempted.
    error Soulbound();
    /// @notice Thrown when minting to an account that already holds the badge.
    error AlreadyHolder(address account);
    /// @notice Thrown when burning from an account that does not hold the badge.
    error NotHolder(address account);

    constructor(string memory name_, string memory symbol_, address owner_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(owner_)
    {}

    /// @notice Mints the badge to `account`, self-delegating so it carries voting power at once.
    function mint(address account) external onlyOwner {
        if (balanceOf(account) != 0) revert AlreadyHolder(account);
        _mint(account, UNIT);
        // Delegate after minting so the checkpoint reflects the new balance. Re-delegating an
        // existing self-delegation would be a no-op, but a fresh mint always needs it.
        _delegate(account, account);
    }

    /// @notice Burns the badge held by `account`, dropping its voting power to zero.
    function burn(address account) external onlyOwner {
        if (balanceOf(account) == 0) revert NotHolder(account);
        _burn(account, UNIT);
    }

    /// @notice EIP-6372 clock: timestamps, matching the CRISP tooling's snapshot convention.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 clock mode descriptor.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @dev Enforces soulboundness. `from == 0` is a mint and `to == 0` is a burn; anything else
    ///      is a transfer between holders and is rejected.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert Soulbound();
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
