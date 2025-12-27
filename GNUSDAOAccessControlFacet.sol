// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import {AccessControlEnumerableUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/access/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/access/AccessControlUpgradeable.sol";
import {IAccessControlUpgradeable} from "@gnus.ai/contracts-upgradeable-diamond/access/IAccessControlUpgradeable.sol";
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
     * @notice Initializes the GNUSDAO Access Control system.
     * @dev This function is restricted to the super admin during contract initialization.
     * Calls the internal `_grantRole` to assign roles.
     * Uses `onlyInitializing` to restrict initialization calls.
     */
    function __GNUSDAOAccessControl_init() internal onlyInitializing onlySuperAdminRole {
        __AccessControlEnumerable_init_unchained();
        __GNUSDAOAccessControl_init_unchained();
    }

    /**
     * @notice Additional initialization logic for the GNUSDAO Access Control system.
     * @dev Assigns the `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` to the super admin.
     * Uses `onlyInitializing` to ensure this is called only during initialization.
     */
    function __GNUSDAOAccessControl_init_unchained() internal onlyInitializing {
        address superAdmin = _msgSender();
        _grantRole(DEFAULT_ADMIN_ROLE, superAdmin);
        _grantRole(UPGRADER_ROLE, superAdmin);
    }

    // Custom Errors
    error CannotRenounceAdminRole();
    error CannotRevokeAdminRole();

    /**
     * @notice Allows an account to renounce a specific role.
     * @dev Prevents the super admin from renouncing the `DEFAULT_ADMIN_ROLE`.
     * Overrides the `renounceRole` function from parent contracts.
     * @param role The role to renounce.
     * @param account The account renouncing the role.
     */
    // solhint-disable-next-line no-complex-inheritance
    function renounceRole(bytes32 role, address account) public override(AccessControlUpgradeable, IAccessControlUpgradeable) {
        if (hasRole(DEFAULT_ADMIN_ROLE, account) && (LibDiamond.diamondStorage().contractOwner == account)) {
            revert CannotRenounceAdminRole();
        }
        super.renounceRole(role, account);
    }

    /**
     * @notice Revokes a specific role from an account.
     * @dev Prevents the super admin from being revoked from the `DEFAULT_ADMIN_ROLE`.
     * Overrides the `revokeRole` function from parent contracts.
     * @param role The role to revoke.
     * @param account The account losing the role.
     */
    // solhint-disable-next-line no-complex-inheritance
    function revokeRole(bytes32 role, address account) public override(AccessControlUpgradeable, IAccessControlUpgradeable) {
        if (hasRole(DEFAULT_ADMIN_ROLE, account) && (LibDiamond.diamondStorage().contractOwner == account)) {
            revert CannotRevokeAdminRole();
        }
        super.revokeRole(role, account);
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