// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "contracts-starter/contracts/facets/DiamondLoupeFacet.sol";
import "contracts-starter/contracts/facets/DiamondCutFacet.sol";
import "contracts-starter/contracts/Diamond.sol";
import "contracts-starter/contracts/libraries/LibDiamond.sol";
import "@gnus.ai/contracts-upgradeable-diamond/utils/introspection/ERC165StorageUpgradeable.sol";
import "@gnus.ai/contracts-upgradeable-diamond/token/ERC1155/IERC1155Upgradeable.sol";
import "./ExampleOwnershipFacet.sol";

/// @title ExampleDiamond
/// @notice Implements a modular and upgradeable diamond contract with ERC165 compatibility.
/// @dev Leverages the EIP-2535 Diamond Standard for modularity and the ERC165 interface for introspection.
/// Includes ownership management through facets.
contract ExampleDiamond is Diamond, ERC165StorageUpgradeable {
    using LibDiamond for LibDiamond.DiamondStorage;

    /**
     * @notice Initializes the ExampleDiamond contract with the contract owner and diamond cut facet.
     * @param _contractOwner The address of the contract owner.
     * @param _diamondCutFacet The address of the DiamondCutFacet contract.
     * @dev This constructor registers supported interfaces and sets the initial state.
     * It also ensures compatibility with ERC165 interfaces.
     */
    constructor(address _contractOwner, address _diamondCutFacet)
        initializer
        payable
        Diamond(_contractOwner, _diamondCutFacet)
    {
        __ERC165Storage_init();

        // Register supported interfaces for introspection
        _registerInterface(type(IERC165Upgradeable).interfaceId);
        _registerInterface(type(IDiamondCut).interfaceId);
        _registerInterface(type(IDiamondLoupe).interfaceId);

        // Mark the contract as uninitialized in the Initializable storage layout
        InitializableStorage.layout()._initialized = false;
    }

    /**
     * @notice Checks if the contract supports a specific interface.
     * @param interfaceId The interface identifier to check.
     * @return True if the interface is supported, otherwise false.
     * @dev Overrides the `supportsInterface` function to include diamond-specific interface storage.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId) ||
            LibDiamond.diamondStorage().supportedInterfaces[interfaceId];
    }
}
