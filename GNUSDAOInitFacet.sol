// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import {ContextUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/utils/ContextUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/access/AccessControlEnumerableUpgradeable.sol";
import {Initializable} from "@gnus.ai/contracts-upgradeable-diamond/proxy/utils/Initializable.sol";
import {LibDiamond} from "contracts-starter/contracts/libraries/LibDiamond.sol";
import {IERC20Upgradeable} from "@gnus.ai/contracts-upgradeable-diamond/token/ERC20/IERC20Upgradeable.sol";

// Interfaces for calling other facets during initialization
interface IGNUSDAOGovernanceTokenFacet {
    function initializeGovernanceToken(string memory _name, string memory _symbol, address _initialOwner) external;
}

interface IGNUSDAOGovernanceFacet {
    function initializeGovernance(address _initialOwner) external;
}

/// @title Diamond Initialization Facet
/// @author Genius DAO
/// @notice Handles initialization logic for the Diamond contract
/// @dev Implements role-based access control and diamond storage initialization
/// @dev All initialization is atomic with DiamondCut to prevent front-running attacks
/// @dev This design follows ERC-2535 best practices for secure initialization:
/// @dev - Single InitFacet for protocol-wide initialization (simplifies upgrades)
/// @dev - Atomic execution with DiamondCut (prevents front-running)
/// @dev - Initializer modifier prevents re-initialization
/// @dev - All facet initializers called in same transaction as DiamondCut
/// @dev Alternative: Individual facet initializers in separate transactions (NOT RECOMMENDED)
/// @dev   - Adds complexity with ordering and interaction issues
/// @dev   - Opens front-running attack vector (initializers not atomic with DiamondCut)
/// @dev   - Can be used if InitFacet approach is not possible for specific facets
contract GNUSDAOInitFacet is Initializable, ContextUpgradeable, AccessControlEnumerableUpgradeable {
    using LibDiamond for LibDiamond.DiamondStorage;

    /// @notice Role identifier for upgrade privileges
    /// @dev Keccak256 hash of "UPGRADER_ROLE"
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Custom Errors
    error OnlySuperAdminAllowed();

    /// @notice Emitted when initialization functions are called
    /// @param sender Address that triggered the initialization
    /// @param initializer Name of the initialization function called
    event InitLog(address indexed sender, string initializer);

    /// @notice Restricts function access to the contract owner
    /// @dev Uses LibDiamond storage to verify ownership
    modifier onlySuperAdminRole() {
        if (LibDiamond.diamondStorage().contractOwner != _msgSender()) {
            revert OnlySuperAdminAllowed();
        }
        _;
    }

    /// @notice Initializes the diamond with version 0.0.0
    /// @dev Sets up initial roles, permissions, and initializes all facets atomically
    /// @dev This function is called atomically with DiamondCut to prevent front-running
    /// @param tokenName Name for the governance token
    /// @param tokenSymbol Symbol for the governance token
    /// @custom:security Protected by initializer modifier to prevent re-initialization
    /// @custom:security All facet initialization happens in one transaction with DiamondCut
    function diamondInitialize000(
        string memory tokenName,
        string memory tokenSymbol
    ) public initializer {
        address sender = _msgSender();
        emit InitLog(sender, "diamondInitialize000 Function called");

        // Set up roles and permissions FIRST
        // This must happen before calling other facet initializers that check roles
        _grantRole(DEFAULT_ADMIN_ROLE, sender);
        _grantRole(UPGRADER_ROLE, sender);

        // Enable ERC20 interface support
        LibDiamond.diamondStorage().supportedInterfaces[type(IERC20Upgradeable).interfaceId] = true;

        // Initialize Governance Token Facet atomically
        // This prevents front-running by ensuring initialization happens in same transaction as DiamondCut
        // The token facet will check that sender has DEFAULT_ADMIN_ROLE (granted above)
        IGNUSDAOGovernanceTokenFacet(address(this)).initializeGovernanceToken(
            tokenName,
            tokenSymbol,
            sender
        );

        // Initialize Governance Facet atomically
        // This prevents front-running by ensuring initialization happens in same transaction as DiamondCut
        IGNUSDAOGovernanceFacet(address(this)).initializeGovernance(sender);
    }

    /// @notice Initializes the diamond with version 1.0.0
    /// @dev Sets up roles and permissions for version 1.0.0
    /// @param tokenName Name for the governance token
    /// @param tokenSymbol Symbol for the governance token
    /// @custom:security Protected by initializer modifier to prevent re-initialization
    /// @custom:security All facet initialization happens in one transaction with DiamondCut
    function diamondInitialize100(
        string memory tokenName,
        string memory tokenSymbol
    ) public initializer {
        address sender = _msgSender();
        emit InitLog(sender, "diamondInitialize100 Function called");
        // Set up initial roles and permissions for version 1.0.0 by calling 0.0.0 initializer
        diamondInitialize000(tokenName, tokenSymbol);
    }
}
