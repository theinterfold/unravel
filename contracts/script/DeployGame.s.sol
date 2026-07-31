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
///      Deployment order is tokens → plugin → game, because the plugin needs the LIFE token address
///      at initialization while the game needs the plugin's. Afterwards the plugin's `censusProvider`
///      must be pointed at this game: the coordination server resolves the electorate by asking the
///      E3's requester, which is the plugin, so without that link it falls back to reconstructing
///      eligibility from token transfer logs and the roster is ignored entirely.
contract DeployGame is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        // Adopted rather than created: the plugin needed the LIFE address before this ran (see
        // DeployTokens). The deployer must still own them here so ownership can be handed over.
        RosterToken life = RosterToken(vm.envAddress("LIFE_TOKEN_ADDRESS"));
        RosterToken jury = RosterToken(vm.envAddress("JURY_TOKEN_ADDRESS"));

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
    ///      `TEAM_COUNT` is a ballot option count, so it is capped at 10 by the CRISP circuit — and
    ///      so is team size, because a council round puts one option per member on the ballot. That
    ///      is what lets 10x10 support 100 players while every ballot stays provable.
    ///
    ///      `MIN_MEMBERS_PER_TEAM` is a floor, not a ceiling: teams may grow to 10 regardless of it,
    ///      and it only decides whether the lobby is balanced enough to start. `MIN_PLAYERS` is the
    ///      matching floor on the whole lobby. `CAMPAIGN_DURATION` has a floor set by the network: the ballot window
    ///      opens when it ends, and committee sortition plus the DKG have to fit inside it (~290s
    ///      measured on a local devnet).
    function _config() internal view returns (SurvivalGame.Config memory) {
        return SurvivalGame.Config({
            campaignDuration: uint64(vm.envOr("CAMPAIGN_DURATION", uint256(20 hours))),
            ballotDuration: uint64(vm.envOr("BALLOT_DURATION", uint256(3 hours))),
            tallyGrace: uint64(vm.envOr("TALLY_GRACE", uint256(1 hours))),
            teamCount: uint8(vm.envOr("TEAM_COUNT", uint256(4))),
            // MEMBERS_PER_TEAM is the old name for the same knob, honoured so existing .env files
            // keep working rather than silently falling back to the default.
            minMembersPerTeam: uint8(
                vm.envOr("MIN_MEMBERS_PER_TEAM", vm.envOr("MEMBERS_PER_TEAM", uint256(2)))
            ),
            minPlayers: uint8(vm.envOr("MIN_PLAYERS", uint256(4))),
            mergeAt: uint8(vm.envOr("MERGE_AT", uint256(6))),
            finalists: uint8(vm.envOr("FINALISTS", uint256(2))),
            maxMissedCheckIns: uint8(vm.envOr("MAX_MISSED_CHECKINS", uint256(2))),
            entryFee: vm.envOr("ENTRY_FEE", uint256(0))
        });
    }
}
