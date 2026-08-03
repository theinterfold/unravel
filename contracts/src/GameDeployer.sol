// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {SurvivalGame} from "./SurvivalGame.sol";

/// @notice Deploys games on the factory's behalf.
///
/// @dev Exists purely to split bytecode. A factory that deployed the game *and* both badges carried
///      the creation code of all three, which put it 4,420 bytes over the EIP-170 limit — a limit
///      that applies to each contract, not to a transaction. Holding the game's creation code here
///      and the badges' in the factory puts both comfortably under it, and a lobby is still one
///      transaction for whoever creates it.
///
///      Deliberately unprivileged and permissionless: it holds no state, grants nothing, and the
///      resulting game's owner is whatever the caller passed. Calling it directly is equivalent to
///      deploying a `SurvivalGame` yourself, which anybody could already do.
contract GameDeployer {
    function deploy(SurvivalGame.InitParams calldata params) external returns (SurvivalGame) {
        return new SurvivalGame(params);
    }
}
