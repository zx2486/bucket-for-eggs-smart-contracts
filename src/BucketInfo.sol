// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

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
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenWhitelisted(address indexed token, bool whitelisted);
    /// @dev Emitted the FIRST time a token's manual price is ever set. This is the
    /// unbounded, no-deviation-check, no-interval-check path (A1) -- kept as a distinct
    /// event (rather than reusing TokenPriceUpdated with a sentinel) specifically so the
    /// unbounded case is observable off-chain without inspecting call data.
    event TokenPriceInitialized(address indexed token, uint256 price);
    /// @dev Emitted on every subsequent manual price update, i.e. once a token already has
    /// a previous price on record. Subject to the A1 rate limit (see setTokenPrice).
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    event MaxPriceStalenessUpdated(address indexed token, uint256 newMaxStaleness);
    event PlatformFeeUpdated(uint256 newFee);
    event FeesWithdrawn(address indexed tokenAddr, address indexed to, uint256 amount);

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

    /// @dev Per-token override of the Chainlink staleness window (seconds). 0 means
    /// "use DEFAULT_MAX_PRICE_STALENESS". Owner-configurable, same setter category as
    /// setPriceFeed/batchSetPriceFeeds (W1 sc-oracle: "staleness window per feed rather
    /// than one global 30 days").
    mapping(address => uint256) public maxPriceStaleness;

    /// @dev List of all whitelisted tokens for enumeration
    address[] private whitelistedTokens;

    /// @dev Platform fee in basis points (100 = 1%)
    uint256 public platformFee;

    /// @dev Price decimals (following Chainlink standard)
    uint256 public constant PRICE_DECIMALS = 8;

    /// @dev Maximum platform fee (10% = 1000 basis points)
    uint256 public constant MAX_PLATFORM_FEE = 1000;

    /// @dev Default Chainlink staleness window used when a token has no per-token override
    /// (maxPriceStaleness[token] == 0). NO EXACT NUMBER WAS CLIENT-SPECIFIED for this --
    /// see W1-SC1-ORACLE-REPORT.md `## Blocked`. 1 hour is a conservative default chosen to
    /// match common Chainlink mainnet heartbeats for liquid pairs; it is owner-configurable
    /// per token via setMaxPriceStaleness so a deployment can widen it for feeds with a
    /// longer heartbeat without a code change.
    uint256 public constant DEFAULT_MAX_PRICE_STALENESS = 1 hours;

    /// @dev A1 (09-DECISION-LOG.md): maximum relative deviation allowed for a single
    /// setTokenPrice/batchSetTokenPrices STEP, in basis points of the previous price
    /// (2000 = 20%). Client-specified. This bounds each step, not the cumulative journey --
    /// see W1-SC1-ORACLE-REPORT.md for the accepted-residual note on 24h compounding.
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 2000;

    /// @dev A1: minimum interval between two manual price updates for the same token.
    /// Client-specified.
    uint256 public constant MIN_PRICE_UPDATE_INTERVAL = 1 hours;

    /// @dev Native token (ETH) address representation
    address public constant NATIVE_TOKEN = address(0);

    /// @dev Accumulated fees withdrawn by token address
    mapping(address => uint256) public accumulatedFeesWithdrawn;

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
    function setTokenWhitelist(address token, bool whitelisted) external onlyOwner {
        require(isWhitelisted[token] != whitelisted, "Already in desired state");

        isWhitelisted[token] = whitelisted;

        if (whitelisted) {
            whitelistedTokens.push(token);
        } else {
            // Remove from array
            for (uint256 i = 0; i < whitelistedTokens.length; i++) {
                if (whitelistedTokens[i] == token) {
                    whitelistedTokens[i] = whitelistedTokens[whitelistedTokens.length - 1];
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
    function batchSetTokenWhitelist(address[] calldata tokens, bool whitelisted) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (isWhitelisted[tokens[i]] != whitelisted) {
                isWhitelisted[tokens[i]] = whitelisted;

                if (whitelisted) {
                    whitelistedTokens.push(tokens[i]);
                } else {
                    // Remove from array
                    for (uint256 j = 0; j < whitelistedTokens.length; j++) {
                        if (whitelistedTokens[j] == tokens[i]) {
                            whitelistedTokens[j] = whitelistedTokens[whitelistedTokens.length - 1];
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
     * @dev Manually set token price (in USD with 8 decimals). Subject to the A1 rate limit:
     * the first-ever price set for a token is unbounded (emits TokenPriceInitialized);
     * every subsequent update must be within MAX_PRICE_DEVIATION_BPS of the previous price
     * and at least MIN_PRICE_UPDATE_INTERVAL after the previous update (emits
     * TokenPriceUpdated), or the call reverts -- it never clamps.
     * @param token Address of the token
     * @param price Price in USD (e.g., 2000.00000000 for $2000)
     */
    function setTokenPrice(address token, uint256 price) external onlyOwner {
        _setTokenPrice(token, price);
    }

    /**
     * @dev Batch set token prices. Each (token, price) pair is subject to the same A1 rate
     * limit as setTokenPrice -- there is no bulk-update exemption, or the cap could be
     * bypassed by routing every update through this function instead.
     * @param tokens Array of token addresses
     * @param prices Array of prices (must match tokens length)
     */
    function batchSetTokenPrices(address[] calldata tokens, uint256[] calldata prices) external onlyOwner {
        require(tokens.length == prices.length, "Arrays length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            _setTokenPrice(tokens[i], prices[i]);
        }
    }

    /**
     * @dev Shared implementation for setTokenPrice/batchSetTokenPrices enforcing A1.
     * @param token Address of the token
     * @param price New price in USD (8 decimals)
     */
    function _setTokenPrice(address token, uint256 price) internal {
        require(isWhitelisted[token], "Token not whitelisted");
        require(price > 0, "Price must be greater than 0");

        uint256 lastUpdate = priceUpdateTimestamps[token];

        if (lastUpdate == 0) {
            // First-ever price for this token: unbounded by design (A1), but distinctly
            // observable so an indexer can tell "initialized" apart from "updated".
            tokenPrices[token] = price;
            priceUpdateTimestamps[token] = block.timestamp;
            emit TokenPriceInitialized(token, price);
            return;
        }

        require(block.timestamp - lastUpdate >= MIN_PRICE_UPDATE_INTERVAL, "Price update too soon");

        uint256 previousPrice = tokenPrices[token];
        // Divide before multiplying: previousPrice can legitimately be as large as
        // type(uint256).max (the first-ever set is unbounded), so previousPrice * 2000
        // would overflow. previousPrice / 5 == 20% of previousPrice, rounded down --
        // a strictly conservative (tighter) cap than true 20%, never looser.
        uint256 maxDelta = previousPrice / (10000 / MAX_PRICE_DEVIATION_BPS);
        uint256 diff = price > previousPrice ? price - previousPrice : previousPrice - price;
        require(diff <= maxDelta, "Price deviation exceeds cap");

        tokenPrices[token] = price;
        priceUpdateTimestamps[token] = block.timestamp;
        emit TokenPriceUpdated(token, previousPrice, price);
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

    function batchSetPriceFeeds(address[] calldata tokens, address[] calldata priceFeeds) external onlyOwner {
        require(tokens.length == priceFeeds.length, "Arrays length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            require(isWhitelisted[tokens[i]], "Token not whitelisted");
            require(priceFeeds[i] != address(0), "Invalid price feed address");

            priceFeedsChainlink[tokens[i]] = priceFeeds[i];
            emit PriceFeedUpdated(tokens[i], priceFeeds[i]);
        }
    }

    /**
     * @dev Set the Chainlink staleness window override for a token (seconds). Pass 0 to
     * fall back to DEFAULT_MAX_PRICE_STALENESS. Same setter category as setPriceFeed --
     * an extension of "price feed" configuration, not a new one.
     * @param token Address of the token
     * @param newMaxStaleness Maximum allowed age (seconds) of a Chainlink round's
     * updatedAt before getTokenPrice/tryGetTokenPrice treat it as stale
     */
    function setMaxPriceStaleness(address token, uint256 newMaxStaleness) external onlyOwner {
        require(isWhitelisted[token], "Token not whitelisted");
        maxPriceStaleness[token] = newMaxStaleness;
        emit MaxPriceStalenessUpdated(token, newMaxStaleness);
    }

    /**
     * @dev Effective staleness window for a token: its override if set, else the default.
     */
    function _maxStalenessFor(address token) internal view returns (uint256) {
        uint256 tokenOverride = maxPriceStaleness[token];
        return tokenOverride == 0 ? DEFAULT_MAX_PRICE_STALENESS : tokenOverride;
    }

    /**
     * @dev Get token price (USD with 8 decimals). Reverts if the token is not whitelisted
     * or if no valid price is available (Chainlink data invalid/stale, or manual price
     * missing/stale). For a never-reverting variant see tryGetTokenPrice.
     * @param token Address of the token
     * @return price Token price in USD
     */
    function getTokenPrice(address token) external view returns (uint256) {
        require(isWhitelisted[token], "Token not whitelisted");

        if (priceFeedsChainlink[token] != address(0)) {
            (bool ok, uint256 price) = _tryReadChainlinkPrice(token);
            require(ok, "Invalid Chainlink price data");
            return price;
        }

        // Check if manual price is stale (older than 30 days)
        require(
            priceUpdateTimestamps[token] > 0 && block.timestamp - priceUpdateTimestamps[token] <= 30 days,
            "Price is outdated"
        );
        return tokenPrices[token];
    }

    /**
     * @dev Never-reverting companion to getTokenPrice. Returns (false, 0) for any input
     * that would cause getTokenPrice to revert -- non-whitelisted token, a reverting or
     * malformed Chainlink feed, negative/zero/stale/incomplete round data, or a missing/
     * stale manual price. Consumers (vaults) use this to check price availability without
     * risking a revert mid-transaction.
     * @param token Address of the token
     * @return ok True if a valid price was found
     * @return price The price in USD (8 decimals) if ok is true, else 0
     */
    function tryGetTokenPrice(address token) external view returns (bool ok, uint256 price) {
        return _tryGetPrice(token);
    }

    /**
     * @dev Per-token oracle-health check: true if this token's price is NOT currently
     * available via tryGetTokenPrice (i.e. it is potentially outpriced / stale / invalid).
     * BucketInfo has no notion of which tokens any given vault holds, so this is
     * necessarily per-token, not per-vault -- a vault consuming this must OR the result
     * across its held-token set. See W1-SC1-ORACLE-REPORT.md `## Corrections to my briefing`.
     * @param token Address of the token
     * @return True if the token's price is currently unavailable/invalid
     */
    function isPotentiallyOutpriced(address token) external view returns (bool) {
        (bool ok,) = _tryGetPrice(token);
        return !ok;
    }

    /**
     * @dev Shared never-reverting price lookup used by tryGetTokenPrice and
     * isPotentiallyOutpriced.
     */
    function _tryGetPrice(address token) internal view returns (bool ok, uint256 price) {
        if (!isWhitelisted[token]) {
            return (false, 0);
        }

        if (priceFeedsChainlink[token] != address(0)) {
            return _tryReadChainlinkPrice(token);
        }

        if (priceUpdateTimestamps[token] > 0 && block.timestamp - priceUpdateTimestamps[token] <= 30 days) {
            return (true, tokenPrices[token]);
        }

        return (false, 0);
    }

    /**
     * @dev Reads and validates a Chainlink round for `token`. Never reverts -- every
     * failure mode (reverting call, negative/zero answer, updatedAt == 0, a carried-forward
     * round where answeredInRound < roundId, or a round older than the effective staleness
     * window) returns (false, 0) instead. The int256 -> uint256 cast is guarded by the
     * `answer <= 0` check immediately above it, so it can never reinterpret a negative
     * two's-complement value as a huge positive price.
     */
    function _tryReadChainlinkPrice(address token) internal view returns (bool ok, uint256 price) {
        address feedAddr = priceFeedsChainlink[token];
        if (feedAddr == address(0)) {
            return (false, 0);
        }
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feedAddr);

        try priceFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, /* startedAt, unused */ uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (false, 0);
            if (updatedAt == 0) return (false, 0);
            if (updatedAt > block.timestamp) return (false, 0);
            if (answeredInRound < roundId) return (false, 0);
            if (block.timestamp - updatedAt > _maxStalenessFor(token)) return (false, 0);

            uint8 decimals;
            try priceFeed.decimals() returns (uint8 d) {
                decimals = d;
            } catch {
                return (false, 0);
            }

            // Guarded, explicit cast: answer > 0 was just verified above, so this can
            // never reinterpret a negative two's-complement bit pattern.
            uint256 rawPrice = uint256(answer);

            if (decimals < PRICE_DECIMALS) {
                return (true, rawPrice * (10 ** (PRICE_DECIMALS - decimals)));
            } else if (decimals > PRICE_DECIMALS) {
                return (true, rawPrice / (10 ** (decimals - PRICE_DECIMALS)));
            } else {
                return (true, rawPrice);
            }
        } catch {
            return (false, 0);
        }
    }

    /**
     * @dev Get price feed address for a token
     * @param token Address of the token
     * @return priceFeed Address of the Chainlink price feed
     */
    function getPriceFeed(address token) external view returns (address) {
        return priceFeedsChainlink[token];
    }

    /**
     * @dev Check if a token is whitelisted
     * @param token Address of the token
     * @return True if token is whitelisted
     */
    function isTokenWhitelisted(address token) external view returns (bool) {
        return isWhitelisted[token];
    }

    /**
     * @dev Get manually set token price (USD with 8 decimals)
     * @param token Address of the token
     * @return price Manually set token price (0 if not set or using Chainlink)
     */
    function getManualTokenPrice(address token) external view returns (uint256) {
        return tokenPrices[token];
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

    /*//////////////////////////////////////////////////////////////
                        FEE WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Withdraw accumulated fees (ERC-20 tokens) collected from Bucket contracts
     * @param to Recipient address
     * @param tokenAddr Token address to withdraw (the bucket share tokens)
     * @param amount Amount of tokens to withdraw
     */
    function withdrawAccumulatedFees(address to, address tokenAddr, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddr).safeTransfer(to, amount);
        accumulatedFeesWithdrawn[tokenAddr] += amount;

        emit FeesWithdrawn(tokenAddr, to, amount);
    }

    function withdrawAccumulatedETHFees(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        (bool success,) = to.call{value: amount}("");
        require(success, "ETH transfer failed");

        accumulatedFeesWithdrawn[NATIVE_TOKEN] += amount;

        emit FeesWithdrawn(NATIVE_TOKEN, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
}
