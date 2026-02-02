// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title BucketInfo
 * @dev Central information contract for the Bucket for Eggs platform
 *
 * This contract manages:
 * - Whitelist of accepted tokens/coins
 * - Platform-wide pause state
 * - Price feeds for tokens/coins (to be integrated with Chainlink)
 * - Platform configuration
 */
contract BucketInfo is Ownable, Pausable {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenWhitelisted(address indexed token, bool whitelisted);
    event PriceUpdated(address indexed token, uint256 price);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    event PlatformFeeUpdated(uint256 newFee);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping of token address to whitelist status
    mapping(address => bool) private isWhitelisted;

    /// @dev Mapping of token address to price (in USD with 8 decimals, like Chainlink)
    /// Price represents USD per 1 token (e.g., 1 ETH = 2000.00000000 USD)
    mapping(address => uint256) private tokenPrices;

    /// @dev Mapping of token address to last price update timestamp
    mapping(address => uint256) private priceUpdateTimestamps;

    /// @dev Mapping of token address to Chainlink price feed address
    mapping(address => address) private priceFeedsChainlink;

    /// @dev List of all whitelisted tokens for enumeration
    address[] private whitelistedTokens;

    /// @dev Platform fee in basis points (100 = 1%)
    uint256 public platformFee;

    /// @dev Price decimals (following Chainlink standard)
    uint256 public constant PRICE_DECIMALS = 8;

    /// @dev Maximum platform fee (10% = 1000 basis points)
    uint256 public constant MAX_PLATFORM_FEE = 1000;

    /// @dev Native token (ETH) address representation
    address public constant NATIVE_TOKEN = address(0);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Constructor sets the initial owner
     */
    constructor() Ownable(msg.sender) {
        platformFee = 100; // Default 1% fee

        // Whitelist native token (ETH) by default
        isWhitelisted[NATIVE_TOKEN] = true;
        whitelistedTokens.push(NATIVE_TOKEN);
        emit TokenWhitelisted(NATIVE_TOKEN, true);
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Add or remove a token from whitelist
     * @param token Address of the token (use address(0) for native ETH)
     * @param whitelisted True to whitelist, false to remove
     */
    function setTokenWhitelist(
        address token,
        bool whitelisted
    ) external onlyOwner {
        require(
            isWhitelisted[token] != whitelisted,
            "Already in desired state"
        );

        isWhitelisted[token] = whitelisted;

        if (whitelisted) {
            whitelistedTokens.push(token);
        } else {
            // Remove from array
            for (uint256 i = 0; i < whitelistedTokens.length; i++) {
                if (whitelistedTokens[i] == token) {
                    whitelistedTokens[i] = whitelistedTokens[
                        whitelistedTokens.length - 1
                    ];
                    whitelistedTokens.pop();
                    break;
                }
            }
        }

        emit TokenWhitelisted(token, whitelisted);
    }

    /**
     * @dev Batch whitelist multiple tokens
     * @param tokens Array of token addresses
     * @param whitelisted True to whitelist, false to remove
     */
    function batchSetTokenWhitelist(
        address[] calldata tokens,
        bool whitelisted
    ) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (isWhitelisted[tokens[i]] != whitelisted) {
                isWhitelisted[tokens[i]] = whitelisted;

                if (whitelisted) {
                    whitelistedTokens.push(tokens[i]);
                } else {
                    // Remove from array
                    for (uint256 j = 0; j < whitelistedTokens.length; j++) {
                        if (whitelistedTokens[j] == tokens[i]) {
                            whitelistedTokens[j] = whitelistedTokens[
                                whitelistedTokens.length - 1
                            ];
                            whitelistedTokens.pop();
                            break;
                        }
                    }
                }

                emit TokenWhitelisted(tokens[i], whitelisted);
            }
        }
    }

    /**
     * @dev Get all whitelisted tokens
     * @return Array of whitelisted token addresses
     */
    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }

    /**
     * @dev Get number of whitelisted tokens
     * @return Count of whitelisted tokens
     */
    function getWhitelistedTokenCount() external view returns (uint256) {
        return whitelistedTokens.length;
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Manually set token price (in USD with 8 decimals)
     * @param token Address of the token
     * @param price Price in USD (e.g., 2000.00000000 for $2000)
     */
    function setTokenPrice(address token, uint256 price) external onlyOwner {
        require(isWhitelisted[token], "Token not whitelisted");
        require(price > 0, "Price must be greater than 0");

        tokenPrices[token] = price;
        priceUpdateTimestamps[token] = block.timestamp;
        emit PriceUpdated(token, price);
    }

    /**
     * @dev Batch set token prices
     * @param tokens Array of token addresses
     * @param prices Array of prices (must match tokens length)
     */
    function batchSetTokenPrices(
        address[] calldata tokens,
        uint256[] calldata prices
    ) external onlyOwner {
        require(tokens.length == prices.length, "Arrays length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            require(isWhitelisted[tokens[i]], "Token not whitelisted");
            require(prices[i] > 0, "Price must be greater than 0");

            tokenPrices[tokens[i]] = prices[i];
            priceUpdateTimestamps[token] = block.timestamp;
            emit PriceUpdated(tokens[i], prices[i]);
        }
    }

    /**
     * @dev Set Chainlink price feed for a token
     * @param token Address of the token
     * @param priceFeed Address of the Chainlink price feed
     */
    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        require(isWhitelisted[token], "Token not whitelisted");
        require(priceFeed != address(0), "Invalid price feed address");

        priceFeedsChainlink[token] = priceFeed;
        emit PriceFeedUpdated(token, priceFeed);
    }

    /**
     * @dev Get token price (USD with 8 decimals)
     * @param token Address of the token
     * @return price Token price in USD
     */
    function getTokenPrice(address token) external view returns (uint256) {
        require(isWhitelisted[token], "Token not whitelisted");
        if (priceFeedsChainlink[token] != address(0)) {
            AggregatorV3Interface priceFeed = AggregatorV3Interface(
                priceFeedsChainlink[token]
            );
            (, int256 price, , , ) = priceFeed.latestRoundData();
            uint8 decimals = priceFeed.decimals();
            // Adjust price to have 8 decimals
            if (decimals < PRICE_DECIMALS) {
                return uint256(price) * (10 ** (PRICE_DECIMALS - decimals));
            } else if (decimals > PRICE_DECIMALS) {
                return uint256(price) / (10 ** (decimals - PRICE_DECIMALS));
            } else {
                return uint256(price);
            }
        }
        // Check if manual price is stale (older than 30 days)
        require(
            priceUpdateTimestamps[token] > 0 &&
                block.timestamp - priceUpdateTimestamps[token] <= 30 days,
            "Price is outdated"
        );
        return tokenPrices[token];
    }

    /**
     * @dev Get price feed address for a token
     * @param token Address of the token
     * @return priceFeed Address of the Chainlink price feed
     */
    function getPriceFeed(address token) external view returns (address) {
        return priceFeedsChainlink[token];
    }

    /*//////////////////////////////////////////////////////////////
                        PLATFORM MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Pause the entire platform
     */
    function pausePlatform() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the platform
     */
    function unpausePlatform() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Set platform fee
     * @param newFee Fee in basis points (100 = 1%)
     */
    function setPlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");
        platformFee = newFee;
        emit PlatformFeeUpdated(newFee);
    }

    /**
     * @dev Check if platform is operational
     * @return True if not paused and ready for operations
     */
    function isPlatformOperational() external view returns (bool) {
        return !paused();
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate fee amount for a given value
     * @param amount The amount to calculate fee on
     * @return feeAmount The calculated fee
     */
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * platformFee) / 10000;
    }

    /**
     * @dev Check if a token is valid for platform use
     * @param token Address of the token to check
     * @return valid True if token is whitelisted and platform is operational
     */
    function isTokenValid(address token) external view returns (bool) {
        return isWhitelisted[token] && !paused();
    }
}
