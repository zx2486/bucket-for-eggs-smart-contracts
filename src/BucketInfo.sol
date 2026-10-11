// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/shared/interfaces/AggregatorV3Interface.sol";
import {TimelockedAdmin} from "./libs/TimelockedAdmin.sol";

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
contract BucketInfo is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;
    using TimelockedAdmin for TimelockedAdmin.AddressTimelock;
    using TimelockedAdmin for TimelockedAdmin.UintTimelock;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenWhitelisted(address indexed token, bool whitelisted);
    /// @dev Emitted the FIRST time a token's manual price is ever set. This is the
    /// unbounded, no-deviation-check, no-interval-check path -- kept as a distinct event
    /// (rather than reusing TokenPriceUpdated with a sentinel) specifically so the unbounded
    /// case is observable off-chain without inspecting call data.
    event TokenPriceInitialized(address indexed token, uint256 price);
    /// @dev Emitted on every subsequent manual price update, i.e. once a token already has
    /// a previous price on record. Subject to the deviation/interval rate limit (see
    /// setTokenPrice).
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    event MaxPriceStalenessUpdated(address indexed token, uint256 newMaxStaleness);
    event PlatformFeeUpdated(uint256 newFee);
    event FeesWithdrawn(address indexed tokenAddr, address indexed to, uint256 amount);

    /// @dev One Proposed/Canceled pair per timelocked setter family (whitelist additions,
    /// price feeds, platform fee); the corresponding *Updated/*Whitelisted event above is
    /// reused to signal the applied change at execute time, so indexers built against the
    /// old event names keep working.
    event WhitelistAdditionProposed(address indexed token, uint256 eta);
    event WhitelistAdditionCanceled(address indexed token);
    event PriceFeedProposed(address indexed token, address priceFeed, uint256 eta);
    event PriceFeedCanceled(address indexed token, address canceledPriceFeed);
    event PlatformFeeProposed(uint256 newFee, uint256 eta);
    event PlatformFeeCanceled(uint256 canceledFee);

    /// @dev Single event covers both add and remove, mirroring {TokenWhitelisted}'s own
    /// single-event-with-bool convention.
    event AddressBlacklistUpdated(address indexed account, bool blacklisted);

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
    /// setPriceFeed/batchSetPriceFeeds.
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
    /// (maxPriceStaleness[token] == 0). 1 hour is a conservative default chosen to match
    /// common Chainlink mainnet heartbeats for liquid pairs; it is owner-configurable per
    /// token via setMaxPriceStaleness so a deployment can widen it for feeds with a longer
    /// heartbeat without a code change.
    uint256 public constant DEFAULT_MAX_PRICE_STALENESS = 1 hours;

    /// @dev Maximum relative deviation allowed for a single setTokenPrice/batchSetTokenPrices
    /// STEP, in basis points of the previous price (2000 = 20%). This bounds each step, not
    /// the cumulative journey over many steps.
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 2000;

    /// @dev Minimum interval between two manual price updates for the same token.
    uint256 public constant MIN_PRICE_UPDATE_INTERVAL = 1 hours;

    /// @dev Delay enforced between proposing and executing a platform-fee change, a
    /// price-feed change, or a whitelist addition on this contract. One platform-wide delay
    /// so a newly whitelisted token (which becomes swappable/depositable instantly) and a
    /// price feed change carry the same investor exit window as the vault upgrade timelock.
    uint256 public constant PLATFORM_SETTER_TIMELOCK_DELAY = 48 hours;

    /// @dev Native token (ETH) address representation
    address public constant NATIVE_TOKEN = address(0);

    /// @dev Accumulated fees withdrawn by token address
    mapping(address => uint256) public accumulatedFeesWithdrawn;

    /// @dev One pending platform-fee proposal (global, not per-token), one pending price-feed
    /// proposal per token, one pending whitelist-addition proposal per token. Whitelist-addition
    /// proposals have no meaningful "value" beyond the token address itself (already the mapping
    /// key), so `pending` is set to the sentinel `1` purely to distinguish "a proposal exists"
    /// from the zeroed default -- only `eta` carries real timing information for this one.
    TimelockedAdmin.UintTimelock private _platformFeeTimelock;
    mapping(address => TimelockedAdmin.AddressTimelock) private _priceFeedTimelocks;
    mapping(address => TimelockedAdmin.UintTimelock) private _whitelistAdditionTimelocks;

    /// @dev Fail-closed compliance blacklist. Deliberately a single flat mapping with an O(1)
    /// getter ({isBlacklisted}) -- no loop, no external call -- since it must be safe to call
    /// from every token contract's transfer hook on every deposit/redeem/transfer. No
    /// enumeration array is kept here (unlike {whitelistedTokens}): nothing requires walking
    /// "all blacklisted addresses" on-chain, and adding one would be unbounded growth with no
    /// offsetting benefit.
    mapping(address => bool) private _blacklisted;

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
     * @notice Propose adding `token` to the whitelist. Additions are timelocked: a
     * newly-whitelisted token becomes swappable/depositable platform-wide the instant it
     * lands, so investors get an exit-aware window, same as a price feed or fee change.
     * Removal stays immediate ({removeTokenWhitelist}) -- pulling a bad token out can never
     * need to wait.
     * @param token Address of the token (use address(0) for native ETH)
     */
    function proposeWhitelistAddition(address token) external onlyOwner {
        require(!isWhitelisted[token], "Already in desired state");
        _whitelistAdditionTimelocks[token].propose(1, PLATFORM_SETTER_TIMELOCK_DELAY);
        emit WhitelistAdditionProposed(token, _whitelistAdditionTimelocks[token].eta);
    }

    /// @notice Apply a previously proposed whitelist addition for `token` once its timelock
    /// has elapsed.
    function executeWhitelistAddition(address token) external onlyOwner {
        _whitelistAdditionTimelocks[token].execute();
        require(!isWhitelisted[token], "Already in desired state");

        isWhitelisted[token] = true;
        whitelistedTokens.push(token);
        emit TokenWhitelisted(token, true);
    }

    /// @notice Cancel a pending whitelist addition for `token` before it executes.
    function cancelWhitelistAddition(address token) external onlyOwner {
        _whitelistAdditionTimelocks[token].cancel();
        emit WhitelistAdditionCanceled(token);
    }

    /**
     * @notice Remove `token` from the whitelist. Immediate, no timelock -- pulling a bad token
     * out can never need to wait, and a delayed removal would leave a known-bad token live for
     * the whole window it was supposed to protect against.
     * @param token Address of the token (use address(0) for native ETH)
     */
    function removeTokenWhitelist(address token) external onlyOwner {
        require(isWhitelisted[token], "Already in desired state");

        isWhitelisted[token] = false;

        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            if (whitelistedTokens[i] == token) {
                whitelistedTokens[i] = whitelistedTokens[whitelistedTokens.length - 1];
                whitelistedTokens.pop();
                break;
            }
        }

        emit TokenWhitelisted(token, false);
    }

    /// @notice Batch convenience wrapper over {proposeWhitelistAddition}.
    function batchProposeWhitelistAdditions(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(!isWhitelisted[tokens[i]], "Already in desired state");
            _whitelistAdditionTimelocks[tokens[i]].propose(1, PLATFORM_SETTER_TIMELOCK_DELAY);
            emit WhitelistAdditionProposed(tokens[i], _whitelistAdditionTimelocks[tokens[i]].eta);
        }
    }

    /// @notice Batch convenience wrapper over {executeWhitelistAddition}.
    function batchExecuteWhitelistAdditions(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            _whitelistAdditionTimelocks[tokens[i]].execute();
            require(!isWhitelisted[tokens[i]], "Already in desired state");
            isWhitelisted[tokens[i]] = true;
            whitelistedTokens.push(tokens[i]);
            emit TokenWhitelisted(tokens[i], true);
        }
    }

    /// @notice Batch convenience wrapper over {removeTokenWhitelist}.
    function batchRemoveTokenWhitelist(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (isWhitelisted[tokens[i]]) {
                isWhitelisted[tokens[i]] = false;
                for (uint256 j = 0; j < whitelistedTokens.length; j++) {
                    if (whitelistedTokens[j] == tokens[i]) {
                        whitelistedTokens[j] = whitelistedTokens[whitelistedTokens.length - 1];
                        whitelistedTokens.pop();
                        break;
                    }
                }
                emit TokenWhitelisted(tokens[i], false);
            }
        }
    }

    /// @notice Whether a whitelist-addition proposal is currently pending for `token`.
    function pendingWhitelistAddition(address token) external view returns (bool) {
        return _whitelistAdditionTimelocks[token].eta != 0;
    }

    /// @notice The execution timestamp of the pending whitelist-addition proposal for `token`
    /// (0 if none).
    function whitelistAdditionEta(address token) external view returns (uint256) {
        return _whitelistAdditionTimelocks[token].eta;
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
     * @dev Manually set token price (in USD with 8 decimals). Subject to a rate limit:
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
     * @dev Batch set token prices. Each (token, price) pair is subject to the same rate
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
     * @dev Shared implementation for setTokenPrice/batchSetTokenPrices enforcing the rate limit.
     * @param token Address of the token
     * @param price New price in USD (8 decimals)
     */
    function _setTokenPrice(address token, uint256 price) internal {
        require(isWhitelisted[token], "Token not whitelisted");
        require(price > 0, "Price must be greater than 0");

        uint256 lastUpdate = priceUpdateTimestamps[token];

        if (lastUpdate == 0) {
            // First-ever price for this token: unbounded by design, but distinctly
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
     * @notice Propose a new Chainlink price feed for `token`. A price feed swap carries a
     * rug-pull shape identical to a whitelist addition or fee change, so it gets the same
     * timelock. Overwrites any existing proposal for this token.
     * @param token Address of the token
     * @param priceFeed Address of the Chainlink price feed
     */
    function proposePriceFeed(address token, address priceFeed) external onlyOwner {
        require(isWhitelisted[token], "Token not whitelisted");
        require(priceFeed != address(0), "Invalid price feed address");
        _priceFeedTimelocks[token].propose(priceFeed, PLATFORM_SETTER_TIMELOCK_DELAY);
        emit PriceFeedProposed(token, priceFeed, _priceFeedTimelocks[token].eta);
    }

    /**
     * @notice Apply a previously proposed price feed for `token` once its timelock has
     * elapsed. Re-checks whitelist status at execution time -- a token removed from the
     * whitelist during the window must not have its price feed installed anyway.
     */
    function executePriceFeed(address token) external onlyOwner {
        address newFeed = _priceFeedTimelocks[token].execute();
        require(isWhitelisted[token], "Token not whitelisted");
        priceFeedsChainlink[token] = newFeed;
        emit PriceFeedUpdated(token, newFeed);
    }

    /// @notice Cancel a pending price feed proposal for `token` before it executes.
    function cancelPriceFeed(address token) external onlyOwner {
        address canceled = _priceFeedTimelocks[token].pending;
        _priceFeedTimelocks[token].cancel();
        emit PriceFeedCanceled(token, canceled);
    }

    /// @notice Batch convenience wrapper over {proposePriceFeed} -- identical per-token
    /// semantics and checks, just looped. Not a bulk-update exemption from the timelock.
    function proposeBatchPriceFeeds(address[] calldata tokens, address[] calldata priceFeeds) external onlyOwner {
        require(tokens.length == priceFeeds.length, "Arrays length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(isWhitelisted[tokens[i]], "Token not whitelisted");
            require(priceFeeds[i] != address(0), "Invalid price feed address");
            _priceFeedTimelocks[tokens[i]].propose(priceFeeds[i], PLATFORM_SETTER_TIMELOCK_DELAY);
            emit PriceFeedProposed(tokens[i], priceFeeds[i], _priceFeedTimelocks[tokens[i]].eta);
        }
    }

    /// @notice Batch convenience wrapper over {executePriceFeed}.
    function executeBatchPriceFeeds(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            address newFeed = _priceFeedTimelocks[tokens[i]].execute();
            require(isWhitelisted[tokens[i]], "Token not whitelisted");
            priceFeedsChainlink[tokens[i]] = newFeed;
            emit PriceFeedUpdated(tokens[i], newFeed);
        }
    }

    /// @notice The currently pending price feed proposal for `token`, if any.
    function pendingPriceFeed(address token) external view returns (address) {
        return _priceFeedTimelocks[token].pending;
    }

    /// @notice The execution timestamp of the pending price feed proposal for `token` (0 if
    /// none).
    function priceFeedEta(address token) external view returns (uint256) {
        return _priceFeedTimelocks[token].eta;
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
     * across its held-token set.
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
     * @notice Propose a new platform fee. Must clear {PLATFORM_SETTER_TIMELOCK_DELAY} before
     * {executePlatformFee} can apply it. Overwrites any existing proposal.
     * @param newFee Fee in basis points (100 = 1%)
     */
    function proposePlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");
        _platformFeeTimelock.propose(newFee, PLATFORM_SETTER_TIMELOCK_DELAY);
        emit PlatformFeeProposed(newFee, _platformFeeTimelock.eta);
    }

    /**
     * @notice Apply a previously proposed platform fee once its timelock has elapsed.
     * Re-validates the cap at execution time as well as proposal time, in case
     * MAX_PLATFORM_FEE semantics are ever revisited -- belt-and-suspenders, not currently
     * reachable since the cap cannot change within one proposal's window.
     */
    function executePlatformFee() external onlyOwner {
        uint256 newFee = _platformFeeTimelock.execute();
        require(newFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");
        platformFee = newFee;
        emit PlatformFeeUpdated(newFee);
    }

    /// @notice Cancel a pending platform fee proposal before it executes.
    function cancelPlatformFee() external onlyOwner {
        uint256 canceled = _platformFeeTimelock.pending;
        _platformFeeTimelock.cancel();
        emit PlatformFeeCanceled(canceled);
    }

    /// @notice The currently pending platform fee proposal, if any (0 if none pending --
    /// note 0 is also a valid fee value, so cross-check {platformFeeEta} != 0 to distinguish
    /// "no proposal" from "a proposal to set the fee to zero").
    function pendingPlatformFee() external view returns (uint256) {
        return _platformFeeTimelock.pending;
    }

    /// @notice The execution timestamp of the pending platform fee proposal (0 if none).
    function platformFeeEta() external view returns (uint256) {
        return _platformFeeTimelock.eta;
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
                        GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown by {renounceOwnership}, which is always disabled -- if this contract is
    /// ever to become ownerless, ownership would move to a DAO contract via
    /// `transferOwnership`, not via renunciation.
    error RenounceOwnershipDisabled();

    /// @notice Always reverts -- ownership must always be transferable, never abandoned, since
    /// `transferOwnership` (two-step, via `Ownable2Step`) is the only route to a new owner.
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                        COMPLIANCE -- BLACKLIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether `account` is blacklisted. A pure storage read, no external call, no
    /// loop, no oracle -- every token contract's transfer hook calls this on every
    /// deposit/redeem/transfer, so it must stay O(1) and revert-free by construction.
    /// @dev The single source of truth every contract in the system checks: addresses on the
    /// blacklist must not be able to do anything with any contract in this project, no matter
    /// deposit, withdraw, rebalance, or even transferring the contract tokens.
    /// @param account The address to check.
    /// @return True if `account` is currently blacklisted.
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @notice Add `account` to the compliance blacklist. Immediate -- no timelock, by design:
    /// a delayed freeze would let a bad actor act before it takes effect, so the immediate
    /// action IS the freeze itself.
    /// @dev Gated on this contract's own `onlyOwner`, i.e. the platform, never a vault's own
    /// owner (a customer).
    function blacklistAddress(address account) external onlyOwner {
        require(account != address(0), "Invalid address");
        require(!_blacklisted[account], "Already in desired state");
        _blacklisted[account] = true;
        emit AddressBlacklistUpdated(account, true);
    }

    /// @notice Remove `account` from the compliance blacklist. Immediate, same rationale as
    /// {blacklistAddress}.
    function removeBlacklist(address account) external onlyOwner {
        require(_blacklisted[account], "Already in desired state");
        _blacklisted[account] = false;
        emit AddressBlacklistUpdated(account, false);
    }

    /// @notice Batch convenience wrapper over {blacklistAddress}. Mirrors
    /// {batchRemoveTokenWhitelist}'s forgiving style (skip a no-op entry rather than revert the
    /// whole batch) -- a compliance sweep should not fail entirely because one address in the
    /// list was already blacklisted.
    function batchBlacklistAddresses(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] != address(0) && !_blacklisted[accounts[i]]) {
                _blacklisted[accounts[i]] = true;
                emit AddressBlacklistUpdated(accounts[i], true);
            }
        }
    }

    /// @notice Batch convenience wrapper over {removeBlacklist}. Same forgiving style as
    /// {batchBlacklistAddresses}.
    function batchRemoveBlacklist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (_blacklisted[accounts[i]]) {
                _blacklisted[accounts[i]] = false;
                emit AddressBlacklistUpdated(accounts[i], false);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
}
