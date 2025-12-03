// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@gnus.ai/contracts-upgradeable-diamond/utils/ContextUpgradeable.sol";
import "@gnus.ai/contracts-upgradeable-diamond/access/AccessControlEnumerableUpgradeable.sol";
import "@gnus.ai/contracts-upgradeable-diamond/proxy/utils/Initializable.sol";
import "contracts-starter/contracts/libraries/LibDiamond.sol";
import "@gnus.ai/contracts-upgradeable-diamond/token/ERC20/IERC20Upgradeable.sol";

/// @title Diamond Initialization Facet
/// @author Genius DAO
/// @notice Handles initialization logic for the Diamond contract
/// @dev Implements role-based access control and diamond storage initialization
contract GNUSDAOInitFacet is Initializable, ContextUpgradeable, AccessControlEnumerableUpgradeable {
    using LibDiamond for LibDiamond.DiamondStorage;

    /// @notice Role identifier for upgrade privileges
    /// @dev Keccak256 hash of "UPGRADER_ROLE"
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Emitted when initialization functions are called
    /// @param sender Address that triggered the initialization
    /// @param initializer Name of the initialization function called
    event InitLog(address indexed sender, string initializer);

    /// @notice Restricts function access to the contract owner
    /// @dev Uses LibDiamond storage to verify ownership
    modifier onlySuperAdminRole() {
        require(
            LibDiamond.diamondStorage().contractOwner == _msgSender(),
            "Only SuperAdmin allowed"
        );
        _;
    }

    /// @notice Initializes the diamond with version 0.0.0
    /// @dev Sets up initial roles and permissions for the contract
    /// @custom:security Protected by initializer modifier to prevent re-initialization
    function diamondInitialize000() public initializer {
        address sender = _msgSender();
        emit InitLog(sender, "diamondInitialize000 Function called");

        // Set up roles and permissions
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(UPGRADER_ROLE, _msgSender());

        // Enable ERC20 interface support as example
        LibDiamond.diamondStorage().supportedInterfaces[type(IERC20Upgradeable).interfaceId] = true;
    }

    /// @notice Initializes the diamond with version 1.0.0
    /// @dev Sets up roles and permissions for version 1.0.0
    /// @custom:security Protected by initializer modifier to prevent re-initialization
    function diamondInitialize100() public initializer {
        address sender = _msgSender();
        emit InitLog(sender, "diamondInitialize100 Function called");
        // Set up initial roles and permissions for version 1.0.0 by calling 0.0.0 initializer
        diamondInitialize000();
    }
}
