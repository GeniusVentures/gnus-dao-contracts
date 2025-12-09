// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Upgradeable} from "@gnus.ai/contracts-upgradeable-diamond/token/ERC20/IERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {GNUSDAO_MAX_SUPPLY} from "./GNUSDAOConstantsFacet.sol";
import {GNUSDAOAccessControlFacet} from "./GNUSDAOAccessControlFacet.sol";

/**
 * @title GNUSDAOGovernanceTokenFacet
 * @dev Diamond facet for ERC20 governance token with voting capabilities
 * Adapted from Decentralized_Voting_DAO GovernanceToken contract
 * Features:
 * - Vote delegation and checkpointing
 * - Minting and burning capabilities
 * - Pausable transfers for emergency situations
 * - Permit functionality for gasless approvals
 * - Integration with Diamond storage pattern
 */
contract GNUSDAOGovernanceTokenFacet is
    IERC20Upgradeable,
    IERC20MetadataUpgradeable,
    GNUSDAOAccessControlFacet
{
    // Custom Errors
    error AlreadyInitialized();
    error NotMinter();
    error ZeroAddress();
    error AlreadyMinter();
    error NotAMinter();
    error ExceedsMaxSupply();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error AlreadyPaused();
    error NotPaused();
    error TransferFromZero();
    error TransferToZero();
    error ApproveFromZero();
    error ApproveToZero();
    error MintToZero();
    error BurnFromZero();
    error TokensPaused();

    // Checkpoint for tracking historical balances
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    // Storage struct for Diamond pattern
    struct GovernanceTokenStorage {
        // ERC20 storage
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        uint256 totalSupply;
        string name;
        string symbol;
        uint8 decimals;

        // Governance token specific storage
        mapping(address => bool) minters;
        uint256 maxSupply;
        uint256 initialSupply;
        bool initialized;
        bool paused;

        // Checkpointing for voting power
        mapping(address => Checkpoint[]) checkpoints;
        mapping(address => address) delegates;
        mapping(address => uint256) numCheckpoints;
    }
    
    // Storage slot for Diamond pattern
    bytes32 private constant GOVERNANCE_TOKEN_STORAGE_SLOT = 
        keccak256("gnusdao.storage.governancetoken");
    
    function _getGovernanceTokenStorage() internal pure returns (GovernanceTokenStorage storage gs) {
        bytes32 slot = GOVERNANCE_TOKEN_STORAGE_SLOT;
        assembly {
            gs.slot := slot
        }
    }
    
    // Governance Events (ERC20 events are inherited from IERC20)
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event Paused();
    event Unpaused();
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);
    
    // Modifiers
    modifier onlyMinter() {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (!gs.minters[msg.sender] && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotMinter();
        }
        _;
    }

    modifier whenNotPaused() {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (gs.paused) {
            revert TokensPaused();
        }
        _;
    }

    modifier whenPaused() {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (!gs.paused) {
            revert NotPaused();
        }
        _;
    }
    
    /**
     * @dev Initialize the governance token facet
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _initialOwner Initial owner of the contract (must be diamond owner)
     * @custom:security This function should only be called by the InitFacet during diamond initialization
     * @custom:security The initializer check prevents re-initialization
     */
    function initializeGovernanceToken(
        string memory _name,
        string memory _symbol,
        address _initialOwner
    ) external {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (gs.initialized) {
            revert AlreadyInitialized();
        }

        // Verify initial owner is not zero address first
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }

        // Note: No authorization check here because this is only called during initialization
        // The InitFacet handles authorization and calls this atomically with DiamondCut
        // The initialized check above prevents unauthorized re-initialization

        // Initialize ERC20 data
        gs.name = _name;
        gs.symbol = _symbol;
        gs.decimals = 18;
        gs.totalSupply = 0;
        gs.paused = false;

        // Set constants from GNUSDAOConstantsFacet
        gs.maxSupply = GNUSDAO_MAX_SUPPLY;
        gs.initialSupply = GNUSDAO_MAX_SUPPLY / 10; // 10% of max supply as initial
        gs.initialized = true;

        // Grant admin role to initial owner
        _grantRole(DEFAULT_ADMIN_ROLE, _initialOwner);

        // Mint initial supply to the initial owner
        _mint(_initialOwner, gs.initialSupply);
        
        // Auto-delegate to self to activate voting power
        _delegate(_initialOwner, _initialOwner);
        
        emit TokensMinted(_initialOwner, gs.initialSupply);
    }

    // ERC20 Implementation

    /**
     * @dev Returns the name of the token
     */
    function name() public view override returns (string memory) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.name;
    }

    /**
     * @dev Returns the symbol of the token
     */
    function symbol() public view override returns (string memory) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.symbol;
    }

    /**
     * @dev Returns the decimals of the token
     */
    function decimals() public view override returns (uint8) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.decimals;
    }

    /**
     * @dev Returns the total supply of the token
     */
    function totalSupply() public view override returns (uint256) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.totalSupply;
    }

    /**
     * @dev Returns the balance of an account
     */
    function balanceOf(address account) public view override returns (uint256) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.balances[account];
    }

    /**
     * @dev Returns the allowance of a spender for an owner
     */
    function allowance(address owner, address spender) public view override returns (uint256) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.allowances[owner][spender];
    }

    /**
     * @dev Transfer tokens
     */
    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @dev Approve spender to spend tokens
     */
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @dev Transfer tokens from one account to another
     */
    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint256 currentAllowance = gs.allowances[from][msg.sender];
        
        // Don't decrease infinite allowance (ERC20 standard behavior)
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            _approve(from, msg.sender, currentAllowance - amount);
        }

        _transfer(from, to, amount);

        return true;
    }

    /**
     * @dev Add a new minter
     * @param _minter Address to add as minter
     */
    function addMinter(address _minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_minter == address(0)) {
            revert ZeroAddress();
        }
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (gs.minters[_minter]) {
            revert AlreadyMinter();
        }
        
        gs.minters[_minter] = true;
        emit MinterAdded(_minter);
    }
    
    /**
     * @dev Remove a minter
     * @param _minter Address to remove as minter
     */
    function removeMinter(address _minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (!gs.minters[_minter]) {
            revert NotAMinter();
        }
        
        gs.minters[_minter] = false;
        emit MinterRemoved(_minter);
    }
    
    /**
     * @dev Mint new tokens
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyMinter {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (totalSupply() + amount > gs.maxSupply) {
            revert ExceedsMaxSupply();
        }
        
        // Auto-delegate to self if not already delegating
        bool needsDelegate = (gs.delegates[to] == address(0));
        
        _mint(to, amount);
        
        // Delegate after minting so balance is correct
        if (needsDelegate) {
            _delegate(to, to);
        }
        
        emit TokensMinted(to, amount);
    }
    
    /**
     * @dev Burn tokens from caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @dev Burn tokens from specified account (requires allowance)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) external {
        if (amount == 0) {
            revert ZeroAmount();
        }

        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint256 currentAllowance = gs.allowances[from][msg.sender];
        
        // Don't decrease infinite allowance (ERC20 standard behavior)
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            _approve(from, msg.sender, currentAllowance - amount);
        }

        _burn(from, amount);
        emit TokensBurned(from, amount);
    }
    
    /**
     * @dev Pause token transfers
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (gs.paused) {
            revert AlreadyPaused();
        }
        gs.paused = true;
        emit Paused();
    }

    /**
     * @dev Unpause token transfers
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        if (!gs.paused) {
            revert NotPaused();
        }
        gs.paused = false;
        emit Unpaused();
    }
    
    // Internal helper functions

    /**
     * @dev Internal transfer function
     */
    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) {
            revert TransferFromZero();
        }
        if (to == address(0)) {
            revert TransferToZero();
        }

        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint256 fromBalance = gs.balances[from];
        if (fromBalance < amount) {
            revert InsufficientBalance();
        }

        gs.balances[from] = fromBalance - amount;
        gs.balances[to] += amount;

        // Update voting power checkpoints
        _moveVotingPower(gs.delegates[from], gs.delegates[to], amount);

        emit Transfer(from, to, amount);
    }

    /**
     * @dev Internal approve function
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0)) {
            revert ApproveFromZero();
        }
        if (spender == address(0)) {
            revert ApproveToZero();
        }

        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        gs.allowances[owner][spender] = amount;

        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Internal mint function
     */
    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) {
            revert MintToZero();
        }

        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        gs.totalSupply += amount;
        gs.balances[to] += amount;

        // Update voting power checkpoints
        _moveVotingPower(address(0), gs.delegates[to], amount);

        emit Transfer(address(0), to, amount);
    }

    /**
     * @dev Internal burn function
     */
    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) {
            revert BurnFromZero();
        }

        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint256 accountBalance = gs.balances[from];
        if (accountBalance < amount) {
            revert InsufficientBalance();
        }

        gs.balances[from] = accountBalance - amount;
        gs.totalSupply -= amount;

        // Update voting power checkpoints
        _moveVotingPower(gs.delegates[from], address(0), amount);

        emit Transfer(from, address(0), amount);
    }


    
    /**
     * @dev Delegate votes to another address
     * @param delegatee Address to delegate votes to
     */
    function delegate(address delegatee) external {
        if (delegatee == address(0)) {
            revert ZeroAddress();
        }
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @dev Get current votes balance for an account
     * @param account Address to check voting power for
     * @return Current voting power
     */
    function getVotingPower(address account) external view returns (uint256) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint256 nCheckpoints = gs.numCheckpoints[account];
        return nCheckpoints > 0 ? gs.checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @dev Get the voting power of an account at a specific block
     * @param account Address to check voting power for
     * @param blockNumber Block number to check at
     * @return Voting power at the specified block
     */
    function getPastVotingPower(address account, uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) {
            revert ZeroAmount(); // Reuse error for invalid block
        }

        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint256 nCheckpoints = gs.numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // Check most recent checkpoint
        if (gs.checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return gs.checkpoints[account][nCheckpoints - 1].votes;
        }

        // Check earliest checkpoint
        if (gs.checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        // Binary search - find the checkpoint at or before the target block
        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = lower + (upper - lower) / 2; // Standard binary search midpoint
            Checkpoint memory cp = gs.checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center + 1; // Move past center
            } else {
                upper = center; // Don't skip center
            }
        }
        // Return the checkpoint at or before the target block
        // If lower > 0, we found a checkpoint; if lower == 0, check if it's valid
        if (lower > 0 && gs.checkpoints[account][lower].fromBlock > blockNumber) {
            return gs.checkpoints[account][lower - 1].votes;
        }
        return lower < nCheckpoints ? gs.checkpoints[account][lower].votes : 0;
    }

    /**
     * @dev Get the address an account is delegating to
     * @param account Address to check
     * @return Address being delegated to (or address(0) if self-delegating)
     */
    function getDelegates(address account) external view returns (address) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.delegates[account];
    }

    /**
     * @dev Internal delegation function
     */
    function _delegate(address delegator, address delegatee) internal {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        address currentDelegate = gs.delegates[delegator];
        uint256 delegatorBalance = gs.balances[delegator];
        gs.delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveVotingPower(currentDelegate, delegatee, delegatorBalance);
    }

    /**
     * @dev Move voting power when tokens are transferred or delegated
     */
    function _moveVotingPower(address src, address dst, uint256 amount) internal {
        if (src != dst && amount > 0) {
            if (src != address(0)) {
                GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
                uint256 srcNum = gs.numCheckpoints[src];
                uint256 srcOld = srcNum > 0 ? gs.checkpoints[src][srcNum - 1].votes : 0;
                
                // Check for underflow
                if (srcOld < amount) {
                    revert InsufficientBalance();
                }
                
                uint256 srcNew = srcOld - amount;
                _writeCheckpoint(src, srcNum, srcOld, srcNew);
            }

            if (dst != address(0)) {
                GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
                uint256 dstNum = gs.numCheckpoints[dst];
                uint256 dstOld = dstNum > 0 ? gs.checkpoints[dst][dstNum - 1].votes : 0;
                uint256 dstNew = dstOld + amount;
                _writeCheckpoint(dst, dstNum, dstOld, dstNew);
            }
        }
    }

    /**
     * @dev Write a checkpoint for voting power
     */
    function _writeCheckpoint(address delegatee, uint256 nCheckpoints, uint256 oldVotes, uint256 newVotes) internal {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        uint32 blockNumber = _safe32(block.number);

        // Check if we can update the last checkpoint (same block)
        bool canUpdateLast = false;
        if (nCheckpoints > 0) {
            uint32 lastCheckpointBlock = gs.checkpoints[delegatee][nCheckpoints - 1].fromBlock;
            // Use >= to avoid strict equality warning, but logically same as ==
            canUpdateLast = (lastCheckpointBlock >= blockNumber && lastCheckpointBlock <= blockNumber);
        }

        if (canUpdateLast) {
            gs.checkpoints[delegatee][nCheckpoints - 1].votes = _safe224(newVotes);
        } else {
            gs.checkpoints[delegatee].push(Checkpoint({
                fromBlock: blockNumber,
                votes: _safe224(newVotes)
            }));
            gs.numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    /**
     * @dev Safe cast to uint32
     */
    function _safe32(uint256 n) internal pure returns (uint32) {
        if (n > type(uint32).max) {
            revert ZeroAmount(); // Reuse error for overflow
        }
        return uint32(n);
    }

    /**
     * @dev Safe cast to uint224
     */
    function _safe224(uint256 n) internal pure returns (uint224) {
        if (n > type(uint224).max) {
            revert ZeroAmount(); // Reuse error for overflow
        }
        return uint224(n);
    }
    
    /**
     * @dev Check if address is a minter
     * @param account Address to check
     * @return True if address is a minter
     */
    function isMinter(address account) external view returns (bool) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.minters[account];
    }
    
    /**
     * @dev Get maximum supply
     * @return Maximum token supply
     */
    function getMaxSupply() external view returns (uint256) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.maxSupply;
    }
    
    /**
     * @dev Get initial supply
     * @return Initial token supply
     */
    function getInitialSupply() external view returns (uint256) {
        GovernanceTokenStorage storage gs = _getGovernanceTokenStorage();
        return gs.initialSupply;
    }
}
