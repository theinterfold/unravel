// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IInterfold} from "../../src/interfaces/IInterfold.sol";
import {E3, IE3Program, IDecryptionVerifier} from "../../src/interfaces/IE3.sol";
import {ICiphernodeRegistry} from "../../src/interfaces/ICiphernodeRegistry.sol";
import {IBondingRegistry} from "../../src/interfaces/IBondingRegistry.sol";
import {IImmunitySource} from "../../src/interfaces/IImmunitySource.sol";

/// @notice Plain ERC20 standing in for the Interfold fee token.
contract MockFeeToken is ERC20 {
    constructor() ERC20("Mock Fee", "mFEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal Interfold stub: hands out sequential E3 ids and charges a flat quote.
/// @dev Only the surface `SurvivalGame` touches is implemented — quoting, requesting and the fee
///      token. Everything else in `IInterfold` is irrelevant to the game's state machine, which is
///      the point of testing against a stub: the round logic is exercised with no crypto in the
///      loop, so a failing test means the game is wrong, not the committee.
contract MockInterfold {
    IERC20 public immutable feeTokenAddress;
    uint256 public quote;
    uint256 public nextE3Id;

    /// @notice Records the custom params of the last request so tests can assert the ballot shape.
    bytes public lastCustomParams;
    uint256[2] public lastInputWindow;

    constructor(IERC20 feeToken_, uint256 quote_) {
        feeTokenAddress = feeToken_;
        quote = quote_;
    }

    function setQuote(uint256 quote_) external {
        quote = quote_;
    }

    function feeToken() external view returns (IERC20) {
        return feeTokenAddress;
    }

    function getE3Quote(IInterfold.E3RequestParams calldata) external view returns (uint256) {
        return quote;
    }

    function request(IInterfold.E3RequestParams calldata params)
        external
        returns (uint256 e3Id, E3 memory e3)
    {
        feeTokenAddress.transferFrom(msg.sender, address(this), quote);

        lastCustomParams = params.customParams;
        lastInputWindow = params.inputWindow;

        e3Id = nextE3Id++;
        return (e3Id, e3);
    }
}

/// @notice CRISP program stub whose tally is set directly by tests.
contract MockCRISP {
    mapping(uint256 => uint256[]) internal tallies;

    function setTally(uint256 e3Id, uint256[] calldata counts) external {
        tallies[e3Id] = counts;
    }

    function decodeTally(uint256 e3Id) external view returns (uint256[] memory) {
        return tallies[e3Id];
    }
}

/// @notice Immunity stub returning a fixed player per round.
contract MockImmunitySource is IImmunitySource {
    mapping(uint256 => address) public immune;

    function set(uint256 round, address player) external {
        immune[round] = player;
    }

    function immuneFor(uint256 round) external view returns (address) {
        return immune[round];
    }
}
