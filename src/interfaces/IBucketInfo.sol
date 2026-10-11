// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Interface to platform configuration and token pricing.
interface IBucketInfo {
    /// @notice Whether a token is whitelisted and the platform is operational.
    function isTokenValid(address token) external view returns (bool);

    /// @notice Whether a token is whitelisted, regardless of platform pause state.
    function isTokenWhitelisted(address token) external view returns (bool);

    /// @notice Get a token's USD price, reverting if the price is invalid.
    function getTokenPrice(address token) external view returns (uint256);

    /// @notice Try to get a token's USD price without reverting.
    function tryGetTokenPrice(address token) external view returns (bool ok, uint256 price);

    /// @notice Whether a token's price feed may be outpriced.
    function isPotentiallyOutpriced(address token) external view returns (bool);

    /// @notice Whether the platform is operational.
    function isPlatformOperational() external view returns (bool);

    /// @notice Calculate the platform fee for an amount.
    function calculateFee(uint256 amount) external view returns (uint256);

    /// @notice Return all whitelisted token addresses.
    function getWhitelistedTokens() external view returns (address[] memory);

    /// @notice Number of decimals used for token prices.
    function PRICE_DECIMALS() external view returns (uint256);

    /// @notice Platform fee in basis points.
    function platformFee() external view returns (uint256);

    /// @notice Return the BucketInfo owner.
    function owner() external view returns (address);

    /// @notice Whether an account is blacklisted.
    function isBlacklisted(address account) external view returns (bool);

    /// @notice Return a token's Chainlink feed, or zero if manually priced.
    function getPriceFeed(address token) external view returns (address);
}
