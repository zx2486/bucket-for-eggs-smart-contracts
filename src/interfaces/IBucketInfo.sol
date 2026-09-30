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

    /// @notice Get the price of a token in USD (8 decimals, Chainlink standard). Reverts on
    /// invalid/stale/non-positive price data.
    /// @param token The token address
    /// @return Token price in USD with 8 decimals
    function getTokenPrice(address token) external view returns (uint256);

    /// @notice Non-reverting variant of {getTokenPrice}. Added by W1 (sc-oracle) directly on
    /// `BucketInfo.sol:339` but never previously surfaced through this shared interface — added
    /// here (W1, sc-refactor-base) so `IBucketInfo`-typed callers (both vaults) can use it
    /// without depending on the concrete `BucketInfo` type.
    /// @param token The token address
    /// @return ok True if a usable price was returned, false otherwise (never reverts)
    /// @return price Token price in USD with 8 decimals if `ok`; undefined otherwise
    function tryGetTokenPrice(address token) external view returns (bool ok, uint256 price);

    /// @notice Whether `token`'s price feed is potentially outpriced (e.g. stale or
    /// out-of-bounds), per-token. Added by W1 (sc-oracle) at `BucketInfo.sol:352`; added here for
    /// the same reason as {tryGetTokenPrice}.
    /// @param token The token address
    /// @return True if this token's price feed is potentially outpriced
    function isPotentiallyOutpriced(address token) external view returns (bool);

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

    /// @notice Get the owner of the BucketInfo contract
    /// @return The owner address
    function owner() external view returns (address);
}
