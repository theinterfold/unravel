// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {PublicImmunityVote} from "../src/PublicImmunityVote.sol";
import {ICrispVotingPlugin} from "../src/interfaces/ICrispVotingPlugin.sol";

/// @notice Deploys the LIFE/JURY badges and the game, then hands both tokens to the game.
///
/// @dev The ownership transfer is not bookkeeping: the game mints and burns badges as players join
///      and are eliminated, and `RosterToken` gates both on `onlyOwner`. Skipping it produces a game
///      that cannot start a round.
///
///      The CRISP voting plugin must already be deployed (see ../plugin) and its `censusProvider`
///      pointed at this game — the coordination server resolves the electorate by asking the E3's
///      requester, which is the plugin, so without that link it falls back to reconstructing
///      eligibility from token transfer logs and the roster is ignored.
contract DeployGame is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        RosterToken life = new RosterToken("Unravel Life", "LIFE", deployer);
        RosterToken jury = new RosterToken("Unravel Jury", "JURY", deployer);

        SurvivalGame game = new SurvivalGame(
            SurvivalGame.InitParams({
                owner: deployer,
                plugin: ICrispVotingPlugin(vm.envAddress("CRISP_VOTING_PLUGIN_ADDRESS")),
                feeToken: IERC20(vm.envAddress("FEE_TOKEN_ADDRESS")),
                lifeToken: life,
                juryToken: jury,
                config: _config()
            })
        );

        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));

        address immunity;
        if (vm.envOr("ENABLE_IMMUNITY", false)) {
            PublicImmunityVote vote = new PublicImmunityVote(game, life);
            game.setImmunitySource(vote);
            immunity = address(vote);
        }

        vm.stopBroadcast();

        console2.log("LIFE", address(life));
        console2.log("JURY", address(jury));
        console2.log("GAME", address(game));
        console2.log("IMMUNITY", immunity);
    }

    /// @dev Split out to keep `run` under the stack limit.
    ///
    ///      Both `TEAM_COUNT` and `MEMBERS_PER_TEAM` are ballot option counts, so both are capped at
    ///      10 by the CRISP circuit — that is what lets 10x10 support 100 players while every ballot
    ///      stays provable. `CAMPAIGN_DURATION` has a floor set by the network: the ballot window
    ///      opens when it ends, and committee sortition plus the DKG have to fit inside it (~290s
    ///      measured on a local devnet).
    function _config() internal view returns (SurvivalGame.Config memory) {
        return SurvivalGame.Config({
            campaignDuration: uint64(vm.envOr("CAMPAIGN_DURATION", uint256(20 hours))),
            ballotDuration: uint64(vm.envOr("BALLOT_DURATION", uint256(3 hours))),
            tallyGrace: uint64(vm.envOr("TALLY_GRACE", uint256(1 hours))),
            teamCount: uint8(vm.envOr("TEAM_COUNT", uint256(4))),
            membersPerTeam: uint8(vm.envOr("MEMBERS_PER_TEAM", uint256(3))),
            mergeAt: uint8(vm.envOr("MERGE_AT", uint256(6))),
            finalists: uint8(vm.envOr("FINALISTS", uint256(2))),
            maxMissedCheckIns: uint8(vm.envOr("MAX_MISSED_CHECKINS", uint256(2))),
            entryFee: vm.envOr("ENTRY_FEE", uint256(0))
        });
    }
}
