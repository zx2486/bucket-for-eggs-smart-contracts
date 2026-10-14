// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";
import {IImplementationRegistry} from "./interfaces/IImplementationRegistry.sol";
import {BucketVaultBase} from "./base/BucketVaultBase.sol";

/**
 * @title ActiveBucket
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-20 vault without predefined distributions. The owner has full
 * control over portfolio composition via swapBy1inch. flashLoan is holder-callable -- any
 * address holding a nonzero share balance may call it, not just the owner.
 * Users deposit tokens to receive shares and redeem shares to receive proportional tokens.
 * @dev Uses UUPS proxy pattern. Similar to PassiveBucket but without bucket distributions,
 * accountability requirements, or DefiSwap rebalancing. Inherits shared deposit-accounting,
 * valuation and oracle-consumption logic from {BucketVaultBase}; state variables stay declared
 * here.
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
    /// @dev No longer incremented by `redeem()`, since that would require an oracle call on the
    /// exit path. Frozen at its last pre-redesign value; an off-chain indexer derives the
    /// current statistic from the `Redeemed` event's token amounts plus its own price history.
    uint256 public totalWithdrawValue;

    /// @notice Flash loan interest rate (2% = 200 bps). ActiveBucket-only; PassiveBucket has no
    /// flash-loan feature, so this is not shared via BucketVaultBase.
    uint256 public constant FLASH_LOAN_FEE_BPS = 200;

    /// @notice Performance fee in basis points
    uint256 public performanceFeeBps;

    /// @notice The platform-owned {ImplementationRegistry} this vault's upgrades are checked
    /// against. Immutable and constructor-set so the whitelist authority can never be swapped
    /// out by this vault's (customer) owner.
    IImplementationRegistry public immutable REGISTRY;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

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

    error InsufficientBalance();
    error InsufficientRepayment(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

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
     * @notice Initializes the ActiveBucket contract
     * @param bucketInfoAddr The BucketInfo contract address
     * @param oneInchRouterAddr The 1inch aggregation router address
     */
    function initialize(address bucketInfoAddr, address oneInchRouterAddr, string memory name, string memory symbol)
        external
        initializer
    {
        // Only a platform-authorized factory may initialize a proxy against this
        // implementation, preventing a direct `ERC1967Proxy` deploy from bypassing the factory
        // with an attacker-controlled `bucketInfoAddr`.
        if (!REGISTRY.isAuthorizedFactory(msg.sender)) revert UnauthorizedInitializer();
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

        performanceFeeBps = 1300; // 13% default
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
     * @notice Redeem shares for proportional underlying tokens
     * @dev Returns tokens the vault actually holds (the held-tokens registry), not the full
     * BucketInfo whitelist, so redemption never depends on a token still being whitelisted.
     * @param shares The number of share tokens to redeem
     */
    function redeem(uint256 shares) external nonReentrant whenNotPaused whenPlatformOperational {
        // Shared with `previewRedeem` below and with `PassiveBucket`: validation, the
        // held-tokens snapshot and the pro-rata amounts are computed once in the base contract
        // so redemption logic isn't duplicated per vault type.
        (address[] memory tokens, uint256[] memory returnAmounts) = _previewRedeemCore(shares);

        // Burn shares
        _burn(msg.sender, shares);

        // Transfer tokens (interactions)
        _payoutAndSync(msg.sender, tokens, returnAmounts);

        // `totalWithdrawValue` is preserved as a getter but no longer incremented here; an
        // off-chain indexer can reconstruct the USD value from this event's token amounts plus
        // its own price history.
        emit Redeemed(msg.sender, shares, totalSupply(), tokens, returnAmounts);

        _syncOutpricedStatus();
    }

    /**
     * @notice Preview the tokens/amounts a `redeem(shares)` call would produce for
     * `msg.sender` against the CURRENT on-chain state, without mutating anything.
     * @dev ActiveBucket has no owner-accountability check, so this is a thin wrapper with no
     * extra guard.
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
     * @dev Builds the router calldata from typed parameters internally, so there is no
     * arbitrary-calldata surface. Does not check distribution or accountability. Value loss
     * must stay under the per-call cap and within the cumulative per-epoch budget.
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
        // No mint/burn on this path, so the blacklist hook on transfers never fires -- check
        // explicitly.
        _assertNotBlacklisted(msg.sender);

        uint256 beforeTokenPrice = tokenPrice;

        (uint256 totalValueBefore, uint256 totalValueAfter) = _execute1inchSwap(srcToken, dstToken, amount, minReturn);

        // Keep the held-tokens registry accurate: a swap can move this vault from holding zero
        // of `dstToken` to holding some, or some `srcToken` down to zero.
        _syncAllHeldTokensFromWhitelist();

        _syncOutpricedStatus();

        // Send performance fee to BucketInfo and owner
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            beforeTokenPrice * tokenTotalSupply / PRECISION, totalValueAfter, performanceFeeBps, tokenTotalSupply
        );

        emit SwapExecuted(msg.sender, totalValueBefore, totalValueAfter, tokenPrice);
    }

    /**
     * @notice Execute several 1inch swaps in one call (owner only), e.g. trading multiple
     * held tokens into one or more others to change the portfolio composition in a single
     * transaction.
     * @dev Each leg is independently validated and value-checked exactly as `swapBy1inch`
     * checks its single leg; only the swap cooldown is shared across all legs.
     * @param legs The ordered list of swaps to execute, one `swapBy1inch`-style leg each.
     */
    function executeMultiSwapBy1inch(SwapLeg[] calldata legs)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        whenSwapNotPaused
        whenPlatformOperational
    {
        // No mint/burn on this path, so the blacklist hook on transfers never fires -- check
        // explicitly.
        _assertNotBlacklisted(msg.sender);

        uint256 beforeTokenPrice = tokenPrice;

        (uint256 totalValueBefore, uint256 totalValueAfter) = _executeMultiLegSwap(legs);

        _syncAllHeldTokensFromWhitelist();
        _syncOutpricedStatus();

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
     * @notice Flash loan any token held by the contract (holder-callable, 2% interest)
     * @dev Callable by any address holding a nonzero share balance, not just the owner.
     * Receiver must implement `IFlashLoanReceiver.onFlashLoan` and repay the loan plus fee
     * within the same transaction. `nonReentrant` shares the same lock as
     * `deposit`/`redeem`/`redeemForStable`, so a receiver's callback cannot re-enter any of
     * those mid-loan to extract value before the repayment check below runs.
     * @param token The token to flash loan (address(0) for ETH)
     * @param amount The amount to flash loan
     * @param receiver The address that receives the tokens and callback
     * @param data Arbitrary data to pass to the flash loan receiver
     */
    function flashLoan(address token, uint256 amount, address receiver, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        _requireHasShares();
        // No mint/burn on this path, so the blacklist hook on transfers never fires -- check
        // explicitly.
        _assertNotBlacklisted(msg.sender);

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

    /// @dev Reverts unless the caller holds a nonzero share balance.
    function _requireHasShares() private view {
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents deposits and redemptions)
    /// @dev Also blocks a blacklisted owner from pausing.
    function pause() external onlyOwner whenCallerNotBlacklisted {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner whenCallerNotBlacklisted {
        _unpause();
    }

    /// @notice Pause swap and flash loan functions
    function pauseSwap() external onlyOwner whenCallerNotBlacklisted {
        if (swapPaused) revert SwapIsPaused();
        swapPaused = true;
        emit SwapPauseChanged(true);
    }

    /// @notice Unpause swap and flash loan functions
    function unpauseSwap() external onlyOwner whenCallerNotBlacklisted {
        if (!swapPaused) revert SwapNotPaused();
        swapPaused = false;
        emit SwapPauseChanged(false);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the 1inch router address
     * @param newRouter New router address
     */
    function setOneInchRouter(address newRouter) external onlyOwner whenCallerNotBlacklisted {
        if (newRouter == address(0)) revert ZeroAddress();
        oneInchRouter = newRouter;
        emit OneInchRouterUpdated(newRouter);
    }

    /**
     * @notice Update the performance fee parameters
     * @param _performanceFeeBps  Performance fee in basis points (e.g., 500 = 5%)
     */
    function setPerformanceFee(uint256 _performanceFeeBps) external onlyOwner whenCallerNotBlacklisted {
        require(_performanceFeeBps <= BPS_DENOMINATOR, "Fee exceeds 100%");
        performanceFeeBps = _performanceFeeBps;
        emit PerformanceFeeUpdated(_performanceFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        // provide performance fee or penalty only when owner is accountable (holding >= MIN_OWNER_BPS,
        // currently 1%, of total supply)
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

        // Platform fee to BucketInfo, clamped to BucketInfo's own fee cap.
        uint256 platformFeeValue = _boundedPlatformFee(valueDifference, bucketInfo.calculateFee(valueDifference));
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

    /*//////////////////////////////////////////////////////////////
                    BucketVaultBase ABSTRACT HOOKS
    //////////////////////////////////////////////////////////////*/
    // Exposes this contract's own state variables to the shared base logic.

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
        return IImplementationRegistry.Kind.ActiveBucket;
    }

    /// @dev Owner-triggered upgrade authorization. {BucketVaultBase._authorizeUpgradeCommon}
    /// enforces the remaining conditions: the implementation must be registry-approved, the
    /// 48-hour timelock must have elapsed, and approval is re-checked at execution time.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        _authorizeUpgradeCommon(newImplementation);
    }

    /*//////////////////////////////////////////////////////////////
                          RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
