// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GameFactory} from "../src/GameFactory.sol";
import {ICrispVotingPlugin} from "../src/interfaces/ICrispVotingPlugin.sol";

/// @notice Deploys the lobby factory.
///
/// @dev Deployed once, alongside one plugin and one DAO, and then never again — every lobby after
///      that is a transaction rather than a deployment. That is the whole point: starting a game
///      stops requiring a private key and a deploy script.
///
///      The plugin is shared by every lobby, which only works because it records a census provider
///      per round rather than globally. Pointing this at a plugin without that change would give
///      every lobby but one an empty census, and those rounds would run with the wrong electorate
///      rather than failing.
contract DeployFactory is Script {
    function run() external {
        vm.startBroadcast();

        GameFactory factory = new GameFactory(
            ICrispVotingPlugin(vm.envAddress("CRISP_VOTING_PLUGIN_ADDRESS")),
            IERC20(vm.envAddress("FEE_TOKEN_ADDRESS"))
        );

        vm.stopBroadcast();

        console2.log("FACTORY", address(factory));
    }
}
