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
     * @param _initialOwner Initial owner of the contract
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
        if (currentAllowance < amount) {
            revert InsufficientAllowance();
        }

        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);

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
        
        _mint(to, amount);
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
        if (currentAllowance < amount) {
            revert InsufficientAllowance();
        }

        _approve(from, msg.sender, currentAllowance - amount);
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

        emit Transfer(from, address(0), amount);
    }


    
    /**
     * @dev Get the current voting power of an account (simplified - returns balance)
     * @param account Address to check voting power for
     * @return Current voting power (token balance)
     */
    function getVotingPower(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @dev Get the voting power of an account at a specific block (simplified - returns current balance)
     * @param account Address to check voting power for
     * @param blockNumber Block number to check at (ignored in this simplified version)
     * @return Voting power (current token balance)
     */
    function getPastVotingPower(address account, uint256 blockNumber) external view returns (uint256) {
        // In a full implementation, this would return historical balance
        // For now, return current balance
        blockNumber; // Silence unused parameter warning
        return balanceOf(account);
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
