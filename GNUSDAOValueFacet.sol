// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./GNUSDAOConstantsFacet.sol";

/// @title GNUSDAOValueFacet
/// @notice A simple facet that returns a value for testing Diamond functionality.
/// @dev This facet demonstrates basic Diamond pattern implementation with a simple getter function.
contract GNUSDAOValueFacet {
    
    /// @notice Returns a simple string value
    /// @return A hardcoded string value for testing
    function getValue() external pure returns (string memory) {
        return "Hello from GNUSDAO Value Facet!";
    }
    
    /// @notice Returns a numeric value
    /// @return A hardcoded numeric value for testing
    function getNumericValue() external pure returns (uint256) {
        return 42;
    }
    
    /// @notice Returns the GNUSDAO token name from constants
    /// @return The GNUSDAO token name
    function getTokenName() external pure returns (string memory) {
        return GNUSDAO_NAME;
    }
    
    /// @notice Returns the GNUSDAO token symbol from constants
    /// @return The GNUSDAO token symbol
    function getTokenSymbol() external pure returns (string memory) {
        return GNUSDAO_SYMBOL;
    }
    
    /// @notice Returns the maximum supply from constants
    /// @return The maximum supply of GNUSDAO tokens
    function getMaxSupply() external pure returns (uint256) {
        return GNUSDAO_MAX_SUPPLY;
    }
}
