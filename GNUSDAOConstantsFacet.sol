// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

/// @title XMPL Constants
/// @notice This file defines global constants used throughout the XMPL project.

// Reserve Currency/Token Name
/// @dev The name of the Example Token (XMPL).
string constant XMPL_NAME = "Example Tokens";

// Reserve Currency/Token Symbol
/// @dev The symbol of the Example Token (XMPL).
string constant XMPL_SYMBOL = "XMPL";

// Decimals for the Example Token
/// @dev The number of decimals for the Example Token (XMPL).
uint256 constant XMPL_DECIMALS = 10 ** 18;

// Maximum Supply for the Example Token
/// @dev The maximum supply of Example Tokens (50 million tokens with 18 decimals).
uint256 constant XMPL_MAX_SUPPLY = 50000000 * XMPL_DECIMALS;

// Metadata URI for XMPL NFTs
/// @dev The URI for accessing metadata of XMPL NFTs. The `{id}` is a placeholder for the token ID.
string constant XMPL_URI = "https://nft.XMPL.io/{id}";

// Token ID for XMPL ERC20 Token
/// @dev The unique ID for the Example Token (XMPL) in the ERC1155 token standard.
uint256 constant XMPL_TOKEN_ID = 0;

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
/// @dev A placeholder address used to represent native Ether in the XMPL system.
address constant ETHER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
