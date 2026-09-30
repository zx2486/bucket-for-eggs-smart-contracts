// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";
import {BucketVaultBase} from "./base/BucketVaultBase.sol";

/**
 * @title ActiveBucket
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-20 vault without predefined distributions. The owner has full
 * control over portfolio composition via swapBy1inch and flashLoan functions.
 * Users deposit tokens to receive shares and redeem shares to receive proportional tokens.
 * @dev Uses UUPS proxy pattern. Similar to PassiveBucket but without bucket distributions,
 * accountability requirements, or DefiSwap rebalancing.
 * W1 (sc-refactor-base): inherits shared deposit-accounting/value/oracle-consumption logic from
 * {BucketVaultBase}. All state variables below stay declared here, at their pre-refactor linear
 * slots — none were moved into the base contract. See W1-SCR-REFACTOR-REPORT.md.
 */
contract ActiveBucket is BucketVaultBase {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice BucketInfo contract for token validation and pricing
    IBucketInfo public bucketInfo;

    /// @notice 1inch aggregation router address
    address public oneInchRouter;

    /// @notice Share price in USD with 8 decimals
    uint256 public tokenPrice;

    /// @notice Whether swap functions are paused
    bool public swapPaused;

    /// @notice Total deposited value in USD (8 decimals)
    uint256 public totalDepositValue;

    /// @notice Total withdrawn value in USD (8 decimals)
    /// @dev W2 (sc-vault-exit): no longer incremented by `redeem()`. The computation required an
    /// oracle call (`_calculateValueOfShares` -> `_bucketInfo().getTokenPrice`), which INV-1
    /// forbids on the exit path (workspace CLAUDE.md §"What this project is": "no oracle call,
    /// no external price, no whitelist iteration on any path a user takes to exit"). Per root
    /// CLAUDE.md §8 ("Do not remove `totalWithdrawValue`... move the computation off-chain via
    /// an event; do not delete the capability"), this getter is preserved but is now a frozen
    /// historical value as of the last pre-W2 redemption on this vault — it does not grow
    /// further. The statistic itself moves off-chain: an indexer derives it from the redesigned
    /// `Redeemed` event's `tokens`/`amounts` plus its own price history. See
    /// BucketVaultBase.sol's `Redeemed` event doc comment.
    uint256 public totalWithdrawValue;

    /// @notice Flash loan interest rate (2% = 200 bps). ActiveBucket-only; PassiveBucket has no
    /// flash-loan feature, so this is not shared via BucketVaultBase.
    uint256 public constant FLASH_LOAN_FEE_BPS = 200;

    /// @notice Performance fee in basis points
    uint256 public performanceFeeBps;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    // Deposited, Redeemed, TokenReturned, SwapPauseChanged, TokensRecovered, BucketInfoUpdated
    // moved to BucketVaultBase (byte-identical declarations, verified against PassiveBucket's
    // matching events before the move). ActiveBucket-only events stay here.

    event SwapExecuted(
        address indexed caller, uint256 totalValueBefore, uint256 totalValueAfter, uint256 newTokenPrice
    );
    event FlashLoan(
        address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee
    );
    event OneInchRouterUpdated(address indexed newRouter);
    event PerformanceFeeDistributed(address indexed recipient, uint256 sharesMinted, uint256 feeValueUsd);
    event PerformancePenaltyBurned(address indexed owner, uint256 sharesBurned, uint256 penaltyValueUsd);
    event PerformanceFeeUpdated(uint256 newFeeBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    // PlatformNotOperational, InvalidToken, ZeroAddress, ZeroAmount, InvalidRedeemAmount,
    // SwapIsPaused, SwapNotPaused, InsufficientShares, ETHTransferFailed, SwapFailed,
    // ValueLossTooHigh, CannotRecoverWhitelistedToken, UnauthorizedBucketInfoUpdate moved to
    // BucketVaultBase. ActiveBucket-only (flash-loan-specific) errors stay here.

    error InsufficientBalance();
    error InsufficientRepayment(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/
    // whenPlatformOperational / whenSwapNotPaused moved to BucketVaultBase, rewritten there
    // against the _bucketInfo()/_swapPaused() hooks below instead of these local state vars
    // directly — identical behavior.

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
     * @notice Initializes the ActiveBucket contract
     * @param bucketInfoAddr The BucketInfo contract address
     * @param oneInchRouterAddr The 1inch aggregation router address
     */
    function initialize(address bucketInfoAddr, address oneInchRouterAddr, string memory name, string memory symbol)
        external
        initializer
    {
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

        performanceFeeBps = 1400; // 14% default
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit a whitelisted token and receive share tokens
     * @dev W2 (sc-vault-entry): mints against the vault's LIVE NAV
     * (`_calculateTotalValue()`/`totalSupply()`), not the stale `tokenPrice` state variable —
     * see `BucketVaultBase._processDeposit`'s doc comment. `tokenPrice` is now kept
     * continuously live-synced on every deposit (not just on rebalance) as a side effect.
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
     * @notice Redeem shares for proportional underlying tokens
     * @dev W2 (sc-vault-exit): returns tokens the vault actually holds (the held-tokens
     * registry maintained by `deposit()`/swap paths since W1), not the full BucketInfo
     * whitelist — see INV-1 and the in-function comments below.
     * @param shares The number of share tokens to redeem
     */
    function redeem(uint256 shares) external nonReentrant whenNotPaused whenPlatformOperational {
        if (shares == 0 || shares > balanceOf(msg.sender)) {
            revert InvalidRedeemAmount();
        }

        uint256 supply = totalSupply();
        // Explicit panic-to-revert conversion (W2): division-by-zero below would panic (0x12)
        // if `supply` were 0. Unreachable today — `shares > 0` and
        // `shares <= balanceOf(msg.sender) <= supply` together guarantee `supply > 0` — but
        // guarded explicitly rather than relying on that invariant implicitly.
        if (supply == 0) revert InvalidRedeemAmount();

        // INV-1 (workspace CLAUDE.md; 04-CONTRACTS-IMPLEMENTATION-PLAN.md §3): redemption
        // depends on nothing but share arithmetic — no oracle call, no whitelist iteration. W2
        // (sc-vault-exit): enumerate the held-tokens registry instead of
        // `bucketInfo.getWhitelistedTokens()`. This also fixes a latent defect in the prior
        // code: a token de-whitelisted by BucketInfo's owner after users deposited it would
        // silently vanish from this loop, stranding those users' funds; the held-tokens
        // registry does not depend on the current whitelist at all.
        address[] memory tokens = _heldTokensList();

        // Calculate return amounts before burning
        uint256[] memory returnAmounts = new uint256[](tokens.length);
        bool anyPayout = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _getTokenBalance(tokens[i]);
            returnAmounts[i] = (balance * shares) / supply;
            if (returnAmounts[i] > 0) anyPayout = true;
        }
        // W2 (sc-vault-exit): revert on an all-zero payout (e.g. `shares` so small every
        // per-token amount rounds down to 0) instead of silently burning shares for nothing.
        if (!anyPayout) revert NothingToRedeem();

        // Burn shares
        _burn(msg.sender, shares);

        // Transfer tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            if (returnAmounts[i] > 0) {
                _transferToken(tokens[i], msg.sender, returnAmounts[i]);
                // Keep the held-tokens registry accurate if this payout fully drains a token —
                // mirrors the sync PassiveBucket's swap paths already perform post-swap.
                _syncHeldTokenByBalance(tokens[i]);
                emit TokenReturned(msg.sender, tokens[i], returnAmounts[i]);
            }
        }

        // W2 (sc-vault-exit): `Redeemed` redesigned (BucketVaultBase.sol doc comment) — USD
        // value is no longer computed on-chain here (that required the oracle call INV-1
        // forbids); `totalWithdrawValue` is preserved as a getter but no longer incremented,
        // per root CLAUDE.md §8. The event carries token amounts so an off-chain indexer can
        // reconstruct the same statistic from its own price history.
        emit Redeemed(msg.sender, shares, totalSupply(), tokens, returnAmounts);
    }

    /**
     * @notice Preview the tokens/amounts a `redeem(shares)` call would produce for
     * `msg.sender` against the CURRENT on-chain state, without mutating anything.
     * @dev ActiveBucket.redeem has no owner-accountability check (unlike PassiveBucket.redeem —
     * see PassiveBucket.previewRedeem's doc comment), so this is exactly
     * `BucketVaultBase._previewRedeemCore` with no extra wrapper.
     * @param shares The number of share tokens to preview redeeming
     */
    function previewRedeem(uint256 shares) external view returns (address[] memory tokens, uint256[] memory amounts) {
        return _previewRedeemCore(shares);
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP BY 1INCH
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a swap via 1inch aggregation router (owner only)
     * @dev W2 (sc-swap) rewrite: replaced the caller-supplied `bytes calldata swapCalldata` with
     * four typed parameters — this contract (via the shared BucketVaultBase._execute1inchSwap)
     * now builds 100% of the router calldata itself, so there is no arbitrary-calldata surface
     * left even though this entry point is `onlyOwner`. See BucketVaultBase.sol's contract-level
     * doc comment and `_execute1inchSwap`'s doc comment for the full rationale (INV-2, INV-9,
     * hard rule 12 / R-V1). Does not check distribution or accountability. Value loss must be
     * < 0.5% per call (existing) AND within the cumulative per-epoch budget (new, W2).
     * @param srcToken Token being sold (address(0) = native ETH). Must be whitelisted.
     * @param dstToken Token being bought (address(0) = native ETH). Must be whitelisted.
     * @param amount Amount of `srcToken` to swap, bounded by this vault's held balance.
     * @param minReturn Minimum acceptable `dstToken` out; must clear an oracle-derived floor.
     */
    function swapBy1inch(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        whenSwapNotPaused
        whenPlatformOperational
    {
        uint256 beforeTokenPrice = tokenPrice;

        // Mechanical call-and-value-loss-check is shared (BucketVaultBase._execute1inchSwap);
        // access control (onlyOwner, above) and fee handling (below) stay local — see
        // BucketVaultBase's contract-level doc comment for why this split is intentional.
        (uint256 totalValueBefore, uint256 totalValueAfter) = _execute1inchSwap(srcToken, dstToken, amount, minReturn);

        // W2 (sc-swap): close the cross-wave gap flagged by sc-vault-exit — PassiveBucket already
        // re-syncs the held-tokens registry after a swap (see PassiveBucket.rebalanceBy1inch); a
        // 1inch swap can move this vault from holding zero of `dstToken` to holding some, or from
        // some `srcToken` down to zero, and the registry (consumed by redeem()'s payout token
        // list) must reflect that.
        _syncAllHeldTokensFromWhitelist();

        // Send performance fee to BucketInfo and owner
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            beforeTokenPrice * tokenTotalSupply / PRECISION, totalValueAfter, performanceFeeBps, tokenTotalSupply
        );

        emit SwapExecuted(msg.sender, totalValueBefore, totalValueAfter, tokenPrice);
    }

    /*//////////////////////////////////////////////////////////////
                          FLASH LOAN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Flash loan any token held by the contract (owner only, 2% interest)
     * @param token The token to flash loan (address(0) for ETH)
     * @param amount The amount to flash loan
     * @param receiver The address that receives the tokens and callback
     * @param data Arbitrary data to pass to the flash loan receiver
     */
    function flashLoan(address token, uint256 amount, address receiver, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = _getTokenBalance(token);
        if (balanceBefore < amount) revert InsufficientBalance();

        uint256 fee = (amount * FLASH_LOAN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 beforeTokenPrice = tokenPrice;

        // Transfer tokens to receiver
        _transferToken(token, receiver, amount);

        // Execute callback
        IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, token, amount, fee, data);

        // Check repayment
        uint256 balanceAfter = _getTokenBalance(token);
        uint256 expectedBalance = balanceBefore + fee;
        if (balanceAfter < expectedBalance) {
            revert InsufficientRepayment(expectedBalance, balanceAfter);
        }

        // Send performance fee to BucketInfo and owner
        uint256 totalValueAfterLoan = _calculateTotalValue();
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            beforeTokenPrice * tokenTotalSupply / PRECISION, totalValueAfterLoan, performanceFeeBps, tokenTotalSupply
        );

        emit FlashLoan(msg.sender, receiver, token, amount, fee);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents deposits and redemptions)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Pause swap and flash loan functions
    function pauseSwap() external onlyOwner {
        if (swapPaused) revert SwapIsPaused();
        swapPaused = true;
        emit SwapPauseChanged(true);
    }

    /// @notice Unpause swap and flash loan functions
    function unpauseSwap() external onlyOwner {
        if (!swapPaused) revert SwapNotPaused();
        swapPaused = false;
        emit SwapPauseChanged(false);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // recoverTokens, updateBucketInfo moved to BucketVaultBase (byte-identical logic, verified
    // against PassiveBucket's matching functions before the move; the one cosmetic change is
    // recoverTokens now calling the shared _transferToken helper instead of inlining the
    // ETH-call/safeTransfer branch — same behavior, matching PassiveBucket's pre-existing style).

    /**
     * @notice Update the 1inch router address
     * @param newRouter New router address
     */
    function setOneInchRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        oneInchRouter = newRouter;
        emit OneInchRouterUpdated(newRouter);
    }

    /**
     * @notice Update the performance fee parameters
     * @param _performanceFeeBps  Performance fee in basis points (e.g., 500 = 5%)
     */
    function setPerformanceFee(uint256 _performanceFeeBps) external onlyOwner {
        require(_performanceFeeBps <= BPS_DENOMINATOR, "Fee exceeds 100%");
        performanceFeeBps = _performanceFeeBps;
        emit PerformanceFeeUpdated(_performanceFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // calculateTotalValue() moved to BucketVaultBase (byte-identical wrapper around the shared
    // _calculateTotalValue()).

    /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // _calculateTotalValue, _calculateValueOfShares, _getTokenBalance, _getTokenDecimals,
    // _transferToken moved to BucketVaultBase. Verified identical logic against PassiveBucket's
    // matching helpers before the move: ActiveBucket previously inlined the per-token value
    // calculation directly here instead of naming it `_getTokenValue`; PassiveBucket already had
    // the named helper, and both iterated the same `bucketInfo.getWhitelistedTokens()` universe,
    // so unifying `_calculateTotalValue` around the shared `_getTokenValue` changes no behavior.

    /**
     * @dev Handle fee distribution and token price updates after swapping or flash loan repayment. Distributes performance fees to BucketInfo and owner, and updates token price based on new total value.
     * @param totalValueBefore Total value before rebalance (USD 8 dec)
     * @param totalValueAfter Total value after rebalance (USD 8 dec)
     * @param ownerFeeBps Owner performancefee in basis points (e.g., 500 = 5%)
     * @param tokenTotalSupply Total supply of the tokens for price calculation
     */
    function _handleRebalanceFees(
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 ownerFeeBps,
        uint256 tokenTotalSupply
    ) internal returns (uint256) {
        // Calculate new token price (pre-fee-minting)
        uint256 newPrice = (totalValueAfter * PRECISION) / tokenTotalSupply;
        uint256 valueDifference = totalValueAfter > totalValueBefore
            ? totalValueAfter - totalValueBefore
            : totalValueBefore - totalValueAfter;
        // provide performance fee or penalty only when owner is accountable (holding >= 5% of total supply)
        if ((balanceOf(owner()) * BPS_DENOMINATOR) / tokenTotalSupply >= MIN_OWNER_BPS) {
            if (totalValueAfter > totalValueBefore) {
                uint256 increase = totalValueAfter - totalValueBefore;

                // Owner fee
                uint256 ownerFeeValue = (increase * ownerFeeBps * PRECISION) / BPS_DENOMINATOR;
                if (ownerFeeValue > 0 && newPrice > 0) {
                    uint256 ownerShares = (ownerFeeValue) / newPrice;
                    ownerFeeValue = ownerFeeValue / PRECISION; // adjust back to USD value for event
                    if (ownerShares > 0) {
                        _mint(owner(), ownerShares);
                        emit PerformanceFeeDistributed(owner(), ownerShares, ownerFeeValue);
                    }
                }
            } else if (totalValueAfter < totalValueBefore) {
                uint256 decrease = totalValueBefore - totalValueAfter;

                // Owner bears some of decrease (burned from owner shares)
                uint256 penaltyValue = (decrease * performanceFeeBps * PRECISION) / BPS_DENOMINATOR;
                uint256 sharesToBurn = (penaltyValue) / newPrice;
                penaltyValue = penaltyValue / PRECISION; // adjust back to USD value for event
                uint256 ownerBalance = balanceOf(owner());

                if (sharesToBurn > ownerBalance) {
                    sharesToBurn = ownerBalance;
                }
                if (sharesToBurn > 0) {
                    _burn(owner(), sharesToBurn);
                    emit PerformancePenaltyBurned(owner(), sharesToBurn, penaltyValue);
                }
            }
        }

        // Platform fee to BucketInfo
        uint256 platformFeeValue = bucketInfo.calculateFee(valueDifference);
        if (platformFeeValue > 0 && newPrice > 0) {
            uint256 platformShares = (platformFeeValue * PRECISION) / newPrice;
            if (platformShares > 0) {
                _mint(address(bucketInfo), platformShares);
                emit PerformanceFeeDistributed(address(bucketInfo), platformShares, platformFeeValue);
            }
        }
        // Update token price to reflect new state
        return (totalSupply() > 0) ? (_calculateTotalValue() * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
    }

    // isBucketAccountable() moved to BucketVaultBase (byte-identical logic, verified against
    // PassiveBucket's matching function before the move).

    /*//////////////////////////////////////////////////////////////
                    BucketVaultBase ABSTRACT HOOKS
    //////////////////////////////////////////////////////////////*/
    // Thin overrides exposing this contract's own linear state variables to the shared base
    // logic, without moving that state out of ActiveBucket (see the storage-layout note at the
    // top of BucketVaultBase.sol).

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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                          RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
