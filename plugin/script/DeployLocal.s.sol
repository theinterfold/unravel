// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import {CrispVoting} from "../src/CrispVoting.sol";
import {ICrispVoting} from "../src/ICrispVoting.sol";
import {IInterfold} from "../src/IInterfold.sol";

/// @notice Deploys a DAO and the CRISP voting plugin onto a local devnet.
///
/// @dev Deliberately bypasses `DAOFactory` and `PluginRepoFactory`, which the upstream
///      `DeploySimple` script requires. Those are Aragon *framework* contracts that exist on public
///      networks and are not part of a CRISP devnet — the addresses in upstream's `.env.example` are
///      Sepolia's. Their job is publishing a versioned plugin to a `PluginRepo` so DAOs can install
///      it through the PluginSetupProcessor. Local testing needs a working plugin, not a published
///      one, so this deploys both directly and wires the permission by hand.
///
///      Both contracts are UUPS: their constructors call `_disableInitializers()`, so the
///      implementation can never be initialized and each must sit behind a proxy. Deploying the
///      implementation and calling `initialize` on it directly silently produces a dead contract.
///
///      Required env: INTERFOLD_ADDRESS, CRISP_PROGRAM_ADDRESS, VOTING_TOKEN_ADDRESS.
///      Optional: COMPUTE_PROVIDER_PARAMS, COMMITTEE_SIZE, PARAM_SET, MIN_PARTICIPATION,
///      MIN_DURATION, MIN_PROPOSER_VOTING_POWER.
contract DeployLocal is Script {
    using ProxyLib for address;

    function run() external {
        address interfold = vm.envAddress("INTERFOLD_ADDRESS");
        address crispProgram = vm.envAddress("CRISP_PROGRAM_ADDRESS");
        // The plugin reads voting power from this token. For UNRAVEL it is the LIFE badge, whose
        // holders are exactly the surviving players.
        address votingToken = vm.envAddress("VOTING_TOKEN_ADDRESS");

        vm.startBroadcast();
        address deployer = msg.sender;

        // ─── DAO ──────────────────────────────────────────────────────────────────────────────
        //
        // The deployer is the initial owner, which grants it ROOT on the DAO — enough to hand the
        // plugin execute rights below. On a devnet that is the point; on a real deployment ROOT
        // would be revoked once the permissions are wired.
        DAO daoImpl = new DAO();
        // `payable` because DAO has a payable fallback, so a plain address cast is rejected.
        DAO dao = DAO(
            payable(
                address(daoImpl).deployUUPSProxy(
                    abi.encodeCall(DAO.initialize, (bytes("unravel-devnet"), deployer, address(0), ""))
                )
            )
        );

        // ─── Plugin ───────────────────────────────────────────────────────────────────────────

        CrispVoting pluginImpl = new CrispVoting();
        CrispVoting plugin = CrispVoting(
            address(pluginImpl).deployUUPSProxy(
                abi.encodeCall(
                    CrispVoting.initialize,
                    (
                        ICrispVoting.PluginInitParams({
                            dao: IDAO(address(dao)),
                            token: votingToken,
                            interfold: interfold,
                            committeeSize: IInterfold.CommitteeSize(vm.envOr("COMMITTEE_SIZE", uint256(0))),
                            paramSet: uint8(vm.envOr("PARAM_SET", uint256(0))),
                            crispProgramAddress: crispProgram,
                            computeProviderParams: vm.envOr("COMPUTE_PROVIDER_PARAMS", bytes("")),
                            votingSettings: ICrispVoting.VotingSettings({
                                minProposerVotingPower: vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(0)),
                                // Participation is checked against the electorate the proposal
                                // declares, so a low threshold here keeps a devnet round from being
                                // blocked by one absent voter.
                                minParticipation: uint32(vm.envOr("MIN_PARTICIPATION", uint256(1))),
                                minDuration: uint64(vm.envOr("MIN_DURATION", uint256(60)))
                            }),
                            // Set after the game is deployed — it needs this plugin's address first.
                            censusProvider: address(0)
                        })
                    )
                )
            )
        );

        // ─── Permissions ──────────────────────────────────────────────────────────────────────
        //
        // Without EXECUTE_PERMISSION the plugin can tally a proposal but never enact it. UNRAVEL
        // reads the tally itself and does not rely on DAO execution, so this is not strictly needed
        // for the game — but a plugin that cannot execute is not a working plugin, and leaving it
        // out would make any later DAO-executing round fail for a non-obvious reason.
        dao.grant(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID());

        // The deployer keeps MANAGER_PERMISSION so it can call setCensusProvider below.
        dao.grant(address(plugin), deployer, plugin.MANAGER_PERMISSION_ID());

        vm.stopBroadcast();

        console2.log("DAO", address(dao));
        console2.log("PLUGIN", address(plugin));
        console2.log("");
        console2.log("Next: deploy the game with CRISP_VOTING_PLUGIN_ADDRESS set to PLUGIN,");
        console2.log("then point the plugin back at it:");
        console2.log("  cast send PLUGIN 'setCensusProvider(address)' GAME");
    }
}
