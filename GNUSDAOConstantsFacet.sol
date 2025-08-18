// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

/// @title GNUSDAO Constants
/// @notice This file defines global constants used throughout the GNUSDAO project.

// Reserve Currency/Token Name
/// @dev The name of the GNUSDAO Token (GDAO).
string constant GNUSDAO_NAME = "GNUSDAO Tokens";

// Reserve Currency/Token Symbol
/// @dev The symbol of the GNUSDAO Token (GDAO).
string constant GNUSDAO_SYMBOL = "GDAO";

// Decimals for the GNUSDAO Token
/// @dev The number of decimals for the GNUSDAO Token (GDAO).
uint256 constant GNUSDAO_DECIMALS = 10 ** 18;

// Maximum Supply for the GNUSDAO Token
/// @dev The maximum supply of GNUSDAO Tokens (50 million tokens with 18 decimals).
uint256 constant GNUSDAO_MAX_SUPPLY = 50000000 * GNUSDAO_DECIMALS;

// Metadata URI for GNUSDAO NFTs
/// @dev The URI for accessing metadata of GNUSDAO NFTs. The `{id}` is a placeholder for the token ID.
string constant GNUSDAO_URI = "https://nft.GNUSDAO.io/{id}";

// Token ID for GNUSDAO ERC20 Token
/// @dev The unique ID for the GNUSDAO Token (GDAO) in the ERC1155 token standard.
uint256 constant GNUSDAO_TOKEN_ID = 0;

// Maximum Value for a uint128
/// @dev The maximum possible value for a uint128 variable.
uint128 constant MAX_UINT128 = uint128(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);

// Parent Token Mask
/// @dev A mask used to identify the parent type of a token. This uses the upper 128 bits of a uint256.
uint256 constant PARENT_MASK = uint256(MAX_UINT128) << 128;

// Child Token Mask
/// @dev A mask used to identify the child type of a token. This uses the lower 128 bits of a uint256.
uint256 constant CHILD_MASK = MAX_UINT128;

// Native Ether Address
/// @dev A placeholder address used to represent native Ether in the GNUSDAO system.
address constant ETHER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
