// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {IImplementationRegistry} from "./interfaces/IImplementationRegistry.sol";
import {BucketVaultBase} from "./base/BucketVaultBase.sol";
import {DexConfig, DexSwapLib} from "./libraries/DexSwapLib.sol";
import {DistributionLib} from "./libraries/DistributionLib.sol";
import {RebalanceFeeLib} from "./libraries/RebalanceFeeLib.sol";
import {FactoryAuthLib} from "./libraries/FactoryAuthLib.sol";

/**
 * @title PassiveBucket
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-20 vault that manages a basket of tokens according to predefined
 * weight distributions. Users deposit tokens to receive shares and redeem shares to receive
 * proportional underlying tokens. Rebalancing aligns actual holdings with target distribution.
 * @dev Uses UUPS proxy pattern. Integrates with BucketInfo for token validation and pricing,
 *      and with whitelisted DEX routers for rebalancing. Inherits shared
 * deposit-accounting/value/oracle-consumption logic from {BucketVaultBase}; all state variables
 * below stay declared here, at their original linear slots. The Uniswap best-quote-and-swap
 * logic and the sell-to-WETH/buy-from-WETH trade-execution block used by `rebalanceByDefi` live
 * in `libraries/DexSwapLib.sol` and are reached via a library delegatecall, keeping this
 * contract's own runtime bytecode under the EIP-170 size limit.
 */
contract PassiveBucket is BucketVaultBase {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token and its target weight in the bucket distribution
    /// @param token The token address (address(0) for native ETH)
    /// @param weight The weight percentage (all weights must sum to 100)
    struct BucketDistribution {
        address token;
        uint256 weight;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice BucketInfo contract for token validation and pricing
    IBucketInfo public bucketInfo;

    /// @dev Deprecated storage slot retained for proxy layout compatibility.
    address private __deprecated_oneInchRouter;

    /// @notice WETH address for DEX swaps involving native ETH
    address public weth;

    /// @notice Current bucket distributions
    BucketDistribution[] private _bucketDistributions;

    /// @notice Share price in USD with 8 decimals (matching BucketInfo)
    uint256 public tokenPrice;

    /// @notice Whether swap/rebalance functions are paused
    bool public swapPaused;

    /// @notice Total deposited value in USD (8 decimals)
    uint256 public totalDepositValue;

    /// @notice Total withdrawn value in USD (8 decimals)
    /// @dev No longer incremented by `redeem()`; see `BucketVaultBase.sol`'s `Redeemed` event
    /// doc comment for the off-chain replacement.
    uint256 public totalWithdrawValue;

    /// @notice DEX configurations indexed by ID
    mapping(uint8 => DexConfig) public dexConfigs;

    /// @notice Number of configured DEXs
    uint8 public dexCount;

    /// @notice Owner fee in basis points for rebalanceByDefi (e.g., 300 = 3%)
    uint256 public rebalanceOwnerFeeBps;

    /// @notice Caller fee in basis points for rebalanceByDefi (e.g., 100 = 1%)
    uint256 public rebalanceCallerFeeBps;

    /// @notice Weight denominator (weights must sum to this value)
    uint256 public constant WEIGHT_SUM = 100;

    /// @notice Distribution tolerance for rebalance verification (2%)
    uint256 public constant DISTRIBUTION_TOLERANCE = 2;

    /// @notice The platform-owned {ImplementationRegistry} this vault's upgrades are checked
    /// against. Immutable and constructor-set, never repointable — the whitelist authority
    /// itself must not be swappable by this vault's (customer) owner.
    IImplementationRegistry public immutable REGISTRY;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event BucketDistributionsUpdated(BucketDistribution[] distributions);
    event Rebalanced(
        address indexed caller,
        uint256 totalValueBeforeSwap,
        uint256 totalValueBasedOnLastTokenPrice,
        uint256 totalValueAfter,
        uint256 newTokenPrice
    );
    event RebalanceFeeDistributed(address indexed recipient, uint256 sharesMinted, uint256 feeValueUsd);
    event OwnerPenaltyBurned(address indexed owner, uint256 sharesBurned, uint256 penaltyValueUsd);
    event DexConfigured(uint8 indexed dexId, address router, address quoter, bool enabled);
    event WETHUpdated(address indexed weth);
    event RebalanceFeesUpdated(uint256 ownerFeeBps, uint256 callerFeeBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidDistributions();
    error WeightSumMismatch(uint256 totalWeight);
    error DuplicateToken(address token);
    error EmptyDistributions();
    /// @dev `OwnerNotAccountable` lives in {BucketVaultBase}'s shared-errors block since
    /// `redeemForStable()` applies the same owner-accountability guard to both vault types; the
    /// selector is unchanged, resolved here by inheritance.
    /// @dev Narrowed to zero-arg since `_verifyDistribution`'s tolerance check doesn't carry
    /// per-token detail into the revert.
    error DistributionMismatch();
    /// @dev Custom error in place of a `require(..., "string")` — same revert conditions, same
    /// call sites, smaller bytecode.
    error FeesExceed100Percent();
    error InvalidPriceAfterRebalance();
    error PriceDeviationTooHigh();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures owner holds >= `MIN_OWNER_BPS` (currently 1%) of total supply; reverts
    /// owner-only calls otherwise
    /// @dev Also blocks a blacklisted owner from using an owner-only call. Accountability is a
    /// separate, third check layered on top of the shared base owner/blacklist check, since some
    /// callers (e.g. `unpause()`) must NOT additionally require accountability.
    modifier onlyAccountableOwner() {
        _checkOwnerNotBlacklisted();
        if (!isBucketAccountable()) revert OwnerNotAccountable();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param registry_ The platform-owned {ImplementationRegistry} this vault checks upgrade
    /// implementations against. Set once at construction and never repointable.
    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        REGISTRY = IImplementationRegistry(registry_);
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the PassiveBucket contract
     * @param bucketInfoAddr The BucketInfo contract address
     * @param distributions The initial bucket distributions (token + weight arrays)
     */
    function initialize(
        address bucketInfoAddr,
        BucketDistribution[] calldata distributions,
        string memory name,
        string memory symbol
    ) external initializer {
        // Only a platform-authorized factory may initialize a proxy against this
        // implementation, preventing a direct `ERC1967Proxy` deploy from bypassing the factory.
        // Routed through {FactoryAuthLib} for bytecode-size relief; revert data is unchanged.
        FactoryAuthLib.requireAuthorizedFactory(REGISTRY, msg.sender);
        _requireNonZero(bucketInfoAddr);

        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __Pausable_init();
        __Ownable_init(msg.sender);
        // __ReentrancyGuard_init();
        // __UUPSUpgradeable_init();

        bucketInfo = IBucketInfo(bucketInfoAddr);

        rebalanceOwnerFeeBps = 800; // 8% default
        rebalanceCallerFeeBps = 500; // 5% default

        _validateAndStoreDistributions(distributions);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @dev `deposit()` itself is shared verbatim from {BucketVaultBase}; this just writes the
    /// result into this contract's own `totalDepositValue` / `tokenPrice` storage.
    function _recordDeposit(uint256 depositValue, uint256 newSharePrice) internal override {
        totalDepositValue += depositValue;
        tokenPrice = newSharePrice;
    }

    /**
     * @notice Redeem shares for proportional underlying tokens from the distribution
     * @dev Owner can only redeem if isBucketAccountable is true before and after, keeping the
     * owner above the minimum ownership floor. Returns tokens the vault actually holds (the
     * held-tokens registry), not the configured target distribution.
     * @param shares The number of share tokens to redeem
     */
    function redeem(uint256 shares) external nonReentrant whenNotPaused whenPlatformOperational {
        if (shares == 0 || shares > balanceOf(msg.sender)) {
            revert InvalidRedeemAmount();
        }

        // Owner accountability check (before).
        bool isOwnerCaller = (msg.sender == owner());
        _checkOwnerAccountable(isOwnerCaller);

        // Delegates to the same held-tokens enumeration and per-token payout arithmetic that
        // backs `previewRedeem`, so the preview and the real redemption always agree.
        (address[] memory tokens, uint256[] memory returnAmounts) = _previewRedeemCore(shares);

        // Burn shares (effect)
        _burn(msg.sender, shares);

        // Transfer tokens (interactions) — delegates to {PayoutLib} via
        // {BucketVaultBase._payoutAndSync}: transfers each nonzero payout, re-syncs the
        // held-tokens registry, and emits `TokenReturned` per token.
        _payoutAndSync(msg.sender, tokens, returnAmounts);

        // Owner accountability check (after).
        _checkOwnerAccountable(isOwnerCaller);

        emit Redeemed(msg.sender, shares, totalSupply(), tokens, returnAmounts);

        // Runs once per state-changing function, after the per-token payout loop completes --
        // never inside it, or this becomes O(n^2).
        _syncOutpricedStatus();
    }

    /**
     * @notice Preview the tokens/amounts a `redeem(shares)` call would produce for
     * `msg.sender` against the CURRENT on-chain state, without mutating anything.
     * @dev Mirrors `redeem()`'s owner-accountability guard EXACTLY (before AND after — unlike
     * ActiveBucket.previewRedeem, which has no such wrapper because ActiveBucket.redeem has no
     * such check): reverts `OwnerNotAccountable` under the same conditions the real `redeem()`
     * would, computed from the CURRENT `balanceOf(owner())`/`totalSupply()` rather than an
     * oracle call (this guard is pure share arithmetic, same as `isBucketAccountable()` itself).
     * @param shares The number of share tokens to preview redeeming
     */
    function previewRedeem(uint256 shares) external view returns (address[] memory tokens, uint256[] memory amounts) {
        bool isOwnerCaller = (msg.sender == owner());
        _checkOwnerAccountable(isOwnerCaller);

        (tokens, amounts) = _previewRedeemCore(shares);

        if (isOwnerCaller) {
            uint256 supplyAfter = totalSupply() - shares;
            bool accountableAfter = supplyAfter == 0
                ? true
                : ((balanceOf(owner()) - shares) * BPS_DENOMINATOR) / supplyAfter >= MIN_OWNER_BPS;
            if (!accountableAfter) revert OwnerNotAccountable();
        }
    }

    /*//////////////////////////////////////////////////////////////
                      BUCKET DISTRIBUTION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the bucket distributions (owner only, must be accountable)
     * @param distributions The new bucket distributions
     */
    function updateBucketDistributions(BucketDistribution[] calldata distributions)
        external
        onlyAccountableOwner
        whenPlatformOperational
    {
        _validateAndStoreDistributions(distributions);
    }

    /**
     * @notice Returns the current bucket distributions
     * @return Array of BucketDistribution structs
     */
    function getBucketDistributions() external view returns (BucketDistribution[] memory) {
        return _bucketDistributions;
    }

    /*//////////////////////////////////////////////////////////////
                          REBALANCING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rebalance the portfolio via best DEX offers
     * @dev Callable by any shareholder with no input. Automatically computes required swaps
     *      to realign holdings to target distribution, querying all configured DEXs for the
     *      best price per swap. If the distribution is already within tolerance, no swaps are
     *      executed. After the swap block, fees are always settled based on the change in
     *      total portfolio value: platform fee to BucketInfo, ownerFeeBps to owner,
     *      callerFeeBps to caller (minted as shares), and a penalty burned from owner on
     *      value decrease.
     */
    function rebalanceByDefi() external nonReentrant whenNotPaused whenSwapNotPaused whenPlatformOperational {
        _requireRebalanceCaller();
        uint256 totalValueBefore = _calculateTotalValue();
        uint256 beforeTokenPrice = tokenPrice;

        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        // Only execute swaps when distribution has drifted outside tolerance
        if (!_isDistributionValid()) {
            uint256 len = tokens.length;
            // Classify tokens as overweight/underweight against target and size the trades
            // needed to close the gap; see {DistributionLib.classifyAndSizeRebalanceTrades}.
            uint256[] memory currentValuesUsd = new uint256[](len);
            for (uint256 i = 0; i < len; i++) {
                currentValuesUsd[i] = _getTokenValue(tokens[i]);
            }
            // Packed into a struct to keep the library call's parameter count low enough to
            // avoid a stack-too-deep compiler error.
            DistributionLib.RebalanceContext memory ctx = DistributionLib.RebalanceContext({
                distributions: _bucketDistributions,
                totalValueBefore: totalValueBefore,
                weightSum: WEIGHT_SUM,
                bucketInfo: bucketInfo
            });
            (
                address[] memory sellTokens,
                uint256[] memory sellAmounts,
                address[] memory buyTokens,
                uint256[] memory buyDeficits,
                uint256[3] memory countAndDeficit
            ) = DistributionLib.classifyAndSizeRebalanceTrades(tokens, currentValuesUsd, ctx);
            // countAndDeficit packs [sellCount, buyCount, totalDeficit].

            // For each overweight token, sell its excess proportionally to every underweight token
            if (countAndDeficit[2] > 0) {
                // To reduce the number of swaps, sell all the overweight tokens to WETH and buy
                // the underweight tokens back from WETH, rather than swapping every
                // overweight/underweight pair directly.
                DexSwapLib.executeRebalanceTrades(
                    dexConfigs,
                    dexCount,
                    weth,
                    sellTokens,
                    sellAmounts,
                    buyTokens,
                    buyDeficits,
                    countAndDeficit[0],
                    countAndDeficit[1],
                    countAndDeficit[2]
                );
            }
        }

        // Calculate new total value and settle fees / update token price
        uint256 totalValueAfter = _calculateTotalValue();
        _checkValueLossAndConsumeBudget(totalValueBefore, totalValueAfter);
        _settleRebalance(totalValueBefore, totalValueAfter, beforeTokenPrice);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents deposits and redemptions)
    function pause() external onlyAccountableOwner {
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Plain `onlyOwner`, NOT `onlyAccountableOwner`. An accountability check must never
    /// gate the un-blocking direction: if the owner is diluted below `MIN_OWNER_BPS` while
    /// paused, `onlyAccountableOwner` here would make `unpause()` permanently unreachable, since
    /// deposit/redeem stay `whenNotPaused` with no other admin override. `pause()` keeps the
    /// accountability gate; `unpause()` does not.
    function unpause() external onlyOwnerNotBlacklisted {
        _unpause();
    }

    /// @notice Pause swap/rebalance functions
    function pauseSwap() external onlyAccountableOwner {
        _setSwapPaused(true);
    }

    /// @notice Unpause swap/rebalance functions
    function unpauseSwap() external onlyAccountableOwner {
        _setSwapPaused(false);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure a DEX for rebalancing
     * @param dexId The DEX identifier
     * @param router Router address
     * @param quoter Quoter address
     * @param fee Fee tier (for Uniswap-style DEXs)
     * @param enabled Whether the DEX is enabled
     */
    function configureDEX(uint8 dexId, address router, address quoter, uint24 fee, bool enabled)
        external
        onlyOwnerNotBlacklisted
    {
        dexConfigs[dexId] = DexConfig({router: router, quoter: quoter, fee: fee, enabled: enabled});
        if (dexId >= dexCount) {
            dexCount = dexId + 1;
        }
        emit DexConfigured(dexId, router, quoter, enabled);
    }

    /**
     * @notice Set the WETH address for DEX swaps involving native ETH
     * @param _weth The WETH contract address
     */
    // _weth is checked via _requireNonZero on the line immediately inside the function body;
    // the lint's parameter-level pattern match doesn't trace that helper call.
    // forge-lint: disable-next-line(missing-zero-check)
    function setWETH(address _weth) external onlyOwnerNotBlacklisted {
        _requireNonZero(_weth);
        weth = _weth;
        emit WETHUpdated(_weth);
    }

    /**
     * @notice Update the rebalanceByDefi fee parameters
     * @param _ownerFeeBps  Owner fee in basis points (e.g., 300 = 3%)
     * @param _callerFeeBps Caller fee in basis points (e.g., 100 = 1%)
     */
    function setRebalanceFees(uint256 _ownerFeeBps, uint256 _callerFeeBps) external onlyOwnerNotBlacklisted {
        if (_ownerFeeBps + _callerFeeBps > BPS_DENOMINATOR) revert FeesExceed100Percent();
        rebalanceOwnerFeeBps = _ownerFeeBps;
        rebalanceCallerFeeBps = _callerFeeBps;
        emit RebalanceFeesUpdated(_ownerFeeBps, _callerFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the number of distributions
     * @return The length of the distributions array
     */
    function getDistributionCount() external view returns (uint256) {
        return _bucketDistributions.length;
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL: DISTRIBUTION VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Validate and store bucket distributions
     * @param distributions The distributions to validate and store
     */
    function _validateAndStoreDistributions(BucketDistribution[] calldata distributions) internal {
        // Validates token-whitelist membership, nonzero weights, no duplicates, and that
        // weights sum to WEIGHT_SUM.
        DistributionLib.validateDistributions(distributions, bucketInfo, WEIGHT_SUM);

        // Clear existing and store new
        delete _bucketDistributions;
        for (uint256 i = 0; i < distributions.length; i++) {
            _bucketDistributions.push(distributions[i]);
        }

        emit BucketDistributionsUpdated(distributions);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: DEX SWAP EXECUTION
    //////////////////////////////////////////////////////////////*/
    // Best-DEX swap execution lives in {DexSwapLib.executeBestSwap}, called at each rebalance
    // call site below.

    /*//////////////////////////////////////////////////////////////
                INTERNAL: DISTRIBUTION VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns true if all token weights are within DISTRIBUTION_TOLERANCE of targets.
     *      Returns true when total value is zero (nothing to check).
     */
    function _isDistributionValid() internal view returns (bool) {
        uint256 totalValue = _calculateTotalValue();
        if (totalValue == 0) return true;

        for (uint256 i = 0; i < _bucketDistributions.length; i++) {
            uint256 tokenValue = _getTokenValue(_bucketDistributions[i].token);
            uint256 actualWeight = (tokenValue * WEIGHT_SUM) / totalValue;
            uint256 targetWeight = _bucketDistributions[i].weight;

            if (
                actualWeight + DISTRIBUTION_TOLERANCE < targetWeight
                    || actualWeight > targetWeight + DISTRIBUTION_TOLERANCE
            ) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Verify that the current token value distribution matches target weights
     * within the allowed tolerance. Reverts with DistributionMismatch on failure.
     */
    function _verifyDistribution() internal view {
        if (!_isDistributionValid()) revert DistributionMismatch();
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: REBALANCE FEE HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @dev Rebalance requires shares and a non-blacklisted caller.
    function _requireHasShares() private view {
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();
    }

    /// @dev Shared zero-address guard, used by `initialize()` and `setWETH()`.
    function _requireNonZero(address a) private pure {
        if (a == address(0)) revert ZeroAddress();
    }

    /// @dev Reverts `OwnerNotAccountable` if `isOwnerCaller` and the owner is currently below
    /// `MIN_OWNER_BPS`. Shared by `redeem()`'s before/after checks and `previewRedeem()`'s
    /// before check -- all three were the same inline conditional, checked separately.
    function _checkOwnerAccountable(bool isOwnerCaller) private view {
        if (isOwnerCaller && !isBucketAccountable()) revert OwnerNotAccountable();
    }

    /// @dev Shared setter for `pauseSwap()`/`unpauseSwap()`: reverts if already in the
    /// requested state, otherwise flips `swapPaused` and emits `SwapPauseChanged`.
    function _setSwapPaused(bool paused) private {
        if (swapPaused == paused) {
            if (paused) revert SwapIsPaused();
            revert SwapNotPaused();
        }
        swapPaused = paused;
        emit SwapPauseChanged(paused);
    }

    /// @dev Shared entry guard for rebalance: caller must hold shares
    /// and must not be blacklisted. Collapsed into one function (size relief, same conditions
    /// each call site checked separately before) since none of the three mint/burn on this
    /// path, so the transfer-time blacklist hook never fires and each must check explicitly.
    function _requireRebalanceCaller() private view {
        _requireHasShares();
        _assertNotBlacklisted(msg.sender);
    }

    /**
     * @dev Shared post-swap settlement step for both rebalance entry points: verifies the
     * distribution is back within tolerance, re-syncs the held-tokens registry, settles fees
     * and emits `Rebalanced`.
     * @param totalValueBefore Total USD-8-decimal value before the swap block.
     * @param totalValueAfter Total USD-8-decimal value after the swap block.
     * @param beforeTokenPrice `tokenPrice` as it stood before this rebalance call.
     */
    function _settleRebalance(uint256 totalValueBefore, uint256 totalValueAfter, uint256 beforeTokenPrice) internal {
        // Revert if distribution is still out of tolerance after swaps.
        _verifyDistribution();
        // Held-tokens registry: swaps in the block above may have zeroed out sell-side tokens
        // or newly acquired buy-side tokens. Re-derive from on-contract balances across the
        // full whitelist so the registry stays accurate.
        _syncAllHeldTokensFromWhitelist();

        _syncOutpricedStatus();

        uint256 tokenTotalSupply = totalSupply();
        uint256 totalValueBasedOnLastTokenPrice = (beforeTokenPrice * tokenTotalSupply) / PRECISION;
        tokenPrice = _handleRebalanceFees(
            totalValueBasedOnLastTokenPrice, totalValueAfter, rebalanceOwnerFeeBps, rebalanceCallerFeeBps
        );

        emit Rebalanced(msg.sender, totalValueBefore, totalValueBasedOnLastTokenPrice, totalValueAfter, tokenPrice);
    }

    /// @dev Mints fee shares to `recipient` and emits `RebalanceFeeDistributed`; no-op if
    /// `shares` is zero.
    function _mintFee(address recipient, uint256 shares, uint256 value) private {
        if (shares > 0) {
            _mint(recipient, shares);
            emit RebalanceFeeDistributed(recipient, shares, value);
        }
    }

    /**
     * @dev Handle fee distribution and token price updates after rebalance
     * @param totalValueBefore Total value before rebalance (USD 8 dec)
     * @param totalValueAfter Total value after rebalance (USD 8 dec)
     * @param ownerFeeBps Owner fee in basis points (e.g., 300 = 3%)
     * @param callerFeeBps Caller fee in basis points (e.g., 100 = 1%)
     */
    function _handleRebalanceFees(
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 ownerFeeBps,
        uint256 callerFeeBps
    ) internal returns (uint256) {
        uint256 valueDifference = _absDiff(totalValueAfter, totalValueBefore);

        RebalanceFeeLib.FeeResult memory r = RebalanceFeeLib.computeRebalanceFees(
            totalValueBefore,
            totalValueAfter,
            ownerFeeBps,
            callerFeeBps,
            isBucketAccountable(),
            balanceOf(owner()),
            totalSupply(),
            bucketInfo.calculateFee(valueDifference)
        );

        // Mint fee shares to owner, caller and platform.
        _mintFee(owner(), r.ownerShares, r.ownerFeeValue);
        _mintFee(msg.sender, r.callerShares, r.callerFeeValue);
        if (r.sharesToBurn > 0) {
            _burn(owner(), r.sharesToBurn);
            emit OwnerPenaltyBurned(owner(), r.sharesToBurn, r.penaltyValue);
        }
        _mintFee(address(bucketInfo), r.platformShares, r.platformFeeValue);

        // Update token price to reflect new state. Delegates the recompute+bound-check to
        // {RebalanceFeeLib.validatePriceAfterRebalance} (DELEGATECALL, not inlined) — same
        // pattern as {RebalanceFeeLib.computeRebalanceFees} just above.
        return RebalanceFeeLib.validatePriceAfterRebalance(_calculateTotalValue(), totalSupply(), r.newPrice);
    }

    /// @dev Shared absolute-difference helper, used by both value-change and price-change
    /// checks in `_handleRebalanceFees` above.
    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /*//////////////////////////////////////////////////////////////
                    BucketVaultBase ABSTRACT HOOKS
    //////////////////////////////////////////////////////////////*/

    function _bucketInfo() internal view override returns (IBucketInfo) {
        return bucketInfo;
    }

    function _setBucketInfo(address newBucketInfo) internal override {
        bucketInfo = IBucketInfo(newBucketInfo);
    }

    function _swapPaused() internal view override returns (bool) {
        return swapPaused;
    }

    function _registry() internal view override returns (IImplementationRegistry) {
        return REGISTRY;
    }

    function _registryKind() internal pure override returns (IImplementationRegistry.Kind) {
        return IImplementationRegistry.Kind.PassiveBucket;
    }

    /*//////////////////////////////////////////////////////////////
                          UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @dev Owner-triggered upgrade authorization. {BucketVaultBase._authorizeUpgradeCommon}
    /// enforces the remaining conditions: the implementation must be registry-approved, the
    /// 48-hour timelock must have elapsed, and approval is re-checked at execution time.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        _authorizeUpgradeCommon(newImplementation);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
