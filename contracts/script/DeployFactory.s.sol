// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GameFactory} from "../src/GameFactory.sol";
import {GameDeployer} from "../src/GameDeployer.sol";
import {NameRegistry} from "../src/NameRegistry.sol";
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

        // Two contracts because EIP-170 applies per contract: the game's creation code and the
        // badges' do not fit in one factory. Creating a lobby is still a single transaction.
        GameDeployer deployer = new GameDeployer();

        GameFactory factory = new GameFactory(
            deployer,
            ICrispVotingPlugin(vm.envAddress("CRISP_VOTING_PLUGIN_ADDRESS")),
            IERC20(vm.envAddress("FEE_TOKEN_ADDRESS"))
        );

        // Shared by every lobby, and read by nothing on chain: a name is display only.
        NameRegistry names = new NameRegistry();

        vm.stopBroadcast();

        console2.log("NAMES", address(names));
        console2.log("DEPLOYER", address(deployer));
        console2.log("FACTORY", address(factory));
    }
}
