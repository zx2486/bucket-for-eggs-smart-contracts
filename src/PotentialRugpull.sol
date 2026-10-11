// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {TimelockedAdmin} from "./libs/TimelockedAdmin.sol";
import {SeizureLib} from "./libraries/SeizureLib.sol";
import {PayoutLib} from "./libraries/PayoutLib.sol";
import {GovernanceLib} from "./libraries/GovernanceLib.sol";

// ============================================================
// @title PotentialRugpull
// @notice A deliberately permissive vault: the owner can freely deposit, trade off-chain, and
// withdraw Chainlink-priced tokens with no on-chain portfolio or swap logic, in exchange for one
// guarantee to investors — a minimum "cash floor" of investor-deposited value, set by `cashRatio`
// (10-90%), that owner withdrawals may never breach. The owner reports total portfolio value
// manually via {setAssertedPortfolioValue}; token price is derived from that value divided by
// total shares. Users are expected to understand they are trusting the owner's off-chain conduct,
// relying solely on the cash-floor protection — hence the contract's name.
//
// Non-upgradeable by design, with a single-parameter constructor (`cashRatio`). The `BucketInfo`
// pointer, owner address, and token name/symbol are set once by the factory via {initialize}
// immediately after deployment, in the same transaction.
// ============================================================
contract PotentialRugpull is ERC20, ERC20Burnable, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========================================================
    // Errors
    // ========================================================
    error ZeroAddress();
    error ZeroAmount();
    error OnlyFactory();
    error AlreadyInitialized();
    error PlatformNotOperational();
    error InvalidToken(address token);
    error InvalidCashRatio(uint256 cashRatio);
    error InsufficientShares();
    error InvalidRedeemAmount();
    error NothingToRedeem();
    error ETHTransferFailed();
    error RenounceOwnershipDisabled();
    error Blacklisted(address account);
    error OwnerWithdrawalFloorBreached(uint256 remaining, uint256 required);
    error ZeroPortfolioValue();

    /// @dev Selector-identical to `GovernanceLib`'s own `UnauthorizedBucketInfoUpdate()` — a
    /// library cannot revert with an error it did not itself declare, and Solidity matches custom
    /// errors by selector (name + arg types), not by declaring contract.
    error UnauthorizedBucketInfoUpdate();

    // ========================================================
    // Events
    // ========================================================
    event Initialized(address indexed bucketInfo, address indexed owner, string name, string symbol);
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 valueUsd8);
    event Redeemed(address indexed user, uint256 shares18, address[] tokens, uint256[] amounts);
    event OwnerDeposited(address indexed owner, address indexed token, uint256 amount);
    event OwnerWithdrawn(address indexed owner, address indexed token, uint256 amount, uint256 valueUsd8);
    event AssertedPortfolioValueUpdated(uint256 oldValueUsd8, uint256 newValueUsd8);
    event TokenReturned(address indexed user, address indexed token, uint256 amount);

    /// @dev Selector-identical to `GovernanceLib`'s own `BucketInfoUpdateProposed(...)` — see that
    /// library's header comment for why these must match the emitting library's declaration.
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed newBucketInfo, address indexed proposedBy, uint256 eta
    );
    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);

    // ========================================================
    // Constants
    // ========================================================
    /// @dev Share arithmetic scale (18-decimal). Never conflate with `PRICE_DECIMALS8`.
    uint256 internal constant PRECISION = 1e18;

    /// @dev USD/price fixed-point scale — matches `IBucketInfo.PRICE_DECIMALS()` (8).
    uint256 internal constant PRICE_DECIMALS8 = 1e8;

    /// @dev Default asserted portfolio value — one whole USD at 8-decimal scale.
    uint256 internal constant DEFAULT_PORTFOLIO_VALUE_USD8 = 1e8;

    /// @dev Default share amount minted to the owner at initialization — one whole share at
    /// 18-decimal scale, keeping totalSupply() away from zero.
    uint256 internal constant DEFAULT_SHARE_AMOUNT = 1e18;

    /// @dev Allowed inclusive range for cashRatio.
    uint256 internal constant MIN_CASH_RATIO = 10;
    uint256 internal constant MAX_CASH_RATIO = 90;
    uint256 internal constant CASH_RATIO_DENOMINATOR = 100;

    // ========================================================
    // Immutables
    // ========================================================
    /// @notice The cash-floor protection ratio (10-90), set once at construction and immutable.
    uint256 public immutable cashRatio;

    /// @notice The factory that deployed this instance, captured from `msg.sender` at construction
    /// time. Used solely to gate the one-shot {initialize} call that follows in the same
    /// transaction.
    address public immutable FACTORY;

    // ========================================================
    // Storage
    // ========================================================
    /// @notice The platform-owned `BucketInfo` instance this vault defers to for whitelisting,
    /// pricing, the kill switch, and the blacklist. Set exactly once, inside {initialize}, from a
    /// value the factory supplies, never from this contract's own constructor.
    IBucketInfo public bucketInfo;

    /// @notice True once {initialize} has run; latches it as one-shot.
    bool public initialized;

    /// @notice Owner-asserted total portfolio value, USD 8-decimal. Defaults to
    /// `DEFAULT_PORTFOLIO_VALUE_USD8` (1 USD) at {initialize} time and is settable thereafter only
    /// by the owner via {setAssertedPortfolioValue}.
    uint256 public assertedPortfolioValue;

    /// @notice Live ledger of the USD-8-decimal value of deposits made by non-owner callers, net of
    /// proportional reductions on their redemptions. Not decremented by {ownerWithdraw}.
    uint256 public netInvestorDeposits;

    /// @notice Cumulative USD-8-decimal value the owner has withdrawn via {ownerWithdraw}.
    /// Monotonically increasing; used with {netInvestorDeposits} to derive the remaining cushion.
    uint256 public ownerWithdrawnValueUsd8;

    /// @dev Per-instance name/symbol, set once in {initialize} and returned by the overridden
    /// {name}/{symbol} getters.
    string private _instanceName;
    string private _instanceSymbol;

    /// @dev Tokens currently held by the contract with a nonzero balance.
    EnumerableSet.AddressSet private heldTokens;

    /// @dev Pending seizure requests, keyed by the blacklisted account.
    mapping(address => TimelockedAdmin.SeizureTimelock) private seizureTimelocks;

    /// @dev Delay between proposing and executing a compliance seizure.
    uint256 internal constant SEIZURE_TIMELOCK_DELAY = 48 hours;

    /// @dev Pending BucketInfo-repoint proposal, if any. See the "updateBucketInfo" section below.
    TimelockedAdmin.AddressTimelock private bucketInfoUpdateTimelock;

    /// @dev Propose→execute delay for {proposeUpdateBucketInfo}. Reuses the same 48-hour figure as
    /// the vaults' equivalent (`BucketVaultBase.BUCKET_INFO_UPDATE_TIMELOCK_DELAY`) and the seizure
    /// delay above — one platform-wide number, not an unexplained new one.
    uint256 public constant BUCKET_INFO_UPDATE_TIMELOCK_DELAY = 48 hours;

    // ========================================================
    // Modifiers
    // ========================================================
    modifier onlyFactory() {
        if (msg.sender != FACTORY) revert OnlyFactory();
        _;
    }

    modifier whenPlatformOperational() {
        if (!bucketInfo.isPlatformOperational()) revert PlatformNotOperational();
        _;
    }

    /// @dev Blocks blacklisted callers from owner actions that don't mint or burn shares, so they
    /// aren't caught by the {_update} transfer hook.
    modifier whenCallerNotBlacklisted() {
        _assertNotBlacklisted(msg.sender);
        _;
    }

    // ========================================================
    // Constructor + initialize
    // ========================================================
    /// @notice Constructor takes only the cash-floor ratio (10-90). `name`/`symbol` are set later
    /// via {initialize}; `Ownable` is given the factory as a transient owner, immediately replaced
    /// by the real customer inside {initialize} in the same transaction.
    constructor(uint256 cashRatio_) ERC20("", "") Ownable(msg.sender) {
        if (cashRatio_ < MIN_CASH_RATIO || cashRatio_ > MAX_CASH_RATIO) revert InvalidCashRatio(cashRatio_);
        cashRatio = cashRatio_;
        FACTORY = msg.sender;
    }

    /// @notice One-shot, factory-only setup completing what the single-variable constructor could
    /// not: the real `BucketInfo` pointer, the real owner, and this instance's name/symbol. Must be
    /// called by the factory in the same transaction as construction.
    /// @dev `bucketInfoAddr_` comes from the factory, never from a value this contract's own
    /// constructor accepted, so a vault cannot be pointed at a counterfeit `BucketInfo`.
    function initialize(address bucketInfoAddr_, address owner_, string calldata name_, string calldata symbol_)
        external
        onlyFactory
    {
        if (initialized) revert AlreadyInitialized();
        if (bucketInfoAddr_ == address(0) || owner_ == address(0)) revert ZeroAddress();

        initialized = true;
        bucketInfo = IBucketInfo(bucketInfoAddr_);
        _instanceName = name_;
        _instanceSymbol = symbol_;
        assertedPortfolioValue = DEFAULT_PORTFOLIO_VALUE_USD8;

        _transferOwnership(owner_);

        // Minted directly to owner_ here, not in the constructor, since msg.sender in the
        // constructor would resolve to the factory, not the real customer.
        _mint(owner_, DEFAULT_SHARE_AMOUNT);

        emit Initialized(bucketInfoAddr_, owner_, name_, symbol_);
    }

    // ========================================================
    // name()/symbol() overrides — per-instance values set once in {initialize}
    // ========================================================
    function name() public view virtual override returns (string memory) {
        return _instanceName;
    }

    function symbol() public view virtual override returns (string memory) {
        return _instanceSymbol;
    }

    // ========================================================
    // Views — oracle-value helpers used by deposit/redeem/ownerWithdraw below
    // ========================================================
    /// @dev USD-8-decimal value of `amount` of `token`. Reverts on an invalid or stale price
    /// rather than silently valuing it at zero.
    function _tokenValueUsd8(address token, uint256 amount, uint256 tokenDecimals) internal view returns (uint256) {
        uint256 price8 = bucketInfo.getTokenPrice(token);
        return (amount * price8) / (10 ** tokenDecimals);
    }

    function _tokenDecimals(address token) internal view returns (uint256) {
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    function _tokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Only Chainlink-priced, whitelisted tokens are accepted — manually-priced tokens are
    /// rejected, unlike in the other vaults.
    function _requireChainlinkPriced(address token) internal view {
        if (!bucketInfo.isTokenValid(token)) revert InvalidToken(token);
        if (bucketInfo.getPriceFeed(token) == address(0)) revert InvalidToken(token);
    }

    /// @notice Current share price, USD-8-decimal per whole share. Defaults to 1 USD when supply is
    /// zero. The numerator is the owner-asserted portfolio value, not a balance-derived NAV.
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return DEFAULT_PORTFOLIO_VALUE_USD8;
        uint256 price = (assertedPortfolioValue * PRECISION) / supply;
        return price == 0 ? DEFAULT_PORTFOLIO_VALUE_USD8 : price;
    }

    /// @notice The minimum cash floor that must remain after an owner withdrawal:
    /// `cashRatio * max(assertedPortfolioValue, netInvestorDeposits) / 100`. Anchored to real
    /// investor deposit activity rather than the owner's withdrawal history, so it cannot be
    /// eroded by the owner's own repeated withdrawals.
    function ownerWithdrawalFloorRequired() public view returns (uint256) {
        uint256 denominator =
            assertedPortfolioValue > netInvestorDeposits ? assertedPortfolioValue : netInvestorDeposits;
        return (cashRatio * denominator) / CASH_RATIO_DENOMINATOR;
    }

    /// @dev Shared cushion arithmetic for a hypothetical owner withdrawal, used by both
    /// {isBucketAboveCashLevel} and {ownerWithdraw}.
    function _ownerWithdrawalCushionAfter(uint256 withdrawValueUsd8)
        internal
        view
        returns (uint256 remaining, uint256 required)
    {
        required = ownerWithdrawalFloorRequired();
        uint256 cushion =
            netInvestorDeposits > ownerWithdrawnValueUsd8 ? netInvestorDeposits - ownerWithdrawnValueUsd8 : 0;
        remaining = cushion > withdrawValueUsd8 ? cushion - withdrawValueUsd8 : 0;
    }

    /// @notice Previews whether an owner withdrawal worth `withdrawValueUsd8` would still leave the
    /// cash floor intact, without performing the withdrawal.
    /// @param withdrawValueUsd8 USD-8-decimal value of the hypothetical withdrawal.
    /// @return True if the remaining cushion would still meet the required floor.
    function isBucketAboveCashLevel(uint256 withdrawValueUsd8) public view returns (bool) {
        (uint256 remaining, uint256 required) = _ownerWithdrawalCushionAfter(withdrawValueUsd8);
        return remaining >= required;
    }

    // ========================================================
    // Investor deposit / redeem
    // ========================================================
    // Deliberately NOT unified with {BucketVaultBase._processDeposit} / {_previewRedeemCore}
    // (shared by ActiveBucket/PassiveBucket): this contract doesn't inherit BucketVaultBase, and
    // the accounting itself differs, not just the inheritance tree. Deposit here prices against a
    // live {sharePrice} call rather than a cached tokenPrice snapshot, has no DEAD_SHARES
    // first-deposit mitigation, and maintains `netInvestorDeposits` — a ledger the vaults don't
    // have, needed only for this contract's cash-floor rug-pull guard. Forcing a shared function
    // would mean changing one accounting model to match the other, which is a behaviour change,
    // not a dedup.
    /// @notice Deposit a Chainlink-priced, whitelisted token and mint shares at the current
    /// {sharePrice}. Increments {netInvestorDeposits} by the USD value deposited.
    function deposit(address token, uint256 amount) external payable nonReentrant whenPlatformOperational {
        if (amount == 0) revert ZeroAmount();
        _requireChainlinkPriced(token);

        address depositor = msg.sender;
        uint256 decimals = _tokenDecimals(token);

        if (token == address(0)) {
            if (msg.value != amount) revert ZeroAmount();
        } else {
            IERC20(token).safeTransferFrom(depositor, address(this), amount);
        }

        uint256 valueUsd8 = _tokenValueUsd8(token, amount, decimals);
        if (valueUsd8 == 0) revert ZeroAmount();

        uint256 price8 = sharePrice();
        uint256 shares18 = (valueUsd8 * PRECISION) / price8;
        if (shares18 == 0) revert ZeroAmount();

        netInvestorDeposits += valueUsd8;
        PayoutLib.syncHeldTokenByBalance(heldTokens, token);
        _mint(depositor, shares18);

        emit Deposited(depositor, token, amount, valueUsd8);
    }

    /// @notice Lets the owner deposit a Chainlink-priced token without minting shares. Does not
    /// affect {netInvestorDeposits}, which tracks non-owner deposits only.
    function ownerDeposit(address token, uint256 amount)
        external
        payable
        nonReentrant
        whenPlatformOperational
        onlyOwner
        whenCallerNotBlacklisted
    {
        if (amount == 0) revert ZeroAmount();
        _requireChainlinkPriced(token);

        if (token == address(0)) {
            if (msg.value != amount) revert ZeroAmount();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        PayoutLib.syncHeldTokenByBalance(heldTokens, token);
        emit OwnerDeposited(msg.sender, token, amount);
    }

    /// @notice Redeem shares for a pro-rata slice of every token held by the contract. Reduces
    /// {netInvestorDeposits} proportionally to the non-owner shares burned; the owner's own shares
    /// do not affect this ledger.
    function redeem(uint256 shares18) external nonReentrant whenPlatformOperational {
        address redeemer = msg.sender;
        if (shares18 == 0) revert ZeroAmount();
        uint256 callerBalance = balanceOf(redeemer);
        if (shares18 > callerBalance) revert InsufficientShares();

        uint256 supplyBefore = totalSupply();
        if (supplyBefore == 0) revert NothingToRedeem();

        uint256[] memory amounts;
        address[] memory tokens = heldTokens.values();
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 bal = _tokenBalance(tokens[i]);
            amounts[i] = (bal * shares18) / supplyBefore;
        }

        // Reduce the ledger proportionally to non-owner shares burned; owner redemptions don't
        // affect it.
        if (redeemer != owner()) {
            uint256 ownerBalance = balanceOf(owner());
            uint256 investorSharesBefore = supplyBefore > ownerBalance ? supplyBefore - ownerBalance : 0;
            if (investorSharesBefore > 0) {
                uint256 delta = (netInvestorDeposits * shares18) / investorSharesBefore;
                netInvestorDeposits = netInvestorDeposits > delta ? netInvestorDeposits - delta : 0;
            }
        }

        _burn(redeemer, shares18);
        PayoutLib.payoutAndSync(heldTokens, redeemer, tokens, amounts);

        emit Redeemed(redeemer, shares18, tokens, amounts);
    }

    // ========================================================
    // Owner withdraw / asserted portfolio value
    // ========================================================
    /// @notice Lets the owner withdraw tokens freely, as long as the remaining cushion of investor
    /// deposits stays above the cashRatio floor — the contract's core rug-pull protection.
    function ownerWithdraw(address token, uint256 amount)
        external
        nonReentrant
        whenPlatformOperational
        onlyOwner
        whenCallerNotBlacklisted
    {
        if (amount == 0) revert ZeroAmount();
        uint256 balBefore = _tokenBalance(token);
        if (amount > balBefore) revert InsufficientShares();

        uint256 decimals = _tokenDecimals(token);
        uint256 withdrawValueUsd8 = _tokenValueUsd8(token, amount, decimals);

        // Checked against the remaining cushion (net investor deposits minus what the owner has
        // already withdrawn), not against netInvestorDeposits directly, so the floor cannot be
        // ratcheted down by the owner's own withdrawals.
        (uint256 remaining, uint256 required) = _ownerWithdrawalCushionAfter(withdrawValueUsd8);
        if (remaining < required) revert OwnerWithdrawalFloorBreached(remaining, required);

        ownerWithdrawnValueUsd8 += withdrawValueUsd8;

        address ownerAddr = owner();
        if (token == address(0)) {
            (bool success,) = ownerAddr.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(ownerAddr, amount);
        }
        PayoutLib.syncHeldTokenByBalance(heldTokens, token);

        emit OwnerWithdrawn(ownerAddr, token, amount, withdrawValueUsd8);
    }

    /// @notice Lets the owner set the asserted total portfolio value used to price shares. Must be
    /// nonzero, since zero would be indistinguishable from the share-price zero-state fallback.
    function setAssertedPortfolioValue(uint256 newValueUsd8) external onlyOwner whenCallerNotBlacklisted {
        if (newValueUsd8 == 0) revert ZeroPortfolioValue();
        uint256 old = assertedPortfolioValue;
        assertedPortfolioValue = newValueUsd8;
        emit AssertedPortfolioValueUpdated(old, newValueUsd8);
    }

    // ========================================================
    // Blacklist-gated transfer hook — fails closed: if BucketInfo cannot be reached, the account is
    // treated as blacklisted rather than allowed through.
    // ========================================================
    function _isBlacklistedFailClosed(address account) internal view returns (bool) {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            return blacklisted;
        } catch {
            return true;
        }
    }

    function _assertNotBlacklisted(address account) internal view {
        if (_isBlacklistedFailClosed(account)) revert Blacklisted(account);
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) _assertNotBlacklisted(from);
        if (to != address(0)) _assertNotBlacklisted(to);
        super._update(from, to, value);
    }

    // ========================================================
    // Compliance seizure — lets the platform recover tokens from a blacklisted account after a
    // timelock, delegated to {SeizureLib}.
    // ========================================================
    function proposeSeizure(address account, address to, bytes32 documentHash) external {
        SeizureLib.proposeSeizure(seizureTimelocks, bucketInfo, account, to, documentHash, SEIZURE_TIMELOCK_DELAY);
    }

    function cancelSeizure(address account) external {
        SeizureLib.cancelSeizure(seizureTimelocks, bucketInfo, account);
    }

    function executeSeizure(address account) external {
        uint256 beforeBalance = balanceOf(account);
        address to = SeizureLib.executeSeizure(seizureTimelocks, bucketInfo, account, beforeBalance);
        // Bypasses the normal {_update} blacklist check deliberately: `account` is blacklisted by
        // construction of a valid seizure, so the transfer must be allowed to proceed.
        super._update(account, to, beforeBalance);
    }

    function pendingSeizure(address account) external view returns (address to, bytes32 documentHash, uint256 eta) {
        TimelockedAdmin.SeizureTimelock storage t = seizureTimelocks[account];
        return (t.to, t.documentHash, t.eta);
    }

    // ========================================================
    // updateBucketInfo — propose (BucketInfo owner) + timelock + veto (this contract's owner) +
    // permissionless execute. Mirrors BucketVaultBase's equivalent section exactly, delegated to
    // the same {GovernanceLib}; this contract doesn't inherit BucketVaultBase (see the deposit/
    // redeem header comment above) so the wrapper functions and the timelock slot live here
    // directly instead of behind a shared base. There is no `_setBucketInfo` virtual hook to call
    // back into — {bucketInfo} is a plain public state variable, so {executeUpdateBucketInfo}
    // assigns it directly with the address {GovernanceLib} returns.
    // ========================================================
    function proposeUpdateBucketInfo(address newBucketInfo) external {
        GovernanceLib.proposeUpdateBucketInfo(
            bucketInfoUpdateTimelock, bucketInfo, newBucketInfo, BUCKET_INFO_UPDATE_TIMELOCK_DELAY
        );
    }

    function vetoUpdateBucketInfo() external onlyOwner whenCallerNotBlacklisted {
        GovernanceLib.vetoUpdateBucketInfo(bucketInfoUpdateTimelock);
    }

    function executeUpdateBucketInfo() external {
        address oldBucketInfo = address(bucketInfo);
        address newBucketInfo = GovernanceLib.executeUpdateBucketInfo(bucketInfoUpdateTimelock, oldBucketInfo);
        bucketInfo = IBucketInfo(newBucketInfo);
    }

    function pendingBucketInfoUpdate() external view returns (address pending, uint256 eta) {
        return (bucketInfoUpdateTimelock.pending, bucketInfoUpdateTimelock.eta);
    }

    // ========================================================
    // renounceOwnership is disabled — ownership must always be transferable, never abandoned.
    // ========================================================
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }
}
