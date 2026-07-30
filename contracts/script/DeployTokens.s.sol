// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {RosterToken} from "../src/RosterToken.sol";

/// @notice Deploys the LIFE and JURY badges, owned by the deployer.
///
/// @dev Separate from `DeployGame` to break a circular dependency: the CRISP voting plugin needs the
///      LIFE token address at initialization (it reads voting power from it), while the game needs
///      the plugin's address. So the order is tokens → plugin → game, and `DeployGame` adopts these
///      tokens rather than creating its own.
///
///      Ownership stays with the deployer here and is handed to the game by `DeployGame`. The game
///      mints and burns badges as players join and are eliminated, and both are `onlyOwner`.
contract DeployTokens is Script {
    function run() external {
        vm.startBroadcast();

        RosterToken life = new RosterToken("Unravel Life", "LIFE", msg.sender);
        RosterToken jury = new RosterToken("Unravel Jury", "JURY", msg.sender);

        vm.stopBroadcast();

        console2.log("LIFE", address(life));
        console2.log("JURY", address(jury));
    }
}
