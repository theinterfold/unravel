// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICrispVotingPlugin} from "../../src/interfaces/ICrispVotingPlugin.sol";
import {IImmunitySource} from "../../src/interfaces/IImmunitySource.sol";

/// @notice Plain ERC20 standing in for the Interfold fee token.
contract MockFeeToken is ERC20 {
    constructor() ERC20("Mock Fee", "mFEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for the CRISP Aragon voting plugin.
///
/// @dev Only the surface the game touches: create a proposal (which in production requests the E3),
///      expose the E3 id, and return a tally. Everything about committees, proofs and decryption
///      lives outside the contract under test — so a failing test here means the game's round logic
///      is wrong, not that the crypto misbehaved.
contract MockPlugin {
    uint256 public fee;
    uint256 public nextProposalId;
    uint256 public nextE3Id;

    mapping(uint256 => uint256) public e3IdOf;
    mapping(uint256 => uint256[]) internal tallies;

    /// @notice Custom params of the most recent proposal, so tests can assert the ballot shape.
    bytes public lastData;
    uint64 public lastStartDate;
    uint64 public lastEndDate;
    bytes public lastMetadata;

    IERC20 internal immutable feeToken;

    constructor(IERC20 feeToken_, uint256 fee_) {
        feeToken = feeToken_;
        fee = fee_;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setTally(uint256 proposalId, uint256[] calldata counts) external {
        tallies[proposalId] = counts;
    }

    function createProposal(
        bytes memory metadata,
        ICrispVotingPlugin.Action[] memory,
        uint64 startDate,
        uint64 endDate,
        bytes memory data
    ) external returns (uint256 proposalId) {
        // The real plugin pulls its Interfold fee from the caller, so the game must have approved it.
        feeToken.transferFrom(msg.sender, address(this), fee);

        lastMetadata = metadata;
        lastData = data;
        lastStartDate = startDate;
        lastEndDate = endDate;

        proposalId = ++nextProposalId;
        e3IdOf[proposalId] = nextE3Id++;
    }

    function getE3Id(uint256 proposalId) external view returns (uint256) {
        return e3IdOf[proposalId];
    }

    function getTally(uint256 proposalId) external view returns (ICrispVotingPlugin.TallyResults memory) {
        return ICrispVotingPlugin.TallyResults({counts: tallies[proposalId]});
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
