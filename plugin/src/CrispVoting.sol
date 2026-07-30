// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.29;

import {Action} from "@aragon/osx/core/dao/DAO.sol";
import {PluginUUPSUpgradeable} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {
    ProposalUpgradeable
} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/ProposalUpgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC6372Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";
import {
    IERC20MetadataUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IProposal} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/IProposal.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IInterfold} from "./IInterfold.sol";
import {E3, IE3Program} from "./IE3.sol";
import {ICrispVoting} from "./ICrispVoting.sol";
import {ICRISP} from "./ICRISP.sol";

/// @notice Supplies the eligible voter set for an E3.
/// @dev Implemented by whatever app owns the electorate — a game roster, an allowlisted cohort, a
///      committee. MUST be immutable for a given `e3Id` once its round is open: the server reads it
///      at chain head, and a census that changed mid-round would validate ballots against a
///      different eligibility tree than the one they were proven against.
interface ICensusProvider {
    function getCensus(uint256 e3Id) external view returns (address[] memory);
}

/// @title CrispVoting
/// @notice An Aragon OSx governance plugin that runs private, encrypted votes through Interfold's
/// CRISP E3 program. Proposal creation registers an E3 request with Interfold; once the tally is
/// decrypted and published by the CRISP program, the proposal can be executed if it meets the
/// quorum and winning-option criteria.
/// @dev In order for executed actions to run, the plugin needs to hold EXECUTE_PERMISSION_ID on the DAO.
/// @notice This plugin is inspired by MACI's voting plugin - https://github.com/privacy-ethereum/maci-voting-plugin-aragon/blob/main/src/MaciVoting.sol
contract CrispVoting is PluginUUPSUpgradeable, ProposalUpgradeable, ICrispVoting {
    /// @notice used to perform safe ERC20 operations
    using SafeERC20 for IERC20;

    /// @notice The manager permission id
    bytes32 public constant MANAGER_PERMISSION_ID = keccak256("MANAGER_PERMISSION");

    /// @notice The denominator for ratio calculations.
    uint256 internal constant RATIO_BASE = 100;

    /// @notice The interface id for the Crisp Voting plugin
    bytes4 internal constant CRISP_VOTING_INTERFACE_ID = this.initialize.selector ^ this.minProposerVotingPower.selector
        ^ this.totalVotingPower.selector ^ this.getVotingToken.selector ^ this.minParticipation.selector
        ^ this.minDuration.selector ^ this.getProposal.selector;

    /// @notice The interfold contract reference
    IInterfold public interfold;

    /// @notice The token used to pay for Interfold fees
    IERC20 public interfoldFeeToken;

    /// @notice An
    /// [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes)
    /// compatible contract referencing the token being used for voting.
    IVotesUpgradeable private votingToken;

    /// @notice The voting settings
    VotingSettings private votingSettings;

    /// @notice A mapping between proposal IDs and proposal information.
    mapping(uint256 => Proposal) internal proposals;

    /// @notice The ciphernode threshold
    IInterfold.CommitteeSize private committeeSize;
    /// @notice The parameter set to use
    uint8 private paramSet;
    /// @notice The address of the E3 Program
    address private crispProgramAddress;
    /// @notice The ABI encoded compute provider parameters
    bytes private computeProviderParams;

    /// @notice Contract answering `getCensus(e3Id)` on this plugin's behalf. Zero disables it.
    address public censusProvider;

    /// @notice Disables the initializers on the implementation contract to prevent
    /// it from being left uninitialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the plugin
    /// @param _params The plugin initialization parameters
    function initialize(PluginInitParams calldata _params) external initializer {
        __PluginUUPSUpgradeable_init(_params.dao);

        if (_params.interfold == address(0)) {
            revert ZeroAddress();
        }
        interfold = IInterfold(_params.interfold);
        votingToken = IVotesUpgradeable(_params.token);
        interfoldFeeToken = IERC20(interfold.feeToken());
        committeeSize = _params.committeeSize;
        paramSet = _params.paramSet;
        crispProgramAddress = _params.crispProgramAddress;
        computeProviderParams = _params.computeProviderParams;
        censusProvider = _params.censusProvider;

        _updateVotingSettings(_params.votingSettings);
    }

    /// @notice Sets the contract that answers `getCensus` for this plugin's rounds.
    /// @param _censusProvider The census provider, or the zero address to disable.
    function setCensusProvider(address _censusProvider) external auth(MANAGER_PERMISSION_ID) {
        censusProvider = _censusProvider;
        emit CensusProviderUpdated(_censusProvider);
    }

    /// @notice The eligible voter set for an E3, read by the CRISP coordination server.
    /// @dev The server calls this on the E3's requester, which is this plugin rather than the app
    ///      that created the proposal — so it is forwarded to a provider that actually knows the
    ///      electorate. Returning an empty array makes the server fall back to reconstructing
    ///      eligibility from token-holder logs, which is the correct behaviour when no provider is
    ///      configured. Failures are swallowed for the same reason: a reverting provider should
    ///      degrade to the default, not wedge every round.
    /// @param _e3Id The E3 whose electorate is being resolved.
    /// @return The eligible voters, or an empty array to use the default discovery path.
    function getCensus(uint256 _e3Id) external view returns (address[] memory) {
        address provider = censusProvider;
        if (provider == address(0)) {
            return new address[](0);
        }

        try ICensusProvider(provider).getCensus(_e3Id) returns (address[] memory census) {
            return census;
        } catch {
            return new address[](0);
        }
    }

    /// @inheritdoc ICrispVoting
    function updateVotingSettings(VotingSettings calldata _votingSettings) external auth(MANAGER_PERMISSION_ID) {
        _updateVotingSettings(_votingSettings);
    }

    /// @notice Creates a new E3 request in Interfold
    /// @dev This is a wrapper around the createProposal function as we need it to be payable
    /// as there will be charges for the E3 request in Interfold.
    /// @param _metadata The metadata of the proposal
    /// @param _actions The actions that will be executed if the proposal passes
    /// @param _startDate The start date of the proposal
    /// @param _endDate The end date of the proposal
    /// @param _data The additional abi-encoded data to include more necessary fields
    /// This includes whether to allow failures, and the interfold request start window details
    /// @return proposalId The id of the proposal
    function createProposal(
        bytes memory _metadata,
        Action[] memory _actions,
        uint64 _startDate,
        uint64 _endDate,
        bytes memory _data
    ) external returns (uint256 proposalId) {
        /// @notice Create a deterministic proposal id
        proposalId = _createProposalId(keccak256(abi.encode(_actions, _metadata)));

        /// @notice Get the proposal storage variable
        Proposal storage proposal = proposals[proposalId];

        {
            /// @notice Check if the proposal already exists first
            if (_proposalExists(proposalId)) {
                revert ProposalAlreadyExists(proposalId);
            }

            /// @notice Check if the sender has enough voting power
            uint256 _minProposerVotingPower = minProposerVotingPower();
            if (_minProposerVotingPower != 0) {
                if (votingToken.getVotes(_msgSender()) < _minProposerVotingPower) {
                    revert ProposalCreationForbidden(_msgSender());
                }
            }
        }

        /// @notice Validate and normalise the dates, enforcing the configured minimum duration.
        /// The validated values feed both the Interfold input window and the stored parameters.
        (_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);

        {
            /// @notice Decode the data
            (
                uint256 _allowFailureMap,
                uint256 numOptions,
                uint256 creditMode,
                uint256 credits,
                uint256 electorateSize
            ) = abi.decode(_data, (uint256, uint256, uint256, uint256, uint256));

            if (numOptions < 2) {
                revert InvalidOptionCount(numOptions);
            }

            bytes memory customParams = abi.encode(
                address(votingToken),
                votingSettings.minProposerVotingPower,
                numOptions,
                ICRISP.CreditMode(creditMode),
                credits
            );

            IInterfold.E3RequestParams memory requestParams = IInterfold.E3RequestParams({
                committeeSize: committeeSize,
                inputWindow: [uint256(_startDate), uint256(_endDate)],
                e3Program: IE3Program(crispProgramAddress),
                computeProviderParams: computeProviderParams,
                customParams: customParams,
                paramSet: paramSet
            });

            // quote the fee, collect it from the caller, and open the E3
            uint256 e3Id = _openE3(requestParams);

            /// @notice Store the data
            proposal.tally.counts = new uint256[](numOptions);
            proposal.parameters = ProposalParameters({
                numOptions: numOptions,
                startDate: _startDate,
                endDate: _endDate,
                // snapshot the previous block so voting power is read from a finalized block
                snapshotBlock: _tokenClock() - 1,
                minVotingPower: votingSettings.minProposerVotingPower,
                minParticipation: votingSettings.minParticipation,
                creditMode: ICRISP.CreditMode(creditMode),
                credits: credits,
                electorateSize: electorateSize
            });
            proposal.allowFailureMap = _allowFailureMap;
            proposal.targetConfig = getTargetConfig();
            proposal.e3Id = e3Id;
        }

        for (uint256 i = 0; i < _actions.length;) {
            proposal.actions.push(_actions[i]);
            unchecked {
                ++i;
            }
        }

        emit ProposalCreated(
            proposalId, _msgSender(), _startDate, _endDate, _metadata, _actions, proposal.allowFailureMap
        );
    }

    /// @inheritdoc IProposal
    function execute(uint256 _proposalId) external {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        Proposal storage proposal = proposals[_proposalId];

        // signaling-only proposals (polls) cannot be executed
        // the voting window must have closed before a proposal can be executed
        if (block.timestamp < proposal.parameters.endDate) {
            revert ProposalExecutionForbidden(_proposalId);
        }

        uint256[] memory tallyCounts = ICRISP(crispProgramAddress).decodeTally(proposal.e3Id);

        // check if we can execute it using the freshly decoded tally
        if (!_canExecute(_proposalId, tallyCounts)) {
            revert ProposalExecutionForbidden(_proposalId);
        }

        /// @notice store the final tally
        proposal.tally.counts = tallyCounts;

        /// @notice we set the proposal as executed so it cannot be executed again
        proposal.executed = true;

        // just execute it
        _execute(
            proposal.targetConfig.target,
            bytes32(_proposalId),
            proposal.actions,
            proposal.allowFailureMap,
            proposal.targetConfig.operation
        );

        emit ProposalExecuted(_proposalId);
    }

    /// @notice Returns whether the proposal has succeeded or not.
    /// @dev A proposal has succeeded if it has already been executed or if it currently meets the
    /// execution criteria (quorum and the winning-option rules). This is independent of whether the
    /// proposal has actually been executed.
    /// @param _proposalId The id of the proposal.
    /// @return Whether the proposal has succeeded or not.
    function hasSucceeded(uint256 _proposalId) external view returns (bool) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        if (proposals[_proposalId].executed) {
            return true;
        }

        return _canExecute(_proposalId);
    }

    /// @notice Returns the proposal data for a given proposal ID.
    /// @param _proposalId The ID of the proposal to retrieve.
    /// @return proposal_ The proposal data including execution status, parameters, tally results,
    /// actions, and other metadata.
    function getProposal(uint256 _proposalId) external view returns (Proposal memory proposal_) {
        proposal_ = proposals[_proposalId];
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(PluginUUPSUpgradeable, ProposalUpgradeable)
        returns (bool)
    {
        return _interfaceId == CRISP_VOTING_INTERFACE_ID || super.supportsInterface(_interfaceId);
    }

    /// @inheritdoc ICrispVoting
    function getVotingToken() public view returns (IVotesUpgradeable) {
        return votingToken;
    }

    /// @inheritdoc ICrispVoting
    function minParticipation() public view returns (uint32) {
        return votingSettings.minParticipation;
    }

    /// @inheritdoc ICrispVoting
    function minDuration() public view returns (uint64) {
        return votingSettings.minDuration;
    }

    /// @inheritdoc ICrispVoting
    function minProposerVotingPower() public view returns (uint256) {
        return votingSettings.minProposerVotingPower;
    }

    /// @inheritdoc ICrispVoting
    function totalVotingPower(uint256 _blockNumber) public view returns (uint256) {
        return votingToken.getPastTotalSupply(_blockNumber);
    }

    /// @inheritdoc IProposal
    function canExecute(uint256 _proposalId) public view returns (bool) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }

        return _canExecute(_proposalId);
    }

    /// @notice Get the custom proposal parameters ABI.
    /// @dev Mirrors the `_data` payload decoded in `createProposal`.
    function customProposalParamsABI() external pure returns (string memory) {
        return
            "(uint256 allowFailureMap, uint256 numOptions, uint256 creditMode, uint256 credits, uint256 electorateSize)";
    }

    /// @notice Get the tally result
    /// @param _proposalId The id of the proposal
    /// @return The tally result
    function getTally(uint256 _proposalId) external view returns (TallyResults memory) {
        Proposal memory proposal = proposals[_proposalId];

        // if it's not executed then we wouldn't have saved the result
        if (!proposal.executed) {
            uint256[] memory counts = ICRISP(crispProgramAddress).decodeTally(proposal.e3Id);
            return TallyResults({counts: counts});
        }

        return proposals[_proposalId].tally;
    }

    /// @notice The E3 backing a proposal.
    /// @dev Needed by anything addressing the round off-chain — the CRISP server and its clients key
    ///      everything on the E3 id, not the proposal id.
    /// @param _proposalId The proposal.
    /// @return The E3 id.
    function getE3Id(uint256 _proposalId) external view returns (uint256) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }
        return proposals[_proposalId].e3Id;
    }

    /// @inheritdoc ICrispVoting
    function getWinningOption(uint256 _proposalId) external view returns (uint256) {
        uint256[] memory counts;

        if (proposals[_proposalId].executed) {
            counts = proposals[_proposalId].tally.counts;
        } else {
            counts = ICRISP(crispProgramAddress).decodeTally(proposals[_proposalId].e3Id);
        }

        uint256 maxCount = 0;
        uint256 winnerIndex = 0;

        for (uint256 i = 0; i < counts.length;) {
            if (counts[i] > maxCount) {
                maxCount = counts[i];
                winnerIndex = i;
            }
            unchecked {
                ++i;
            }
        }

        return winnerIndex;
    }

    /// @notice Validates and stores the voting settings.
    /// @dev `minParticipation` is a ratio expressed against `RATIO_BASE`, so it cannot exceed it.
    /// @param _votingSettings The voting settings to store.
    function _updateVotingSettings(VotingSettings memory _votingSettings) internal {
        if (_votingSettings.minParticipation > RATIO_BASE) {
            revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minParticipation});
        }

        votingSettings = _votingSettings;

        emit VotingSettingsUpdated(
            _votingSettings.minProposerVotingPower, _votingSettings.minParticipation, _votingSettings.minDuration
        );
    }

    /// @notice Validates and returns the proposal vote dates, enforcing the minimum duration.
    /// @param _start The start date of the proposal vote. If 0, the current timestamp is used
    /// and the vote starts immediately.
    /// @param _end The end date of the proposal vote. If 0, `_start + minDuration` is used.
    /// @return startDate The validated start date of the proposal vote.
    /// @return endDate The validated end date of the proposal vote.
    function _validateProposalDates(uint64 _start, uint64 _end)
        internal
        view
        returns (uint64 startDate, uint64 endDate)
    {
        // block.timestamp cannot exceed uint64 for ~580 billion years, so the cast is safe.
        uint64 currentTimestamp = uint64(block.timestamp);

        if (_start == 0) {
            startDate = currentTimestamp;
        } else {
            startDate = _start;

            // the vote cannot start in the past, otherwise the minimum duration is meaningless
            if (startDate < currentTimestamp) {
                revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
            }
        }

        // checked arithmetic: an absurdly large `minDuration` simply reverts here, and the caller
        // can pick another date. Bounding `minDuration` on update would tighten this further.
        uint64 earliestEndDate = startDate + votingSettings.minDuration;

        if (_end == 0) {
            endDate = earliestEndDate;
        } else {
            endDate = _end;

            if (endDate < earliestEndDate) {
                revert DateOutOfBounds({limit: earliestEndDate, actual: endDate});
            }
        }
    }

    /// @notice Internal checks to determine whether a proposal can be executed or not.
    /// @dev Fetches the tally from the CRISP program before delegating to the counts-based check.
    /// @param _proposalId The ID of the proposal to be checked
    /// @return Returns `true` if the proposal can be executed, otherwise false
    function _canExecute(uint256 _proposalId) internal view returns (bool) {
        uint256[] memory counts = ICRISP(crispProgramAddress).decodeTally(proposals[_proposalId].e3Id);
        return _canExecute(_proposalId, counts);
    }

    /// @notice Internal checks to determine whether a proposal can be executed or not, given an
    /// already-decoded tally. Avoids a redundant `decodeTally` call on the execution path.
    /// @param _proposalId The ID of the proposal to be checked
    /// @param counts The decoded tally counts for the proposal
    /// @return Returns `true` if the proposal can be executed, otherwise false
    function _canExecute(uint256 _proposalId, uint256[] memory counts) internal view returns (bool) {
        Proposal memory proposal = proposals[_proposalId];

        // can't execute twice
        if (proposal.executed) {
            return false;
        }

        // Sum all votes for quorum check
        uint256 totalVotes = 0;
        for (uint256 i = 0; i < counts.length;) {
            totalVotes += counts[i];
            unchecked {
                ++i;
            }
        }

        if (!_quorumReached(proposal.parameters, totalVotes)) {
            return false;
        }

        // Yes/No/Abstain ballots keep their original semantics: yes (index 0) must strictly beat
        // no (index 1). Argmax would NOT be equivalent — a ballot where abstain polls highest but
        // yes still beats no executes under this rule and would not under argmax — so the existing
        // meaning is preserved rather than quietly redefined.
        if (proposal.parameters.numOptions <= 3 && proposal.parameters.creditMode == ICRISP.CreditMode.CUSTOM) {
            return counts[0] > counts[1];
        }

        // N-option ballots are decided by a unique maximum. A tie is deliberately NOT executable:
        // the plugin has no basis for choosing between tied options, and inventing one would bury a
        // policy decision in infrastructure. Callers that need a tie broken should read the tally
        // and apply their own rule.
        (, bool unique) = _leadingOption(counts);
        return unique;
    }

    /// @notice Whether turnout met the participation threshold.
    /// @dev The denominator depends on the credit mode, and getting this wrong is the reason
    ///      constant-credit proposals used to be barred from executing at all.
    ///
    ///      Under `CUSTOM`, tallies are token power divided by `_voteScale()`, so turnout is scaled
    ///      back up and compared against raw token supply — multiplying turnout rather than dividing
    ///      supply avoids truncation.
    ///
    ///      Under `CONSTANT`, every voter contributes exactly `credits` regardless of holdings, so
    ///      turnout is bounded by `electorateSize * credits`. Comparing it against token supply
    ///      would compare unrelated units and produce an essentially arbitrary verdict.
    /// @param _parameters The stored proposal parameters.
    /// @param _totalVotes The summed tally.
    /// @return Whether quorum was reached.
    function _quorumReached(ProposalParameters memory _parameters, uint256 _totalVotes) internal view returns (bool) {
        uint256 minParticipation_ = uint256(votingSettings.minParticipation);

        if (_parameters.creditMode == ICRISP.CreditMode.CONSTANT) {
            uint256 electorate = _parameters.electorateSize * _parameters.credits;
            // A creator that did not declare an electorate leaves no meaningful denominator, so the
            // proposal cannot clear quorum. Failing closed beats inventing a threshold.
            if (electorate == 0) {
                return false;
            }
            return _totalVotes * RATIO_BASE >= minParticipation_ * electorate;
        }

        uint256 _totalVotingPower = totalVotingPower(_parameters.snapshotBlock);
        if (_totalVotingPower == 0) {
            return false;
        }
        return _totalVotes * _voteScale() * RATIO_BASE >= minParticipation_ * _totalVotingPower;
    }

    /// @notice The highest-polling option, and whether it is unique.
    /// @param counts The decoded tally.
    /// @return index The index of the highest-polling option.
    /// @return unique False if no votes were cast, or if two or more options share the lead.
    function _leadingOption(uint256[] memory counts) internal pure returns (uint256 index, bool unique) {
        uint256 highest;
        uint256 tied;

        for (uint256 i = 0; i < counts.length;) {
            if (counts[i] > highest) {
                highest = counts[i];
                index = i;
                tied = 1;
            } else if (counts[i] == highest && highest != 0) {
                ++tied;
            }
            unchecked {
                ++i;
            }
        }

        // An all-zero tally has no winner: nobody voted, so there is nothing to enact.
        unique = highest != 0 && tied == 1;
    }

    /// @notice Quotes the E3 fee, collects it from the proposer, and opens the E3.
    /// @dev One function rather than three inline steps in `createProposal` because that block is at
    ///      the stack limit — the quote, the shape flag and the fee are kept out of its scope.
    /// @param _params The request parameters in the current six-field shape.
    /// @return e3Id The id of the requested E3.
    function _openE3(IInterfold.E3RequestParams memory _params) private returns (uint256 e3Id) {
        (uint256 fee, bool useAggregationShape) = _quote(_params);

        interfoldFeeToken.safeTransferFrom(_msgSender(), address(this), fee);
        interfoldFeeToken.forceApprove(address(interfold), fee);

        // The shape that quoted successfully is the shape the request must use: the two calls read
        // the same struct, so disagreeing here would revert with empty data.
        e3Id = _request(_params, useAggregationShape);
    }

    /// @notice Quotes the E3 fee, discovering which `E3RequestParams` shape this Interfold speaks.
    /// @dev Two shapes are live: six fields in the current monorepo, seven (with a trailing
    ///      `proofAggregationEnabled`) in the Sepolia deployment. The whole struct is one selector,
    ///      so calling the wrong one hits no function and reverts with *empty* data — no named error,
    ///      nothing in the revert to point at the cause. It is worth spending one extra staticcall to
    ///      never emit that failure.
    ///
    ///      Probed rather than configured deliberately. A version flag set at deployment is one more
    ///      thing to get wrong, and getting it wrong reproduces exactly the undiagnosable revert this
    ///      exists to avoid. `getE3Quote` is `view`, so probing cannot touch state.
    /// @param _params The request parameters in the current six-field shape.
    /// @return fee The quoted fee.
    /// @return withAggregation True if this deployment wants the seven-field shape, which
    ///         {_request} must then use — the two calls have to agree.
    function _quote(IInterfold.E3RequestParams memory _params)
        private
        view
        returns (uint256 fee, bool withAggregation)
    {
        try interfold.getE3Quote(_params) returns (uint256 quoted) {
            return (quoted, false);
        } catch {
            // Either this deployment is the older shape, or the parameters are genuinely invalid.
            // The retry distinguishes them: a shape mismatch succeeds here, bad parameters fail again.
            try interfold.getE3Quote(_withAggregation(_params)) returns (uint256 quoted) {
                return (quoted, true);
            } catch {
                revert InterfoldQuoteRejected();
            }
        }
    }

    /// @notice Submits the E3 request in whichever shape {_quote} established.
    /// @dev Low-level rather than a typed call because `request` returns `(uint256, E3 memory)` and the
    ///      `E3` struct also differs between the two versions — decoding it would revert on a mismatch
    ///      even once the arguments are right. Only `e3Id` is needed, and it is the first word of the
    ///      return data in both versions, so the rest is left undecoded.
    /// @param _params The request parameters in the current six-field shape.
    /// @param _useAggregationShape Whether to send the seven-field shape instead.
    /// @return e3Id The id of the requested E3.
    function _request(IInterfold.E3RequestParams memory _params, bool _useAggregationShape)
        private
        returns (uint256 e3Id)
    {
        bytes memory payload = _useAggregationShape
            ? abi.encodeWithSignature(
                "request((uint8,uint256[2],address,uint8,bytes,bytes,bool))", _withAggregation(_params)
            )
            : abi.encodeWithSignature("request((uint8,uint256[2],address,uint8,bytes,bytes))", _params);

        (bool ok, bytes memory returned) = address(interfold).call(payload);
        if (!ok) {
            // Bubble the original revert when there is one; an empty revert has nothing to bubble.
            if (returned.length == 0) revert InterfoldRequestFailed();
            assembly {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        if (returned.length < 32) revert InterfoldRequestFailed();
        // First word of the head, which is `e3Id` in both versions.
        assembly {
            e3Id := mload(add(returned, 0x20))
        }
    }

    /// @notice Widens the current parameter shape to the older one.
    /// @dev `proofAggregationEnabled` is false: the field is absent in the shape this plugin is
    ///      written against, so the only faithful widening is the one that changes no behaviour.
    /// @param _params The request parameters in the current six-field shape.
    /// @return The same parameters in the seven-field shape.
    function _withAggregation(IInterfold.E3RequestParams memory _params)
        private
        pure
        returns (IInterfold.E3RequestParamsWithAggregation memory)
    {
        return IInterfold.E3RequestParamsWithAggregation({
            committeeSize: _params.committeeSize,
            inputWindow: _params.inputWindow,
            e3Program: _params.e3Program,
            paramSet: _params.paramSet,
            computeProviderParams: _params.computeProviderParams,
            customParams: _params.customParams,
            proofAggregationEnabled: false
        });
    }

    /// @notice Current timepoint in the voting token's ERC-6372 clock units.
    /// @dev Upstream snapshots `block.number - 1`, which silently breaks against a token whose
    ///      `CLOCK_MODE` is `timestamp`: `getPastVotes` would be asked for a timepoint billions of
    ///      seconds in the past and return zero voting power for everyone. Reading the token's own
    ///      clock works for both block-numbered (OZ default) and timestamp-clocked tokens. Tokens
    ///      predating ERC-6372 have no `clock()`, so fall back to `block.number`.
    /// @return The current timepoint in the token's own clock units.
    function _tokenClock() internal view returns (uint256) {
        try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timepoint) {
            return timepoint;
        } catch {
            return block.number;
        }
    }

    /// @notice The factor by which each voter's power is divided before being submitted to CRISP.
    /// @dev Vote weights must fit inside the CRISP plaintext vote vector, so the client divides each
    /// voter's token power by `10 ** (decimals / 2)` before voting. The recorded tally is therefore in
    /// these scaled units, and the quorum check scales `totalVotes` back up by the same factor so it is
    /// comparable to the raw token supply. This MUST stay in sync with the client-side scaling.
    /// @return The scaling factor applied to vote weights.
    function _voteScale() internal view returns (uint256) {
        uint8 tokenDecimals = IERC20MetadataUpgradeable(address(votingToken)).decimals();
        return 10 ** (uint256(tokenDecimals) / 2);
    }

    /// @notice Checks if proposal exists or not.
    /// @param _proposalId The ID of the proposal.
    /// @return Returns `true` if proposal exists, otherwise false.
    function _proposalExists(uint256 _proposalId) private view returns (bool) {
        return proposals[_proposalId].parameters.snapshotBlock != 0;
    }

    /// @notice This empty reserved space is put in place to allow future versions to add new variables
    ///         without shifting down storage in the inheritance chain
    ///         (see [OpenZeppelin's guide about storage gaps](https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps)).
    uint256[49] private __gap;
}
