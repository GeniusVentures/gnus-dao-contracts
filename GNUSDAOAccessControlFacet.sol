// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import {AccessControlEnumerableUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/access/AccessControlEnumerableUpgradeable.sol";
import {Initializable} from "@gnus.ai/contracts-upgradeable-diamond/proxy/utils/Initializable.sol";
import {LibDiamond} from "contracts-starter/contracts/libraries/LibDiamond.sol";

/// @title GNUSDAO Access Control Contract
/// @author GNUSDAO Team
/// @notice Provides role-based access control with additional constraints for super admins.
/// @dev Extends `AccessControlEnumerableUpgradeable` to enable enumerability and role management.
contract GNUSDAOAccessControlFacet is Initializable, AccessControlEnumerableUpgradeable {

    /// @notice Role identifier for the upgrader role.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Initializes the GNUSDAO Access Control system
     * @dev This function is restricted to the super admin during contract initialization.
     * Calls the internal `_grantRole` to assign roles.
     * Uses `onlyInitializing` to restrict initialization calls.
     */
    function initializeGNUSDAOAccessControl() internal onlyInitializing onlySuperAdminRole {
        __AccessControlEnumerable_init_unchained();
        initializeGNUSDAOAccessControlUnchained();
    }

    /**
     * @notice Additional initialization logic for the GNUSDAO Access Control system
     * @dev Assigns the `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` to the super admin.
     * Uses `onlyInitializing` to ensure this is called only during initialization.
     */
    function initializeGNUSDAOAccessControlUnchained() internal onlyInitializing {
        address superAdmin = _msgSender();
        _grantRole(DEFAULT_ADMIN_ROLE, superAdmin);
        _grantRole(UPGRADER_ROLE, superAdmin);
    }

    // Custom Errors
    error CannotRenounceAdminRole();
    error CannotRevokeAdminRole();

    /**
     * @notice Safely renounce a role with admin protection
     * @dev Prevents the super admin from renouncing the `DEFAULT_ADMIN_ROLE`.
     * @param role The role to renounce
     * @param account The account renouncing the role
     */
    function safeRenounceRole(bytes32 role, address account) public {
        if (hasRole(DEFAULT_ADMIN_ROLE, account) && (LibDiamond.diamondStorage().contractOwner == account)) {
            revert CannotRenounceAdminRole();
        }
        _revokeRole(role, account);
    }

    /**
     * @notice Safely revoke a role with admin protection
     * @dev Prevents the super admin from being revoked from the `DEFAULT_ADMIN_ROLE`.
     * @param role The role to revoke
     * @param account The account losing the role
     */
    function safeRevokeRole(bytes32 role, address account) public onlyRole(getRoleAdmin(role)) {
        if (hasRole(DEFAULT_ADMIN_ROLE, account) && (LibDiamond.diamondStorage().contractOwner == account)) {
            revert CannotRevokeAdminRole();
        }
        _revokeRole(role, account);
    }

    // Custom Error for modifier
    error OnlySuperAdminAllowed();

    /**
     * @notice Modifier to restrict access to functions for the super admin.
     * @dev Ensures that the caller is the owner defined in the `LibDiamond` storage.
     */
    modifier onlySuperAdminRole {
        if (LibDiamond.diamondStorage().contractOwner != msg.sender) {
            revert OnlySuperAdminAllowed();
        }
        _;
    }
}