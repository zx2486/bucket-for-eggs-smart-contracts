// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title IBucketInfo
 * @notice Interface for the BucketInfo contract used by Bucket contracts
 * @dev Provides token validation, pricing, platform status, and fee calculation
 */
interface IBucketInfo {
    /// @notice Check if a token is valid (whitelisted and platform operational)
    /// @param token The token address (address(0) for native ETH)
    /// @return True if the token is valid
    function isTokenValid(address token) external view returns (bool);

    /// @notice Check if a token is whitelisted (regardless of platform pause state)
    /// @param token The token address
    /// @return True if the token is whitelisted
    function isTokenWhitelisted(address token) external view returns (bool);

    /// @notice Get the price of a token in USD (8 decimals, Chainlink standard)
    /// @param token The token address
    /// @return Token price in USD with 8 decimals
    function getTokenPrice(address token) external view returns (uint256);

    /// @notice Check if platform is operational (not paused)
    /// @return True if platform is operational
    function isPlatformOperational() external view returns (bool);

    /// @notice Calculate platform fee for a given amount
    /// @param amount The amount to calculate fee on
    /// @return The calculated fee amount
    function calculateFee(uint256 amount) external view returns (uint256);

    /// @notice Get all whitelisted token addresses
    /// @return Array of whitelisted token addresses
    function getWhitelistedTokens() external view returns (address[] memory);

    /// @notice Price decimals constant (8)
    function PRICE_DECIMALS() external view returns (uint256);

    /// @notice Platform fee in basis points
    function platformFee() external view returns (uint256);
}
