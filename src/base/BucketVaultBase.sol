// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IImplementationRegistry} from "../interfaces/IImplementationRegistry.sol";
import {TimelockedAdmin} from "../libs/TimelockedAdmin.sol";
import {SeizureLib} from "../libraries/SeizureLib.sol";
import {GovernanceLib} from "../libraries/GovernanceLib.sol";
import {OraclePricingLib} from "../libraries/OraclePricingLib.sol";
import {PayoutLib} from "../libraries/PayoutLib.sol";
import {SwapExecutionLib} from "../libraries/SwapExecutionLib.sol";

/// @title Shared base for active and passive vaults.
abstract contract BucketVaultBase is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:bucket-for-eggs.storage.BucketVaultBase
    struct BucketVaultBaseStorage {
        EnumerableSet.AddressSet heldTokens;
        /// Swap cooldown and per-epoch value-loss state.
        SwapExecutionLib.SwapCooldownState swapCooldown;
        SwapExecutionLib.EpochLossBudget epochLossBudget;
        /// Pending BucketInfo address update.
        TimelockedAdmin.AddressTimelock bucketInfoUpdateTimelock;
        /// Pending implementation upgrade.
        TimelockedAdmin.AddressTimelock upgradeTimelock;
        /// Pending seizure state keyed by the account being seized from.
        mapping(address => TimelockedAdmin.SeizureTimelock) seizureTimelocks;
        /// Last-known aggregate outpriced status.
        OraclePricingLib.OutpricedTracker outpricedTracker;
        /// Owner-adjustable per-swap and per-epoch value-loss limits, in basis points.
        SwapExecutionLib.MaxValueLossBpsState maxValueLossBps;
    }

    bytes32 private constant BucketVaultBaseStorageLocation =
        0x9f30ad90d3ca0770ef0f83f64df7579794e50d1de913b949a234fef0170b6e00;

    function _getBucketVaultBaseStorage() private pure returns (BucketVaultBaseStorage storage $) {
        assembly {
            $.slot := BucketVaultBaseStorageLocation
        }
    }

    /// @dev Share arithmetic fixed-point scale. 18-decimal, matches ERC-20 share decimals.
    uint256 public constant PRECISION = 1e18;

    /// @dev Zero-state fallback share price: 1 USD, 8-decimal.
    uint256 public constant INITIAL_TOKEN_PRICE = 1e8;

    /// @dev Shares permanently locked on the first deposit to mitigate donation attacks.
    uint256 public constant DEAD_SHARES = 1e18;

    /// @dev Recipient of permanently locked shares.
    address public constant DEAD_SHARES_RECIPIENT = address(0x000000000000000000000000000000000000dEaD);

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Floor on the owner's retained fee share, and the threshold `isBucketAccountable()`
    /// checks the owner's balance against. 100 = 1%.
    uint256 public constant MIN_OWNER_BPS = 100;

    /// @dev Default per-swap value-loss limit, in basis points.
    uint256 public constant MAX_VALUE_LOSS_BPS = 50;

    /// @dev Maximum configurable per-swap loss limit and per-epoch budget, in basis points.
    uint256 internal constant MAX_VALUE_LOSS_BPS_CEILING = 1000;

    /// @dev Maximum platform fee applied by this vault, in basis points.
    uint256 public constant MAX_LOCAL_PLATFORM_FEE_BPS = 1000;

    /// @dev Minimum time between swap actions by the same caller.
    uint256 public constant CALLER_SWAP_COOLDOWN = 5 minutes;
    /// @dev Minimum time between any two swap actions.
    uint256 public constant GLOBAL_SWAP_COOLDOWN = 1 minutes;
    /// @dev Rolling period for the cumulative value-loss budget.
    uint256 public constant VALUE_LOSS_EPOCH_LENGTH = 1 days;
    /// @dev Default cumulative value-loss budget per epoch, in basis points.
    uint256 public constant EPOCH_VALUE_LOSS_BUDGET_BPS = 150;
    /// @dev Slippage tolerance used to derive the minimum-return floor, in basis points.
    uint256 public constant MIN_RETURN_FLOOR_TOLERANCE_BPS = 100;

    error PlatformNotOperational();
    error InvalidToken(address token);
    error ZeroAddress();
    error UnauthorizedInitializer();
    error ZeroAmount();
    error InvalidRedeemAmount();
    error NothingToRedeem();
    error ReceivedBelowMinReturn(uint256 received, uint256 minReturn);
    error FirstDepositTooSmall();
    error SwapIsPaused();
    error SwapNotPaused();
    error InsufficientShares();
    error ETHTransferFailed();
    error SwapFailed();
    error ValueLossTooHigh(uint256 valueBefore, uint256 valueAfter);
    error CannotRecoverWhitelistedToken(address token);
    error UnauthorizedBucketInfoUpdate();
    error SameToken();
    error AmountExceedsHeldBalance(uint256 amount, uint256 heldBalance);
    error MinReturnBelowFloor(uint256 minReturnValueUsd, uint256 floorValueUsd);
    error SwapCooldownActive(uint256 cooldownUntil);
    error EpochValueLossBudgetExceeded(uint256 projectedLossUsd, uint256 budgetUsd);
    error MalformedSwapPayload();
    error EmptyLegs();
    error UpgradeImplementationMismatch(address expected, address provided);
    error UpgradeNotApproved(address implementation);
    error RenounceOwnershipDisabled();
    error OwnerNotAccountable();
    error MaxValueLossBpsExceedsCeiling(uint256 requested);

    event Deposited(
        address indexed user, address indexed token, uint256 amount, uint256 sharesMinted, uint256 depositValueUsd
    );
    /// @notice Emitted when shares are redeemed for the held-token basket.
    event Redeemed(address indexed user, uint256 shares, uint256 supply, address[] tokens, uint256[] amounts);
    /// @notice Emitted when shares are redeemed for a single destination token.
    event RedeemedForStable(
        address indexed user,
        uint256 shares,
        uint256 supply,
        address indexed dstToken,
        uint256 dstAmountOut,
        address[] tokens,
        uint256[] amounts
    );
    event TokenReturned(address indexed user, address indexed token, uint256 amount);
    event SwapPauseChanged(bool paused);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);
    /// @notice Emitted when a BucketInfo update is proposed.
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed proposedBucketInfo, address indexed proposedBy, uint256 eta
    );
    /// @notice Emitted when a BucketInfo update is vetoed.
    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);
    /// @notice Emitted when an upgrade is queued.
    event UpgradeQueued(address indexed vault, address indexed newImplementation, uint256 eta);
    /// @notice Emitted when a queued upgrade is cancelled.
    event UpgradeCancelled(address indexed vault, address indexed implementation);
    /// @notice Emitted when swap value-loss limits are updated.
    event MaxValueLossBpsUpdated(uint256 newBps, uint256 newEpochBudgetBps);

    /// @dev Return this vault's BucketInfo contract.
    function _bucketInfo() internal view virtual returns (IBucketInfo);

    /// @dev Set this vault's BucketInfo contract.
    function _setBucketInfo(address newBucketInfo) internal virtual;

    /// @dev Return this vault's 1inch router.
    function _oneInchRouter() internal view virtual returns (address);

    /// @dev Return whether swaps are paused.
    function _swapPaused() internal view virtual returns (bool);

    /// @dev Return the platform implementation registry.
    function _registry() internal view virtual returns (IImplementationRegistry);

    /// @dev Registry namespace for this vault type.
    function _registryKind() internal pure virtual returns (IImplementationRegistry.Kind);

    modifier whenPlatformOperational() {
        if (!_bucketInfo().isPlatformOperational()) revert PlatformNotOperational();
        _;
    }

    modifier whenSwapNotPaused() {
        if (_swapPaused()) revert SwapIsPaused();
        _;
    }

    error Blacklisted(address account);

    /// @dev Returns true if the account is blacklisted or BucketInfo cannot be reached.
    function _isBlacklistedFailClosed(address account) internal view returns (bool) {
        try _bucketInfo().isBlacklisted(account) returns (bool blacklisted) {
            return blacklisted;
        } catch {
            return true;
        }
    }

    /// @dev Reverts if the account is blacklisted or BucketInfo cannot be reached.
    function _assertNotBlacklisted(address account) internal view {
        if (_isBlacklistedFailClosed(account)) revert Blacklisted(account);
    }

    /// @notice Blocks transfers involving blacklisted addresses.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) _assertNotBlacklisted(from);
        if (to != address(0)) _assertNotBlacklisted(to);
        super._update(from, to, value);
    }

    modifier whenCallerNotBlacklisted() {
        _assertNotBlacklisted(msg.sender);
        _;
    }

    modifier onlyOwnerNotBlacklisted() {
        _checkOwnerNotBlacklisted();
        _;
    }

    function _checkOwnerNotBlacklisted() internal view {
        _checkOwner();
        _assertNotBlacklisted(msg.sender);
    }

    /// @dev Blocks blacklisted spenders from using allowances.
    function _spendAllowance(address owner_, address spender, uint256 value) internal virtual override {
        _assertNotBlacklisted(spender);
        super._spendAllowance(owner_, spender, value);
    }

    /// @dev Blocks blacklisted callers from setting allowances.
    function approve(address spender, uint256 value) public virtual override whenCallerNotBlacklisted returns (bool) {
        return super.approve(spender, value);
    }

    /// @dev Delay before a seizure can be executed.
    uint256 internal constant SEIZURE_TIMELOCK_DELAY = 48 hours;

    /// @notice Propose seizing a blacklisted account's balance.
    function proposeSeizure(address account, address to, bytes32 documentHash) external {
        SeizureLib.proposeSeizure(
            _getBucketVaultBaseStorage().seizureTimelocks,
            _bucketInfo(),
            account,
            to,
            documentHash,
            SEIZURE_TIMELOCK_DELAY
        );
    }

    /// @notice Cancel a pending seizure proposal.
    function cancelSeizure(address account) external {
        SeizureLib.cancelSeizure(_getBucketVaultBaseStorage().seizureTimelocks, _bucketInfo(), account);
    }

    /// @notice Execute a matured seizure proposal.
    function executeSeizure(address account) external {
        uint256 beforeBalance = balanceOf(account);
        address to = SeizureLib.executeSeizure(
            _getBucketVaultBaseStorage().seizureTimelocks, _bucketInfo(), account, beforeBalance
        );

        super._update(account, to, beforeBalance);
    }

    /// @notice Return the pending seizure proposal for an account.
    function pendingSeizure(address account) external view returns (address to, bytes32 documentHash, uint256 eta) {
        TimelockedAdmin.SeizureTimelock storage t = _getBucketVaultBaseStorage().seizureTimelocks[account];
        return (t.to, t.documentHash, t.eta);
    }

    /// @dev Return the USD-8 value of all whitelisted token balances.
    function _calculateTotalValue() internal view returns (uint256) {
        return SwapExecutionLib.calculateTotalValue(_bucketInfo());
    }

    /// @dev Return the USD-8 value of a token balance.
    function _getTokenValue(address token) internal view returns (uint256) {
        return SwapExecutionLib.getTokenValue(_bucketInfo(), token);
    }

    /// @dev USD value (8 decimals) of `shares` out of `supply` total shares.
    function _calculateValueOfShares(uint256 shares, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 0;
        return (_calculateTotalValue() * shares) / supply;
    }

    /// @dev Clamp the platform fee to the local maximum.
    function _boundedPlatformFee(uint256 amount, uint256 rawFee) internal pure returns (uint256) {
        uint256 maxFee = (amount * MAX_LOCAL_PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        return rawFee > maxFee ? maxFee : rawFee;
    }

    /// @dev Token balance held by this contract; `address(0)` means native ETH.
    function _getTokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Token decimals; native ETH is treated as 18-decimal.
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    /// @dev Transfer a token or native ETH. Every current caller (recoverTokens,
    /// redeemForStable, and ActiveBucket.flashLoan) is nonReentrant, and nonReentrant is a
    /// single contract-wide lock (ReentrancyGuardTransient), so a reentrant call here cannot
    /// re-enter any other nonReentrant-guarded function either. `to` is always a
    /// caller-authenticated address (the owner for recoverTokens, msg.sender for
    /// redeemForStable, the flash-loan receiver for flashLoan), not an arbitrary unvalidated
    /// address. forge-lint's reentrancy-eth/reentrancy-balance analysis flags this call site
    /// directly rather than tracing nonReentrant through all callers, so it fires regardless
    /// of caller context -- confirmed false positive, suppressed below.
    function _transferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            // forge-lint: disable-next-line(arbitrary-send-eth,reentrancy-eth,reentrancy-balance)
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Calculate the share price and shares minted for a deposit.
    function _computeDepositShares(uint256 depositValue, uint256 totalValueBeforeDeposit, uint256 supplyBeforeDeposit)
        private
        pure
        returns (uint256 newSharePrice, uint256 sharesToMint)
    {
        newSharePrice =
            supplyBeforeDeposit > 0 ? (totalValueBeforeDeposit * PRECISION) / supplyBeforeDeposit : INITIAL_TOKEN_PRICE;
        if (newSharePrice == 0) newSharePrice = INITIAL_TOKEN_PRICE;

        sharesToMint = (depositValue * PRECISION) / newSharePrice;
        if (sharesToMint == 0) revert ZeroAmount();

        if (supplyBeforeDeposit == 0) {
            if (sharesToMint <= DEAD_SHARES) revert FirstDepositTooSmall();
            sharesToMint -= DEAD_SHARES;
        }
    }

    /// @dev Process a deposit and mint shares.
    function _processDeposit(address token, uint256 amount)
        internal
        returns (uint256 actualAmount, uint256 sharesToMint, uint256 depositValue, uint256 newSharePrice)
    {
        if (!_bucketInfo().isTokenValid(token)) revert InvalidToken(token);

        uint256 totalValueBeforeDeposit = _calculateTotalValue();
        uint256 supplyBeforeDeposit = totalSupply();

        if (token == address(0)) {
            actualAmount = msg.value;
        } else {
            actualAmount = amount;
            IERC20(token).safeTransferFrom(msg.sender, address(this), actualAmount);
        }
        if (actualAmount == 0) revert ZeroAmount();

        uint256 oraclePrice = _bucketInfo().getTokenPrice(token);
        if (oraclePrice == 0) revert InvalidToken(token);
        uint8 decimals = _getTokenDecimals(token);
        depositValue = (actualAmount * oraclePrice) / (10 ** decimals);

        if (token == address(0)) {
            // Exclude the deposit from the pre-deposit value.
            totalValueBeforeDeposit -= depositValue;
        }

        (newSharePrice, sharesToMint) =
            _computeDepositShares(depositValue, totalValueBeforeDeposit, supplyBeforeDeposit);

        if (supplyBeforeDeposit == 0) {
            _mint(DEAD_SHARES_RECIPIENT, DEAD_SHARES);
        }
        _mint(msg.sender, sharesToMint);
        _registerHeldToken(token);
        _syncOutpricedStatus();
    }

    /// @notice Deposit a whitelisted token and receive shares.
    function deposit(address token, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        (uint256 actualAmount, uint256 sharesToMint, uint256 depositValue, uint256 newSharePrice) =
            _processDeposit(token, amount);

        _recordDeposit(depositValue, newSharePrice);

        emit Deposited(msg.sender, token, actualAmount, sharesToMint, depositValue);
    }

    /// @dev Record deposit values in the child vault's storage.
    function _recordDeposit(uint256 depositValue, uint256 newSharePrice) internal virtual;

    /// @notice Preview the shares and USD value for a deposit.
    function previewDeposit(address token, uint256 amount)
        external
        view
        returns (uint256 sharesToMint, uint256 depositValue)
    {
        if (!_bucketInfo().isTokenValid(token)) revert InvalidToken(token);
        if (amount == 0) revert ZeroAmount();

        uint256 totalValueBeforeDeposit = _calculateTotalValue();
        uint256 supplyBeforeDeposit = totalSupply();

        uint256 oraclePrice = _bucketInfo().getTokenPrice(token);
        if (oraclePrice == 0) revert InvalidToken(token);
        uint8 decimals = _getTokenDecimals(token);
        depositValue = (amount * oraclePrice) / (10 ** decimals);

        (, sharesToMint) = _computeDepositShares(depositValue, totalValueBeforeDeposit, supplyBeforeDeposit);
    }

    /// @notice Live NAV share price (USD, 8 decimals). Falls back to `INITIAL_TOKEN_PRICE` when
    /// supply or total value is zero.
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return INITIAL_TOKEN_PRICE;
        uint256 price = (_calculateTotalValue() * PRECISION) / supply;
        return price == 0 ? INITIAL_TOKEN_PRICE : price;
    }

    /// @dev Calculate redemption payouts without changing state.
    function _previewRedeemCore(uint256 shares)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (shares == 0 || shares > balanceOf(msg.sender)) {
            revert InvalidRedeemAmount();
        }

        uint256 supply = totalSupply();
        if (supply == 0) revert InvalidRedeemAmount();

        tokens = _heldTokensList();
        amounts = new uint256[](tokens.length);
        bool anyPayout = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _getTokenBalance(tokens[i]);
            amounts[i] = (balance * shares) / supply;
            if (amounts[i] > 0) anyPayout = true;
        }
        if (!anyPayout) revert NothingToRedeem();
    }

    /// @notice Whether the owner holds at least `MIN_OWNER_BPS` of total supply.
    function isBucketAccountable() public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return (balanceOf(owner()) * BPS_DENOMINATOR) / supply >= MIN_OWNER_BPS;
    }

    /// @notice Recover a non-whitelisted token or native ETH.
    // nonReentrant added: this function sends value to a caller-chosen `to` via _transferToken,
    // which can trigger the recipient's fallback before TokensRecovered is emitted. The lint
    // flagged the shared _transferToken helper for this reason; every other caller already had
    // nonReentrant, so this was the one real gap in the cluster.
    function recoverTokens(address token, uint256 amount, address to) external nonReentrant onlyOwnerNotBlacklisted {
        if (to == address(0)) revert ZeroAddress();
        if (_bucketInfo().isTokenWhitelisted(token)) {
            revert CannotRecoverWhitelistedToken(token);
        }

        _transferToken(token, to, amount);

        emit TokensRecovered(token, to, amount);
    }

    /// @dev Delay before a BucketInfo update can be executed.
    uint256 public constant BUCKET_INFO_UPDATE_TIMELOCK_DELAY = 48 hours;

    /**
     * @notice Propose a BucketInfo address update.
     */
    function proposeUpdateBucketInfo(address newBucketInfo) external {
        GovernanceLib.proposeUpdateBucketInfo(
            _getBucketVaultBaseStorage().bucketInfoUpdateTimelock,
            _bucketInfo(),
            newBucketInfo,
            BUCKET_INFO_UPDATE_TIMELOCK_DELAY
        );
    }

    /**
     * @notice Veto a pending BucketInfo update.
     */
    function vetoUpdateBucketInfo() external onlyOwnerNotBlacklisted {
        GovernanceLib.vetoUpdateBucketInfo(_getBucketVaultBaseStorage().bucketInfoUpdateTimelock);
    }

    /**
     * @notice Execute a matured BucketInfo update.
     */
    function executeUpdateBucketInfo() external {
        address oldBucketInfo = address(_bucketInfo());
        address newBucketInfo =
            GovernanceLib.executeUpdateBucketInfo(_getBucketVaultBaseStorage().bucketInfoUpdateTimelock, oldBucketInfo);
        _setBucketInfo(newBucketInfo);
    }

    /// @notice Return the pending BucketInfo update.
    function pendingBucketInfoUpdate() external view returns (address pending, uint256 eta) {
        TimelockedAdmin.AddressTimelock storage t = _getBucketVaultBaseStorage().bucketInfoUpdateTimelock;
        return (t.pending, t.eta);
    }

    /// @dev Delay before a queued upgrade can be executed.
    uint256 public constant UPGRADE_TIMELOCK_DELAY = 48 hours;

    /**
     * @notice Queue a UUPS upgrade.
     */
    function queueUpgrade(address newImplementation) external onlyOwnerNotBlacklisted {
        GovernanceLib.queueUpgrade(
            _getBucketVaultBaseStorage().upgradeTimelock, newImplementation, UPGRADE_TIMELOCK_DELAY
        );
    }

    /**
     * @notice Cancel a pending upgrade.
     */
    function cancelUpgrade() external onlyOwnerNotBlacklisted {
        GovernanceLib.cancelUpgrade(_getBucketVaultBaseStorage().upgradeTimelock);
    }

    /// @notice Revert because ownership renunciation is disabled.
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Return the queued implementation, or zero if none.
    function pendingImplementation() external view returns (address) {
        return _getBucketVaultBaseStorage().upgradeTimelock.pending;
    }

    /// @notice Return the queued upgrade's execution timestamp, or zero if none.
    function upgradeEta() external view returns (uint256) {
        return _getBucketVaultBaseStorage().upgradeTimelock.eta;
    }

    /// @dev Validate authorization for a UUPS upgrade.
    function _authorizeUpgradeCommon(address newImplementation) internal {
        _assertNotBlacklisted(msg.sender);
        GovernanceLib.authorizeUpgrade(
            _getBucketVaultBaseStorage().upgradeTimelock, _registry(), _registryKind(), newImplementation
        );
    }

    /// @notice Total value of whitelisted tokens held by this contract (USD, 8 decimals).
    function calculateTotalValue() external view returns (uint256) {
        return _calculateTotalValue();
    }

    /// @dev Selector for the typed 1inch swap function.
    // casting to 'bytes4' is safe because this is the standard 4-byte function-selector
    // derivation (truncating a keccak256 hash to its first 4 bytes), not a value reinterpretation.
    bytes4 public constant ONEINCH_SWAP_SELECTOR =
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4(keccak256("execute1inchSwap(address,address,address,uint256,uint256)"));

    /// @dev Execute a validated 1inch swap.
    function _execute1inchSwap(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        internal
        returns (uint256 totalValueBefore, uint256 totalValueAfter)
    {
        _validateSwapLeg(srcToken, dstToken, amount, minReturn);

        _enforceSwapCooldown(msg.sender);

        return _executeSwapNoCooldown(srcToken, dstToken, amount, minReturn);
    }

    /// @dev One leg of a multi-leg swap: see `_executeMultiLegSwap`.
    struct SwapLeg {
        address srcToken;
        address dstToken;
        uint256 amount;
        uint256 minReturn;
    }

    /// @dev Execute several swap legs under one cooldown charge.
    function _executeMultiLegSwap(SwapLeg[] calldata legs)
        internal
        returns (uint256 totalValueBefore, uint256 totalValueAfter)
    {
        if (legs.length == 0) revert EmptyLegs();

        _enforceSwapCooldown(msg.sender);

        totalValueBefore = _calculateTotalValue();
        for (uint256 i = 0; i < legs.length; i++) {
            SwapLeg calldata leg = legs[i];
            _validateSwapLeg(leg.srcToken, leg.dstToken, leg.amount, leg.minReturn);
            _executeSwapNoCooldown(leg.srcToken, leg.dstToken, leg.amount, leg.minReturn);
        }
        totalValueAfter = _calculateTotalValue();
    }

    /// @dev Validate a swap leg before charging the cooldown.
    function _validateSwapLeg(address srcToken, address dstToken, uint256 amount, uint256 minReturn) internal view {
        SwapExecutionLib.validateSwapLeg(_bucketInfo(), srcToken, dstToken, amount, minReturn);
    }

    /// @dev Dispatch the swap and enforce value-loss limits.
    function _executeSwapNoCooldown(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        internal
        returns (uint256 totalValueBefore, uint256 totalValueAfter)
    {
        totalValueBefore = _calculateTotalValue();

        SwapExecutionLib.dispatchSwap(_oneInchRouter(), ONEINCH_SWAP_SELECTOR, srcToken, dstToken, amount, minReturn);

        totalValueAfter = _calculateTotalValue();

        _checkValueLossAndConsumeBudget(totalValueBefore, totalValueAfter);
    }

    /// @dev Enforce the per-swap and cumulative loss limits.
    function _checkValueLossAndConsumeBudget(uint256 totalValueBefore, uint256 totalValueAfter) internal {
        SwapExecutionLib.checkValueLossAndConsumeBudget(
            _getBucketVaultBaseStorage().epochLossBudget,
            totalValueBefore,
            totalValueAfter,
            maxValueLossBps(),
            epochValueLossBudgetBps()
        );
    }

    /// @notice Set per-swap and per-epoch value-loss limits.
    function setMaxValueLossBps(uint256 newMaxValueLossBps, uint256 newEpochBudgetBps)
        external
        onlyOwnerNotBlacklisted
    {
        SwapExecutionLib.setMaxValueLossBps(
            _getBucketVaultBaseStorage().maxValueLossBps, newMaxValueLossBps, newEpochBudgetBps
        );
    }

    /// @notice Return the current per-swap value-loss limit.
    function maxValueLossBps() public view returns (uint256) {
        uint256 bps = _getBucketVaultBaseStorage().maxValueLossBps.bps;
        return bps == 0 ? MAX_VALUE_LOSS_BPS : bps;
    }

    /// @notice Return the current per-epoch value-loss budget.
    function epochValueLossBudgetBps() public view returns (uint256) {
        uint256 bps = _getBucketVaultBaseStorage().maxValueLossBps.epochBudgetBps;
        return bps == 0 ? EPOCH_VALUE_LOSS_BUDGET_BPS : bps;
    }

    /// @dev Calculate the minimum output for a stable-token redemption leg.
    function _minReturnForStableLeg(address srcToken, address dstToken, uint256 amount, uint256 maxSlippageBps)
        internal
        view
        returns (uint256 minReturn)
    {
        return SwapExecutionLib.minReturnForStableLeg(_bucketInfo(), srcToken, dstToken, amount, maxSlippageBps);
    }

    /// @dev Enforce caller and global swap cooldowns.
    function _enforceSwapCooldown(address caller) internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        SwapExecutionLib.enforceSwapCooldown($.swapCooldown, caller);
    }

    /// @dev Add a token to the held set if its balance is positive.
    function _registerHeldToken(address token) internal {
        if (_getTokenBalance(token) > 0) {
            _getBucketVaultBaseStorage().heldTokens.add(token);
        }
    }

    /// @dev Update held status from the current token balance.
    function _syncHeldTokenByBalance(address token) internal {
        PayoutLib.syncHeldTokenByBalance(_getBucketVaultBaseStorage().heldTokens, token);
    }

    /// @dev Update held status for every whitelisted token.
    function _syncAllHeldTokensFromWhitelist() internal {
        PayoutLib.syncAllHeldTokensFromWhitelist(
            _getBucketVaultBaseStorage().heldTokens, _bucketInfo().getWhitelistedTokens()
        );
    }

    /// @notice Return the number of held tokens.
    function heldTokensCount() external view returns (uint256) {
        return _getBucketVaultBaseStorage().heldTokens.length();
    }

    /// @notice Return the held token at an index.
    function heldTokenAt(uint256 index) external view returns (address) {
        return _getBucketVaultBaseStorage().heldTokens.at(index);
    }

    /// @notice Whether a token is currently held.
    function isHeldToken(address token) external view returns (bool) {
        return _getBucketVaultBaseStorage().heldTokens.contains(token);
    }

    /// @notice Return all currently held tokens.
    function getHeldTokens() external view returns (address[] memory) {
        return _getBucketVaultBaseStorage().heldTokens.values();
    }

    /// @dev Return all held tokens for internal callers.
    function _heldTokensList() internal view returns (address[] memory) {
        return _getBucketVaultBaseStorage().heldTokens.values();
    }

    /// @notice Return the cached aggregate outpriced status.
    function isAnyHeldTokenPotentiallyOutpriced() external view returns (bool) {
        return _getBucketVaultBaseStorage().outpricedTracker.lastKnownOutpriced;
    }

    /// @notice Return held tokens whose feeds may be outpriced.
    function getOutpricedHeldTokens() external view returns (address[] memory) {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        return OraclePricingLib.getOutpricedHeldTokens(_bucketInfo(), $.heldTokens);
    }

    /// @notice Return held tokens without a Chainlink feed.
    function getManualPricedHeldTokens() external view returns (address[] memory) {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        return OraclePricingLib.getManualPricedHeldTokens(_bucketInfo(), $.heldTokens);
    }

    /// @dev Update the cached aggregate outpriced status.
    function _syncOutpricedStatus() internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        OraclePricingLib.syncOutpricedStatus($.outpricedTracker, _bucketInfo(), $.heldTokens);
    }

    /// @dev Transfer redemption payouts and update held-token status.
    function _payoutAndSync(address to, address[] memory tokens, uint256[] memory returnAmounts) internal {
        PayoutLib.payoutAndSync(_getBucketVaultBaseStorage().heldTokens, to, tokens, returnAmounts);
    }

    /**
     * @notice Redeem shares for a single destination token.
     */
    function redeemForStable(uint256 shares, address dstToken, uint256 maxSlippageBps)
        external
        nonReentrant
        whenNotPaused
        whenPlatformOperational
        whenSwapNotPaused
        returns (uint256 totalStableOut)
    {
        if (!_bucketInfo().isTokenValid(dstToken)) revert InvalidToken(dstToken);

        bool isOwnerCaller = (msg.sender == owner());
        if (isOwnerCaller && !isBucketAccountable()) revert OwnerNotAccountable();

        (address[] memory tokens, uint256[] memory amounts) = _previewRedeemCore(shares);

        _burn(msg.sender, shares);

        _enforceSwapCooldown(msg.sender);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;

            if (tokens[i] == dstToken) {
                totalStableOut += amount;
                continue;
            }

            uint256 legMinReturn = _minReturnForStableLeg(tokens[i], dstToken, amount, maxSlippageBps);
            _validateSwapLeg(tokens[i], dstToken, amount, legMinReturn);

            uint256 dstBalBefore = _getTokenBalance(dstToken);
            _executeSwapNoCooldown(tokens[i], dstToken, amount, legMinReturn);
            uint256 received = _getTokenBalance(dstToken) - dstBalBefore;

            if (received < legMinReturn) revert ReceivedBelowMinReturn(received, legMinReturn);

            totalStableOut += received;
            _syncHeldTokenByBalance(tokens[i]);
        }

        if (totalStableOut == 0) revert NothingToRedeem();

        _transferToken(dstToken, msg.sender, totalStableOut);
        _syncHeldTokenByBalance(dstToken);
        emit TokenReturned(msg.sender, dstToken, totalStableOut);

        if (isOwnerCaller && !isBucketAccountable()) revert OwnerNotAccountable();

        emit RedeemedForStable(msg.sender, shares, totalSupply(), dstToken, totalStableOut, tokens, amounts);
        _syncOutpricedStatus();
    }
}

