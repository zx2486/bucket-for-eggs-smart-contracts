// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {BucketVaultBase} from "./base/BucketVaultBase.sol";
import {DexConfig, DexSwapLib} from "./libraries/DexSwapLib.sol";

/**
 * @title PassiveBucket
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-20 vault that manages a basket of tokens according to predefined
 * weight distributions. Users deposit tokens to receive shares and redeem shares to receive
 * proportional underlying tokens. Rebalancing aligns actual holdings with target distribution.
 * @dev Uses UUPS proxy pattern. Integrates with BucketInfo for token validation and pricing,
 * and with DEX routers (Uniswap V3 style + 1inch) for rebalancing.
 * W1 (sc-refactor-base): inherits shared deposit-accounting/value/oracle-consumption logic from
 * {BucketVaultBase}. All state variables below stay declared here, at their pre-refactor linear
 * slots — none were moved into the base contract. See W1-SCR-REFACTOR-REPORT.md.
 * W3 (size-reduction): the `ISwapRouter`/`IQuoter`/`IWETH` interfaces and the `DexConfig` struct
 * that used to be declared directly in this file now live in `libraries/DexSwapLib.sol`, along
 * with the Uniswap-best-quote-and-swap logic itself (formerly `_executeBestSwap`, now
 * `DexSwapLib.executeBestSwap`) and the sell-to-WETH/buy-from-WETH trade-execution block from
 * `rebalanceByDefi` (now `DexSwapLib.executeRebalanceTrades`) — both called via a library
 * DELEGATECALL, moved out purely to bring this contract's own runtime bytecode back under the
 * EIP-170 24,576-byte limit. See `DexSwapLib.sol`'s doc comment for the full rationale and why
 * this is a pure bytecode-location change, not a behavior change.
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

    /// @notice 1inch aggregation router address
    address public oneInchRouter;

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
    /// @dev W2 (sc-vault-exit): no longer incremented by `redeem()` — same rationale as
    /// ActiveBucket.sol's identical state variable. See BucketVaultBase.sol's `Redeemed` event
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
    error OwnerNotAccountable();
    /// @dev W3 size-reduction: was `DistributionMismatch(address,uint256,uint256)`; narrowed to
    /// zero-arg once `_verifyDistribution` stopped running its own copy of the tolerance-check
    /// loop (see the doc comment on that function) — nothing in `test/` or `script/` asserts on
    /// the removed fields (verified: zero hits for `DistributionMismatch` outside this file).
    error DistributionMismatch();
    /// @dev W3 size-reduction: replaces three `require(..., "string")` reverts (`setRebalanceFees`,
    /// `_handleRebalanceFees`) with custom errors — a require's string literal is encoded into
    /// PassiveBucket's own runtime bytecode at every call site, whereas a custom error's selector
    /// is 4 bytes. Same revert conditions, same call sites, no behavior change.
    error FeesExceed100Percent();
    error InvalidPriceAfterRebalance();
    error PriceDeviationTooHigh();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures owner holds >= 5% of total supply; reverts owner-only calls otherwise
    modifier onlyAccountableOwner() {
        _checkOwner();
        if (!isBucketAccountable()) revert OwnerNotAccountable();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the PassiveBucket contract
     * @param bucketInfoAddr The BucketInfo contract address
     * @param distributions The initial bucket distributions (token + weight arrays)
     * @param oneInchRouterAddr The 1inch aggregation router address
     */
    function initialize(
        address bucketInfoAddr,
        BucketDistribution[] calldata distributions,
        address oneInchRouterAddr,
        string memory name,
        string memory symbol
    ) external initializer {
        if (bucketInfoAddr == address(0)) revert ZeroAddress();
        if (oneInchRouterAddr == address(0)) revert ZeroAddress();

        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __Pausable_init();
        __Ownable_init(msg.sender);
        // __ReentrancyGuard_init();
        // __UUPSUpgradeable_init();

        bucketInfo = IBucketInfo(bucketInfoAddr);
        oneInchRouter = oneInchRouterAddr;

        rebalanceOwnerFeeBps = 600; // 6% default
        rebalanceCallerFeeBps = 300; // 3% default

        _validateAndStoreDistributions(distributions);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit a whitelisted token and receive share tokens
     * @dev For ETH deposits, send value with msg.value and set token to address(0).
     *      For ERC-20, approve this contract first.
     *      W2 (sc-vault-entry): mints against the vault's LIVE NAV
     *      (`_calculateTotalValue()`/`totalSupply()`), not the stale `tokenPrice` state
     *      variable — see `BucketVaultBase._processDeposit`'s doc comment. `tokenPrice` is now
     *      kept continuously live-synced on every deposit (not just on rebalance) as a side
     *      effect.
     * @param token The token address (address(0) for ETH)
     * @param amount The amount to deposit (ignored for ETH; msg.value is used)
     */
    function deposit(address token, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        (uint256 actualAmount, uint256 sharesToMint, uint256 depositValue, uint256 newSharePrice) =
            _processDeposit(token, amount);

        totalDepositValue += depositValue;
        tokenPrice = newSharePrice;

        emit Deposited(msg.sender, token, actualAmount, sharesToMint, depositValue);
    }

    /**
     * @notice Redeem shares for proportional underlying tokens from the distribution
     * @dev Owner can only redeem if isBucketAccountable is true before and after (unchanged by
     * W2 — this is a SEPARATE, pre-existing 5% guard local to PassiveBucket, not the new,
     * deliberately unwired 20% N5/A3 floor built in BucketVaultBase this wave; see
     * BucketVaultBase.isOwnerWithdrawalFloorMet's doc comment).
     *      W2 (sc-vault-exit): returns tokens the vault actually holds (the held-tokens
     *      registry), not `_bucketDistributions` — see the in-function comment below.
     * @param shares The number of share tokens to redeem
     */
    function redeem(uint256 shares) external nonReentrant whenNotPaused whenPlatformOperational {
        if (shares == 0 || shares > balanceOf(msg.sender)) {
            revert InvalidRedeemAmount();
        }

        // Owner accountability check (before) — unchanged by W2.
        bool isOwnerCaller = (msg.sender == owner());
        if (isOwnerCaller) {
            if (!isBucketAccountable()) revert OwnerNotAccountable();
        }

        uint256 supply = totalSupply();
        // Explicit panic-to-revert conversion (W2): division-by-zero below would panic (0x12)
        // if `supply` were 0. Unreachable today — `shares > 0` and
        // `shares <= balanceOf(msg.sender) <= supply` together guarantee `supply > 0` — but
        // guarded explicitly rather than relying on that invariant implicitly.
        if (supply == 0) revert InvalidRedeemAmount();

        // INV-1: enumerate the held-tokens registry, not `_bucketDistributions` (W2,
        // sc-vault-exit). This also fixes a latent defect: a token held from a distribution
        // superseded by `updateBucketDistributions` would silently disappear from the old
        // `_bucketDistributions`-only payout loop, stranding those funds. `_bucketDistributions`
        // itself is untouched — still used by rebalanceByDefi/updateBucketDistributions exactly
        // as before; only redeem()'s enumeration source changes.
        address[] memory tokens = _heldTokensList();

        // Calculate return amounts before burning
        uint256[] memory returnAmounts = new uint256[](tokens.length);
        bool anyPayout = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _getTokenBalance(tokens[i]);
            returnAmounts[i] = (balance * shares) / supply;
            if (returnAmounts[i] > 0) anyPayout = true;
        }
        // W2 (sc-vault-exit): revert on an all-zero payout instead of silently burning shares
        // for nothing.
        if (!anyPayout) revert NothingToRedeem();

        // Burn shares (effect)
        _burn(msg.sender, shares);

        // Transfer tokens (interactions)
        for (uint256 i = 0; i < tokens.length; i++) {
            if (returnAmounts[i] > 0) {
                _transferToken(tokens[i], msg.sender, returnAmounts[i]);
                // Keep the held-tokens registry accurate if this payout fully drains a token.
                _syncHeldTokenByBalance(tokens[i]);
                emit TokenReturned(msg.sender, tokens[i], returnAmounts[i]);
            }
        }

        // Owner accountability check (after) — unchanged by W2.
        if (isOwnerCaller) {
            if (!isBucketAccountable()) revert OwnerNotAccountable();
        }

        // W2 (sc-vault-exit): `Redeemed` redesigned — see BucketVaultBase.sol doc comment.
        emit Redeemed(msg.sender, shares, totalSupply(), tokens, returnAmounts);
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
        if (isOwnerCaller && !isBucketAccountable()) revert OwnerNotAccountable();

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
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();
        // W2 (sc-swap): rebalanceByDefi does not route through `_execute1inchSwap`, so it must
        // enforce the shared per-caller/global swap cooldown itself.
        _enforceSwapCooldown(msg.sender);

        uint256 totalValueBefore = _calculateTotalValue();
        uint256 beforeTokenPrice = tokenPrice;

        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        // Only execute swaps when distribution has drifted outside tolerance
        if (!_isDistributionValid()) {
            // uint256 len = _bucketDistributions.length;
            // address[] memory tokens = bucketInfo.getWhitelistedTokens();
            uint256 len = tokens.length;
            // Classify each distribution token as a seller (overweight) or buyer (underweight)
            address[] memory sellTokens = new address[](len);
            uint256[] memory sellAmounts = new uint256[](len); // in token-native units
            address[] memory buyTokens = new address[](len);
            uint256[] memory buyDeficits = new uint256[](len); // in USD (8 decimals)
            uint256[] memory countAndDeficit = new uint256[](3); // array of keeping sellCount, buyCount and totalDeficit
            // uint256 sellCount = 0;
            // uint256 buyCount = 0;
            // uint256 totalDeficit = 0;

            for (uint256 i = 0; i < len; i++) {
                address token = tokens[i];
                uint256 currentValueUSD = _getTokenValue(token);
                // Find target distribution weight based on token address (0 for ETH) and calculate target USD value
                uint256 targetWeight = 0;
                for (uint256 j = 0; j < _bucketDistributions.length; j++) {
                    if (_bucketDistributions[j].token == token) {
                        targetWeight = _bucketDistributions[j].weight;
                        break;
                    }
                }
                uint256 targetValueUSD = (totalValueBefore * targetWeight) / WEIGHT_SUM;

                if (currentValueUSD > targetValueUSD) {
                    // Overweight: convert excess USD value into token units to sell.
                    // W2 (sc-swap): migrated from the reverting `getTokenPrice` to the
                    // never-reverts `tryGetTokenPrice` so a single token's temporarily-bad price
                    // gracefully skips that token's sell leg instead of reverting the entire
                    // rebalanceByDefi call. NOTE (flagged in W2-SC-SWAP-REPORT.md "Corrections
                    // to my briefing"): `currentValueUSD` immediately above was computed by
                    // `_getTokenValue(token)` at :419, which itself calls the REVERTING
                    // `bucketInfo.getTokenPrice` — so a bad price on this same token already
                    // reverted this call before this line is ever reached. This migration is
                    // still correct and forward-compatible, but its practical benefit is capped
                    // until/unless a future wave also migrates `_getTokenValue`/
                    // `_calculateTotalValue` (BucketVaultBase.sol, out of this wave's
                    // file-ownership scope).
                    uint256 excessUSD = currentValueUSD - targetValueUSD;
                    (bool priceOk, uint256 price) = bucketInfo.tryGetTokenPrice(token);
                    if (!priceOk) continue;
                    uint8 dec = _getTokenDecimals(token);
                    uint256 excessTokens = (excessUSD * (10 ** dec)) / price;
                    if (excessTokens > 0) {
                        sellTokens[countAndDeficit[0]] = token;
                        sellAmounts[countAndDeficit[0]] = excessTokens;
                        countAndDeficit[0]++;
                    }
                } else if (targetValueUSD > currentValueUSD) {
                    // Underweight: record USD deficit for proportional buy allocation
                    uint256 deficitUSD = targetValueUSD - currentValueUSD;
                    buyTokens[countAndDeficit[1]] = token;
                    buyDeficits[countAndDeficit[1]] = deficitUSD;
                    countAndDeficit[2] += deficitUSD;
                    countAndDeficit[1]++;
                }
            }

            // For each overweight token, sell its excess proportionally to every underweight token
            if (countAndDeficit[2] > 0) {
                /*
                for (uint256 i = 0; i < countAndDeficit[0]; i++) {
                    for (uint256 j = 0; j < countAndDeficit[1]; j++) {
                        uint256 amountToSell = (sellAmounts[i] * buyDeficits[j]) / countAndDeficit[2];
                        if (amountToSell > 0) {
                            _executeBestSwap(sellTokens[i], buyTokens[j], amountToSell, 0);
                        }
                    }
                }
                */
                // To reduce the number of swapping, we sell all the tokens to WETH and buy them
                // back. W3 (size-reduction): this whole sell-then-buy block moved into
                // {DexSwapLib.executeRebalanceTrades} — identical logic, just parameterized over
                // the counts/arrays computed above instead of running inline. Safe to move
                // (unlike the classification loop above it) because this block makes no call to
                // any BucketVaultBase-inherited internal function — every call it makes is either
                // to `IWETH`/the DEX routers (external contracts) or to `_executeBestSwap`
                // itself, already moved into the same library. See DexSwapLib.sol's doc comment.
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
        // Check value loss < 0.5% per call (existing), AND consume the new cumulative per-epoch
        // budget (W2 sc-swap) — independent guards, same rationale as `_execute1inchSwap`'s
        // 1inch path: a loop of calls each individually under the per-call cap must still be
        // bounded overall.
        if (totalValueAfter < totalValueBefore) {
            uint256 loss = totalValueBefore - totalValueAfter;
            uint256 maxLoss = (totalValueBefore * MAX_VALUE_LOSS_BPS) / BPS_DENOMINATOR;
            if (loss > maxLoss) {
                revert ValueLossTooHigh(totalValueBefore, totalValueAfter);
            }
            _consumeEpochValueLossBudget(totalValueBefore, loss);
        }
        // Revert if distribution is still out of tolerance after swaps
        _verifyDistribution();
        // Held-tokens registry: swaps in the block above may have zeroed out sell-side tokens
        // or newly acquired buy-side tokens. Re-derive from on-contract balances across the
        // full whitelist so the registry stays accurate. Deferred from redeem's payout loop
        // per W1-SCR-REFACTOR-REPORT.md — this only maintains the registry, does not consume it.
        _syncAllHeldTokensFromWhitelist();
        // Send performance fee to BucketInfo, owner and msg.sender based on value change, and burn owner penalty if value decreased
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            (beforeTokenPrice * tokenTotalSupply) / PRECISION,
            totalValueAfter,
            rebalanceOwnerFeeBps,
            rebalanceCallerFeeBps
        );

        emit Rebalanced(
            msg.sender, totalValueBefore, (beforeTokenPrice * tokenTotalSupply) / PRECISION, totalValueAfter, tokenPrice
        );
    }

    /**
     * @notice Rebalance the portfolio via 1inch aggregation router
     * @dev Callable by any shareholder. W2 (sc-swap) rewrite: replaced the caller-supplied
     * `bytes calldata swapCalldata` with four typed parameters — see
     * BucketVaultBase._execute1inchSwap's doc comment for the full rationale (this entry point is
     * permissionless/share-gated, which is exactly why the pre-fix arbitrary-calldata shape was
     * exploitable — see test/OneInchSwapSecurity.t.sol's `PreFixRebalanceBy1inchDrainTest`).
     * Value loss must be < 0.5% per call (existing) AND within the cumulative per-epoch budget
     * (new, W2). Fees: 6% of increase to owner, 3% to caller.
     * @param srcToken Token being sold (address(0) = native ETH). Must be whitelisted.
     * @param dstToken Token being bought (address(0) = native ETH). Must be whitelisted.
     * @param amount Amount of `srcToken` to swap, bounded by this vault's held balance.
     * @param minReturn Minimum acceptable `dstToken` out; must clear an oracle-derived floor.
     */
    function rebalanceBy1inch(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        external
        nonReentrant
        whenNotPaused
        whenSwapNotPaused
        whenPlatformOperational
    {
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();

        uint256 beforeTokenPrice = tokenPrice;

        // Execute swap via 1inch and enforce the shared <0.5% per-call bound plus the new
        // cumulative per-epoch budget (BucketVaultBase._execute1inchSwap).
        (uint256 totalValueBefore, uint256 totalValueAfter) = _execute1inchSwap(srcToken, dstToken, amount, minReturn);

        // Verify distribution matches target
        _verifyDistribution();
        // See the identical comment in rebalanceByDefi above: keep the held-tokens registry
        // accurate after a swap whose token movements are arbitrary caller-supplied calldata.
        _syncAllHeldTokensFromWhitelist();
        // Send performance fee to BucketInfo, owner and msg.sender based on value change, and burn owner penalty if value decreased
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            (beforeTokenPrice * tokenTotalSupply) / PRECISION,
            totalValueAfter,
            rebalanceOwnerFeeBps,
            rebalanceCallerFeeBps
        );

        emit Rebalanced(
            msg.sender, totalValueBefore, (beforeTokenPrice * tokenTotalSupply) / PRECISION, totalValueAfter, tokenPrice
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents deposits and redemptions)
    function pause() external onlyAccountableOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyAccountableOwner {
        _unpause();
    }

    /// @notice Pause swap/rebalance functions
    function pauseSwap() external onlyAccountableOwner {
        if (swapPaused) revert SwapIsPaused();
        swapPaused = true;
        emit SwapPauseChanged(true);
    }

    /// @notice Unpause swap/rebalance functions
    function unpauseSwap() external onlyAccountableOwner {
        if (!swapPaused) revert SwapNotPaused();
        swapPaused = false;
        emit SwapPauseChanged(false);
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
    function configureDEX(uint8 dexId, address router, address quoter, uint24 fee, bool enabled) external onlyOwner {
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
    function setWETH(address _weth) external onlyOwner {
        if (_weth == address(0)) revert ZeroAddress();
        weth = _weth;
        emit WETHUpdated(_weth);
    }

    /**
     * @notice Update the rebalanceByDefi fee parameters
     * @param _ownerFeeBps  Owner fee in basis points (e.g., 300 = 3%)
     * @param _callerFeeBps Caller fee in basis points (e.g., 100 = 1%)
     */
    function setRebalanceFees(uint256 _ownerFeeBps, uint256 _callerFeeBps) external onlyOwner {
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
        if (distributions.length == 0) revert EmptyDistributions();

        uint256 totalWeight = 0;

        // Check for duplicates and validate tokens
        for (uint256 i = 0; i < distributions.length; i++) {
            if (!bucketInfo.isTokenValid(distributions[i].token)) {
                revert InvalidToken(distributions[i].token);
            }
            if (distributions[i].weight == 0) revert InvalidDistributions();

            // Check for duplicates
            for (uint256 j = 0; j < i; j++) {
                if (distributions[j].token == distributions[i].token) {
                    revert DuplicateToken(distributions[i].token);
                }
            }

            totalWeight += distributions[i].weight;
        }

        if (totalWeight != WEIGHT_SUM) revert WeightSumMismatch(totalWeight);

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

    /**
     * @dev Execute a swap using the best available DEX (queries all configured DEXs).
     * W3 (size-reduction): the body that used to live here directly now lives in
     * {DexSwapLib.executeBestSwap}, called via `DexSwapLib.executeBestSwap(...)` at each of this
     * function's former call sites — moved out entirely to shrink PassiveBucket's own runtime
     * bytecode under the EIP-170 limit. See DexSwapLib.sol's doc comment for why this is a pure
     * bytecode-location change (DELEGATECALL preserves `address(this)`/`msg.sender`), not a
     * behavior change. This function itself is now deleted; nothing calls `_executeBestSwap`
     * anymore.
     */

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
     * @dev W3 size-reduction: this used to run its own copy of the exact tolerance-check loop
     * that {_isDistributionValid} already runs, just reverting with per-token detail instead of
     * returning a bool — two near-identical loops (each calling `_getTokenValue` and doing the
     * same arithmetic) inlined into PassiveBucket's own bytecode. No test or script anywhere in
     * this repo asserts on `DistributionMismatch`'s fields (verified: `grep -rn
     * "DistributionMismatch" test/ script/` returns zero hits outside this file's own
     * declaration/revert site), so collapsing the two loops into one — this function now just
     * calls {_isDistributionValid} and reverts on `false` — changes only the revert's argument
     * detail (dropped, error is now zero-arg), never whether/when it reverts. `_verifyDistribution`
     * and `_isDistributionValid` agree on failure by construction, since the latter is now the
     * only place the tolerance check is evaluated.
     */
    function _verifyDistribution() internal view {
        if (!_isDistributionValid()) revert DistributionMismatch();
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: REBALANCE FEE HANDLING
    //////////////////////////////////////////////////////////////*/

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
        bool accountable = isBucketAccountable();
        // Calculate new token price (pre-fee-minting)
        uint256 newPrice = (totalSupply() > 0) ? (totalValueAfter * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
        uint256 valueDifference = totalValueAfter > totalValueBefore
            ? totalValueAfter - totalValueBefore
            : totalValueBefore - totalValueAfter;

        if (totalValueAfter > totalValueBefore) {
            uint256 increase = totalValueAfter - totalValueBefore;
            if (accountable) {
                // Owner fee
                uint256 ownerFeeValue = (increase * ownerFeeBps * PRECISION) / BPS_DENOMINATOR;
                if (ownerFeeValue > 0 && newPrice > 0) {
                    uint256 ownerShares = (ownerFeeValue) / newPrice;
                    ownerFeeValue = ownerFeeValue / PRECISION; // adjust back to USD value for event
                    if (ownerShares > 0) {
                        _mint(owner(), ownerShares);
                        emit RebalanceFeeDistributed(owner(), ownerShares, ownerFeeValue);
                    }
                }
            }
            // Caller fee
            uint256 callerFeeValue = (increase * callerFeeBps * PRECISION) / BPS_DENOMINATOR;
            if (callerFeeValue > 0 && newPrice > 0) {
                uint256 callerShares = (callerFeeValue) / newPrice;
                callerFeeValue = callerFeeValue / PRECISION; // adjust back to USD value for event
                if (callerShares > 0) {
                    _mint(msg.sender, callerShares);
                    emit RebalanceFeeDistributed(msg.sender, callerShares, callerFeeValue);
                }
            }
        } else if (totalValueAfter < totalValueBefore) {
            uint256 decrease = totalValueBefore - totalValueAfter;

            // Owner bears some of the decrease (burned from owner shares)
            if (accountable) {
                uint256 penaltyValue = (decrease * (callerFeeBps + ownerFeeBps) * PRECISION) / BPS_DENOMINATOR;
                uint256 sharesToBurn = (penaltyValue) / newPrice;
                penaltyValue = penaltyValue / PRECISION; // adjust back to USD value for event
                uint256 ownerBalance = balanceOf(owner());

                if (sharesToBurn > ownerBalance) {
                    sharesToBurn = ownerBalance;
                }
                if (sharesToBurn > 0) {
                    _burn(owner(), sharesToBurn);
                    emit OwnerPenaltyBurned(owner(), sharesToBurn, penaltyValue);
                }
            }
        }

        // Platform fee to BucketInfo
        uint256 platformFeeValue = bucketInfo.calculateFee(valueDifference);
        if (platformFeeValue > 0 && newPrice > 0) {
            uint256 platformShares = (platformFeeValue * PRECISION) / newPrice;
            if (platformShares > 0) {
                _mint(address(bucketInfo), platformShares);
                emit RebalanceFeeDistributed(address(bucketInfo), platformShares, platformFeeValue);
            }
        }

        // Update token price to reflect new state
        uint256 priceAfterRebalance =
            (totalSupply() > 0) ? (_calculateTotalValue() * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
        if (priceAfterRebalance == 0) revert InvalidPriceAfterRebalance();
        uint256 priceChange =
            priceAfterRebalance > newPrice ? priceAfterRebalance - newPrice : newPrice - priceAfterRebalance;
        if (priceChange > (newPrice * 20) / 100) revert PriceDeviationTooHigh();
        return priceAfterRebalance;
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

    function _oneInchRouter() internal view override returns (address) {
        return oneInchRouter;
    }

    function _swapPaused() internal view override returns (bool) {
        return swapPaused;
    }

    /*//////////////////////////////////////////////////////////////
                          UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorize upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
