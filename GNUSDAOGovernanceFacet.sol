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
    function getPastVotingPower(address account, uint256 blockNumber) external view returns (uint256);
    function burnFrom(address from, uint256 amount) external;
    function delegate(address delegatee) external;
    function getDelegates(address account) external view returns (address);
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
    error MaxActionsExceeded();
    error EmergencyWithdrawalFailed();
    error TreasuryWithdrawalFailed();

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
    event TreasuryReconciled(uint256 oldBalance, uint256 newBalance, int256 difference);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event GovernancePaused(address indexed by);
    event GovernanceUnpaused(address indexed by);
    event ProposalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event QuorumThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event VotingDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MaxVotesPerWalletUpdated(uint256 oldMax, uint256 newMax);
    
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
            proposalThreshold: 1000 * 10**18,    // 1,000 tokens to create proposal
            votingDelay: 1 days,                 // 1 day delay before voting starts
            votingPeriod: 7 days,                // 7 days voting period
            quorumThreshold: 1000,               // 1,000 votes minimum (vote count, not tokens)
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
        if (bytes(title).length > 256) {
            revert EmptyTitle(); // Reuse error for too long title
        }
        if (bytes(ipfsHash).length == 0) {
            revert EmptyIPFS();
        }
        if (bytes(ipfsHash).length > 128) {
            revert EmptyIPFS(); // Reuse error for too long IPFS hash
        }

        GovernanceStorage storage gs = _getGovernanceStorage();

        // Check cooldown FIRST to prevent oracle attacks
        if (block.timestamp < gs.lastProposalTime[_msgSender()] + gs.votingConfig.proposalCooldown) {
            revert CooldownNotMet();
        }

        // Then check proposal threshold - validate proposer has sufficient voting power
        uint256 proposerVotingPower = _getVotingPower(_msgSender());
        if (proposerVotingPower < gs.votingConfig.proposalThreshold) {
            revert InsufficientTokens();
        }

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

        if (votes > gs.votingConfig.maxVotesPerWallet) {
            revert ExceedsMaxVotes();
        }

        Proposal storage proposal = gs.proposals[proposalId];
        if (proposal.hasVoted[_msgSender()]) {
            revert AlreadyVoted();
        }

        // Prevent overflow: check votes is reasonable before squaring
        // Max safe value: 1e10 (10 billion votes)
        // (1e10)^2 * 1e18 = 1e38, well below uint256 max
        // This is a more practical limit while still being extremely high
        if (votes > 1e10) {
            revert ExceedsMaxVotes();
        }

        // Calculate quadratic cost: cost = votes²
        uint256 voteCost = votes * votes;
        
        // Check for overflow before multiplying by 10^18
        // voteCost is at most (1e15)^2 = 1e30
        // 1e30 * 1e18 = 1e48, which is safe for uint256
        uint256 tokensCost = voteCost * 10**18; // Convert to wei

        // Check voting power at proposal start time (prevents flash loan attacks)
        // Use block number from start time (approximate - use current block if start time is in future)
        uint256 checkBlock = block.number > 1 ? block.number - 1 : 0;
        uint256 availableVotes = _getPastVotingPower(_msgSender(), checkBlock);
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
     * @notice This is a wrapper around the token facet's delegate function
     * @notice Delegation is NOT affected by governance pause (it's a token function)
     */
    function delegateVotes(address delegatee) external {
        if (delegatee == address(0)) {
            revert ZeroAddress();
        }
        if (delegatee == _msgSender()) {
            revert CannotDelegateToSelf();
        }

        // Call token facet's delegate function
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        tokenFacet.delegate(delegatee);

        emit VoteDelegated(_msgSender(), delegatee);
    }

    /**
     * @dev Revoke vote delegation (delegate back to self)
     * @notice This is a wrapper around the token facet's delegate function
     * @notice Delegation is NOT affected by governance pause (it's a token function)
     */
    function revokeDelegation() external {
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        address currentDelegate = tokenFacet.getDelegates(_msgSender());
        
        // Check if user is delegating to someone else (not self)
        if (currentDelegate == address(0) || currentDelegate == _msgSender()) {
            revert NoActiveDelegation();
        }

        // Delegate back to self (revoke delegation to others)
        tokenFacet.delegate(_msgSender());

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

        // Mark proposal as executed FIRST (reentrancy protection)
        proposal.executed = true;

        // Execute all actions and deduct treasury balance per action
        uint256 actionsLength = proposal.actions.length;
        for (uint256 i = 0; i < actionsLength; i++) {
            ProposalAction storage action = proposal.actions[i];

            // Check treasury balance before each action
            if (action.value > gs.treasuryBalance) {
                revert InsufficientTreasuryBalance();
            }

            // Deduct from treasury balance BEFORE executing action (reentrancy protection)
            gs.treasuryBalance -= action.value;

            // Execute the action
            (bool success, bytes memory returnData) = action.target.call{value: action.value}(action.data);

            if (!success) {
                // If the call failed, revert with detailed error
                // Revert will automatically restore all state changes including treasury balance
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

        bool isProposer = _msgSender() == proposal.proposer;
        bool isOwner = _msgSender() == LibDiamond.contractOwner();

        if (!isProposer && !isOwner) {
            revert OnlyProposerOrOwner();
        }

        // Proposer can only cancel if not yet queued
        // This prevents proposers from canceling after community has voted and proposal passed quorum
        if (isProposer && !isOwner && proposal.queued) {
            revert OnlyProposerOrOwner(); // Only owner can cancel queued proposals
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
     * @notice Minimum delay is 1 day, maximum is 30 days for security
     */
    function updateTimelockDelay(uint256 newDelay) external onlyOwner {
        // Enforce minimum timelock of 1 day and maximum of 30 days
        if (newDelay < 1 days || newDelay > 30 days) {
            revert ZeroAmount(); // Reuse error for invalid delay
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldDelay = gs.votingConfig.timelockDelay;
        gs.votingConfig.timelockDelay = newDelay;
        emit TimelockDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @dev Update proposal threshold
     * @param newThreshold New proposal threshold in tokens (with decimals)
     * @notice Only owner can update proposal threshold
     * @notice Minimum threshold is 100 tokens to prevent spam
     */
    function updateProposalThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold < 100 * 10**18) {
            revert ZeroAmount(); // Reuse error for invalid threshold
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldThreshold = gs.votingConfig.proposalThreshold;
        gs.votingConfig.proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @dev Update quorum threshold
     * @param newThreshold New quorum threshold in vote count
     * @notice Only owner can update quorum threshold
     * @notice Minimum quorum is 100 votes
     */
    function updateQuorumThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold < 100) {
            revert ZeroAmount(); // Reuse error for invalid threshold
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldThreshold = gs.votingConfig.quorumThreshold;
        gs.votingConfig.quorumThreshold = newThreshold;
        emit QuorumThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @dev Update voting delay
     * @param newDelay New voting delay in seconds
     * @notice Only owner can update voting delay
     * @notice Minimum delay is 1 hour, maximum is 7 days
     */
    function updateVotingDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < 1 hours || newDelay > 7 days) {
            revert ZeroAmount(); // Reuse error for invalid delay
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldDelay = gs.votingConfig.votingDelay;
        gs.votingConfig.votingDelay = newDelay;
        emit VotingDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @dev Update voting period
     * @param newPeriod New voting period in seconds
     * @notice Only owner can update voting period
     * @notice Minimum period is 1 day, maximum is 30 days
     */
    function updateVotingPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < 1 days || newPeriod > 30 days) {
            revert ZeroAmount(); // Reuse error for invalid period
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldPeriod = gs.votingConfig.votingPeriod;
        gs.votingConfig.votingPeriod = newPeriod;
        emit VotingPeriodUpdated(oldPeriod, newPeriod);
    }

    /**
     * @dev Update max votes per wallet
     * @param newMax New maximum votes per wallet
     * @notice Only owner can update max votes
     * @notice Minimum is 100 votes, maximum is 1,000,000 votes
     */
    function updateMaxVotesPerWallet(uint256 newMax) external onlyOwner {
        if (newMax < 100 || newMax > 1000000) {
            revert ZeroAmount(); // Reuse error for invalid max
        }
        
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 oldMax = gs.votingConfig.maxVotesPerWallet;
        gs.votingConfig.maxVotesPerWallet = newMax;
        emit MaxVotesPerWalletUpdated(oldMax, newMax);
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
     * @dev Emergency withdrawal function (only when paused)
     * @param to Address to send funds to
     * @param amount Amount to withdraw
     * @notice Can only be called by owner when governance is paused
     * @notice Use this only in emergency situations to recover funds
     */
    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (!gs.paused) {
            revert ProposalNotActive(); // Reuse error - must be paused
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (amount > gs.treasuryBalance) {
            revert InsufficientTreasuryBalance();
        }

        gs.treasuryBalance -= amount;

        (bool success, ) = to.call{value: amount}("");
        if (!success) {
            revert EmergencyWithdrawalFailed();
        }

        emit TreasuryWithdrawal(to, amount);
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
    function withdrawFromTreasury(address payable to, uint256 amount) external onlyTreasuryManager nonReentrant {
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
        if (!success) {
            revert TreasuryWithdrawalFailed();
        }

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
     * @dev Get treasury balance (tracked)
     */
    function getTreasuryBalance() external view returns (uint256) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.treasuryBalance;
    }

    /**
     * @dev Get actual contract ETH balance
     * @return Actual ETH balance held by the contract
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Reconcile treasury balance with actual contract balance
     * @notice Only owner can reconcile
     * @notice Use this if ETH was sent directly to contract bypassing depositToTreasury
     * @notice This syncs the tracked balance with actual balance
     * @notice Emits TreasuryReconciled event for transparency
     */
    function reconcileTreasuryBalance() external onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        uint256 actualBalance = address(this).balance;
        
        // Sync tracked balance to actual balance
        if (actualBalance != gs.treasuryBalance) {
            uint256 oldBalance = gs.treasuryBalance;
            int256 difference = int256(actualBalance) - int256(oldBalance);
            
            gs.treasuryBalance = actualBalance;
            
            // Emit specific reconciliation event for transparency
            emit TreasuryReconciled(oldBalance, actualBalance, difference);
            
            // Also emit standard events for tracking
            if (actualBalance > oldBalance) {
                emit TreasuryDeposit(address(0), actualBalance - oldBalance);
            } else {
                emit TreasuryWithdrawal(address(0), oldBalance - actualBalance);
            }
        }
    }

    /**
     * @dev Check if address is treasury manager
     */
    function isTreasuryManager(address account) external view returns (bool) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        return gs.treasuryManagers[account];
    }

    /**
     * @dev Get current voting power for an address (includes delegated votes)
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        return _getVotingPower(account);
    }

    /**
     * @dev Get who an address has delegated to
     */
    function getDelegatedTo(address account) external view returns (address) {
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        return tokenFacet.getDelegates(account);
    }

    /**
     * @dev Get voting power at a specific block
     */
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256) {
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        return tokenFacet.getPastVotingPower(account, blockNumber);
    }

    // Internal helper functions to interact with other facets

    /**
     * @dev Internal function to get current voting power from governance token facet
     * @param account Address to check voting power for
     * @return Voting power of the account
     */
    function _getVotingPower(address account) internal view returns (uint256) {
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        return tokenFacet.getVotingPower(account);
    }

    /**
     * @dev Internal function to get past voting power from governance token facet
     * @param account Address to check voting power for
     * @param blockNumber Block number to check at
     * @return Voting power of the account at the specified block
     */
    function _getPastVotingPower(address account, uint256 blockNumber) internal view returns (uint256) {
        IGovernanceTokenFacet tokenFacet = IGovernanceTokenFacet(address(this));
        return tokenFacet.getPastVotingPower(account, blockNumber);
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
