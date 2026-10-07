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

// ============================================================
// PotentialRugpull — W5.1 / SC-8 (task #63).
//
// Client's own spec, verbatim (`00-EXECUTIVE-SUMMARY-USER-REPLY.md:15`): "We plan to create a new
// contract called PotentialRugpull contract. The constructor will only take one variable
// (cashRatio, 10-90). Users can deposit or withdraw in a similar way of ActiveBucket, but
// Chainlink pricefeed tokens are allowed. There is not any portfolio or swap in this contract.
// Contract owner can set arbitrary portfolio value of the contract, token price will be updated
// by (portfolio value)/(contract token amount). The default portfolio value will be 1 USD and
// default contract token amount is also 1 (hold by the contract owner). Contract owner can
// withdraw investor deposited tokens to their own wallet, but the remaining investor deposited
// token total should be larger or equal to cashRatio*(portfolio value)/100. Contract owner can
// also deposit Chainlink pricefeed tokens without issuing new contract tokens. The target is let
// contract owner to build and trade as they wish without limitations but have some kind of
// unsuccessful protection (cashRatio). This is why it is called PotentialRugpull contracts. Users
// will be fully warned before joining such contracts."
//
// ============================================================
// DECISION 1 — architecture: NON-UPGRADEABLE, constructor takes ONLY `cashRatio_`.
// ============================================================
// The client's wording is a literal, specific technical constraint, not a loose description --
// "The constructor will only take one variable" rules out the UUPS-proxy-plus-initialize shape
// `ActiveBucket`/`PassiveBucket`/`PureMembership` all use (their real constructors always take at
// least a `registry_` address; business parameters are set via a separate `initialize`, which the
// client's sentence does not exempt). Corroborating, independent evidence from source (not just
// the client's wording): `IImplementationRegistry.Kind` (`src/interfaces/IImplementationRegistry.sol:23-27`)
// enumerates exactly `{ActiveBucket, PassiveBucket, PureMembership}` -- THREE members, no
// `PotentialRugpull` -- meaning the platform-whitelisted-implementation + customer-triggered
// 48-hour-timelock upgrade machinery (W3.3/W3.10) was never extended to cover this contract. Two
// independent signals pointing the same way is why this is implemented, not escalated-and-blocked.
//
// Problem: a non-upgradeable contract whose constructor takes only `cashRatio_` still needs (a) an
// immutable pointer to the real, platform-owned `BucketInfo` (never caller-suppliable, per root
// CLAUDE.md §1.1's precondition analysis -- "a customer can create a vault pointing at a
// BucketInfo they wrote... Make it factory-immutable"), (b) a real owner address (the customer who
// called the factory, not the factory itself), and (c) per-instance ERC-20 name/symbol (so
// multiple deployed PotentialRugpull instances are distinguishable in a wallet UI -- every other
// vault's factory takes `name`/`symbol` as caller params; losing that here purely because of the
// one-variable constructor rule would be a usability regression nothing in the client's wording
// asks for).
//
// RESOLUTION — Uniswap-V3-style deferred-parameter pattern: the constructor captures
// `FACTORY = msg.sender` (derived, not a parameter -- does not violate "one variable"). The
// factory calls a ONE-SHOT, factory-only `initialize(bucketInfoAddr_, owner_, name_, symbol_)`
// immediately after `new PotentialRugpull(cashRatio_)` returns, in the SAME transaction. This:
//   - sets the immutable-after-first-call `bucketInfo` pointer from a value the FACTORY supplies
//     (constructor-immutable in the factory itself, per W1.7's precedent), never from a vault
//     constructor parameter the customer could substitute;
//   - mints the default `DEFAULT_SHARE_AMOUNT` shares directly to `owner_` (the real customer).
//     ⚠ Self-caught design bug, fixed before any code existed: minting inside the CONSTRUCTOR to
//     `msg.sender` would mint to the FACTORY (since `new PotentialRugpull(...)` is called BY the
//     factory, `msg.sender` inside the constructor is the factory's address, not the customer's).
//     There is no other mechanism that would later move an ERC-20 balance from factory to
//     customer -- `transferOwnership` moves `Ownable` ownership only, never token balances. Hence
//     minting is deferred to `initialize`, where the real `owner_` is an explicit parameter;
//   - calls `_transferOwnership(owner_)`;
//   - sets per-instance `name`/`symbol` via STORAGE (not OZ's constructor-set immutable-ish
//     private strings): `ERC20`'s own `name()`/`symbol()` are `public virtual`, so this contract
//     calls the base constructor with placeholder empty strings and overrides both getters to
//     return instance-specific storage set once in `initialize` -- preserving the literal "one
//     constructor variable" rule while still giving every instance a distinct, wallet-visible
//     name, which no client answer ever asked to sacrifice.
//
// ============================================================
// DECISION 2 — R1 lockout hazard, resolved for THIS contract's floor DIFFERENTLY from N5, with
// the structural reason recorded (root CLAUDE.md hard rule 5: contradict the plan with evidence).
// ============================================================
// Task #63's own brief instructs mirroring "the LIVE-ratio resolution SC-2 already chose for N5"
// (`BucketVaultBase.sol:963-971`, `isOwnerWithdrawalFloorMet`: `balanceOf(owner())/totalSupply()
// >= floorBps`) rather than a never-decremented lifetime accumulator (R1,
// `09-DECISION-LOG.md:428-458`). That LIVE-RATIO *shape* is correct to borrow -- "live, not
// lifetime" is the actual lesson of R1 -- but N5's exact FORMULA cannot be reused literally here,
// and shipping it literally would make the floor a no-op:
//   - N5's check gates the OWNER REDEEMING THEIR OWN SHARES. Redeeming shares changes
//     `balanceOf(owner())` and `totalSupply()` TOGETHER, so the ratio moves in response to the
//     exact action being gated.
//   - PotentialRugpull's floor gates `ownerWithdraw`, which pulls arbitrary ERC-20 TOKENS directly
//     off this contract's balance sheet -- NO shares are burned, so `balanceOf(owner())` and
//     `totalSupply()` are COMPLETELY UNCHANGED by the action the floor is supposed to restrict. A
//     share-ratio check would read identically before and after any `ownerWithdraw`, so it would
//     never actually block a drain -- a vacuous "protection" on the one contract whose entire
//     stated purpose (client: "some kind of unsuccessful protection (cashRatio). This is why it is
//     called PotentialRugpull") is that this check does something.
//
// RESOLUTION: implement the floor as a LIVE (never a lifetime-monotonic) USD-value ledger,
// `netInvestorDeposits` (8-decimal, matching `PRICE_DECIMALS`), that DOES move in direct response
// to `ownerWithdraw`:
//   - incremented by a non-owner `deposit`'s USD value (A3, `09-DECISION-LOG.md §3.4`: "the
//     accumulated USD value of deposits not made by the owner" -- owner's own non-minting deposits
//     via `ownerDeposit` are excluded, matching A3 exactly);
//   - decremented, proportionally to shares burned over pre-burn non-owner shares, on `redeem`
//     (so a full investor exit drains it back toward zero instead of leaving a stale historical
//     peak -- this is the actual R1 fix: nothing here can ever lock the owner out, because the gate
//     and the ledger both shrink together as investors leave);
//   - decremented by the exact USD value pulled out, floored at zero, on EVERY `ownerWithdraw`
///    (this is what makes the floor non-vacuous: the ledger the next check reads is strictly lower
//     immediately after a withdrawal that spent it down).
// D1 (`04-CONTRACTS-IMPLEMENTATION-PLAN.md:50`) is honoured by gating against
// `cashRatio * max(assertedPortfolioValue, netInvestorDeposits) / 100` using the PRE-withdrawal
// `netInvestorDeposits` in the `max()` -- so the owner cannot shrink the floor by lowering the
// asserted value first.
// ⚠ FLAGGED FOR CONFIRMATION, not silently decided as final (root CLAUDE.md hard rule 9): this is
// a reasoned, cited deviation from the task brief's literal instruction to mirror N5's formula,
// made because mirroring it literally would ship a check that can never fire. See
// `test/PotentialRugpull.t.sol`'s `test_W5R1_NoLockout_*` tests for the proof this ledger does not
// reproduce R1's lockout, and the W5 wave report's "Corrections to my briefing" section.
//
// ⚠ SEPARATE EDGE CASE, ALSO FLAGGED, NOT SILENTLY RESOLVED: because `ownerWithdrawalFloorRequired`
// takes `max(assertedPortfolioValue, netInvestorDeposits)` and `assertedPortfolioValue` defaults to
// a nonzero `1e8` and can never be set back to zero (`setAssertedPortfolioValue`'s own
// `ZeroPortfolioValue` guard), `required` is NEVER zero, while `remaining` IS zero whenever
// `netInvestorDeposits == 0` (both before any investor has ever deposited, and again after every
// investor has fully exited). The consequence: `ownerWithdraw` unconditionally reverts with
// `OwnerWithdrawalFloorBreached` any time `netInvestorDeposits == 0`, including the owner trying to
// pull back tokens THEY THEMSELVES put in via {ownerDeposit} with zero investors ever involved. Two
// readings both survive the client's exact words ("Contract owner can withdraw investor deposited
// tokens to their own wallet, but the remaining investor deposited token total should be larger or
// equal to cashRatio*(portfolio value)/100", 00:15): (a) this is intentional -- the sentence only
// ever grants the owner a path to withdraw "investor deposited tokens", so if none exist yet there
// is nothing this function is for, and reverting is correct, not a bug; (b) this is overly strict --
// the floor's PURPOSE is to protect investor money, so it should impose no constraint at all when
// there is none to protect, and today's formula accidentally also blocks the owner reclaiming their
// OWN {ownerDeposit}'d tokens, which the client's sentence never said to restrict. Implemented here
// per reading (a) -- the literal text -- rather than silently "fixing" it toward (b) without
// authority. See `test/PotentialRugpull.t.sol`'s `test_OwnerWithdraw_RevertsWhenNoInvestorCushionYet_EdgeCase`
// for the proof this is the shipped behavior, and the W5 wave report's escalations section.
//
// ⚠ THIRD FINDING, caught by running (not just reading) `test/PotentialRugpull.t.sol`: a FULL
// investor exit can never recover 100% of the pool pro-rata. `redeem`'s payout is `(bal *
// shares18) / supplyBefore`, and `supplyBefore` always includes the owner's permanent
// `DEFAULT_SHARE_AMOUNT` (1e18, minted once at {initialize} and never burned in the ordinary
// investor flow) -- so even a redeemer holding 100% of the NON-OWNER shares still divides by a
// `supplyBefore` that is slightly larger than their own balance, leaving a sliver (proportional to
// `ownerShares / totalSupply`) permanently stuck in the contract after every full exit. This is a
// rounding/dilution property of the share-ratio payout formula, not a security bug -- the sliver
// is never lost, it simply sits as unredeemed token balance, discoverable by any later redeemer at
// the current ratio -- but it means `ownerWithdraw` cannot assume the full originally-deposited
// token amount is still sitting in the contract once `netInvestorDeposits` reads back to zero (see
// `test/PotentialRugpull.t.sol`'s `test_W5R1_NoLockout_FloorRelaxesAfterInvestorExit`, which
// originally asserted the stronger, false claim and was corrected after actually running it).
//
// ============================================================
// Other scoped decisions, cited inline at their point of use below:
//   (g).2 -- only Chainlink-priced tokens accepted, both for investor `deposit` and owner
//     `ownerDeposit` (plan `04:239`): enforced via `IBucketInfo.getPriceFeed(token) != address(0)`
//     plus the existing whitelist/validity checks.
//   (g).3 -- default portfolio value 1 USD (`1e8`), default share amount `1e18`, held by the owner
//     from construction (plan `04:240`). ⚠ Correction to the plan's own framing: it calls this
//     "also serves as the inflation-attack dead-share" (same role `DEAD_SHARES` plays elsewhere).
//     That is only partially true here -- the classic ERC-4626 inflation attack works by an
//     attacker DONATING real tokens to inflate a BALANCE-DERIVED NAV denominator; this contract's
//     denominator (`assertedPortfolioValue`) is OWNER-SET, not balance-derived, so donation cannot
//     manipulate it. The 1e18 initial supply still provides the same ROUNDING-SAFETY benefit (never
//     dividing by a near-zero `totalSupply()`), just not via the same attack vector -- recorded as
//     a correction, not silently inherited.
//   W4 compliance ("no matter deposit, withdraw, rebalance, or even transferring the contract
//     tokens", `00-EXECUTIVE-SUMMARY-USER-REPLY.md:19`) applies to this contract exactly as to
//     every other: blacklist-gated `_update` override, platform-owner-gated seizure via
//     {SeizureLib}, `renounceOwnership` disabled (Q14.2, universal).
//   No `Pausable` surface of its own: this contract gates every state-changing entry point on
//     `IBucketInfo.isPlatformOperational()` (the ONE kill switch, root CLAUDE.md §8) rather than
//     inventing a second, locally-owned pause bit nothing asked for.
// ============================================================
contract PotentialRugpull is ERC20, ERC20Burnable, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========================================================
    // Errors — redeclared locally (not imported) for the same reason {SeizureLib}/{PayoutLib}
    // redeclare `ETHTransferFailed`: a library/standalone contract cannot revert with an error it
    // did not itself declare, and this contract does not inherit `BucketVaultBase`.
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

    // ========================================================
    // Constants
    // ========================================================
    /// @dev Share arithmetic scale — identical meaning to `BucketVaultBase.PRECISION`
    /// (`BucketVaultBase.sol:176`). Root CLAUDE.md §6: never conflate with `PRICE_DECIMALS8`.
    uint256 internal constant PRECISION = 1e18;

    /// @dev USD/price fixed-point scale — matches `IBucketInfo.PRICE_DECIMALS()` (8), hardcoded
    /// here as a constant rather than re-queried per call since `BucketInfo.sol:57` fixes it as a
    /// contract-wide constant that has never changed and is not expected to.
    uint256 internal constant PRICE_DECIMALS8 = 1e8;

    /// @dev Default asserted portfolio value: "The default portfolio value will be 1 USD"
    /// (00:15) — one whole USD at 8-decimal scale.
    uint256 internal constant DEFAULT_PORTFOLIO_VALUE_USD8 = 1e8;

    /// @dev Default contract token amount: "default contract token amount is also 1 (hold by the
    /// contract owner)" (00:15) — one whole share at 18-decimal scale. See DECISION comment above
    /// re: this is NOT a classic inflation-attack dead-share (the denominator it protects,
    /// `assertedPortfolioValue`, is owner-set, not balance-derived) but still provides rounding
    /// safety by keeping `totalSupply()` away from zero.
    uint256 internal constant DEFAULT_SHARE_AMOUNT = 1e18;

    /// @dev cashRatio bounds, client-specified inclusive range (00:15): "cashRatio, 10-90".
    uint256 internal constant MIN_CASH_RATIO = 10;
    uint256 internal constant MAX_CASH_RATIO = 90;
    uint256 internal constant CASH_RATIO_DENOMINATOR = 100;

    // ========================================================
    // Immutables
    // ========================================================
    /// @notice The protection ratio (10-90), set once at construction and never changeable
    /// afterward — the client's wording gives no setter for this value, unlike `assertedPortfolioValue`.
    uint256 public immutable cashRatio;

    /// @notice The factory that deployed this instance — captured from `msg.sender` at
    /// construction time (NOT a constructor parameter, so this does not violate the client's
    /// "constructor will only take one variable" constraint). Used solely to gate the one-shot
    /// {initialize} call that follows in the same transaction.
    address public immutable FACTORY;

    // ========================================================
    // Storage
    // ========================================================
    /// @notice The platform-owned `BucketInfo` instance this vault defers to for whitelisting,
    /// pricing, the kill switch, and the blacklist. Set exactly once, inside {initialize}, from a
    /// value the FACTORY supplies (never a value this contract's own constructor accepted) — see
    /// DECISION 1 above and root CLAUDE.md §1.1's factory-immutable-BucketInfo-pointer precondition.
    IBucketInfo public bucketInfo;

    /// @notice True once {initialize} has run; latches it as one-shot.
    bool public initialized;

    /// @notice Owner-asserted total portfolio value, USD 8-decimal. Defaults to
    /// `DEFAULT_PORTFOLIO_VALUE_USD8` (1 USD) at {initialize} time and is settable thereafter only
    /// by the owner via {setAssertedPortfolioValue}.
    uint256 public assertedPortfolioValue;

    /// @notice LIVE (never lifetime-monotonic) ledger of the USD-8-decimal value of deposits made
    /// by non-owner callers, net of proportional reductions on their redemptions. See DECISION 2
    /// above for the full rationale.
    /// ⚠ VERIFIER FIX (2026-10-04): this ledger is deliberately NOT decremented by
    /// {ownerWithdraw} any more -- see the "VERIFIER FIX" block directly above
    /// {ownerWithdrawalFloorRequired} for why decrementing it there was the actual bug, and
    /// {ownerWithdrawnValueUsd8} below for the variable that now carries that role instead.
    uint256 public netInvestorDeposits;

    /// @notice Cumulative USD-8-decimal value the owner has pulled out via {ownerWithdraw} to
    /// date. Monotonically increasing -- never decremented (not even by investor {redeem}; see
    /// the VERIFIER FIX comment on {ownerWithdrawalFloorRequired}'s call site for why a cushion
    /// derived from this and the live {netInvestorDeposits} is the correct non-ratcheting check).
    uint256 public ownerWithdrawnValueUsd8;


    /// @dev Per-instance name/symbol, set once in {initialize}. See DECISION 1 above: `ERC20`'s own
    /// constructor is called with placeholder empty strings; {name}/{symbol} are overridden below
    /// to read these instead.
    string private _instanceName;
    string private _instanceSymbol;

    /// @dev Tokens currently held with nonzero balance — mirrors `BucketVaultBase`'s
    /// `heldTokens` (`BucketVaultBaseStorage.sol:112`), reused here via {PayoutLib} directly rather
    /// than through inheritance (this contract does not inherit `BucketVaultBase`).
    EnumerableSet.AddressSet private heldTokens;

    /// @dev W4 compliance (seizure path) — mirrors `BucketVaultBaseStorage.seizureTimelocks`
    /// (`:140`), reused here via {SeizureLib} directly, same reasoning as `heldTokens` above.
    mapping(address => TimelockedAdmin.SeizureTimelock) private seizureTimelocks;

    /// @dev Seizure timelock delay — identical value and purpose to
    /// `BucketVaultBase.SEIZURE_TIMELOCK_DELAY` (`:566`).
    uint256 internal constant SEIZURE_TIMELOCK_DELAY = 48 hours;

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

    /// @dev Verifier fix (2026-10-04): mirrors `BucketVaultBase.whenCallerNotBlacklisted` /
    /// `PureMembership.whenCallerNotBlacklisted` -- this contract has neither base, so the
    /// modifier is redeclared here too (same reason `_isBlacklistedFailClosed`/
    /// `_assertNotBlacklisted` below are already duplicated rather than inherited). Needed on
    /// {ownerDeposit}, {ownerWithdraw} and {setAssertedPortfolioValue}: none of the three mints or
    /// burns shares, so {_update} structurally never fires for them, same gap class as
    /// `ActiveBucket.swapBy1inch`/`flashLoan` before their W4.2c fix.
    modifier whenCallerNotBlacklisted() {
        _assertNotBlacklisted(msg.sender);
        _;
    }

    // ========================================================
    // Constructor + initialize
    // ========================================================
    /// @notice Client's literal constraint (00:15): "The constructor will only take one variable
    /// (cashRatio, 10-90)." `name`/`symbol` are passed as empty placeholders to the `ERC20` base
    /// constructor — see DECISION 1's name()/symbol() override explanation — and `Ownable`'s
    /// constructor is given `msg.sender` (the FACTORY) as a transient owner, immediately replaced
    /// by the real customer inside {initialize} in the same transaction.
    constructor(uint256 cashRatio_) ERC20("", "") Ownable(msg.sender) {
        if (cashRatio_ < MIN_CASH_RATIO || cashRatio_ > MAX_CASH_RATIO) revert InvalidCashRatio(cashRatio_);
        cashRatio = cashRatio_;
        FACTORY = msg.sender;
    }

    /// @notice One-shot, factory-only setup completing what the single-variable constructor could
    /// not: the real `BucketInfo` pointer, the real owner, and this instance's name/symbol. Must be
    /// called by the factory in the same transaction as construction (see
    /// `PotentialRugpullFactory.createPotentialRugpull`).
    /// @dev `bucketInfoAddr_` comes from the FACTORY, not from any value this contract's own
    /// constructor accepted — satisfying root CLAUDE.md §1.1's factory-immutable-pointer
    /// precondition the same way `implementation` is immutable on the other three factories.
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

        // Default contract token amount: "also 1 (hold by the contract owner)" (00:15). Minted
        // directly to `owner_` here — NOT inside the constructor, where `msg.sender` would resolve
        // to the FACTORY rather than the real customer. See DECISION 1's self-caught-bug note.
        _mint(owner_, DEFAULT_SHARE_AMOUNT);

        emit Initialized(bucketInfoAddr_, owner_, name_, symbol_);
    }

    // ========================================================
    // name()/symbol() overrides — see DECISION 1
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
    /// @dev USD-8-decimal value of `amount` of `token`, via `IBucketInfo.getTokenPrice` (reverts
    /// on invalid/stale/non-positive price — deliberate: (g).2 restricts both deposit paths to
    /// Chainlink-priced tokens only, so an unpriceable token must revert, not silently zero-value).
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

    /// @dev Validates (g).2: only Chainlink-priced tokens are ever accepted, for BOTH the
    /// investor {deposit} path and the owner {ownerDeposit} path (client's exact wording covers
    /// both). `getPriceFeed(token) == address(0)` means "manually priced" per
    /// `IBucketInfo.getPriceFeed`'s own doc comment — rejected here unconditionally, since this
    /// contract (unlike the two existing vaults) never accepts manual pricing at all.
    function _requireChainlinkPriced(address token) internal view {
        if (!bucketInfo.isTokenValid(token)) revert InvalidToken(token);
        if (bucketInfo.getPriceFeed(token) == address(0)) revert InvalidToken(token);
    }

    /// @notice Current share price, USD-8-decimal per whole share — same zero-state fallback rule
    /// as every other vault (root CLAUDE.md §6: `INITIAL_TOKEN_PRICE` is the zero-state default).
    /// Here the "total value" numerator is the OWNER-ASSERTED portfolio value, not a balance-
    /// derived NAV — the defining difference from `ActiveBucket`/`PassiveBucket`'s `sharePrice()`.
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return DEFAULT_PORTFOLIO_VALUE_USD8;
        uint256 price = (assertedPortfolioValue * PRECISION) / supply;
        return price == 0 ? DEFAULT_PORTFOLIO_VALUE_USD8 : price;
    }

    /// @notice The floor an owner withdrawal of `withdrawValueUsd8` must leave intact — see
    /// DECISION 2: `cashRatio * max(assertedPortfolioValue, netInvestorDeposits) / 100`, evaluated
    /// against the CURRENT `netInvestorDeposits` (D1, `04:50`).
    /// ⚠ VERIFIER FIX (2026-10-04), replacing a confirmed bug: this formula is exactly what the
    /// client specified and is UNCHANGED by this fix — the bug was never the formula, it was what
    /// {ownerWithdraw} compared it against. The old code decremented `netInvestorDeposits` itself
    /// by every withdrawal's USD value, so the very next call's `required` was computed from an
    /// already-shrunk `netInvestorDeposits` — a feedback loop. Concretely, with cashRatio = r%,
    /// each max-size withdrawal left `netInvestorDeposits` at `r% * netInvestorDeposits`, so N
    /// repeated max withdrawals left `(r/100)^N * netInvestorDeposits_original` — a geometric
    /// decay toward `assertedPortfolioValue` (which the owner also controls and can set to the
    /// 1 USD minimum), not toward a fixed, protective floor. That is exactly the verifier's claim
    /// ("the floor drops a bit after every owner withdrawal, so repeated withdrawals can drain
    /// investors almost to zero") and it checks out against this source.
    /// The fix: `netInvestorDeposits` now moves ONLY on investor {deposit}/{redeem} (A3's own
    /// definition — "deposits not made by the owner" — never said owner withdrawals should move
    /// it). `required` is therefore anchored to real investor activity, not to the owner's own
    /// withdrawal history, so it cannot be ratcheted down by the very withdrawals it is meant to
    /// cap. {ownerWithdraw} instead checks a derived cushion — see its body.
    function ownerWithdrawalFloorRequired() public view returns (uint256) {
        uint256 denominator =
            assertedPortfolioValue > netInvestorDeposits ? assertedPortfolioValue : netInvestorDeposits;
        return (cashRatio * denominator) / CASH_RATIO_DENOMINATOR;
    }

    // ========================================================
    // Investor deposit / redeem
    // ========================================================
    /// @notice Deposit a Chainlink-priced, whitelisted token. Mints shares at the current
    /// {sharePrice}, mirroring `ActiveBucket`/`PassiveBucket`'s deposit math (money-math rule:
    /// multiply before dividing). Increments {netInvestorDeposits} by the USD value deposited —
    /// DECISION 2's live-ledger increment side.
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

    /// @notice Owner deposits a Chainlink-priced token WITHOUT issuing shares (client, 00:15:
    /// "Contract owner can also deposit Chainlink pricefeed tokens without issuing new contract
    /// tokens"). Deliberately does NOT touch {netInvestorDeposits} — A3's exact wording restricts
    /// that ledger to "deposits not made by the owner."
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

    /// @notice Redeem `shares18` for a pro-rata slice of every held token, mirroring
    /// `ActiveBucket`/`PassiveBucket`'s redeem payout shape via {PayoutLib.payoutAndSync}.
    /// Decrements {netInvestorDeposits} proportionally to the fraction of NON-OWNER shares burned
    /// — DECISION 2's live-ledger decrement side. The owner redeeming their own initial shares
    /// does not touch this ledger at all (owner deposits never minted shares in the first place,
    /// so there is nothing investor-attributable about the owner's own balance).
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

        // Live-ledger decrement, proportional to non-owner shares burned. Owner redeeming does not
        // reduce netInvestorDeposits (A3: the ledger tracks non-owner deposits only).
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
    /// @notice "Contract owner can withdraw investor deposited tokens to their own wallet, but the
    /// remaining investor deposited token total should be larger or equal to
    /// cashRatio*(portfolio value)/100" (00:15) — the contract's defining protection. See
    /// DECISION 2 for the full derivation of why this is checked against the LIVE
    /// {netInvestorDeposits} ledger rather than N5's share-ratio formula.
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

        // VERIFIER FIX (2026-10-04): `required` is read from the now-non-ratcheting
        // `netInvestorDeposits` (see {ownerWithdrawalFloorRequired}'s updated doc comment for the
        // full before/after). The check here is against a CUSHION derived from
        // `netInvestorDeposits - ownerWithdrawnValueUsd8` -- i.e. how much of the investors' net
        // deposited value has NOT already been pulled out by the owner -- rather than against
        // `netInvestorDeposits` itself, which must stay untouched by this function so the next
        // call's `required` cannot be computed from a value this very withdrawal shrank.
        uint256 required = ownerWithdrawalFloorRequired();
        uint256 cushion = netInvestorDeposits > ownerWithdrawnValueUsd8 ? netInvestorDeposits - ownerWithdrawnValueUsd8 : 0;
        uint256 remaining = cushion > withdrawValueUsd8 ? cushion - withdrawValueUsd8 : 0;
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

    /// @notice "Contract owner can set arbitrary portfolio value of the contract" (00:15) — no
    /// bounds beyond nonzero (a zero value would make {sharePrice} divide-by-zero-equivalent via
    /// the zero-state fallback, masking the real asserted value; disallowed outright instead).
    function setAssertedPortfolioValue(uint256 newValueUsd8) external onlyOwner whenCallerNotBlacklisted {
        if (newValueUsd8 == 0) revert ZeroPortfolioValue();
        uint256 old = assertedPortfolioValue;
        assertedPortfolioValue = newValueUsd8;
        emit AssertedPortfolioValueUpdated(old, newValueUsd8);
    }

    // ========================================================
    // W4 compliance — blacklist-gated _update override, mirrors
    // BucketVaultBase.sol:468-498 verbatim (fail-closed: an unreachable/reverting BucketInfo is
    // treated as blacklisted, never as "unknown, so allow").
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
    // W4 compliance — seizure, delegating to {SeizureLib} exactly as `BucketVaultBase.sol:568-631`
    // does, reused directly here since this contract does not inherit `BucketVaultBase`.
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
        // Bypasses the normal {_update} override's blacklist check deliberately, since `account`
        // IS blacklisted by construction of a valid seizure — identical reasoning to
        // `BucketVaultBase.sol:620-628`.
        super._update(account, to, beforeBalance);
    }

    function pendingSeizure(address account) external view returns (address to, bytes32 documentHash, uint256 eta) {
        TimelockedAdmin.SeizureTimelock storage t = seizureTimelocks[account];
        return (t.to, t.documentHash, t.eta);
    }

    // ========================================================
    // Q14.2 — renounceOwnership() must revert, universal across every contract in this system.
    // ========================================================
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }
}
