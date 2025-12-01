// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReentrancyGuardUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/security/PausableUpgradeable.sol";
import {Initializable} from "@gnus.ai/contracts-upgradeable-diamond/proxy/utils/Initializable.sol";
import "contracts-starter/contracts/libraries/LibDiamond.sol";

/**
 * @title GNUSDAOGovernanceFacet
 * @dev Diamond facet for DAO governance with quadratic voting and Sybil resistance
 * Adapted from Decentralized_Voting_DAO DAOGovernance contract
 * Features:
 * - Proposal creation with IPFS metadata
 * - Quadratic voting mechanism (cost = votes²)
 * - Vote delegation
 * - Sybil resistance via token thresholds and cooldowns
 * - Treasury management integration
 */
// Interface for token facet functions
interface IGovernanceTokenFacet {
    function balanceOf(address account) external view returns (uint256);
    function getVotingPower(address account) external view returns (uint256);
    function burnFrom(address from, uint256 amount) external;
}

contract GNUSDAOGovernanceFacet is Initializable, ReentrancyGuardUpgradeable, PausableUpgradeable {

    // Custom Errors
    error AlreadyInitialized();
    error NotTreasuryManager();
    error ProposalNotFound();
    error VotingNotStarted();
    error VotingEnded();
    error ProposalNotActive();
    error EmptyTitle();
    error EmptyIPFS();
    error InsufficientTokens();
    error CooldownNotMet();
    error ZeroVotes();
    error ExceedsMaxVotes();
    error AlreadyVoted();
    error InsufficientVotingPower();
    error ZeroAddress();
    error CannotDelegateToSelf();
    error NoActiveDelegation();
    error VotingStillActive();
    error AlreadyExecuted();
    error ProposalAlreadyCancelled();
    error QuorumNotMet();
    error OnlyProposerOrOwner();
    error CannotCancelExecuted();
    error AlreadyCancelled();
    error ZeroAmount();
    error InsufficientTreasuryBalance();
    error RecipientIsContract();
    error ProposalNotQueued();
    error TimelockNotExpired();
    error TimelockExpired();
    error InvalidActionIndex();
    error NoActions();
    error ActionExecutionFailed(uint256 actionIndex);
    error TooManyActions();
    error InsufficientContractBalance();
    error VotesOverflowRisk();
    error TokensDelegated();
    error MaxActionsExceeded();

    // Structs

    /// @notice Represents a single action to be executed as part of a proposal
    struct ProposalAction {
        address target;      // Contract address to call
        uint256 value;       // ETH value to send with the call
        bytes data;          // Encoded function call data
        string description;  // Human-readable description of the action
    }

    /// @notice Represents a governance proposal with voting and execution data
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string ipfsHash;
        uint256 startTime;
        uint256 endTime;
        uint256 totalVotes;
        uint256 totalVoters;
        bool executed;
        bool cancelled;
        bool queued;                    // Whether proposal is queued for execution
        uint256 queuedTime;             // Timestamp when proposal was queued
        ProposalAction[] actions;       // Array of actions to execute
        mapping(address => uint256) votes;
        mapping(address => bool) hasVoted;
    }
    
    struct VotingConfig {
        uint256 proposalThreshold;      // Minimum tokens to create proposal
        uint256 votingDelay;           // Delay before voting starts (in blocks)
        uint256 votingPeriod;          // Voting duration (in blocks)
        uint256 quorumThreshold;       // Minimum participation for valid proposal
        uint256 maxVotesPerWallet;     // Maximum votes per wallet (Sybil resistance)
        uint256 proposalCooldown;      // Cooldown between proposals from same address
        uint256 timelockDelay;         // Delay between queuing and execution (in seconds)
        uint256 maxProposalActions;    // Maximum number of actions per proposal
    }
    
    // Storage struct for Diamond pattern
    struct GovernanceStorage {
        VotingConfig votingConfig;
        uint256 proposalCount;
        mapping(uint256 => Proposal) proposals;
        mapping(address => uint256) lastProposalTime;
        mapping(address => address) delegatedTo;
        mapping(address => uint256) delegatedVotes;
        mapping(address => uint256) delegatedAmount; // Track actual delegated amount per user
        mapping(address => bool) treasuryManagers;
        uint256 treasuryBalance;
        bool initialized;
        bool paused;
    }
    
    // Storage slot for Diamond pattern
    bytes32 private constant GOVERNANCE_STORAGE_SLOT = 
        keccak256("gnusdao.storage.governance");
    
    function _getGovernanceStorage() internal pure returns (GovernanceStorage storage gs) {
        bytes32 slot = GOVERNANCE_STORAGE_SLOT;
        assembly {
            gs.slot := slot
        }
    }
    
    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        string ipfsHash,
        uint256 startTime,
        uint256 endTime
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint256 votes,
        uint256 tokensCost
    );
    
    event VoteDelegated(address indexed delegator, address indexed delegatee);
    event VoteDelegationRevoked(address indexed delegator, address indexed delegatee);

    event ProposalQueued(uint256 indexed proposalId, uint256 executionTime);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event ActionExecuted(uint256 indexed proposalId, uint256 indexed actionIndex, address target, uint256 value, bytes data);

    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);
    event TreasuryManagerAdded(address indexed manager);
    event TreasuryManagerRemoved(address indexed manager);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event GovernancePaused(address indexed by);
    event GovernanceUnpaused(address indexed by);
    
    // Modifiers
    modifier onlyOwner() {
        LibDiamond.enforceIsContractOwner();
        _;
    }
    
    modifier onlyTreasuryManager() {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (!gs.treasuryManagers[_msgSender()] && _msgSender() != LibDiamond.contractOwner()) {
            revert NotTreasuryManager();
        }
        _;
    }
    
    modifier proposalExists(uint256 proposalId) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (proposalId == 0 || proposalId > gs.proposalCount) {
            revert ProposalNotFound();
        }
        _;
    }
    
    modifier votingActive(uint256 proposalId) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];
        if (block.timestamp < proposal.startTime) {
            revert VotingNotStarted();
        }
        if (block.timestamp > proposal.endTime) {
            revert VotingEnded();
        }
        if (proposal.executed || proposal.cancelled) {
            revert ProposalNotActive();
        }
        _;
    }

    modifier whenNotPausedCustom() {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (gs.paused) {
            revert ProposalNotActive(); // Reuse error for paused state
        }
        _;
    }
    
    /**
     * @dev Initialize the governance facet
     * @param _initialOwner Initial owner of the contract (must be diamond owner)
     */
    function initializeGovernance(address _initialOwner) external initializer {
        GovernanceStorage storage gs = _getGovernanceStorage();
        
        if (gs.initialized) {
            revert AlreadyInitialized();
        }

        // Ensure caller is diamond owner
        LibDiamond.enforceIsContractOwner();
        
        // Verify initial owner matches diamond owner
        if (_initialOwner != LibDiamond.contractOwner()) {
            revert ZeroAddress(); // Reuse error for invalid owner
        }

        // Initialize OpenZeppelin contracts
        __ReentrancyGuard_init();
        __Pausable_init();
        
        // Set default voting configuration
        gs.votingConfig = VotingConfig({
            proposalThreshold: 1000 * 10**18,    // 1,000 tokens
            votingDelay: 1 days,                 // 1 day delay
            votingPeriod: 7 days,                // 7 days voting period
            quorumThreshold: 1000,               // 1,000 votes minimum (reasonable for production)
            maxVotesPerWallet: 10000,            // Maximum 10,000 votes per wallet
            proposalCooldown: 1 days,            // 1 day cooldown between proposals
            timelockDelay: 2 days,               // 2 days timelock delay for execution
            maxProposalActions: 10               // Maximum 10 actions per proposal
        });
        
        gs.initialized = true;
        gs.paused = false;
    }
    
    /**
     * @dev Create a new proposal with executable actions
     * @param title Proposal title
     * @param ipfsHash IPFS hash containing proposal details
     * @param targets Array of target contract addresses for actions
     * @param values Array of ETH values to send with each action
     * @param calldatas Array of encoded function call data for each action
     * @param descriptions Array of human-readable descriptions for each action
     */
    function propose(
        string memory title,
        string memory ipfsHash,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string[] memory descriptions
    ) external whenNotPausedCustom nonReentrant returns (uint256) {
        if (bytes(title).length == 0) {
            revert EmptyTitle();
        }
        if (bytes(ipfsHash).length == 0) {
            revert EmptyIPFS();
        }

        GovernanceStorage storage gs = _getGovernanceStorage();

        // Validate actions arrays have matching lengths
        uint256 actionsLength = targets.length;
        if (actionsLength != values.length || actionsLength != calldatas.length || actionsLength != descriptions.length) {
            revert InvalidActionIndex();
        }

        // Check maximum actions limit
        if (actionsLength > gs.votingConfig.maxProposalActions) {
            revert MaxActionsExceeded();
        }

        // Validate actions and calculate total value
        {
            uint256 totalValue = 0;
            for (uint256 i = 0; i < actionsLength; i++) {
                if (targets[i] == address(0)) {
                    revert ZeroAddress();
                }
                totalValue += values[i];
            }
            
            // Check if total value exceeds available treasury
            if (totalValue > gs.treasuryBalance) {
                revert InsufficientTreasuryBalance();
            }
        }

        // Check proposal threshold
        if (_getVotingPower(_msgSender()) < gs.votingConfig.proposalThreshold) {
            revert InsufficientTokens();
        }

        // Check cooldown
        if (block.timestamp < gs.lastProposalTime[_msgSender()] + gs.votingConfig.proposalCooldown) {
            revert CooldownNotMet();
        }

        gs.proposalCount++;
        uint256 proposalId = gs.proposalCount;

        Proposal storage newProposal = gs.proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = _msgSender();
        newProposal.title = title;
        newProposal.ipfsHash = ipfsHash;
        newProposal.startTime = block.timestamp + gs.votingConfig.votingDelay;
        newProposal.endTime = newProposal.startTime + gs.votingConfig.votingPeriod;
        newProposal.queued = false;
        newProposal.queuedTime = 0;

        // Store actions
        for (uint256 i = 0; i < actionsLength; i++) {
            newProposal.actions.push(ProposalAction({
                target: targets[i],
                value: values[i],
                data: calldatas[i],
                description: descriptions[i]
            }));
        }

        gs.lastProposalTime[_msgSender()] = block.timestamp;

        emit ProposalCreated(
            proposalId,
            _msgSender(),
            title,
            ipfsHash,
            newProposal.startTime,
            newProposal.endTime
        );

        return proposalId;
    }
    
    /**
     * @dev Vote on a proposal using quadratic voting
     * @param proposalId ID of the proposal to vote on
     * @param votes Number of votes to cast
     */
    function vote(
        uint256 proposalId,
        uint256 votes
    ) external proposalExists(proposalId) votingActive(proposalId) whenNotPausedCustom nonReentrant {
        if (votes == 0) {
            revert ZeroVotes();
        }

        GovernanceStorage storage gs = _getGovernanceStorage();
        
        // Prevent voting if tokens are delegated
        if (gs.delegatedTo[_msgSender()] != address(0)) {
            revert TokensDelegated();
        }

        if (votes > gs.votingConfig.maxVotesPerWallet) {
            revert ExceedsMaxVotes();
        }

        Proposal storage proposal = gs.proposals[proposalId];
        if (proposal.hasVoted[_msgSender()]) {
            revert AlreadyVoted();
        }

        // Prevent overflow: check votes is reasonable before squaring
        // Max safe value: sqrt(type(uint256).max / 10^18) ≈ 3.4e19
        if (votes > 1e10) { // 10 billion votes max (10^10)^2 * 10^18 = 10^38, safe
            revert VotesOverflowRisk();
        }

        // Calculate quadratic cost: cost = votes²
        uint256 voteCost = votes * votes;
        uint256 tokensCost = voteCost * 10**18; // Convert to wei

        // Check if user has enough tokens (own balance only, not delegated)
        uint256 availableVotes = _getVotingPower(_msgSender());
        if (availableVotes < tokensCost) {
            revert InsufficientVotingPower();
        }

        // Record the vote
        proposal.votes[_msgSender()] = votes;
        proposal.hasVoted[_msgSender()] = true;
        proposal.totalVotes += votes;
        proposal.totalVoters++;

        // Burn tokens for quadratic cost - call governance token facet
        _burnFrom(_msgSender(), tokensCost);
        
        emit VoteCast(proposalId, _msgSender(), votes, tokensCost);
    }

    /**
     * @dev Delegate voting power to another address
     * @param delegatee Address to delegate votes to
     */
    function delegateVotes(address delegatee) external whenNotPausedCustom {
        if (delegatee == address(0)) {
            revert ZeroAddress();
        }
        if (delegatee == _msgSender()) {
            revert CannotDelegateToSelf();
        }

        GovernanceStorage storage gs = _getGovernanceStorage();
        address currentDelegate = gs.delegatedTo[_msgSender()];
        uint256 voterBalance = _getVotingPower(_msgSender());

        if (currentDelegate != address(0)) {
            // Revoke previous delegation using tracked amount
            uint256 previousDelegatedAmount = gs.delegatedAmount[_msgSender()];
            if (gs.delegatedVotes[currentDelegate] >= previousDelegatedAmount) {
                gs.delegatedVotes[currentDelegate] -= previousDelegatedAmount;
            } else {
                gs.delegatedVotes[currentDelegate] = 0; // Safety: prevent underflow
            }
            emit VoteDelegationRevoked(_msgSender(), currentDelegate);
        }

        // Set new delegation with current balance
        gs.delegatedTo[_msgSender()] = delegatee;
        gs.delegatedAmount[_msgSender()] = voterBalance;
        gs.delegatedVotes[delegatee] += voterBalance;

        emit VoteDelegated(_msgSender(), delegatee);
    }

    /**
     * @dev Revoke vote delegation
     */
    function revokeDelegation() external whenNotPausedCustom {
        GovernanceStorage storage gs = _getGovernanceStorage();
        address currentDelegate = gs.delegatedTo[_msgSender()];
        if (currentDelegate == address(0)) {
            revert NoActiveDelegation();
        }

        // Use tracked delegated amount to prevent underflow
        uint256 delegatedAmount = gs.delegatedAmount[_msgSender()];
        if (gs.delegatedVotes[currentDelegate] >= delegatedAmount) {
            gs.delegatedVotes[currentDelegate] -= delegatedAmount;
        } else {
            gs.delegatedVotes[currentDelegate] = 0; // Safety: prevent underflow
        }
        
        gs.delegatedTo[_msgSender()] = address(0);
        gs.delegatedAmount[_msgSender()] = 0;

        emit VoteDelegationRevoked(_msgSender(), currentDelegate);
    }

    /**
     * @dev Queue a proposal for execution after voting ends
     * @param proposalId ID of the proposal to queue
     * @notice Proposal must have passed quorum and voting must have ended
     * @notice Starts the timelock delay before execution is allowed
     */
    function queueProposal(uint256 proposalId) external proposalExists(proposalId) onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];

        // Validate voting has ended
        if (block.timestamp <= proposal.endTime) {
            revert VotingStillActive();
        }

        // Validate proposal state
        if (proposal.executed) {
            revert AlreadyExecuted();
        }
        if (proposal.cancelled) {
            revert ProposalAlreadyCancelled();
        }
        if (proposal.queued) {
            revert ProposalNotActive(); // Reuse error for already queued
        }

        // Validate quorum threshold
        if (proposal.totalVotes < gs.votingConfig.quorumThreshold) {
            revert QuorumNotMet();
        }

        // Queue the proposal
        proposal.queued = true;
        proposal.queuedTime = block.timestamp;

        uint256 executionTime = block.timestamp + gs.votingConfig.timelockDelay;
        emit ProposalQueued(proposalId, executionTime);
    }

    /**
     * @dev Execute a queued proposal after timelock delay
     * @param proposalId ID of the proposal to execute
     * @notice Executes all actions in the proposal sequentially
     * @notice Proposal must be queued and timelock delay must have passed
     */
    function executeProposal(uint256 proposalId) external payable proposalExists(proposalId) whenNotPausedCustom nonReentrant onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];

        // Validate proposal is queued
        if (!proposal.queued) {
            revert ProposalNotQueued();
        }

        // Validate proposal state
        if (proposal.executed) {
            revert AlreadyExecuted();
        }
        if (proposal.cancelled) {
            revert ProposalAlreadyCancelled();
        }

        // Validate timelock delay has passed
        if (block.timestamp < proposal.queuedTime + gs.votingConfig.timelockDelay) {
            revert TimelockNotExpired();
        }

        // Validate proposal hasn't expired (30 days after timelock)
        uint256 maxExecutionTime = proposal.queuedTime + gs.votingConfig.timelockDelay + 30 days;
        if (block.timestamp > maxExecutionTime) {
            revert TimelockExpired();
        }

        // Mark proposal as executed before executing actions (reentrancy protection)
        proposal.executed = true;

        // Execute all actions
        uint256 actionsLength = proposal.actions.length;
        uint256 totalEthUsed = 0;
        
        for (uint256 i = 0; i < actionsLength; i++) {
            ProposalAction storage action = proposal.actions[i];
            totalEthUsed += action.value;

            // Execute the action
            (bool success, bytes memory returnData) = action.target.call{value: action.value}(action.data);

            if (!success) {
                // If the call failed, revert with detailed error
                if (returnData.length > 0) {
                    // Bubble up the revert reason
                    assembly {
                        let returnDataSize := mload(returnData)
                        revert(add(32, returnData), returnDataSize)
                    }
                } else {
                    revert ActionExecutionFailed(i);
                }
            }

            emit ActionExecuted(proposalId, i, action.target, action.value, action.data);
        }

        // Deduct from treasury balance after successful execution
        if (totalEthUsed > gs.treasuryBalance) {
            revert InsufficientTreasuryBalance();
        }
        gs.treasuryBalance -= totalEthUsed;

        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Cancel a proposal
     * @param proposalId ID of the proposal to cancel
     * @notice Can cancel proposals that are not yet executed
     * @notice Proposer can cancel before queuing, owner can cancel anytime before execution
     */
    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];

        // Proposer can cancel before queuing, owner can cancel anytime before execution
        bool isProposer = _msgSender() == proposal.proposer;
        bool isOwner = _msgSender() == LibDiamond.contractOwner();

        if (!isProposer && !isOwner) {
            revert OnlyProposerOrOwner();
        }

        // Proposer can only cancel if not yet queued
        if (isProposer && !isOwner && proposal.queued) {
            revert OnlyProposerOrOwner(); // Reuse error - only owner can cancel queued proposals
        }

        if (proposal.executed) {
            revert CannotCancelExecuted();
        }
        if (proposal.cancelled) {
            revert AlreadyCancelled();
        }

        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    /**
     * @dev Add treasury manager
     * @param manager Address to add as treasury manager
     */
    function addTreasuryManager(address manager) external onlyOwner {
        if (manager == address(0)) {
            revert ZeroAddress();
        }
        GovernanceStorage storage gs = _getGovernanceStorage();
        gs.treasuryManagers[manager] = true;
        emit TreasuryManagerAdded(manager);
    }

    /**
     * @dev Remove treasury manager
     * @param manager Address to remove as treasury manager
     */
    function removeTreasuryManager(address manager) external onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        gs.treasuryManagers[manager] = false;
        emit TreasuryManagerRemoved(manager);
    }

    /**
     * @dev Update timelock delay
     * @param newDelay New timelock delay in seconds
     * @notice Only owner can update timelock delay
     * @notice Recommended: 2-7 days for production DAOs
     * @notice Minimum delay is 1 day for security
     */
    function updateTimelockDelay(uint256 newDelay) external onlyOwner {
        // Enforce minimum timelock of 1 day
        if (newDelay < 1 days) {
            revert ZeroAmount(); // Reuse error for invalid delay
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldDelay = gs.votingConfig.timelockDelay;
        gs.votingConfig.timelockDelay = newDelay;
        emit TimelockDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @dev Pause governance operations
     * @notice Only owner can pause
     * @notice Pauses proposal creation, voting, and delegation
     */
    function pauseGovernance() external onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (gs.paused) {
            revert AlreadyInitialized(); // Reuse error for already paused
        }
        gs.paused = true;
        emit GovernancePaused(_msgSender());
    }

    /**
     * @dev Unpause governance operations
     * @notice Only owner can unpause
     */
    function unpauseGovernance() external onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (!gs.paused) {
            revert ProposalNotActive(); // Reuse error for not paused
        }
        gs.paused = false;
        emit GovernanceUnpaused(_msgSender());
    }

    /**
     * @dev Check if governance is paused
     * @return True if paused, false otherwise
     */
    function isGovernancePaused() external view returns (bool) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.paused;
    }

    /**
     * @dev Deposit ETH to treasury
     */
    function depositToTreasury() external payable {
        if (msg.value == 0) {
            revert ZeroAmount();
        }
        GovernanceStorage storage gs = _getGovernanceStorage();
        gs.treasuryBalance += msg.value;
        emit TreasuryDeposit(_msgSender(), msg.value);
    }

    /**
     * @dev Check if an address is a contract
     * @param account Address to check
     * @return True if the address contains code, false otherwise
     */
    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @dev Withdraw from treasury
     * @param to Address to withdraw to (must be EOA, not contract)
     * @param amount Amount to withdraw
     * @notice Only allows withdrawals to EOA addresses to prevent reentrancy attacks
     * @notice For contract recipients, use the proposal execution system instead
     */
    // slither-disable-next-line arbitrary-send-eth
    function withdrawFromTreasury(address payable to, uint256 amount) external onlyTreasuryManager {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        // Prevent sending to contracts to avoid reentrancy attacks
        if (_isContract(to)) {
            revert RecipientIsContract();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (amount > gs.treasuryBalance) {
            revert InsufficientTreasuryBalance();
        }

        gs.treasuryBalance -= amount;

        // Use .call() instead of .transfer() to avoid 2300 gas limit
        // Safe from reentrancy because recipient is verified to be an EOA
        (bool success, ) = to.call{value: amount}("");
        require(success, "Treasury withdrawal failed");

        emit TreasuryWithdrawal(to, amount);
    }

    // View functions

    /**
     * @dev Get basic proposal details
     * @param proposalId ID of the proposal
     */
    function getProposalBasic(uint256 proposalId) external view proposalExists(proposalId) returns (
        uint256 id,
        address proposer,
        string memory title,
        string memory ipfsHash
    ) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.ipfsHash
        );
    }

    /**
     * @dev Get proposal timing and status
     * @param proposalId ID of the proposal
     */
    function getProposalStatus(uint256 proposalId) external view proposalExists(proposalId) returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalVotes,
        uint256 totalVoters,
        bool executed,
        bool cancelled,
        bool queued,
        uint256 queuedTime
    ) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];
        return (
            proposal.startTime,
            proposal.endTime,
            proposal.totalVotes,
            proposal.totalVoters,
            proposal.executed,
            proposal.cancelled,
            proposal.queued,
            proposal.queuedTime
        );
    }

    /**
     * @dev Get proposal actions
     * @param proposalId ID of the proposal
     * @return targets Array of target addresses
     * @return values Array of ETH values
     * @return calldatas Array of encoded function calls
     * @return descriptions Array of action descriptions
     */
    function getProposalActions(uint256 proposalId) external view proposalExists(proposalId) returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string[] memory descriptions
    ) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];

        uint256 actionsLength = proposal.actions.length;
        targets = new address[](actionsLength);
        values = new uint256[](actionsLength);
        calldatas = new bytes[](actionsLength);
        descriptions = new string[](actionsLength);

        for (uint256 i = 0; i < actionsLength; i++) {
            ProposalAction storage action = proposal.actions[i];
            targets[i] = action.target;
            values[i] = action.value;
            calldatas[i] = action.data;
            descriptions[i] = action.description;
        }

        return (targets, values, calldatas, descriptions);
    }

    /**
     * @dev Get number of actions in a proposal
     * @param proposalId ID of the proposal
     */
    function getProposalActionsCount(uint256 proposalId) external view proposalExists(proposalId) returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.proposals[proposalId].actions.length;
    }

    /**
     * @dev Get user's vote on a proposal
     * @param proposalId ID of the proposal
     * @param voter Address of the voter
     */
    function getVote(uint256 proposalId, address voter) external view proposalExists(proposalId) returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.proposals[proposalId].votes[voter];
    }

    /**
     * @dev Check if user has voted on a proposal
     * @param proposalId ID of the proposal
     * @param voter Address of the voter
     */
    function hasVoted(uint256 proposalId, address voter) external view proposalExists(proposalId) returns (bool) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.proposals[proposalId].hasVoted[voter];
    }

    /**
     * @dev Get voting configuration
     */
    function getVotingConfig() external view returns (VotingConfig memory) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.votingConfig;
    }

    /**
     * @dev Get proposal count
     */
    function getProposalCount() external view returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.proposalCount;
    }

    /**
     * @dev Get treasury balance
     */
    function getTreasuryBalance() external view returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.treasuryBalance;
    }

    /**
     * @dev Check if address is treasury manager
     */
    function isTreasuryManager(address account) external view returns (bool) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.treasuryManagers[account];
    }

    /**
     * @dev Get delegated votes for an address
     */
    function getDelegatedVotes(address account) external view returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.delegatedVotes[account];
    }

    /**
     * @dev Get who an address has delegated to
     */
    function getDelegatedTo(address account) external view returns (address) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.delegatedTo[account];
    }

    /**
     * @dev Get the amount an address has delegated
     */
    function getDelegatedAmount(address account) external view returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.delegatedAmount[account];
    }

    // Internal helper functions to interact with other facets

    /**
     * @dev Internal function to get voting power from governance token facet
     * @param account Address to check voting power for
     * @return Voting power of the account
     */
    function _getVotingPower(address account) internal view returns (uint256) {
        // Call the governance token facet through the diamond proxy
        // Using 'this' routes through the diamond to the correct facet
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        return tokenFacet.getVotingPower(account);
    }

    /**
     * @dev Internal function to burn tokens from governance token facet
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function _burnFrom(address from, uint256 amount) internal {
        if (from == address(0) || amount == 0) {
            revert ZeroAddress();
        }
        // Call the governance token facet through the diamond proxy
        // Using 'this' routes through the diamond to the correct facet
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        tokenFacet.burnFrom(from, amount);
    }

    // Receive function to accept ETH deposits
    receive() external payable {
        GovernanceStorage storage gs = _getGovernanceStorage();
        gs.treasuryBalance += msg.value;
        emit TreasuryDeposit(_msgSender(), msg.value);
    }
}
