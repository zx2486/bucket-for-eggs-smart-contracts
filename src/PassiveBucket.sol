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

    /// @notice The platform-owned {ImplementationRegistry} this vault's upgrades are checked
    /// against. W3.3 (`09-DECISION-LOG.md` §10.1): `immutable`, constructor-set, never
    /// repointable — mirrors why {bucketInfo}'s repoint path requires the CURRENT BucketInfo
    /// owner's sign-off, not this vault owner's alone; the whitelist authority itself must not
    /// be swappable by this vault's (customer) owner.
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
    /// @dev W5 (sc-stable-exit, task #64): MOVED to {BucketVaultBase}'s shared-errors block —
    /// `redeemForStable()` applies this same owner-accountability guard to BOTH vault types (see
    /// that function's doc comment for why), so the error now lives where the check lives.
    /// Deleted here, not duplicated — a second `error OwnerNotAccountable();` declaration in this
    /// contract would be a DeclarationError (same selector, now already visible via inheritance).
    /// `PassiveBucket.OwnerNotAccountable.selector` (used throughout this file and in
    /// `test/PassiveBucket.t.sol`) is unchanged by the move — Solidity resolves an inherited
    /// error through the derived contract's own name exactly like an inherited function.
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

    /// @notice Ensures owner holds >= `MIN_OWNER_BPS` (currently 1%) of total supply; reverts
    /// owner-only calls otherwise
    /// @dev Verifier fix (2026-10-04): also blocks a blacklisted owner -- an admin call by a
    /// blacklisted owner, same gap class covered by {BucketVaultBase.whenCallerNotBlacklisted}.
    /// Folded into this modifier (rather than added separately at each of its four call sites)
    /// since every caller of `onlyAccountableOwner` is already `msg.sender == owner()` by the
    /// time this runs.
    /// @dev Verifier fix (2026-10-04) follow-up: collapses the owner+blacklist half of this
    /// modifier into {BucketVaultBase._checkOwnerNotBlacklisted} (one internal-call `JUMP`
    /// instead of two) — same measured size-relief technique as `onlyOwnerNotBlacklisted`'s own
    /// correction comment explains. Accountability stays a separate, third check layered on top,
    /// since it is NOT part of the shared base modifier (that modifier is used by callers that
    /// must NOT additionally require accountability, e.g. `unpause()`).
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
    /// implementations against. W3.3: baked in as an immutable constructor parameter, never
    /// threaded through `initialize`, following the same "factory-immutable" precedent as
    /// {implementation}/{bucketInfo} on the factory itself (root CLAUDE.md §1.1, W1.7) — so the
    /// factory needs zero changes to supply it (`09-DECISION-LOG.md` §11.2 / D-3).
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
     * @param oneInchRouterAddr The 1inch aggregation router address
     */
    function initialize(
        address bucketInfoAddr,
        BucketDistribution[] calldata distributions,
        address oneInchRouterAddr,
        string memory name,
        string memory symbol
    ) external initializer {
        // Task #33 (W1.7 direct-proxy-bypass fix): only a platform-authorized factory may
        // initialize a proxy against this implementation. See the identical check in
        // ActiveBucket.sol's `initialize()` for the full rationale. Routed through
        // {FactoryAuthLib} rather than inlined (EIP-170 size relief, task #75) -- the revert
        // data is byte-identical to the inline form, see that library's doc comment.
        FactoryAuthLib.requireAuthorizedFactory(REGISTRY, msg.sender);
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
     * W2 — this is a SEPARATE, pre-existing `MIN_OWNER_BPS` guard (currently 1%) local to
     * PassiveBucket, not the new, deliberately unwired 20% N5/A3 floor built in BucketVaultBase
     * this wave; see BucketVaultBase.isOwnerWithdrawalFloorMet's doc comment).
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

        // W3 (size-reduction, task #48): tokens/returnAmounts used to be computed by an inline
        // "enumerate held tokens, compute balance*shares/supply per token, track anyPayout"
        // loop here — byte-for-byte the same loop {BucketVaultBase._previewRedeemCore} already
        // runs for `previewRedeem` (same held-tokens enumeration via `_heldTokensList()`, same
        // per-token `_getTokenBalance(tokens[i]) * shares / supply` arithmetic, same dead
        // zero-supply `InvalidRedeemAmount` guard, same all-zero-payout `NothingToRedeem`
        // guard). `_previewRedeemCore` is `internal` and already compiled into this contract's
        // own runtime bytecode (it backs the external `previewRedeem`), so calling it here
        // removes a second, near-identical copy of that loop from PassiveBucket's OWN bytecode
        // without changing any output — same reverts, same values. The `shares == 0 || shares
        // > balanceOf(msg.sender)` check above is deliberately kept here (rather than deleted
        // and left solely to `_previewRedeemCore`'s own copy of the identical check) so this
        // function's own check ORDER is unchanged versus the pre-refactor inline code:
        // shares-validity, THEN owner-accountability-before, THEN the (dead) zero-supply guard
        // and the payout computation. `_previewRedeemCore`'s copy of the shares-validity check
        // is therefore unreachable dead code on this call path, not a second live gate — this is
        // a pure bytecode relocation, not a change to which revert fires first.
        // INV-1 (W2, sc-vault-exit, unchanged by this move): `_previewRedeemCore` enumerates the
        // held-tokens registry via `_heldTokensList()`, not `_bucketDistributions` — this still
        // fixes the same latent defect the original inline comment here documented: a token held
        // from a distribution superseded by `updateBucketDistributions` would otherwise silently
        // disappear from a `_bucketDistributions`-only payout loop, stranding those funds.
        (address[] memory tokens, uint256[] memory returnAmounts) = _previewRedeemCore(shares);

        // Burn shares (effect)
        _burn(msg.sender, shares);

        // Transfer tokens (interactions) — W5 (sc-oracle, size relief): delegates to
        // {PayoutLib} via {BucketVaultBase._payoutAndSync} instead of an inline loop; see that
        // library's header comment. Pure bytecode relocation — same transfer, registry-sync and
        // `TokenReturned` emission as before, per nonzero payout amount.
        _payoutAndSync(msg.sender, tokens, returnAmounts);

        // Owner accountability check (after) — unchanged by W2.
        if (isOwnerCaller) {
            if (!isBucketAccountable()) revert OwnerNotAccountable();
        }

        // W2 (sc-vault-exit): `Redeemed` redesigned — see BucketVaultBase.sol doc comment.
        emit Redeemed(msg.sender, shares, totalSupply(), tokens, returnAmounts);

        // W5 (sc-oracle, returning): once per state-changing function, after the per-token
        // payout loop above completes -- never inside it, or this becomes O(n^2).
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
        _requireHasShares();
        // W4.2c: permissionless (share-gated via `_requireHasShares()`, not `onlyOwner`) and
        // mints/burns no shares on this path -- BucketVaultBase's `_update` hook never fires for
        // it, so the caller's blacklist status must be checked explicitly here.
        _assertNotBlacklisted(msg.sender);
        // W2 (sc-swap): rebalanceByDefi does not route through `_execute1inchSwap`, so it must
        // enforce the shared per-caller/global swap cooldown itself.
        _enforceSwapCooldown(msg.sender);

        uint256 totalValueBefore = _calculateTotalValue();
        uint256 beforeTokenPrice = tokenPrice;

        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        // Only execute swaps when distribution has drifted outside tolerance
        if (!_isDistributionValid()) {
            uint256 len = tokens.length;
            // W3 (size-reduction, task #48): the classification double-loop that used to run
            // inline here (target-weight lookup, overweight/underweight split, excess-USD to
            // token-units conversion) now lives in
            // {DistributionLib.classifyAndSizeRebalanceTrades} — see that function's doc comment
            // for exactly where the seam is (this contract still computes `_getTokenValue` per
            // token below, since that call is `address(this)`-dependent and cannot safely move
            // into an externally-linked library; everything downstream of it, including the
            // `tryGetTokenPrice`/`decimals()` calls, does not depend on `address(this)` and moved
            // out). Pure bytecode relocation, not a behavior change — same per-token order, same
            // tie-breaking (`break` on first matching distribution), same skip-on-bad-price via
            // `tryGetTokenPrice`.
            uint256[] memory currentValuesUsd = new uint256[](len);
            for (uint256 i = 0; i < len; i++) {
                currentValuesUsd[i] = _getTokenValue(tokens[i]);
            }
            // Packed into a struct (see DistributionLib.RebalanceContext) purely to keep the
            // library call's own parameter count low enough to avoid a stack-too-deep compiler
            // error there — not a behavior change.
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
            // countAndDeficit packs [sellCount, buyCount, totalDeficit] — see
            // {DistributionLib.classifyAndSizeRebalanceTrades}'s doc comment for why (stack-depth
            // limit on the library side, not a behavior change).

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
        // EIP-170 size-relief (2026-10-04): this used to be inlined here (byte-identical to the
        // check inside `BucketVaultBase._executeSwapNoCooldown`, since this path never calls that
        // function) — now routed through the shared {_checkValueLossAndConsumeBudget} helper. Same
        // two guards, same order, same reverts: the per-call `MAX_VALUE_LOSS_BPS` (0.5%) bound,
        // then the cumulative per-epoch budget consume (W2 sc-swap) — see that helper's own
        // comment for the full rationale and why this was previously duplicated.
        _checkValueLossAndConsumeBudget(totalValueBefore, totalValueAfter);
        // Revert if distribution is still out of tolerance after swaps; keep the held-tokens
        // registry accurate; settle fees and emit `Rebalanced`. W3 (size-reduction, task #48):
        // this used to be three separate calls duplicated byte-for-byte in `rebalanceBy1inch`
        // below — see {_settleRebalance}'s doc comment (now folded to include the
        // verify/sync step, not just fee settlement).
        _settleRebalance(totalValueBefore, totalValueAfter, beforeTokenPrice);
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
        _requireHasShares();
        // W4.2c: permissionless (share-gated, not `onlyOwner`) and mints/burns no shares on this
        // path -- BucketVaultBase's `_update` hook never fires for it, so the caller's blacklist
        // status must be checked explicitly here.
        _assertNotBlacklisted(msg.sender);

        uint256 beforeTokenPrice = tokenPrice;
        (uint256 totalValueBefore, uint256 totalValueAfter) = _execute1inchSwap(srcToken, dstToken, amount, minReturn);

        // Verify distribution matches target, keep the held-tokens registry accurate, settle
        // fees and emit `Rebalanced` — see the identical comment in `rebalanceByDefi` above.
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
    /// @dev W3.5 (V-15, `01-REVIEW-USER-REPLY.md` §4.5(4)): plain `onlyOwner`, NOT
    /// `onlyAccountableOwner`. An accountability check must never gate the UN-blocking
    /// direction: if the owner is diluted below `MIN_OWNER_BPS` (or transfers/sells shares)
    /// while paused, `onlyAccountableOwner` here would make `unpause()` permanently
    /// unreachable, since deposit/redeem stay `whenNotPaused` and there is no other admin
    /// override. `pause()` keeps the accountability gate (only the emergency-recovery
    /// direction needs to always be reachable); `unpause()` does not.
    function unpause() external onlyOwnerNotBlacklisted {
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
    function setWETH(address _weth) external onlyOwnerNotBlacklisted {
        if (_weth == address(0)) revert ZeroAddress();
        weth = _weth;
        emit WETHUpdated(_weth);
    }

    /**
     * @notice Update the rebalanceByDefi fee parameters
     * @param _ownerFeeBps  Owner fee in basis points (e.g., 300 = 3%)
     * @param _callerFeeBps Caller fee in basis points (e.g., 100 = 1%)
     */
    function setRebalanceFees(uint256 _ownerFeeBps, uint256 _callerFeeBps)
        external
        onlyOwnerNotBlacklisted
    {
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
        // W3 (size-reduction, task #48): the validation loop that used to run inline here
        // (token-whitelist check, zero-weight check, duplicate check, weight-sum check) now lives
        // in {DistributionLib.validateDistributions} — moved out entirely, mirroring the
        // `_executeBestSwap` -> `DexSwapLib` move (see that library's doc comment), to shrink
        // PassiveBucket's own runtime bytecode back under the EIP-170 limit. Pure bytecode
        // relocation: DistributionLib redeclares the same four errors with identical selectors
        // (see DistributionLib.sol's doc comment), so revert behavior is unchanged.
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

    /// @dev `rebalanceByDefi` and `rebalanceBy1inch` both start with this exact guard —
    /// deduplicated for the same reason as {_settleRebalance} (task #48, size-reduction): a
    /// plain in-contract dedup, no library/address(this) concerns.
    function _requireHasShares() private view {
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();
    }

    /**
     * @dev Shared post-swap settlement step for both rebalance entry points. W3 (size-reduction,
     * task #48): `rebalanceByDefi` and `rebalanceBy1inch` used to each run their OWN
     * byte-for-byte-identical three-call sequence inline (`_verifyDistribution()`,
     * `_syncAllHeldTokensFromWhitelist()`, then read `totalSupply()` + call
     * {_handleRebalanceFees} + emit `Rebalanced`) — folded into one call at each site, rather
     * than moved to a library: both call sites already live in THIS contract, so there is no
     * `address(this)`/library-boundary concern here at all (unlike the
     * `DistributionLib`/`RebalanceFeeLib` moves elsewhere in this file) — this is a plain
     * in-contract dedup, and `msg.sender` is unchanged across the internal call (used both by
     * {_handleRebalanceFees}'s caller-fee mint and by the `Rebalanced` event below). Pure
     * bytecode relocation: same order (verify, then sync, then settle-and-emit), same
     * arithmetic, same event data.
     * @param totalValueBefore Total USD-8-decimal value before the swap block.
     * @param totalValueAfter Total USD-8-decimal value after the swap block.
     * @param beforeTokenPrice `tokenPrice` as it stood before this rebalance call.
     */
    function _settleRebalance(uint256 totalValueBefore, uint256 totalValueAfter, uint256 beforeTokenPrice) internal {
        // Revert if distribution is still out of tolerance after swaps.
        _verifyDistribution();
        // Held-tokens registry: swaps in the block above may have zeroed out sell-side tokens
        // or newly acquired buy-side tokens (or, for `rebalanceBy1inch`, moved arbitrary
        // caller-supplied amounts). Re-derive from on-contract balances across the full
        // whitelist so the registry stays accurate. Deferred from redeem's payout loop per
        // W1-SCR-REFACTOR-REPORT.md — this only maintains the registry, does not consume it.
        _syncAllHeldTokensFromWhitelist();

        // W5 (sc-oracle, returning): once per state-changing function, after the resync above
        // completes. `_settleRebalance` is the single call site shared by both
        // `rebalanceByDefi` and `rebalanceBy1inch`, so this covers both swap paths.
        _syncOutpricedStatus();

        uint256 tokenTotalSupply = totalSupply();
        // Computed once and reused below — the original inline code at both call sites evaluated
        // this same expression twice (once into `_handleRebalanceFees`, once into the `Rebalanced`
        // event), always to the same value since none of its inputs change in between.
        uint256 totalValueBasedOnLastTokenPrice = (beforeTokenPrice * tokenTotalSupply) / PRECISION;
        tokenPrice = _handleRebalanceFees(
            totalValueBasedOnLastTokenPrice, totalValueAfter, rebalanceOwnerFeeBps, rebalanceCallerFeeBps
        );

        emit Rebalanced(msg.sender, totalValueBefore, totalValueBasedOnLastTokenPrice, totalValueAfter, tokenPrice);
    }

    /// @dev Shared by {_handleRebalanceFees}'s owner-fee, caller-fee and platform-fee branches —
    /// see the call site's comment for why the owner-penalty burn is deliberately NOT folded in
    /// here too. `shares == 0` is a no-op, mirroring each branch's original `if (... > 0)` guard.
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
     * @dev W3 (size-reduction, task #48): the fee/penalty ARITHMETIC that used to run inline
     * here now lives in {RebalanceFeeLib.computeRebalanceFees} — see that function's doc comment
     * for exactly where the seam is (the `_mint`/`_burn`/`emit` calls below stay here, since
     * those are inherited `internal` functions unreachable from a library). Pure bytecode
     * relocation: same snapshotting order, same mutual-exclusivity between the increase/decrease
     * branches, same rounding, same missing `newPrice > 0` guard on the owner-penalty division.
     */
    function _handleRebalanceFees(
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 ownerFeeBps,
        uint256 callerFeeBps
    ) internal returns (uint256) {
        uint256 valueDifference = totalValueAfter > totalValueBefore
            ? totalValueAfter - totalValueBefore
            : totalValueBefore - totalValueAfter;

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

        // W3 (size-reduction, task #48): these three branches used to each inline their own
        // `if (shares > 0) { _mint(recipient, shares); emit RebalanceFeeDistributed(...); }` —
        // byte-for-byte the same shape three times, differing only in which recipient/amount/value
        // triple is passed. Deduplicated into {_mintFee}, an in-contract private function (no
        // library boundary: `_mint` is inherited and only callable on `address(this)`'s own
        // storage, so this could never have been moved to an external library anyway). The
        // owner-penalty burn below is NOT folded in: it calls `_burn`, not `_mint`, and emits a
        // different event (`OwnerPenaltyBurned`), so it is not a byte-for-byte duplicate of the
        // other three and gains nothing from sharing a helper with them.
        _mintFee(owner(), r.ownerShares, r.ownerFeeValue);
        _mintFee(msg.sender, r.callerShares, r.callerFeeValue);
        if (r.sharesToBurn > 0) {
            _burn(owner(), r.sharesToBurn);
            emit OwnerPenaltyBurned(owner(), r.sharesToBurn, r.penaltyValue);
        }
        _mintFee(address(bucketInfo), r.platformShares, r.platformFeeValue);

        // Update token price to reflect new state
        uint256 priceAfterRebalance =
            (totalSupply() > 0) ? (_calculateTotalValue() * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
        if (priceAfterRebalance == 0) revert InvalidPriceAfterRebalance();
        uint256 priceChange =
            priceAfterRebalance > r.newPrice ? priceAfterRebalance - r.newPrice : r.newPrice - priceAfterRebalance;
        if (priceChange > (r.newPrice * 20) / 100) revert PriceDeviationTooHigh();
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

    function _registry() internal view override returns (IImplementationRegistry) {
        return REGISTRY;
    }

    function _registryKind() internal pure override returns (IImplementationRegistry.Kind) {
        return IImplementationRegistry.Kind.PassiveBucket;
    }

    /*//////////////////////////////////////////////////////////////
                          UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @dev W3.3 (`09-DECISION-LOG.md` §10.1): `onlyOwner` alone is condition 1 of 4 — see
    /// {BucketVaultBase._authorizeUpgradeCommon} for conditions 2-4 (announced-implementation
    /// match, elapsed 48-hour timelock, live registry approval re-checked at this exact moment).
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        _authorizeUpgradeCommon(newImplementation);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
