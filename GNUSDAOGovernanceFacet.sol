// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReentrancyGuardUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/security/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/security/PausableUpgradeable.sol";
import {Initializable} from "@gnus.ai/contracts-upgradeable-diamond/proxy/utils/Initializable.sol";

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
contract GNUSDAOGovernanceFacet is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable {

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
    
    // Structs
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
    }
    
    // Storage struct for Diamond pattern
    struct GovernanceStorage {
        VotingConfig votingConfig;
        uint256 proposalCount;
        mapping(uint256 => Proposal) proposals;
        mapping(address => uint256) lastProposalTime;
        mapping(address => address) delegatedTo;
        mapping(address => uint256) delegatedVotes;
        mapping(address => bool) treasuryManagers;
        uint256 treasuryBalance;
        bool initialized;
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
    
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    
    event TreasuryDeposit(address indexed from, uint256 amount);
    event TreasuryWithdrawal(address indexed to, uint256 amount);
    
    // Modifiers
    modifier onlyTreasuryManager() {
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (!gs.treasuryManagers[_msgSender()] && _msgSender() != owner()) {
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
    
    /**
     * @dev Initialize the governance facet
     * @param _initialOwner Initial owner of the contract
     */
    function initializeGovernance(address _initialOwner) external initializer {
        GovernanceStorage storage gs = _getGovernanceStorage();

        // Initialize OpenZeppelin contracts
        __ReentrancyGuard_init();
        __Ownable_init();
        __Pausable_init();

        // Transfer ownership to the initial owner
        _transferOwnership(_initialOwner);
        
        // Set default voting configuration
        gs.votingConfig = VotingConfig({
            proposalThreshold: 1000 * 10**18,    // 1,000 tokens
            votingDelay: 1 days,                 // 1 day delay
            votingPeriod: 7 days,                // 7 days voting period
            quorumThreshold: 100000 * 10**18,    // 100,000 tokens minimum participation
            maxVotesPerWallet: 10000,            // Maximum 10,000 votes per wallet
            proposalCooldown: 1 days             // 1 day cooldown between proposals
        });
        
        gs.initialized = true;
    }
    
    /**
     * @dev Create a new proposal
     * @param title Proposal title
     * @param ipfsHash IPFS hash containing proposal details
     */
    function propose(
        string memory title,
        string memory ipfsHash
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (bytes(title).length == 0) {
            revert EmptyTitle();
        }
        if (bytes(ipfsHash).length == 0) {
            revert EmptyIPFS();
        }

        GovernanceStorage storage gs = _getGovernanceStorage();

        // Check proposal threshold - call governance token facet
        uint256 voterBalance = _getVotingPower(_msgSender());
        if (voterBalance < gs.votingConfig.proposalThreshold) {
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
    ) external proposalExists(proposalId) votingActive(proposalId) whenNotPaused nonReentrant {
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

        // Calculate quadratic cost: cost = votes²
        uint256 voteCost = votes * votes;
        uint256 tokensCost = voteCost * 10**18; // Convert to wei

        // Check if user has enough tokens (including delegated votes)
        uint256 availableVotes = _getVotingPower(_msgSender()) + gs.delegatedVotes[_msgSender()];
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
    function delegateVotes(address delegatee) external whenNotPaused {
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
            // Revoke previous delegation
            gs.delegatedVotes[currentDelegate] -= voterBalance;
            emit VoteDelegationRevoked(_msgSender(), currentDelegate);
        }

        // Set new delegation
        gs.delegatedTo[_msgSender()] = delegatee;
        gs.delegatedVotes[delegatee] += voterBalance;

        emit VoteDelegated(_msgSender(), delegatee);
    }

    /**
     * @dev Revoke vote delegation
     */
    function revokeDelegation() external whenNotPaused {
        GovernanceStorage storage gs = _getGovernanceStorage();
        address currentDelegate = gs.delegatedTo[_msgSender()];
        if (currentDelegate == address(0)) {
            revert NoActiveDelegation();
        }

        uint256 voterBalance = _getVotingPower(_msgSender());
        gs.delegatedVotes[currentDelegate] -= voterBalance;
        gs.delegatedTo[_msgSender()] = address(0);

        emit VoteDelegationRevoked(_msgSender(), currentDelegate);
    }

    /**
     * @dev Execute a proposal (placeholder for future implementation)
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external proposalExists(proposalId) onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];
        if (block.timestamp <= proposal.endTime) {
            revert VotingStillActive();
        }
        if (proposal.executed) {
            revert AlreadyExecuted();
        }
        if (proposal.cancelled) {
            revert ProposalAlreadyCancelled();
        }
        if (proposal.totalVotes < gs.votingConfig.quorumThreshold) {
            revert QuorumNotMet();
        }

        proposal.executed = true;
        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Cancel a proposal
     * @param proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external proposalExists(proposalId) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];
        if (_msgSender() != proposal.proposer && _msgSender() != owner()) {
            revert OnlyProposerOrOwner();
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
    }

    /**
     * @dev Remove treasury manager
     * @param manager Address to remove as treasury manager
     */
    function removeTreasuryManager(address manager) external onlyOwner {
        GovernanceStorage storage gs = _getGovernanceStorage();
        gs.treasuryManagers[manager] = false;
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
     * @dev Withdraw from treasury
     * @param to Address to withdraw to
     * @param amount Amount to withdraw
     */
    function withdrawFromTreasury(address payable to, uint256 amount) external onlyTreasuryManager {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        GovernanceStorage storage gs = _getGovernanceStorage();
        if (amount > gs.treasuryBalance) {
            revert InsufficientTreasuryBalance();
        }

        gs.treasuryBalance -= amount;
        to.transfer(amount);
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
        bool cancelled
    ) {
        GovernanceStorage storage gs = _getGovernanceStorage();
        Proposal storage proposal = gs.proposals[proposalId];
        return (
            proposal.startTime,
            proposal.endTime,
            proposal.totalVotes,
            proposal.totalVoters,
            proposal.executed,
            proposal.cancelled
        );
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

    // Internal helper functions to interact with other facets

    /**
     * @dev Internal function to get voting power from governance token facet
     * @return Voting power of the account
     */
    function _getVotingPower(address /* account */) internal view returns (uint256) {
        // In a real implementation, this would call the governance token facet
        // For now, we'll use a placeholder that returns balance from the token facet
        // This should be replaced with proper Diamond pattern function calls
        return 1000 * 10**18; // Placeholder - should call governance token facet
    }

    /**
     * @dev Internal function to burn tokens from governance token facet
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function _burnFrom(address from, uint256 amount) internal {
        // In a real implementation, this would call the governance token facet
        // For now, we'll use a placeholder
        // This should be replaced with proper Diamond pattern function calls
        if (from == address(0) || amount == 0) {
            revert ZeroAddress();
        }
        // Placeholder - should call governance token facet burnFrom function
    }

    // Receive function to accept ETH deposits
    receive() external payable {
        GovernanceStorage storage gs = _getGovernanceStorage();
        gs.treasuryBalance += msg.value;
        emit TreasuryDeposit(_msgSender(), msg.value);
    }
}
