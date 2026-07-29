// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SurvivalGame} from "../src/SurvivalGame.sol";
import {RosterToken} from "../src/RosterToken.sol";
import {IInterfold} from "../src/interfaces/IInterfold.sol";

/// @notice Deploys the LIFE/JURY badges and the game, then hands both tokens to the game.
///
/// @dev The ownership transfer is not optional bookkeeping: the game mints and burns badges as
///      players join and are eliminated, and `RosterToken` gates both on `onlyOwner`. A deployment
///      that skips it produces a game that cannot start a round.
///
///      Config is read from the environment so the same script drives a 9-day game and a
///      compressed demo. Note that `CAMPAIGN_DURATION` has a floor set by the network — it has to
///      outlast committee sortition and the DKG — so shortening it for a demo is bounded by
///      whatever the target deployment actually achieves, not by taste.
contract DeployGame is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        RosterToken life = new RosterToken("Unravel Life", "LIFE", deployer);
        RosterToken jury = new RosterToken("Unravel Jury", "JURY", deployer);

        SurvivalGame game = new SurvivalGame(
            SurvivalGame.InitParams({
                owner: deployer,
                interfold: IInterfold(vm.envAddress("INTERFOLD_ADDRESS")),
                crispProgram: vm.envAddress("CRISP_PROGRAM_ADDRESS"),
                lifeToken: life,
                juryToken: jury,
                committeeSize: IInterfold.CommitteeSize(vm.envOr("COMMITTEE_SIZE", uint256(0))),
                paramSet: uint8(vm.envOr("PARAM_SET", uint256(0))),
                computeProviderParams: vm.envOr("COMPUTE_PROVIDER_PARAMS", bytes("")),
                config: _config()
            })
        );

        life.transferOwnership(address(game));
        jury.transferOwnership(address(game));

        vm.stopBroadcast();

        console2.log("LIFE", address(life));
        console2.log("JURY", address(jury));
        console2.log("GAME", address(game));
    }

    /// @dev Split out to keep `run` under the stack limit.
    function _config() internal view returns (SurvivalGame.Config memory) {
        return SurvivalGame.Config({
            campaignDuration: uint64(vm.envOr("CAMPAIGN_DURATION", uint256(20 hours))),
            ballotDuration: uint64(vm.envOr("BALLOT_DURATION", uint256(3 hours))),
            tallyGrace: uint64(vm.envOr("TALLY_GRACE", uint256(1 hours))),
            rosterSize: uint8(vm.envOr("ROSTER_SIZE", uint256(10))),
            finalists: uint8(vm.envOr("FINALISTS", uint256(2))),
            maxMissedCheckIns: uint8(vm.envOr("MAX_MISSED_CHECKINS", uint256(2))),
            entryFee: vm.envOr("ENTRY_FEE", uint256(0))
        });
    }
}
