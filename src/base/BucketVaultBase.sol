// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// BucketVaultBase — shared foundation for ActiveBucket and PassiveBucket
//
// Built skeleton-first (CLAUDE.md hard rule 7), then filled section-by-section via incremental
// Edit calls. See W1-SCR-REFACTOR-REPORT.md for the full function inventory, storage rationale,
// and explicit W2/W3/W4 deferrals.
// ============================================================

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

/**
 * @title BucketVaultBase
 * @author Bucket-for-Eggs Team
 * @notice Shared foundation for ActiveBucket and PassiveBucket: identical deposit-accounting
 * math, share-price/value helpers, whitelist-consuming value calculation, oracle-consumption
 * plumbing, the held-tokens registry, and the mechanical (access-control-agnostic) half of the
 * 1inch swap entry point.
 * @dev W1 (sc-refactor-base) extraction. See W1-SCR-REFACTOR-REPORT.md for the full function
 * inventory (what moved here, what stayed diverged, and why), the storage-layout rationale, and
 * explicit deferrals to W2/W3/W4.
 *
 * DELIBERATELY NOT UNIFIED HERE (kept local to each vault, on purpose):
 *  - Access control on the 1inch entry point: ActiveBucket.swapBy1inch is `onlyOwner`
 *    (active buckets are, by product definition, "actively traded by the owner"); PassiveBucket
 *    .rebalanceBy1inch is permissionless-but-share-gated (passive buckets are, by product
 *    definition, "passively rebalanced to a target distribution" by anyone, with a caller-fee
 *    incentive built into `_handleRebalanceFees`). This is a product-design difference between
 *    the two vault TYPES, not a copy-paste bug — see workspace CLAUDE.md §"What this project is"
 *    and ActiveBucket.sol's own doc comment ("The owner has full control over portfolio
 *    composition"). Only the mechanical call-and-value-check body is shared, via
 *    {_execute1inchSwap}.
 *  - The `pause`/`unpause`/`pauseSwap`/`unpauseSwap` external functions themselves: ActiveBucket
 *    gates them `onlyOwner`, PassiveBucket gates them `onlyAccountableOwner`. Unifying the
 *    *check* inside `whenSwapNotPaused` is safe (identical semantics); unifying the *admin gate*
 *    on the pause functions is a separate access-control decision outside this wave's scope, so
 *    those four functions stay defined locally in each vault.
 *  - `_bucketDistributions`, `rebalanceByDefi`, DEX config, `_executeBestSwap`, `_getTokenValue`
 *    consumers specific to PassiveBucket's weighted-rebalance model, and `flashLoan` /
 *    `IFlashLoanReceiver` specific to ActiveBucket. flashLoan is holder-callable, not
 *    owner-directed (W5.3, SC-10, B6 — the prior `onlyOwner` gate was confirmed stale).
 */
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

    // Note: no `using TimelockedAdmin for TimelockedAdmin.AddressTimelock;` and no
    // `using TimelockedAdmin for TimelockedAdmin.SeizureTimelock;` here -- every
    // `.propose()/.execute()/.cancel()` call on EITHER struct now happens inside {GovernanceLib}
    // or {SeizureLib} respectively (EIP-170 size-relief extraction; see this file's
    // "updateBucketInfo"/"Upgrade governance" sections and the COMPLIANCE -- SEIZURE section
    // below). This contract itself only ever reads `.pending`/`.eta` fields directly (in the
    // trivial pendingBucketInfoUpdate/pendingImplementation/upgradeEta getters, deliberately left
    // inline -- see {GovernanceLib}'s header comment for why), which is plain struct field access
    // and needs no `using` directive. Both directives would be dead code if kept.

    // ============================================================
    // STORAGE — ERC-7201 namespaced
    //
    // Every pre-existing state variable in ActiveBucket/PassiveBucket (bucketInfo,
    // oneInchRouter, tokenPrice, swapPaused, totalDepositValue, totalWithdrawValue, etc.) stays
    // declared exactly where it already is, in the CHILD contract, at its existing linear slot.
    // NOTHING is moved here. This base contract introduces exactly one piece of genuinely new
    // state — the held-tokens registry — and it is placed in an ERC-7201 namespaced slot so it
    // can NEVER collide with, or shift, any linear slot declared by either child contract, no
    // matter what future linear state either child adds. This mirrors the pattern already used
    // by every OZ upgradeable parent in this inheritance chain (OwnableUpgradeable,
    // PausableUpgradeable, ERC20Upgradeable, Initializable all use
    // @custom:storage-location erc7201 — confirmed by direct source inspection of
    // lib/openzeppelin-contracts-upgradeable) — this base contract simply extends that same
    // discipline to the one new piece of state it owns. See W1-SCR-REFACTOR-REPORT.md
    // "Storage layout" for the full derivation.
    //
    // Namespace string: "bucket-for-eggs.storage.BucketVaultBase"
    // slot = keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff))
    // Derived via `cast keccak` (verified correct for this use — hashing, not large-integer
    // arithmetic) plus Python arbitrary-precision integer subtraction/masking (cast's
    // to-dec/to-hex subcommands were found to silently truncate a near-2^256 value in this
    // sandbox and were NOT used for the arithmetic step).
    // @custom:storage-location erc7201:bucket-for-eggs.storage.BucketVaultBase
    struct BucketVaultBaseStorage {
        EnumerableSet.AddressSet heldTokens;
        // W2 (sc-swap): shared per-caller/global swap cooldown + cumulative per-epoch
        // value-loss budget state. Mappings/scalars inside an ERC-7201 namespaced struct are
        // safe to add here after the fact — a mapping computes its own storage slots from
        // base-slot + key, and the scalars below simply take the next words after `heldTokens`'s
        // own slot layout, so this addition cannot collide with or shift `heldTokens`, nor with
        // any linear slot declared in either child contract. See _enforceSwapCooldown and
        // _consumeEpochValueLossBudget below for how these are read/written.
        // W5 EIP-170 size-relief (2026-10-01): `callerSwapCooldownUntil` + `globalSwapCooldownUntil`
        // were two bare fields (a mapping + a scalar) here; wrapped into
        // {SwapExecutionLib.SwapCooldownState} for the same storage-reference reason as
        // `epochLossBudget` below. Layout-safe for the same reason: a mapping always reserves
        // exactly one slot number wherever it is declared (nested or not), and the scalar simply
        // takes the next word — identical to the unwrapped layout this replaces.
        SwapExecutionLib.SwapCooldownState swapCooldown;
        // W5 EIP-170 size-relief (2026-10-01): `currentEpochStart` + `currentEpochValueLossUsd`
        // were two bare scalars here; wrapped into {SwapExecutionLib.EpochLossBudget} so
        // `_consumeEpochValueLossBudget` can pass them to the library BY STORAGE REFERENCE
        // (mutated in place, no return-value marshaling) instead of by value. Layout-safe: a
        // struct of two consecutive `uint256` fields occupies the identical two storage slots
        // the bare scalars did, so nothing declared after it shifts.
        SwapExecutionLib.EpochLossBudget epochLossBudget;
        // W3.2 (D3): pending propose+timelock+veto state for {proposeUpdateBucketInfo} /
        // {vetoUpdateBucketInfo} / {executeUpdateBucketInfo}. Appended after the W2 fields
        // above for the same reason they were safe to append: a scalar/struct field simply
        // takes the next word(s) after the namespace's existing layout, so this cannot
        // collide with or shift `heldTokens` or any of the W2 fields, nor with any linear
        // slot declared in either child contract.
        TimelockedAdmin.AddressTimelock bucketInfoUpdateTimelock;
        // W3.3 (`09-DECISION-LOG.md` §10.1): pending queue+timelock state for {queueUpgrade} /
        // {cancelUpgrade} / {_authorizeUpgradeCommon}. Appended after the W3.2 field above for
        // the same append-only-is-safe reason given there.
        TimelockedAdmin.AddressTimelock upgradeTimelock;
        // W4.3 (D2, court-order requirement): pending seizure state for {proposeSeizure} /
        // {cancelSeizure} / {executeSeizure}, keyed by the account being seized from (a mapping,
        // not a single slot, so seizures against different blacklisted addresses can be in
        // flight concurrently). Appended after the W3.3 field above for the same
        // append-only-is-safe reason given there.
        mapping(address => TimelockedAdmin.SeizureTimelock) seizureTimelocks;
        // W5 (sc-oracle, returning): tracks the last-known aggregate outpriced status so
        // {_syncOutpricedStatus} can emit {OraclePricingLib.OutpricedStatusChanged} only on an
        // actual transition. Appended after the W4.3 field above for the same
        // append-only-is-safe reason given there.
        OraclePricingLib.OutpricedTracker outpricedTracker;
    }

    // keccak256(abi.encode(uint256(keccak256("bucket-for-eggs.storage.BucketVaultBase")) - 1))
    //   & ~bytes32(uint256(0xff))
    bytes32 private constant BucketVaultBaseStorageLocation =
        0x9f30ad90d3ca0770ef0f83f64df7579794e50d1de913b949a234fef0170b6e00;

    function _getBucketVaultBaseStorage() private pure returns (BucketVaultBaseStorage storage $) {
        assembly {
            $.slot := BucketVaultBaseStorageLocation
        }
    }

    // ============================================================
    // Shared constants
    //
    // Identical literal values in both ActiveBucket.sol and PassiveBucket.sol today
    // (ActiveBucket.sol:64,67,70,73; PassiveBucket.sol:151-169). WEIGHT_SUM and
    // DISTRIBUTION_TOLERANCE (PassiveBucket-only) are NOT duplicated here — they stay local to
    // PassiveBucket since ActiveBucket has no distribution concept at all.
    //
    // Kept `public` (not `internal`), matching each child's pre-refactor visibility exactly:
    // test/ActiveBucket.t.sol:841-846 asserts `bucket.PRECISION()`, `.INITIAL_TOKEN_PRICE()`,
    // `.BPS_DENOMINATOR()`, `.MAX_VALUE_LOSS_BPS()`, `.MIN_OWNER_BPS()` as external getter calls
    // on the concrete vault instance — Solidity's inherited-public-constant getters satisfy this
    // identically whether declared in the child or a parent, so moving them here does not change
    // that public surface.
    // ============================================================

    /// @dev Share arithmetic fixed-point scale. 18-decimal, matches ERC-20 share decimals.
    uint256 public constant PRECISION = 1e18;

    /// @dev Zero-state fallback share price: 1 USD, 8-decimal (PRICE_DECIMALS), per client spec
    /// (workspace CLAUDE.md §6: "when supply or total value is zero, share price defaults to 1
    /// USD"). Do not divide by zero supply; return this instead.
    uint256 public constant INITIAL_TOKEN_PRICE = 1e8;

    /// @dev W2 (sc-vault-entry) inflation-attack mitigation (INV-6 / B2,
    /// `04-CONTRACTS-IMPLEMENTATION-PLAN.md` conflict (f)): a fixed amount of shares minted to a
    /// dead address at the totalSupply()==0 -> nonzero transition (i.e. inside the very first
    /// deposit any vault instance ever receives). This puts a permanent floor under
    /// `totalSupply()` so a classic first-depositor-then-raw-donation attack can never again
    /// drive a legitimate depositor's minted shares to zero by inflating share price toward
    /// infinity — see `_processDeposit` below and the inflation-attack tests in
    /// test/ActiveBucket.t.sol / test/PassiveBucket.t.sol. Chosen over an OZ-style virtual
    /// shares/assets offset because an offset must be threaded through EVERY consumer of the
    /// share-price formula, including `_handleRebalanceFees` in each child — out of this wave's
    /// file-ownership scope (owned by the THIRD W2 agent, sc-swap, who has not run yet) — whereas
    /// dead shares are entirely local to `_processDeposit` and touch nothing else. 1e18 mirrors
    /// the "one whole share" dead-amount convention already used elsewhere in this codebase for
    /// the same purpose (04 conflict (g).3, PotentialRugpull — a different, out-of-scope
    /// contract, cited only as precedent for the magnitude, Inferred). Carved OUT of the first
    /// depositor's own mint (Uniswap V2 `MINIMUM_LIQUIDITY` pattern), never minted in addition to
    /// it — see the carve-out comment inside `_processDeposit` for why additive minting is wrong.
    uint256 public constant DEAD_SHARES = 1e18;

    /// @dev Classic unrecoverable burn address (no known private key, no way to call `approve`
    /// or `burn`). Not `address(0)`: OpenZeppelin's `ERC20Upgradeable._update` reverts with
    /// `ERC20InvalidReceiver(address(0))` on a mint to the zero address.
    address public constant DEAD_SHARES_RECIPIENT = address(0x000000000000000000000000000000000000dEaD);

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Floor on the owner's retained fee share in a rebalance fee split, and separately the
    /// threshold `isBucketAccountable()` (below) checks the owner's share balance against. 100 =
    /// 1%. ⚠ REVERSED BY DIRECT INSTRUCTION (2026-09-30, this session): task #47 had set this to
    /// `500` (5%) to match `04-CONTRACTS-IMPLEMENTATION-PLAN.md`'s ground-truth table
    /// (`ActiveBucket.sol:79` / `PassiveBucket.sol:160` pre-refactor) and this file's own
    /// `isBucketAccountable()` doc comment. An explicit user instruction ("change MIN_OWNER_BPS to
    /// 100") superseded that fix. **This now re-diverges from the plan's cited ground-truth table
    /// and from the `isBucketAccountable()` doc comment below** (updated in the same edit to say
    /// "1%" so the two stay internally consistent with each other, even though both now disagree
    /// with the plan document, which has not itself been updated). `test_Constants()` in
    /// `test/ActiveBucket.t.sol` and `test_OwnerRedeemAccountabilityCheck()` in
    /// `test/PassiveBucket.t.sol` were updated in the same pass to assert `100`, not `500`.
    uint256 public constant MIN_OWNER_BPS = 100;

    /// @dev Ceiling, in bps, on value lost across a single swap before it reverts.
    uint256 public constant MAX_VALUE_LOSS_BPS = 50;

    /// @dev W3.6 defensive ceiling on the fee value a vault will actually apply from
    /// `BucketInfo.calculateFee()`, mirrored against BucketInfo's own `MAX_PLATFORM_FEE = 1000`
    /// (`BucketInfo.sol:89`). See {_boundedPlatformFee} for why this is re-checked here even
    /// though BucketInfo already enforces it upstream.
    uint256 public constant MAX_LOCAL_PLATFORM_FEE_BPS = 1000;

    /// @dev W2 (sc-swap) cooldowns and epoch-loss-budget constants. Residual ambiguity: neither
    /// `04-CONTRACTS-IMPLEMENTATION-PLAN.md` nor `09-DECISION-LOG.md` specifies exact durations
    /// or bps figures for these — these are this wave's documented defaults, chosen to slow a
    /// repeated-call drain pattern (like the one in test/OneInchSwapSecurity.t.sol's
    /// `PreFixRebalanceBy1inchDrainTest`) to an economically-irrelevant rate without materially
    /// impeding legitimate single-swap rebalances. See W2-SC-SWAP-REPORT.md "Residual
    /// ambiguities with a default" for the full rationale; flagging for client confirmation.
    /// @dev Minimum time a given caller must wait between swap/rebalance actions on one vault.
    uint256 public constant CALLER_SWAP_COOLDOWN = 5 minutes;
    /// @dev Minimum time between ANY two swap/rebalance actions on one vault, regardless of
    /// caller — bounds the total drain rate even if an attacker sybils across many addresses
    /// that each individually hold enough shares to pass the balance gate.
    uint256 public constant GLOBAL_SWAP_COOLDOWN = 1 minutes;
    /// @dev Rolling window over which the cumulative value-loss budget below is tracked.
    uint256 public constant VALUE_LOSS_EPOCH_LENGTH = 1 days;
    /// @dev Ceiling, in bps of the vault's value at the start of the losing call, on TOTAL value
    /// loss across all swaps/rebalances within one epoch — independent of, and in addition to,
    /// the per-call `MAX_VALUE_LOSS_BPS` cap. This is what closes the loophole the pre-fix drain
    /// test exploited: many calls each individually under the per-call cap, but cumulatively
    /// draining the vault.
    uint256 public constant EPOCH_VALUE_LOSS_BUDGET_BPS = 150;
    /// @dev Tolerance subtracted from the oracle-computed src-side value when deriving the
    /// pre-commitment `minReturn` floor, to absorb legitimate DEX slippage/fees while still
    /// blocking a `minReturn` an attacker set low enough to permit a lopsided swap.
    uint256 public constant MIN_RETURN_FLOOR_TOLERANCE_BPS = 100;

    // ============================================================
    // Shared errors
    //
    // Byte-identical declarations in both children today. Moving them here means each child's
    // matching `error X(...)` line is DELETED (not merely left alone) when I edit
    // ActiveBucket.sol/PassiveBucket.sol, or `forge build` fails on duplicate declaration/shadow
    // warnings. PassiveBucket-only errors (distribution/DEX-specific) and ActiveBucket-only
    // errors (flash-loan-specific) are NOT moved here — they stay local to the child that alone
    // uses them.
    // ============================================================

    error PlatformNotOperational();
    error InvalidToken(address token);
    error ZeroAddress();
    /// @dev Task #33 (W1.7 direct-proxy-bypass fix): thrown by `initialize()` when `msg.sender`
    /// is not a factory the platform has authorized via
    /// `IImplementationRegistry.setAuthorizedFactory`. Without this check, anyone can deploy an
    /// `ERC1967Proxy` directly against the shared, immutable implementation address and call
    /// `initialize()` themselves, supplying an attacker-owned `bucketInfoAddr` -- bypassing the
    /// factory and, with it, the 00:44 oracle protection (`updateBucketInfo` is gated on
    /// *BucketInfo's* owner precisely so a vault owner cannot swap the price feed; a
    /// self-initialized vault lets the attacker own that `BucketInfo` from the start).
    error UnauthorizedInitializer();
    error ZeroAmount();
    error InvalidRedeemAmount();
    /// @dev W2 (sc-vault-exit): every per-token payout in `redeem()` rounded to zero (e.g.
    /// `shares` too small relative to the vault's held-token balances). Previously this burned
    /// the caller's shares and emitted `Redeemed` with no token transfer at all — a silent
    /// success that destroyed value and returned nothing. See ActiveBucket.redeem /
    /// PassiveBucket.redeem.
    error NothingToRedeem();
    /// @dev Verifier fix (2026-10-04): `redeemForStable()` derived a per-leg `legMinReturn` and
    /// passed it to the router as a calldata parameter, but never checked the ACTUAL amount this
    /// contract received back against it -- `minReturn` inside router calldata is advisory only;
    /// nothing on this contract's side stops a router that ignores it (or is buggy/malicious) from
    /// returning less and the call still succeeding. Verifier demonstrated this with a router that
    /// short-paid 10% below the floor and the call went through. This error is thrown by the
    /// post-swap balance-delta check added to {redeemForStable} below -- see that function.
    error ReceivedBelowMinReturn(uint256 received, uint256 minReturn);
    /// @dev INV-6 / B2: the very first deposit on a fresh vault must be large enough that, once
    /// `DEAD_SHARES` is carved out of it (see the doc comment on that constant), the depositor
    /// still receives a strictly positive number of shares. Reverting here, rather than silently
    /// minting zero shares to the depositor while still taking their funds, is what makes the
    /// floor a genuine precondition instead of a rounding trap.
    error FirstDepositTooSmall();
    error SwapIsPaused();
    error SwapNotPaused();
    error InsufficientShares();
    error ETHTransferFailed();
    error SwapFailed();
    error ValueLossTooHigh(uint256 valueBefore, uint256 valueAfter);
    error CannotRecoverWhitelistedToken(address token);
    error UnauthorizedBucketInfoUpdate();
    /// @dev W2 (sc-swap): typed-parameter swap executor errors. See `_execute1inchSwap` and its
    /// helper functions below for where each is thrown.
    error SameToken();
    error AmountExceedsHeldBalance(uint256 amount, uint256 heldBalance);
    error MinReturnBelowFloor(uint256 minReturnValueUsd, uint256 floorValueUsd);
    error SwapCooldownActive(uint256 cooldownUntil);
    error EpochValueLossBudgetExceeded(uint256 projectedLossUsd, uint256 budgetUsd);
    /// @dev Belt-and-braces guard in `_decodeSwapReceiver` — should be unreachable in practice
    /// since this contract alone constructs the calldata it decodes; see that function's doc
    /// comment.
    error MalformedSwapPayload();
    /// @dev W3.3: {queueUpgrade}/{_authorizeUpgradeCommon}. The implementation actually installed
    /// via UUPS's `upgradeToAndCall` at execution time must be byte-identical to the one
    /// announced at queue time — queuing the ADDRESS (never a boolean) is the whole point: a
    /// boolean flag would let the queuer announce implementation A and execute implementation B,
    /// "worse than no window, because it manufactures assurance"
    /// (`04-CONTRACTS-IMPLEMENTATION-PLAN.md` §5.6.1/§10.1c).
    error UpgradeImplementationMismatch(address expected, address provided);
    /// @dev W3.3: the platform ({ImplementationRegistry}) has not (or no longer) approved this
    /// implementation for this vault's `Kind`. Re-checked at EXECUTION time (inside
    /// {_authorizeUpgradeCommon}), not just at queue time, so a mid-window revocation actually
    /// blocks the upgrade (`09-DECISION-LOG.md` §10.1).
    error UpgradeNotApproved(address implementation);
    /// @dev Thrown by {renounceOwnership}, which is always disabled -- task #45 (W3 gate)
    /// discovered this override was MISSING on both children (`ActiveBucket`/`PassiveBucket`),
    /// so `OwnableUpgradeable.renounceOwnership()` currently SUCCEEDS and would permanently brick
    /// every `onlyOwner`/`onlyAccountableOwner` path (pause, queueUpgrade, updateBucketInfo,
    /// recoverTokens, ...) with no remedy, since there is no DAO to hand ownership to yet. Q14.2
    /// (`10-BLOCKER-14-DECOMPOSITION-ANSWER.md:6-7`): "If we want to make the contract ownerless,
    /// we will change the owner into a DAO contract (not in scope yet)" -- same rule, same
    /// wording, as `BucketInfo.sol:711`/`ImplementationRegistry.sol:39`. Vaults stay
    /// single-step `Ownable` (D-3, root CLAUDE.md §8) -- this fixes ONLY the renounce path, and
    /// does not add `Ownable2Step`.
    error RenounceOwnershipDisabled();
    /// @dev W5 (sc-stable-exit, task #64): MOVED here from `PassiveBucket.sol` (was declared
    /// local to that contract only). `redeemForStable()` below applies PassiveBucket's existing
    /// `isBucketAccountable()`-gated owner-accountability guard to BOTH vault types — see that
    /// function's doc comment for why this is a deliberate, flagged deviation for ActiveBucket
    /// (which has no such guard on its own `redeem()`) — so the error now lives in the shared
    /// base alongside the check, instead of being re-declared per child. Deleted from
    /// `PassiveBucket.sol`, not duplicated: redeclaring the same zero-arg error (same selector) in
    /// a contract that already inherits it is a compile error, not a shadow.
    /// `PassiveBucket.OwnerNotAccountable.selector` continues to resolve correctly via
    /// inheritance — unchanged in every existing call site and test.
    error OwnerNotAccountable();

    // ============================================================
    // Shared events
    //
    // Same rule as errors: matching declarations in ActiveBucket.sol/PassiveBucket.sol are
    // deleted from the child, not duplicated. `Rebalanced`/`DistributionUpdated`-style events
    // that only one vault type can emit stay local to that vault.
    // ============================================================

    event Deposited(
        address indexed user, address indexed token, uint256 amount, uint256 sharesMinted, uint256 depositValueUsd
    );
    /// @notice Emitted by `redeem()`. W2 (sc-vault-exit) redesign of the original 2-field
    /// `Redeemed(user, sharesRedeemed)`.
    /// @param user The redeemer.
    /// @param shares The number of shares burned.
    /// @param supply Total share supply immediately AFTER the burn (i.e. the new supply).
    /// @param tokens The payout token addresses (native ETH is `address(0)`), same order as
    /// `amounts`. Sourced from the held-tokens registry, not the whitelist — see
    /// ActiveBucket.redeem / PassiveBucket.redeem.
    /// @param amounts The actual amount of each `tokens[i]` transferred to `user`.
    /// @dev INV-1 forbids computing a USD value here — that requires an oracle call. Root
    /// workspace CLAUDE.md §8 forbids deleting the `totalWithdrawValue` statistic, so instead of
    /// removing the capability this event carries what an off-chain indexer needs to
    /// reconstruct it: multiply `amounts[i]` by the indexer's own price history for `tokens[i]`
    /// at the block timestamp, summed over `i`. `totalWithdrawValue` itself is preserved as a
    /// getter on each vault but is no longer incremented on-chain (see the state variable's own
    /// doc comment in ActiveBucket.sol / PassiveBucket.sol).
    event Redeemed(address indexed user, uint256 shares, uint256 supply, address[] tokens, uint256[] amounts);
    /// @notice Emitted by `redeemForStable()` (W5, sc-stable-exit, SC-9) — the sibling of
    /// `Redeemed` for a stable-exit redemption. `tokens`/`amounts` are the SAME basket-portion
    /// values `_previewRedeemCore` computed (i.e. what a plain `redeem()` would have paid out),
    /// preserved here for the same off-chain-reconstruction reason `Redeemed` preserves them —
    /// an indexer can still answer "what would this have been worth as a raw basket" even though
    /// the user actually received `dstToken` only.
    /// @param user The redeemer.
    /// @param shares The number of shares burned.
    /// @param supply Total share supply immediately AFTER the burn.
    /// @param dstToken The single stable token the redeemer actually received.
    /// @param dstAmountOut Total `dstToken` transferred to `user` (sum of the direct `dstToken`
    /// leg, if any, plus every swapped leg's actual received amount, measured by balance delta).
    /// @param tokens The basket-portion token addresses `_previewRedeemCore` computed, same order
    /// as `amounts` — NOT what was transferred; see `dstAmountOut` for that.
    /// @param amounts The basket-portion amounts for `tokens`, same semantics as `Redeemed.amounts`.
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
    /// W3.2 (D3): emitted by {proposeUpdateBucketInfo}. `eta` is when {executeUpdateBucketInfo}
    /// becomes callable absent a veto.
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed proposedBucketInfo, address indexed proposedBy, uint256 eta
    );
    /// W3.2 (D3): emitted by {vetoUpdateBucketInfo}. `vetoedBucketInfo` is the address that was
    /// pending and will now never take effect.
    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);
    /// W3.3 (`09-DECISION-LOG.md` §10.1c): emitted by {queueUpgrade}. Carries the vault's own
    /// address (redundant on a per-vault contract, but lets a multi-vault indexer / `eth_getLogs`
    /// sweep watch every vault's pending upgrades without an archive node) plus the announced
    /// implementation and its `eta`.
    event UpgradeQueued(address indexed vault, address indexed newImplementation, uint256 eta);
    /// W3.3: emitted by {cancelUpgrade}. `implementation` is the address that was pending and
    /// will now never execute.
    event UpgradeCancelled(address indexed vault, address indexed implementation);

    // ============================================================
    // Abstract hooks
    //
    // bucketInfo / oneInchRouter / swapPaused / tokenPrice / totalDepositValue /
    // totalWithdrawValue stay declared as linear state variables in EACH CHILD CONTRACT, at
    // their existing pre-refactor slots — they are deliberately NOT moved into this base
    // contract's storage (see the STORAGE section above). These hooks let base-contract logic
    // read/write that child-owned state without knowing its slot, so the child's storage layout
    // is untouched by this refactor. Each child implements these as thin one-line overrides
    // wrapping its own existing state variable.
    // ============================================================

    /// @dev Returns the vault's own `bucketInfo` state variable, typed as the shared interface.
    function _bucketInfo() internal view virtual returns (IBucketInfo);

    /// @dev Writes the vault's own `bucketInfo` state variable.
    function _setBucketInfo(address newBucketInfo) internal virtual;

    /// @dev Returns the vault's own `oneInchRouter` state variable.
    function _oneInchRouter() internal view virtual returns (address);

    /// @dev Returns the vault's own `swapPaused` state variable.
    function _swapPaused() internal view virtual returns (bool);

    /// @dev W3.3: the platform-owned {ImplementationRegistry} this vault checks upgrade
    /// implementations against. A one-line override in each child returning its own `immutable`
    /// REGISTRY — see the "factory-immutable" precedent (root CLAUDE.md §1.1, W1.7): baked into
    /// the implementation contract's constructor, never threaded through `initialize`, so the
    /// factory needs zero changes to supply it (`09-DECISION-LOG.md` §11.2 / D-3, "W3's factory
    /// diff drops to zero").
    function _registry() internal view virtual returns (IImplementationRegistry);

    /// @dev W3.3: this vault type's namespace within the registry's `Kind` enum. A one-line
    /// override in each child returning its own `constant` REGISTRY_KIND — see
    /// IImplementationRegistry.sol's own doc comment ("every vault's immutable REGISTRY_KIND").
    function _registryKind() internal pure virtual returns (IImplementationRegistry.Kind);

    // ============================================================
    // Shared modifiers
    //
    // Byte-identical logic in both children today (ActiveBucket.sol:131-141,
    // PassiveBucket.sol:226-237), rewritten here against the abstract hooks instead of a
    // directly-declared state variable so behavior is unchanged while storage stays local to
    // each child.
    // ============================================================

    modifier whenPlatformOperational() {
        if (!_bucketInfo().isPlatformOperational()) revert PlatformNotOperational();
        _;
    }

    modifier whenSwapNotPaused() {
        if (_swapPaused()) revert SwapIsPaused();
        _;
    }

    // ============================================================
    // COMPLIANCE — BLACKLIST (W4.2, D2)
    //
    // Client requirement (`00-EXECUTIVE-SUMMARY-USER-REPLY.md:19`): "Addresses on the blacklist
    // will not able to do anything with any contract in this project, no matter deposit,
    // withdraw, rebalance, or even transferring the contract tokens." `BucketInfo.isBlacklisted`
    // (W4.1) is the single source of truth; this section is the shared check every mutable entry
    // point in this base contract and its two children routes through -- written ONCE here
    // (INV-9) so ActiveBucket and PassiveBucket never carry two copies of the same check.
    //
    // D2 (fail-closed): if the external call to `_bucketInfo().isBlacklisted` reverts for any
    // reason -- BucketInfo unreachable, self-destructed, or genuinely reverting -- the address is
    // treated AS IF blacklisted, never as if clear. INV-7 requires {isBlacklisted} on the
    // BucketInfo side to itself be an O(1) storage read with no loop and no further external
    // call, so the only reason this try/catch can ever land in its `catch` branch is BucketInfo
    // itself being unreachable or deliberately reverting -- not gas exhaustion inside a loop on
    // the other side.
    //
    // Note the INV-1 tension this creates, recorded per the plan's own instruction (D2 accepts it
    // consciously): redemption is documented to depend on nothing but share arithmetic plus
    // `whenPlatformOperational`, and this check is a SECOND gate on redeem, alongside deposit and
    // transfer. This is deliberate compliance behaviour, not a regression -- see this wave's
    // report.
    // ============================================================

    /// @dev Thrown by every entry point (via {_assertNotBlacklisted}, the {_update} override
    /// below, or an explicit check at a non-transfer entry point such as `swapBy1inch`) when the
    /// relevant address is blacklisted, or when `BucketInfo` cannot be reached to answer that
    /// question (D2, fail-closed).
    error Blacklisted(address account);

    /// @dev Fail-closed read of `BucketInfo.isBlacklisted(account)`. Never reverts itself --
    /// callers get a definitive true/false, with "true" standing in for both "actually
    /// blacklisted" and "BucketInfo unreachable" (D2). See this section's header comment.
    function _isBlacklistedFailClosed(address account) internal view returns (bool) {
        try _bucketInfo().isBlacklisted(account) returns (bool blacklisted) {
            return blacklisted;
        } catch {
            return true;
        }
    }

    /// @dev Reverts with {Blacklisted} if `account` is blacklisted (or BucketInfo is
    /// unreachable, per D2). The single call site every mutable entry point in this contract and
    /// its children route through -- see this section's header comment (INV-9).
    function _assertNotBlacklisted(address account) internal view {
        if (_isBlacklistedFailClosed(account)) revert Blacklisted(account);
    }

    /// @notice ERC-20 transfer hook (mint, burn, and ordinary transfer all route through this).
    /// W4.2: blocks the transaction if either `from` or `to` is blacklisted -- covers
    /// `deposit`/`redeem`'s own mint/burn AND a plain `transfer`/`transferFrom` of vault shares,
    /// which is the "even transferring the contract tokens" clause of the client's requirement
    /// quoted in this section's header comment. `address(0)` (mint's `from` / burn's `to`) is
    /// skipped -- it is never itself blacklistable (`BucketInfo.blacklistAddress`'s own
    /// zero-address guard) -- so this only ever meaningfully checks the real counterparty of a
    /// mint/burn/transfer, never the zero-address sentinel.
    /// @dev No transfer hook existed anywhere in this codebase before W4 (plan §7.2a); this is
    /// therefore hook CREATION on the shared base both vaults inherit, not a modification of
    /// pre-existing logic.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) _assertNotBlacklisted(from);
        if (to != address(0)) _assertNotBlacklisted(to);
        super._update(from, to, value);
    }

    /// @dev Verifier fix (2026-10-04): {_update} above only ever sees `from`/`to` -- it never sees
    /// a third-party `msg.sender` acting as a SPENDER, so a blacklisted address could previously
    /// still call `approve` (set its own allowance) or act as the spender in `transferFrom`
    /// /`burnFrom` on someone else's balance, in direct contradiction of the client requirement
    /// quoted in the COMPLIANCE — BLACKLIST header above ("will not able to do anything with any
    /// contract in this project, not even transferFrom, approve, and admin calls" — client's own
    /// restated instruction). This modifier (used by `approve` below) plus the
    /// {_spendAllowance} override below it close that gap by checking `msg.sender` explicitly
    /// before any allowance-based action; `from`/`to` on the underlying transfer are still
    /// separately covered by {_update}.
    /// @dev Revision note: an earlier version of this fix put `whenCallerNotBlacklisted` on
    /// separate PUBLIC overrides of `transferFrom` AND `burnFrom` (two full dispatch-table
    /// entries). Both route through the same internal `_spendAllowance(owner_, spender, value)`
    /// hook with `spender == msg.sender` (confirmed against OZ source), so overriding that ONE
    /// internal hook instead — see {_spendAllowance} below — gives the identical check at the
    /// identical point in both call paths for less runtime bytecode. `transferFrom`/`burnFrom`
    /// are no longer overridden at all; they fall through to the stock OZ implementations.
    modifier whenCallerNotBlacklisted() {
        _assertNotBlacklisted(msg.sender);
        _;
    }

    /// @dev CORRECTION to this comment's own earlier claim (recorded per hard rule 5, not
    /// deleted): an earlier revision asserted that folding `onlyOwner` + `whenCallerNotBlacklisted`
    /// into this single modifier would, by itself, recover bytecode by removing a "modifier
    /// boundary." Measured via `forge build --sizes` (`forge clean` first, to rule out a stale
    /// cache): PassiveBucket's margin was IDENTICAL before and after that merge, still -184 B.
    /// The reason is that Solidity modifiers are inlined textually regardless of how many are
    /// stacked on a function — two modifiers each calling one internal function, or one modifier
    /// calling both internal functions in sequence, emit the SAME two `JUMP`s to `_checkOwner()`
    /// and `_assertNotBlacklisted(msg.sender)` either way. There was no redundant modifier-wrapper
    /// overhead to deduplicate. The actual, and only, byte cost is the two internal-function CALLS
    /// themselves, duplicated across every one of this wave's 8 admin call sites (4 here, 4 in
    /// `PassiveBucket`) — real safety checks that did not exist on these call sites before this
    /// wave, not redundant duplication. This modifier is kept (readability, single call-site
    /// annotation instead of two) but is NOT a size fix; {_checkOwnerNotBlacklisted} below, which
    /// collapses the two internal calls into ONE, is the actual size relief — see its own comment.
    modifier onlyOwnerNotBlacklisted() {
        _checkOwnerNotBlacklisted();
        _;
    }

    /// @dev Verifier fix (2026-10-04), REAL size relief (measured, not assumed — see the
    /// correction above this modifier for the approach that did NOT work): collapses
    /// `_checkOwner()` + `_assertNotBlacklisted(msg.sender)` from two separate internal-function
    /// `JUMP`s per call site into one. Same checks, same order (`_checkOwner()` first, exactly as
    /// plain `onlyOwner` alone would run it), same reverts — this only changes how many `JUMP`s
    /// each of the 8 call sites costs, not what they check.
    function _checkOwnerNotBlacklisted() internal view {
        _checkOwner();
        _assertNotBlacklisted(msg.sender);
    }

    /// @dev Verifier fix (2026-10-04), REAL size relief, follow-up to the `_checkOwnerNotBlacklisted`
    /// collapse above: this single override REPLACES what were previously two separate public
    /// overrides (`transferFrom`, `burnFrom`), each with its own selector-dispatch entry, modifier
    /// inline, and delegate-to-`super` call. Confirmed via OZ source
    /// (`ERC20Upgradeable.transferFrom`, `ERC20BurnableUpgradeable.burnFrom`): BOTH call
    /// `_spendAllowance(owner_, spender, value)` with `spender == _msgSender()`, and in BOTH
    /// cases `_spendAllowance` runs strictly before any further external call or state change
    /// (`_transfer`/`_burn`) — so checking the blacklist here, before `super._spendAllowance`'s
    /// own logic (including its `type(uint256).max` infinite-allowance short-circuit) runs, is
    /// byte-for-byte the same check at the same point in each call's control flow as the two
    /// overrides it replaces. `transferFrom`/`burnFrom` themselves are no longer overridden at
    /// all — they fall through to the stock OZ implementations unchanged, which is what removes
    /// their two dispatch-table entries. `approve` stays separately overridden immediately below:
    /// it does not route through `_spendAllowance` at all.
    function _spendAllowance(address owner_, address spender, uint256 value) internal virtual override {
        _assertNotBlacklisted(spender);
        super._spendAllowance(owner_, spender, value);
    }

    /// @dev Verifier fix (2026-10-04): blocks a blacklisted account from setting a new allowance.
    function approve(address spender, uint256 value) public virtual override whenCallerNotBlacklisted returns (bool) {
        return super.approve(spender, value);
    }

    // ============================================================
    // COMPLIANCE — SEIZURE (W4.3, D2 / court-order requirement)
    //
    // Client requirement (`00-EXECUTIVE-SUMMARY-USER-REPLY.md:18-21`): blacklisted addresses can
    // do nothing with any contract in this project, and there needs to be "a function to move
    // the tokens holded by a blacklisted address to another wallet for further manual process",
    // taking a `bytes32` document hash "of a document / court order which force the platform to
    // seize the tokens".
    //
    // ⚠ SOURCE DISAGREES with the client's own description of WHERE this lives: the client says
    // "BuckerInfo contract will have a function" (00:20), but root CLAUDE.md §8 fixes
    // BucketInfo's entire mutable surface at five categories plus blacklist management (W4.1)
    // and calls "any other setter" a defect -- and BucketInfo holds no vault shares of its own
    // to move in the first place; only the token contract holding the balance can move it. Per
    // root CLAUDE.md §9's "⚠ SOURCE DISAGREES" convention, the client's INTENT (the platform can
    // force a seizure) is honoured; their description of the file is not. The mechanism lives
    // here, on the contract that actually holds the balance, gated on BucketInfo's OWNER --
    // exactly the pattern {proposeUpdateBucketInfo} above already uses for the same reason.
    //
    // Gating mirrors {proposeUpdateBucketInfo}/{vetoUpdateBucketInfo}: propose and cancel check
    // `IBucketInfo(bucketInfo).owner()`, NOT this vault's own `onlyOwner` -- seizure is a
    // platform compliance action against a blacklisted third party, not a vault-owner action,
    // and a vault-owner veto here would let a blacklisted vault owner block their own seizure.
    // Unlike {vetoUpdateBucketInfo}, there is deliberately no separate veto party at all.
    //
    // Timelocked at the same 48-hour figure used everywhere else in this system
    // (`PLATFORM_SETTER_TIMELOCK_DELAY`, `BUCKET_INFO_UPDATE_TIMELOCK_DELAY`,
    // `UPGRADE_TIMELOCK_DELAY`) -- one platform-wide delay, not a fourth unexplained number.
    //
    // {executeSeizure} re-checks `isBlacklisted(account)` at the moment of execution -- a
    // revocation between propose and execute must cancel the seizure, not merely delay it. This
    // is the ONE place in this codebase where an unreachable BucketInfo must ABORT rather than
    // proceed: D2's usual fail-closed direction protects USERS by blocking their actions when in
    // doubt; here the action being gated is a PLATFORM action that irreversibly moves a third
    // party's funds, so "in doubt" must resolve the other way. {SeizureLib.requireConfirmedBlacklisted}
    // (used for `account`) is therefore a DELIBERATELY DIFFERENT check from
    // {SeizureLib.requireNotBlacklistedFailClosed} (used for `to`, and matching this contract's
    // own {_isBlacklistedFailClosed} direction) -- do not merge them; "true on revert" semantics
    // for `account` would wave an unverified seizure through.
    // ============================================================

    // ⚠ EIP-170 SIZE-RELIEF EXTRACTION (post-W4.3 `forge build --sizes` finding): the checks,
    // errors, events, and platform-owner/fail-closed-reversed gating that used to live inline
    // here now live in {SeizureLib} instead, a `public`-function library DELEGATECALLed into
    // by this contract exactly as {DexSwapLib.executeBestSwap} already is for PassiveBucket's
    // swap logic (tasks #31/#48/#50) -- moving that function inline had pushed PassiveBucket's
    // runtime margin to -1,547 B, and a first extraction pass (moving only propose/cancel and a
    // validate-only execute helper) recovered just 247 B, still leaving it negative. A second
    // pass folded the destination-blacklist check and the {SeizureExecuted} emission into
    // {SeizureLib.executeSeizure} too -- the event's `afterBalance` is a hardcoded `0` there, not
    // a second `balanceOf` read, since a seizure always sweeps `account`'s entire balance and the
    // post-seizure balance is therefore provably always zero. This is a pure bytecode-location
    // change; see SeizureLib.sol's own doc comment for the full rationale and for why
    // `executeSeizure`'s actual token move (line below calling `super._update`) could not move
    // with the rest: that primitive is `internal` to the OpenZeppelin ERC-20 hierarchy and
    // unreachable from a library with no state of its own.

    /// @dev Same 48-hour figure as {BUCKET_INFO_UPDATE_TIMELOCK_DELAY} / {UPGRADE_TIMELOCK_DELAY}
    /// / BucketInfo's own `PLATFORM_SETTER_TIMELOCK_DELAY} -- see this section's header comment.
    /// @dev Deliberately `internal`, NOT `public` like its two same-valued siblings above: this
    /// is a brand-new W4.3 constant with no test or integration yet depending on an external
    /// getter for it (unlike {BUCKET_INFO_UPDATE_TIMELOCK_DELAY}/{UPGRADE_TIMELOCK_DELAY}, which
    /// W3 gate tests already call as `public` and which this wave must not silently change), so
    /// there is no compatibility cost to skipping the auto-generated getter -- one fewer selector
    /// in the dispatcher, one fewer ABI-encoded `uint256` return, at zero behavioural cost since
    /// the value is already public knowledge via {SeizureProposed}'s emitted `eta`.
    uint256 internal constant SEIZURE_TIMELOCK_DELAY = 48 hours;

    /**
     * @notice Propose seizing whatever `account` currently holds, on a `bytes32` document hash
     * (e.g. a court order) for the record, per the client's requirement.
     * @dev Gated on BucketInfo's owner (the platform) -- see this section's header comment.
     * `account` must be confirmed blacklisted now; execution re-checks this independently.
     * Overwrites any existing pending seizure proposal for this account.
     */
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

    /**
     * @notice Cancel a pending seizure proposal for `account` before it takes effect.
     * @dev Gated on BucketInfo's owner, same as {proposeSeizure} -- deliberately no separate
     * veto party. No-op if nothing is pending, matching `TimelockedAdmin.cancel`'s semantics.
     */
    function cancelSeizure(address account) external {
        SeizureLib.cancelSeizure(_getBucketVaultBaseStorage().seizureTimelocks, _bucketInfo(), account);
    }

    /**
     * @notice Execute a pending seizure once the timelock has elapsed, moving `account`'s
     * entire current balance to the nominated wallet.
     * @dev Deliberately PERMISSIONLESS once the delay has elapsed, mirroring
     * {executeUpdateBucketInfo} -- but {SeizureLib.executeSeizure} still gates the outcome,
     * re-checked at execution time on BOTH `account` (confirmed blacklisted) and `to` (fail-closed
     * not blacklisted), so anyone may trigger it but nobody can make it succeed against an
     * account no longer confirmed blacklisted or into a destination that is itself blacklisted.
     * Bypasses this contract's own {_update} override on `account`'s side deliberately --
     * `account` IS blacklisted, so routing through {_update} would revert on its own check.
     * {SeizureLib.executeSeizure} emits {SeizureLib.SeizureExecuted} itself (with a deterministic
     * `afterBalance` of `0`) before this function performs the actual token move, which is safe
     * because both are part of the same atomic transaction -- a revert in `super._update` below
     * (which cannot happen here, since `to` is never the zero address per {proposeSeizure}'s own
     * check) would unwind the event along with everything else.
     */
    function executeSeizure(address account) external {
        uint256 beforeBalance = balanceOf(account);
        address to = SeizureLib.executeSeizure(
            _getBucketVaultBaseStorage().seizureTimelocks, _bucketInfo(), account, beforeBalance
        );

        super._update(account, to, beforeBalance);
    }

    /// @notice The currently-pending seizure proposal for `account`, if any. `eta == 0` means
    /// nothing is pending.
    /// @dev Reads storage DIRECTLY rather than through {SeizureLib} -- unlike propose/cancel/
    /// execute, this is a trivial 3-field struct read with no check, gating, or event, so routing
    /// it through a DELEGATECALL would cost more in call-setup/return-decode glue than the read
    /// itself, the same diminishing-returns pattern observed when the first extraction pass
    /// recovered far less than {DexSwapLib}'s large-loop precedent. Kept inline for this one
    /// function only; every function that has a check or side effect stays in {SeizureLib}.
    function pendingSeizure(address account) external view returns (address to, bytes32 documentHash, uint256 eta) {
        TimelockedAdmin.SeizureTimelock storage t = _getBucketVaultBaseStorage().seizureTimelocks[account];
        return (t.to, t.documentHash, t.eta);
    }

    // ============================================================
    // Shared internal value/balance/transfer helpers
    //
    // Verified identical logic in both children (ActiveBucket.sol:461-498,
    // PassiveBucket.sol:789-849) modulo one cosmetic difference: ActiveBucket previously inlined
    // the per-token value calculation directly into `_calculateTotalValue` instead of naming it
    // `_getTokenValue`; PassiveBucket already had the named helper. Both iterate
    // `bucketInfo.getWhitelistedTokens()` — the SAME token universe — so, unlike `redeem`'s
    // payout loop (which PassiveBucket walks over `_bucketDistributions`, not the full
    // whitelist, and which stays local to each child), this total-value calculation is safe to
    // unify outright. Sharing it also satisfies INV-9 (every fix written once, never twice):
    // ActiveBucket now calls the same `_getTokenValue` PassiveBucket already named.
    // ============================================================

    /// @dev Calculate total value of whitelisted tokens held by this contract (USD, 8 decimals).
    function _calculateTotalValue() internal view returns (uint256) {
        address[] memory tokens = _bucketInfo().getWhitelistedTokens();
        uint256 totalValue = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            totalValue += _getTokenValue(tokens[i]);
        }
        return totalValue;
    }

    /// @dev USD value (8 decimals) of a specific whitelisted token balance held by this contract.
    function _getTokenValue(address token) internal view returns (uint256) {
        uint256 balance = _getTokenBalance(token);
        if (balance == 0) return 0;
        uint256 price = _bucketInfo().getTokenPrice(token);
        uint8 dec = _getTokenDecimals(token);
        // Multiply before dividing (workspace CLAUDE.md §6); price==0 would otherwise silently
        // zero out this token's contribution rather than surfacing a bad oracle read.
        if (price == 0) revert InvalidToken(token);
        return (balance * price) / (10 ** dec);
    }

    /// @dev USD value (8 decimals) of `shares` out of `supply` total shares.
    function _calculateValueOfShares(uint256 shares, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 0;
        return (_calculateTotalValue() * shares) / supply;
    }

    /// @dev W3.6: defensive ceiling on the fee value read from `BucketInfo.calculateFee()`.
    /// `MAX_PLATFORM_FEE = 1000` bps (10%) is already enforced ON BucketInfo (`BucketInfo.sol:89`,
    /// checked by `setPlatformFee`), but the vaults never re-checked the VALUE THEY ACTUALLY
    /// RECEIVED from that call — this is the belt to the timelock's braces
    /// (`04-CONTRACTS-IMPLEMENTATION-PLAN.md` W3.6). Clamping locally means a vault's own fee
    /// accounting stays bounded even if BucketInfo's guarantee is ever violated (a future bug, a
    /// storage collision, a malicious upgrade of `bucketInfo` itself pending its own timelock).
    /// `amount` is the base the fee is taken from (e.g. `valueDifference`); the clamp is applied
    /// against `amount`, not against `rawFee` alone, so it degrades gracefully to "at most
    /// `MAX_LOCAL_PLATFORM_FEE_BPS` of the base" rather than compounding a corrupted `rawFee`.
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

    /// @dev Transfer `token` (or native ETH if `address(0)`) to `to`.
    function _transferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ============================================================
    // Shared deposit accounting core (W2, sc-vault-entry)
    //
    // ActiveBucket.deposit and PassiveBucket.deposit were byte-identical (pre-W2) EXCEPT that
    // both minted shares against the STALE `tokenPrice` state variable — refreshed only inside
    // `_handleRebalanceFees`, itself only reachable from swap/rebalance paths — instead of the
    // vault's LIVE `_calculateTotalValue()` / `totalSupply()`. A deposit made between two
    // rebalances (or before the first one ever happens, which is the common case for a
    // low-activity vault) minted shares at a price that ignored every market move since the last
    // rebalance. `_processDeposit` below fixes that by snapshotting total value/supply BEFORE
    // this deposit's own funds are counted (the "inflate before you price" trap — see the
    // ETH-specific netting inside), and ships the DEAD_SHARES inflation-attack mitigation
    // (INV-6) in the same change, per this wave's brief. `tokenPrice` / `totalDepositValue`
    // themselves stay linear state in each child (W1's storage-layout discipline) — this helper
    // returns what each child needs to write into its own copy; it does not write them itself.
    // `previewDeposit` and `sharePrice` mirror the same math read-only, with no such
    // per-child divergence, so they are fully shared here (unlike `previewRedeem` below, which
    // is not: see `_previewRedeemCore`'s doc comment).
    // ============================================================

    /// @dev Shared core of `deposit()`. Does NOT check `whenNotPaused` / `whenPlatformOperational`
    /// and does NOT emit `Deposited` — those stay in each child's external `deposit()`, unchanged
    /// from before this wave.
    /// @param token The token address (`address(0)` for native ETH).
    /// @param amount The amount to deposit (ignored for ETH; `msg.value` is used instead, exactly
    /// as before this wave).
    /// @return actualAmount The amount actually received.
    /// @return sharesToMint Shares minted to `msg.sender`.
    /// @return depositValue USD value (8 decimals) of the deposit, per the oracle.
    /// @return newSharePrice The live NAV price basis used for this mint. Callers persist this
    /// into their own `tokenPrice` state variable — this wave's decision is that `tokenPrice`
    /// stays continuously live-synced on every deposit, not just on rebalance (see
    /// W2-SC-ENTRY-REPORT.md).
    function _processDeposit(address token, uint256 amount)
        internal
        returns (uint256 actualAmount, uint256 sharesToMint, uint256 depositValue, uint256 newSharePrice)
    {
        if (!_bucketInfo().isTokenValid(token)) revert InvalidToken(token);

        // Pre-deposit snapshot. For ERC-20 this genuinely precedes `safeTransferFrom` below. For
        // ETH, `msg.value` is already credited to `address(this).balance` by the time this
        // function body executes (an EVM/CALL-level fact — see `_getTokenBalance`'s
        // `address(this).balance` branch above), so it is netted back out a few lines down, once
        // `depositValue` is known, rather than excluded by reordering.
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
            // Net the just-received ETH back out of the snapshot above so it is a genuine
            // pre-deposit basis — see the comment on `totalValueBeforeDeposit` above. Exact, not
            // approximate: both reads price ETH via the same oracle within the same transaction.
            totalValueBeforeDeposit -= depositValue;
        }

        newSharePrice =
            supplyBeforeDeposit > 0 ? (totalValueBeforeDeposit * PRECISION) / supplyBeforeDeposit : INITIAL_TOKEN_PRICE;
        if (newSharePrice == 0) newSharePrice = INITIAL_TOKEN_PRICE;

        sharesToMint = (depositValue * PRECISION) / newSharePrice;
        if (sharesToMint == 0) revert ZeroAmount();

        // INV-6 / B2: `DEAD_SHARES` is carved OUT of the first depositor's own mint (the
        // Uniswap V2 `MINIMUM_LIQUIDITY` pattern), never minted in addition to it. Minting it
        // additively would inflate `totalSupply()` without any backing value, lowering the price
        // basis every LATER depositor mints against relative to the first depositor's own price —
        // i.e. it would dilute the first depositor in favour of every later one, an unbounded and
        // growing unfairness, not a fixed cost. Carving it out of the first mint instead means
        // `totalSupply()` after this transaction is EXACTLY what it would have been with no
        // mitigation at all (`sharesToMint` unchanged); only its split between the depositor and
        // the dead address changes. So every later depositor sees zero distortion, and the entire
        // cost of the mitigation is a single, fixed, one-time sacrifice borne by the first
        // depositor alone — see W2-SC-ENTRY-REPORT.md for the worked numeric example.
        if (supplyBeforeDeposit == 0) {
            if (sharesToMint <= DEAD_SHARES) revert FirstDepositTooSmall();
            _mint(DEAD_SHARES_RECIPIENT, DEAD_SHARES);
            sharesToMint -= DEAD_SHARES;
        }
        _mint(msg.sender, sharesToMint);
        _registerHeldToken(token);
        // W5 (sc-oracle, returning): once per state-changing function, after held-tokens
        // bookkeeping completes -- see {_syncOutpricedStatus}'s own doc comment for why this
        // must never move inside a per-token loop.
        _syncOutpricedStatus();
    }

    /// @notice Preview the shares and USD value a `deposit(token, amount)` call would produce
    /// against the CURRENT on-chain state. Matches `_processDeposit`'s math exactly — this is a
    /// pure view over the same live NAV formula, not a separate or approximate calculation.
    /// @dev For ETH (`token == address(0)`), `amount` stands in for what would be `msg.value` on
    /// a real call — a view function cannot receive value, and unlike `deposit()` itself (which
    /// ignores its own `amount` parameter for ETH), `previewDeposit` needs an explicit amount to
    /// price. No ETH-netting is needed here (unlike `_processDeposit`): since no value actually
    /// moves in a view call, the `_calculateTotalValue()` read below is already the genuine
    /// pre-deposit basis for every token type.
    /// Reverts with the same errors `deposit()` would raise for the same inputs against the same
    /// state (`InvalidToken`, `ZeroAmount`), so a caller can treat a revert here as "this deposit
    /// would also revert."
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

        uint256 sharePriceBasis =
            supplyBeforeDeposit > 0 ? (totalValueBeforeDeposit * PRECISION) / supplyBeforeDeposit : INITIAL_TOKEN_PRICE;
        if (sharePriceBasis == 0) sharePriceBasis = INITIAL_TOKEN_PRICE;

        sharesToMint = (depositValue * PRECISION) / sharePriceBasis;
        if (sharesToMint == 0) revert ZeroAmount();

        // Mirrors `_processDeposit`'s carve-out exactly — see its doc comment for why this is
        // subtractive, not additive.
        if (supplyBeforeDeposit == 0) {
            if (sharesToMint <= DEAD_SHARES) revert FirstDepositTooSmall();
            sharesToMint -= DEAD_SHARES;
        }
    }

    /// @notice Live NAV share price (USD, 8 decimals) — the same basis `deposit()` now mints
    /// against and keeps each vault's own `tokenPrice` state synced to (this wave's decision;
    /// see W2-SC-ENTRY-REPORT.md). Falls back to `INITIAL_TOKEN_PRICE` when supply or total value
    /// is zero, per workspace CLAUDE.md §6.
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return INITIAL_TOKEN_PRICE;
        uint256 price = (_calculateTotalValue() * PRECISION) / supply;
        return price == 0 ? INITIAL_TOKEN_PRICE : price;
    }

    /// @dev Shared core of `previewRedeem()`: mirrors `redeem()`'s exact proportional-share
    /// arithmetic (shares/balance/supply guards, held-tokens payout loop, all-zero-payout
    /// revert) without mutating any state. Deliberately does NOT include PassiveBucket's
    /// additional owner-accountability check — that stays in PassiveBucket's own `previewRedeem`
    /// wrapper, exactly as `redeem()` itself is NOT unified between the two vaults
    /// (sc-vault-exit, W2-SC-EXIT-REPORT.md): ActiveBucket.redeem has no owner-accountability
    /// check at all, PassiveBucket.redeem has one that is orthogonal to this shared arithmetic.
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

    // ============================================================
    // isBucketAccountable
    //
    // Byte-identical in both children today (ActiveBucket.sol:569-573,
    // PassiveBucket.sol:425-429, confirmed identical in prior review of both files this wave).
    // ============================================================

    /**
     * @notice Check if the owner holds at least 1% of total supply
     * @dev ⚠ Was "5%" until 2026-09-30, matching `MIN_OWNER_BPS` at the time. Updated in the same
     * pass as `MIN_OWNER_BPS`'s reversal to `100` (see that constant's doc comment) so this
     * comment does not silently drift from the value it describes.
     * @return True if owner holds >= 1% or total supply is 0
     */
    function isBucketAccountable() public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return (balanceOf(owner()) * BPS_DENOMINATOR) / supply >= MIN_OWNER_BPS;
    }

    // Minimal token level to keep inside a ActiveBucket
    uint256 public constant BUCKET_CASH_FLOOR_BPS = 2000;

    function isBucketAboveCashLevel(uint256 shareToWithdraw) public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        uint256 _totalDepositValue = totalDepositValue();
        uint256 _totalShares = totalSupply();
        uint256 _totalValue = calculateTotalValue();
        if (shareToWithdraw == 0 || _totalShares == 0 || _totalDepositValue == 0) return true;
        if (shareToWithdraw >= _totalShares) return false;
        uint256 tokenPrice = getTokenPrice();
        uint256 minimumCashRequired1 = (_totalDepositValue * BUCKET_CASH_FLOOR_BPS) / BPS_DENOMINATOR;
        uint256 minimumCashRequired2 = (_totalValue * BUCKET_CASH_FLOOR_BPS) / BPS_DENOMINATOR;
        uint256 cashAfterWithdrawal = (_totalShares - shareToWithdraw) * tokenPrice;
        return minimumCashRequired1 <= cashAfterWithdrawal && minimumCashRequired2 <= cashAfterWithdrawal;
    }

    // ============================================================
    // Shared external admin functions
    //
    // Verified identical in both children (ActiveBucket.sol:394-408,435-446,453-455;
    // PassiveBucket.sol:654-663,708-719,729-731) — including access control: both gate
    // `recoverTokens` on plain `onlyOwner` (NOT PassiveBucket's `onlyAccountableOwner`, which is
    // reserved for distribution/DEX/fee administration), and both gate `updateBucketInfo` on the
    // *BucketInfo* owner, never the vault owner (workspace CLAUDE.md §1.1: "Even contract owners
    // should not able to change it" — the vault owner here is the untrusted customer, so this
    // must stay ungated by `onlyOwner`/`onlyAccountableOwner`). One cosmetic unification:
    // ActiveBucket's `recoverTokens` previously inlined the ETH-call/safeTransfer branch instead
    // of calling `_transferToken`; it now calls the shared helper, matching PassiveBucket's
    // pre-existing style, with identical behavior.
    // ============================================================

    /**
     * @notice Recover a non-whitelisted token (or ETH) accidentally sent to this contract.
     * @param token The token address to recover (`address(0)` for native ETH)
     * @param amount The amount to recover
     * @param to The recipient address
     */
    function recoverTokens(address token, uint256 amount, address to)
        external
        onlyOwnerNotBlacklisted
    {
        if (to == address(0)) revert ZeroAddress();
        if (_bucketInfo().isTokenWhitelisted(token)) {
            revert CannotRecoverWhitelistedToken(token);
        }

        _transferToken(token, to, amount);

        emit TokensRecovered(token, to, amount);
    }

    // ============================================================
    // updateBucketInfo — W3.2 REWRITE: propose (BucketInfo owner) + timelock + veto
    // (vault owner) + permissionless execute
    //
    // PRE-FIX (W1 extraction): a single call, gated on the CURRENT BucketInfo's owner,
    // applied the repoint immediately. root CLAUDE.md §1.1 / workspace 00:44 protects
    // investors from an oracle swap by a VAULT owner, but said nothing about protecting
    // them from an instant, unannounced repoint by the BucketInfo owner — the exact rug-pull
    // shape B5/D3 (`04-CONTRACTS-IMPLEMENTATION-PLAN.md` §1.4, §5.6) exist to close for every
    // other BucketInfo-owner-gated setter. D3 resolves it here the same way: propose, wait,
    // and give the vault's OWN owner (the customer whose funds are pointed at whatever
    // `bucketInfo` says) a window to veto before it applies.
    //
    // ⚠ Load-bearing coupling (04 §5.6, "B4 changed status"): this machinery is not merely a
    // governance nicety. It is the ONLY execution path for N2, the BucketInfo migration that
    // is the sole remedy for a `BucketInfo` bug (BucketInfo is permanently non-upgradeable,
    // A2, root CLAUDE.md §8). So `executeUpdateBucketInfo` below is deliberately
    // PERMISSIONLESS once the delay has elapsed and no veto arrived — an emergency repoint
    // across every deployed vault must be able to complete even if no single account is
    // responsible for calling "apply" on each one. Propose and veto stay access-controlled;
    // execute does not, mirroring TimelockedAdmin.sol's own header comment for this call site.
    // ============================================================

    /// @dev Vault-level propose→execute delay for `updateBucketInfo`. NO EXACT NUMBER WAS
    /// CLIENT-SPECIFIED for this veto window — `04-CONTRACTS-IMPLEMENTATION-PLAN.md` W3.2
    /// names the shape (propose + timelock + veto) but not a duration. Reuses the 48-hour
    /// figure the client gave for the vault upgrade timelock (`09-DECISION-LOG.md` §10.1) as
    /// an Inferred default, for the same reason `BucketInfo.sol`'s own
    /// `PLATFORM_SETTER_TIMELOCK_DELAY` does: identical rug-pull shape, and one
    /// platform-wide delay is preferable to inventing a second, unexplained number. Flagged
    /// for the client to confirm or override — see W3-SC-GOVERNANCE-REPORT.md
    /// `## Corrections to my briefing`.
    uint256 public constant BUCKET_INFO_UPDATE_TIMELOCK_DELAY = 48 hours;

    /**
     * @notice Propose updating the BucketInfo contract address.
     * @dev Gated on the CURRENT BucketInfo's owner — NOT this vault's own owner. See
     * workspace CLAUDE.md §1.1: a vault owner must never be able to swap its own price-feed
     * source; here it is the reverse-direction protection, the vault's investors, that the
     * veto window (below) exists for. Overwrites any existing pending proposal, mirroring
     * `Ownable2Step.transferOwnership`'s own single-pending-slot semantics.
     * @param newBucketInfo The proposed new BucketInfo contract address.
     */
    function proposeUpdateBucketInfo(address newBucketInfo) external {
        // ⚠ EIP-170 SIZE-RELIEF EXTRACTION (same rationale as {_authorizeUpgradeCommon} below —
        // see {GovernanceLib}'s header comment): the zero-check, the owner-address comparison,
        // the propose call, and the event emission all moved to
        // {GovernanceLib.proposeUpdateBucketInfo}. `GovernanceLib.ZeroAddress`/
        // `UnauthorizedBucketInfoUpdate`/`BucketInfoUpdateProposed` are selector-identical to this
        // contract's own same-named declarations above, which stay in place unused-at-runtime-here
        // because tests reference them by qualified name (`BucketVaultBase.<Error>.selector`) —
        // see {GovernanceLib}'s header comment.
        GovernanceLib.proposeUpdateBucketInfo(
            _getBucketVaultBaseStorage().bucketInfoUpdateTimelock,
            _bucketInfo(),
            newBucketInfo,
            BUCKET_INFO_UPDATE_TIMELOCK_DELAY
        );
    }

    /**
     * @notice Veto (cancel) a pending BucketInfo update before it takes effect.
     * @dev Gated on THIS vault's own owner — the customer whose funds are at stake — which is
     * the opposite gate from {proposeUpdateBucketInfo}. This is the D3 "veto window": the
     * BucketInfo owner proposes a repoint, and the vault owner alone may stop it during the
     * delay. A no-op (does not revert) if nothing is pending, matching
     * `TimelockedAdmin.cancel`'s own semantics.
     */
    function vetoUpdateBucketInfo() external onlyOwnerNotBlacklisted {
        GovernanceLib.vetoUpdateBucketInfo(_getBucketVaultBaseStorage().bucketInfoUpdateTimelock);
    }

    /**
     * @notice Execute a pending BucketInfo update once the timelock has elapsed and no veto
     * arrived.
     * @dev Deliberately PERMISSIONLESS — see the section doc comment above (N2's migration
     * runs through this call, across every deployed vault, and must not depend on any one
     * account remembering to call it). Reverts `TimelockedAdmin.NoProposalPending` if nothing
     * is pending (including if it was vetoed), or `TimelockedAdmin.TimelockNotElapsed` if
     * called before the delay has passed.
     */
    function executeUpdateBucketInfo() external {
        address oldBucketInfo = address(_bucketInfo());
        address newBucketInfo =
            GovernanceLib.executeUpdateBucketInfo(_getBucketVaultBaseStorage().bucketInfoUpdateTimelock, oldBucketInfo);
        _setBucketInfo(newBucketInfo);
    }

    /// @notice The currently-pending BucketInfo update, if any. `pending == address(0)` and
    /// `eta == 0` both zero means nothing is pending.
    function pendingBucketInfoUpdate() external view returns (address pending, uint256 eta) {
        TimelockedAdmin.AddressTimelock storage t = _getBucketVaultBaseStorage().bucketInfoUpdateTimelock;
        return (t.pending, t.eta);
    }

    // ============================================================
    // Upgrade governance — W3.3 (`09-DECISION-LOG.md` §10.1)
    //
    // Split authority, three parties: the PLATFORM decides WHAT code may run (via the
    // {IImplementationRegistry} each child points at through {_registry}/{_registryKind}); THIS
    // VAULT'S OWNER (the customer) decides WHETHER and WHEN their vault adopts it, by calling
    // {queueUpgrade} and then, 48 hours later, the proxy's own `upgradeToAndCall`; and every
    // OTHER investor in the vault gets that 48-hour window to exit before it takes effect. The
    // registry approval is re-checked at EXECUTION time inside {_authorizeUpgradeCommon}, not
    // merely at queue time, so a platform revocation mid-window actually blocks the upgrade —
    // the plan's own "test 3" (04 §5.6.1/§10.1), the scenario most likely to be omitted.
    //
    // {_authorizeUpgradeCommon} below is the shared body `ActiveBucket`/`PassiveBucket` each call
    // from a one-line `_authorizeUpgrade` override (UUPS calls `_authorizeUpgrade` itself, via its
    // own `upgradeToAndCall` entry point — see TimelockedAdmin.sol's header comment, which names
    // this exact split). `PureMembership` has no shared base to call into and carries its own,
    // fully duplicated copy of this section — see PureMembership.sol.
    //
    // Queues the ADDRESS, never a boolean: a boolean flag would let the queuer announce
    // implementation A and later execute implementation B, "worse than no window, because it
    // manufactures assurance" (04 §5.6.1c). {TimelockedAdmin.AddressTimelock} already stores an
    // address for exactly this reason.
    //
    // ⚠ Revocation-visibility caveat: nothing on THIS vault changes when the platform revokes
    // registry approval mid-window — {pendingImplementation}/{upgradeEta} keep reporting the same
    // queued entry right up until execution is attempted. A frontend reading only those two
    // getters cannot tell whether a pending upgrade can still execute; it would render a
    // countdown for an upgrade that may already be dead. Querying `isApproved` on the registry
    // directly is the only way to know.
    // ============================================================

    /// @dev Vault-level queue(propose)→execute delay for the UUPS upgrade path.
    /// CLIENT-CONFIRMED at exactly 48 hours, no bypass (`09-DECISION-LOG.md` §10.1 /
    /// `10-ANSWER:2`) — unlike {BUCKET_INFO_UPDATE_TIMELOCK_DELAY} above, this figure is NOT
    /// Inferred.
    uint256 public constant UPGRADE_TIMELOCK_DELAY = 48 hours;

    /**
     * @notice Queue a UUPS upgrade to `newImplementation`. Starts the 48-hour investor-exit
     * window.
     * @dev Gated on THIS vault's owner (the customer) — the customer decides whether and when to
     * adopt platform-approved code; the platform itself can never trigger an upgrade (root
     * CLAUDE.md §8: "the platform cannot push a fix into a vault"). Does NOT require registry
     * approval to queue — only to EXECUTE (see {_authorizeUpgradeCommon}) — so a customer may
     * queue in anticipation of an approval landing before the window elapses; the re-check at
     * execution is what actually gates it. Overwrites any existing pending upgrade, mirroring
     * {proposeUpdateBucketInfo}'s single-pending-slot semantics.
     * @param newImplementation The proposed new implementation contract address.
     */
    function queueUpgrade(address newImplementation) external onlyOwnerNotBlacklisted {
        // ⚠ EIP-170 SIZE-RELIEF EXTRACTION — see {GovernanceLib}'s header comment. `onlyOwner` is
        // enforced by the modifier above, unaffected by the extraction; only the zero-check,
        // propose call, and event emission moved.
        GovernanceLib.queueUpgrade(
            _getBucketVaultBaseStorage().upgradeTimelock, newImplementation, UPGRADE_TIMELOCK_DELAY
        );
    }

    /**
     * @notice Cancel a pending upgrade before it takes effect.
     * @dev Gated on this vault's owner — the same party who queued it. Revocation of platform
     * approval is achieved through the registry, not through a separate call here. A no-op (does
     * not revert) if nothing is pending, matching `TimelockedAdmin.cancel`'s own semantics.
     */
    function cancelUpgrade() external onlyOwnerNotBlacklisted {
        GovernanceLib.cancelUpgrade(_getBucketVaultBaseStorage().upgradeTimelock);
    }

    /// @notice Always reverts. Task #45 fix: shared by `ActiveBucket`/`PassiveBucket` (both
    /// inherit this base) -- see {RenounceOwnershipDisabled}'s doc comment for why this override
    /// was missing and what it would otherwise have permanently bricked. Single-step `Ownable`
    /// stays the only ownership base here (D-3) -- this does not introduce `Ownable2Step`.
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }

    /// @notice The currently-queued implementation address, if any. `address(0)` means nothing is
    /// queued.
    function pendingImplementation() external view returns (address) {
        return _getBucketVaultBaseStorage().upgradeTimelock.pending;
    }

    /// @notice The timestamp at which the currently-queued upgrade becomes executable, if any.
    /// `0` means nothing is queued.
    function upgradeEta() external view returns (uint256) {
        return _getBucketVaultBaseStorage().upgradeTimelock.eta;
    }

    /**
     * @dev Shared body of `_authorizeUpgrade`, called from a one-line override in each of
     * `ActiveBucket`/`PassiveBucket`. Enforces the four conditions from
     * `04-CONTRACTS-IMPLEMENTATION-PLAN.md` §5.6.1/§10.1:
     *   1. `msg.sender == owner()` — enforced by the `onlyOwner` modifier on the one-line
     *      override that calls into this function, NOT re-checked here.
     *   2. `newImplementation == pendingImplementation()` — the address actually being installed
     *      must be byte-identical to the one announced at queue time.
     *   3. `block.timestamp >= upgradeEta()` — the 48-hour window has elapsed, no bypass.
     *   4. `registry.isApproved(_registryKind(), newImplementation)` — re-checked HERE, at
     *      execution time, not merely at queue time (see the section doc comment above).
     * Conditions 2+3 are enforced together by `TimelockedAdmin.execute`, which reverts
     * `NoProposalPending` or `TimelockNotElapsed` as appropriate; condition 4 is checked
     * separately since the library knows nothing about the registry (TimelockedAdmin.sol's own
     * header comment). Any revert here reverts the whole transaction, so the pending entry is
     * NEVER actually consumed on a failed upgrade attempt, regardless of internal ordering.
     */
    function _authorizeUpgradeCommon(address newImplementation) internal {
        // Verifier fix (2026-10-04): the calling override's `onlyOwner` modifier only proves
        // `msg.sender == owner()`, not that the owner is clear of the blacklist -- an admin call
        // in the verifier's own words. Checked here, once, rather than in each of the three
        // one-line `_authorizeUpgrade` overrides that call into this shared body.
        _assertNotBlacklisted(msg.sender);
        // ⚠ EIP-170 SIZE-RELIEF EXTRACTION (W4.3 follow-on, see BucketVaultBase's
        // SeizureLib-extraction header comment above for the full rationale and the four
        // consolidation passes it documents): the mismatch check, the TimelockedAdmin.execute()
        // consumption, and the registry re-check all moved to {GovernanceLib.authorizeUpgrade} —
        // this function has real branching logic (a revert path, an external call, a second
        // revert path), the same shape that benefited from SeizureLib's own extraction, unlike
        // the trivial getters/cancels deliberately left inline. `_registry()`/`_registryKind()`
        // are `internal virtual` (each child overrides them) and so are resolved HERE, in the
        // calling contract, and passed to the library as plain values — a library cannot reach a
        // contract's own virtual dispatch table. `GovernanceLib.UpgradeImplementationMismatch`/
        // `UpgradeNotApproved` are selector-identical to this contract's own same-named errors
        // (declared above, and still required there — see that library's header comment — because
        // `test/ActiveBucket.t.sol`/`PassiveBucket.t.sol` reference `BucketVaultBase.<Error>.selector`
        // by qualified name; removing the local declaration would fail those tests to COMPILE, not
        // merely to pass, even though the revert's selector is identical either way).
        GovernanceLib.authorizeUpgrade(
            _getBucketVaultBaseStorage().upgradeTimelock, _registry(), _registryKind(), newImplementation
        );
    }

    /// @notice Total value of whitelisted tokens held by this contract (USD, 8 decimals).
    function calculateTotalValue() external view returns (uint256) {
        return _calculateTotalValue();
    }

    // ============================================================
    // Shared 1inch swap execution helper — W2 (sc-swap) REWRITE
    //
    // PRE-FIX (W1 extraction, see git history / W2-SC-SWAP-REPORT.md): this helper took
    // `bytes calldata swapCalldata` straight from the caller and forwarded it verbatim to
    // `oneInchRouter` via `.call`. Proven exploitable in test/OneInchSwapSecurity.t.sol
    // (`PreFixRebalanceBy1inchDrainTest`): because PassiveBucket.rebalanceBy1inch is
    // permissionless (share-balance-gated only), ANY shareholder could embed a call to an
    // attacker-controlled receiver and, once the router held an allowance (the ONLY missing
    // precondition per A4 / `09-DECISION-LOG.md` §4), drain the vault in a loop bounded only by
    // the per-call 0.5% cap. INV-2 requires that no arbitrary calldata is ever destined for an
    // external call, not even owner-gated — this rewrite replaces the caller-supplied blob with
    // four typed parameters and has this contract build 100% of the router calldata itself, so
    // there is no field left for a caller to redirect.
    //
    // Shared by ActiveBucket.swapBy1inch (ActiveBucket.sol) and PassiveBucket.rebalanceBy1inch
    // (PassiveBucket.sol) per INV-9 (every fix written once, never twice). Deliberately NOT
    // included here (see the contract-level doc comment for why):
    //  - Access control (`onlyOwner` for ActiveBucket vs. share-balance gate for PassiveBucket)
    //  - `_verifyDistribution()` (PassiveBucket-only, post-swap distribution check)
    //  - `_handleRebalanceFees(...)` (different parameter shapes per vault)
    //  - Event emission (`SwapExecuted` vs `Rebalanced`, different shapes)
    // Each child calls this helper, then does its own gating/fee/event work exactly as before.
    //
    // Hard rule 12 / R-V1 CORRECTION (`09-DECISION-LOG.md` §4.2a): an earlier revision of this
    // helper granted the router a scoped, same-transaction allowance
    // (`forceApprove(router, amount)` -> call -> `forceApprove(router, 0)`), reasoning that
    // replacing arbitrary calldata with typed parameters lifted the precondition hard rule 12
    // was written to prevent. That reasoning does not survive a direct read of the ruling: §4.2a's
    // table is drawn strictly BY DIRECTORY, not by whether the calldata is typed —
    // "`src/` | Forbidden without exception. No `approve`, `forceApprove`,
    // `safeIncreaseAllowance` or allowance-granting helper may be added to any contract." — and
    // §4.2a's own closing line removes the ambiguity: "What this ruling does NOT do: it does not
    // weaken the prohibition by one inch on any network, and it does not authorise making
    // `rebalanceBy1inch` succeed on Sepolia. If you are asked to make the swap work, the answer is
    // still that the typed-parameter fix ships first." Root `CLAUDE.md` hard rule 12's own R-V1
    // paragraph carries identical wording ("Forbidden, without exception: `src/` and `script/`.").
    // So this function now NEVER grants the router an allowance, for any token, under any
    // condition. An ERC20 `srcToken` swap therefore has no allowance to rely on and will fail at
    // the router's own `transferFrom` — bubbled via the N6 revert-reason logic below — exactly the
    // same fail-closed outcome every real Sepolia call already produces today (A4), just for an
    // architectural reason instead of a selector mismatch. Only native ETH (`srcToken ==
    // address(0)`) can ever actually move through this function, via `value:`, which needs no
    // allowance at all. Removing the grant does not regress any currently-working path: A4
    // confirms `rebalanceBy1inch`/`swapBy1inch` have never once succeeded against a real router.
    // ============================================================

    /// @dev Selector for the one, and only, router function this contract will ever construct
    /// calldata for: `execute1inchSwap(address srcToken, address dstToken, address dstReceiver,
    /// uint256 amount, uint256 minReturn)`. This IS the selector allowlist (item 2 of this
    /// wave's brief) — there is no code path in this contract that can ever produce a different
    /// selector, so "allowlisting" collapses to "the contract never builds anything else."
    /// Chosen as a minimal, fully-typed stand-in for 1inch AggregationRouterV5's `swap(...)`
    /// (executor/description/permit/data) shape; the real router call has never once succeeded
    /// on Sepolia (A4), so byte-for-byte ABI compatibility with the real router is not something
    /// this wave can verify against source, and is explicitly out of scope — see
    /// W2-SC-SWAP-REPORT.md "Design calls this wave made". What IS in scope, and what this
    /// selector's shape guarantees, is that the receiver field can never be anything other than
    /// `address(this)`, because this contract is the only thing that ever writes it.
    bytes4 public constant ONEINCH_SWAP_SELECTOR =
        bytes4(keccak256("execute1inchSwap(address,address,address,uint256,uint256)"));

    /**
     * @dev Executes a 1inch-router swap from fully-typed, contract-validated parameters, and
     * enforces both the pre-commitment oracle-derived `minReturn` floor and the existing
     * post-hoc `MAX_VALUE_LOSS_BPS` (0.5%) value-loss bound as two INDEPENDENT guards. Also
     * enforces the shared per-caller/global swap cooldown and the cumulative per-epoch
     * value-loss budget (see the constants/state below). Caller (each vault's own external
     * entry point) is responsible for its own access control, distribution/accountability
     * checks, fee handling, and event emission.
     * @param srcToken Token being sold (address(0) = native ETH). Must be `isTokenValid`.
     * @param dstToken Token being bought (address(0) = native ETH). Must be `isTokenValid` and
     * different from `srcToken`.
     * @param amount Amount of `srcToken` to swap, in its native units. Bounded by this vault's
     * OWN held balance of `srcToken` — see W2-SC-SWAP-REPORT.md for why a balance bound, not a
     * distribution-delta bound, is what a helper shared across both vault TYPES can enforce.
     * @param minReturn Minimum acceptable amount of `dstToken` out, in its native units. Must
     * clear an oracle-derived floor BEFORE the swap executes (pre-commitment), independent of
     * the post-hoc value-loss check below.
     * @return totalValueBefore Total vault value (USD 8-dec) immediately before the swap
     * @return totalValueAfter Total vault value (USD 8-dec) immediately after the swap
     */
    function _execute1inchSwap(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        internal
        returns (uint256 totalValueBefore, uint256 totalValueAfter)
    {
        _validateSwapLeg(srcToken, dstToken, amount, minReturn);

        // Shared per-caller + global cooldown (also enforced by PassiveBucket.rebalanceByDefi,
        // which does not route through this helper — see that function's own call site).
        //
        // W5 (sc-stable-exit, task #64) EXTRACTION NOTE: this call stays exactly here, in exactly
        // this order relative to the validation above and the core swap below, so this function's
        // own external behavior for its two PRE-EXISTING callers (ActiveBucket.swapBy1inch,
        // PassiveBucket.rebalanceBy1inch) is BYTE-FOR-BYTE unchanged by the extraction below —
        // same checks, same order, same reverts. `redeemForStable()` cannot route through this
        // function at all for exactly this reason: it needs ONE cooldown charge for potentially
        // MANY legs in one call, not one charge per leg (see that function's own doc comment for
        // why a naive per-leg call here would make a multi-token basket structurally unredeemable
        // via this path). It instead calls `_enforceSwapCooldown` once, itself, then calls
        // `_validateSwapLeg` + `_executeSwapNoCooldown` directly per leg — the same two pieces
        // this function is now built from, just re-sequenced around a single shared cooldown
        // charge instead of this function's fixed one-charge-per-call shape.
        _enforceSwapCooldown(msg.sender);

        return _executeSwapNoCooldown(srcToken, dstToken, amount, minReturn);
    }

    /// @dev The front half of `_execute1inchSwap`: every check that must hold BEFORE either the
    /// cooldown is charged or the router is called, for one `(srcToken, dstToken, amount,
    /// minReturn)` leg. Extracted (W5, sc-stable-exit, task #64) so `redeemForStable()` can run
    /// this same per-leg validation for EVERY leg of a multi-token basket without each leg also
    /// re-charging the shared swap cooldown — see `_execute1inchSwap`'s own doc comment on why
    /// that function itself is unchanged by this split.
    ///
    /// W5 EIP-170 size-relief (2026-10-01): thin wrapper. Body (including the former
    /// `_assertMinReturnAboveFloor`, its only call site) moved verbatim to
    /// {SwapExecutionLib.validateSwapLeg} — see that library's header comment for why.
    /// `heldBalance`/`srcDec`/`dstDec` are NOT pre-computed here and passed in any more — an
    /// earlier version of this wrapper did that, and because Solidity evaluates call arguments
    /// before making the call, it ran `_getTokenDecimals(dstToken)` (an external call touching
    /// `dstToken` directly) BEFORE the library's own whitelist check, letting a non-whitelisted,
    /// non-contract `dstToken` revert with empty data instead of `InvalidToken(dstToken)`. Caught
    /// by `OneInchSwapSecurity.t.sol`'s post-fix regression test. Fixed by moving the
    /// balance/decimals fetch inside {SwapExecutionLib.validateSwapLeg} itself, after its
    /// whitelist checks — see that function's own comment for the full account.
    function _validateSwapLeg(address srcToken, address dstToken, uint256 amount, uint256 minReturn) internal view {
        SwapExecutionLib.validateSwapLeg(_bucketInfo(), srcToken, dstToken, amount, minReturn);
    }

    /// @dev The back half of `_execute1inchSwap`: build-and-dispatch the router call plus the
    /// post-hoc value-loss/epoch-budget checks, assuming the caller has ALREADY run
    /// `_validateSwapLeg` and charged whatever cooldown applies to this call. Extracted (W5,
    /// sc-stable-exit, task #64) for the same reason as `_validateSwapLeg` — see
    /// `_execute1inchSwap`'s doc comment.
    ///
    /// W5 EIP-170 size-relief (2026-10-01): the build-calldata/decode-receiver/dispatch-call
    /// core is now a thin wrapper around {SwapExecutionLib.dispatchSwap} — see that library's
    /// header comment for the full history (PassiveBucket runtime margin went to -1,446 B after
    /// `redeemForStable`'s addition). Hard rule 12 / R-V1 applies identically: it is the SAME
    /// code this function always ran here, byte-for-byte, just relocated — it still NEVER grants
    /// the router an allowance, for any token, under any condition. The before/after
    /// `_calculateTotalValue()` value-loss accounting and the epoch-budget call stay inline here
    /// (not moved) because `_calculateTotalValue` itself is unmoved and `_consumeEpochValueLossBudget`
    /// needs this contract's own storage — see that function's own "extraction tried and
    /// reverted" comment below. Internal and uncallable from outside this contract hierarchy, so
    /// this second entry point cannot be reached except through `_execute1inchSwap` itself or
    /// `redeemForStable`, both of which charge a cooldown before ever calling it.
    function _executeSwapNoCooldown(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        internal
        returns (uint256 totalValueBefore, uint256 totalValueAfter)
    {
        totalValueBefore = _calculateTotalValue();

        SwapExecutionLib.dispatchSwap(_oneInchRouter(), ONEINCH_SWAP_SELECTOR, srcToken, dstToken, amount, minReturn);

        totalValueAfter = _calculateTotalValue();

        _checkValueLossAndConsumeBudget(totalValueBefore, totalValueAfter);
    }

    /// @dev EIP-170 size-relief (2026-10-04): this exact 5-line block — the post-hoc
    /// `MAX_VALUE_LOSS_BPS` (0.5%) per-call bound plus the cumulative per-epoch budget consume —
    /// used to be duplicated byte-for-byte in two places: inline here in
    /// {_executeSwapNoCooldown}, and inline again in `PassiveBucket.rebalanceByDefi` (which never
    /// calls {_executeSwapNoCooldown}, since it dispatches through a different DEX-aggregation
    /// path, so the two copies were never deduplicated by the earlier `_execute1inchSwap`/
    /// `rebalanceBy1inch` consolidation). ActiveBucket has no such inline copy (confirmed by grep
    /// for `ValueLossTooHigh`/`_consumeEpochValueLossBudget`), so this was PassiveBucket-only
    /// waste: one copy via this inherited function's body, one via PassiveBucket's own. Collapsing
    /// both call sites onto this one shared function removes one full copy of the arithmetic +
    /// revert + call from PassiveBucket's bytecode, leaving only a cheap `JUMP` at each site. Same
    /// condition, same revert, same budget call, pure relocation — no behavior change.
    function _checkValueLossAndConsumeBudget(uint256 totalValueBefore, uint256 totalValueAfter) internal {
        if (totalValueAfter < totalValueBefore) {
            uint256 loss = totalValueBefore - totalValueAfter;
            uint256 maxLoss = (totalValueBefore * MAX_VALUE_LOSS_BPS) / BPS_DENOMINATOR;
            if (loss > maxLoss) {
                revert ValueLossTooHigh(totalValueBefore, totalValueAfter);
            }
            _consumeEpochValueLossBudget(totalValueBefore, loss);
        }
    }

    /// @dev W5 (sc-stable-exit, task #64): per-leg `minReturn` for `redeemForStable()`, derived
    /// from the CALLER's own slippage tolerance (`maxSlippageBps`) instead of the hardcoded
    /// `MIN_RETURN_FLOOR_TOLERANCE_BPS` constant — same multiply-before-divide shape as
    /// `_assertMinReturnAboveFloor` immediately above (workspace CLAUDE.md §6), just
    /// parametrised by a variable tolerance instead of a fixed one.
    /// @dev This can only TIGHTEN what `_validateSwapLeg` (via `_assertMinReturnAboveFloor`)
    /// separately and unconditionally enforces on every leg, never loosen it: that call re-derives
    /// and enforces the platform's hardcoded 1% floor regardless of the `minReturn` this function
    /// hands it, so a caller passing a looser `maxSlippageBps` than the platform floor simply gets
    /// a `minReturn` that falls BELOW that floor and reverts `MinReturnBelowFloor` — the same
    /// outcome as asking for more slippage than any other swap entry point in this codebase
    /// permits. A `maxSlippageBps` tighter than the platform floor is the only way this value ever
    /// becomes the binding constraint.
    /// @param maxSlippageBps Caller-supplied tolerance in bps, clamped to `BPS_DENOMINATOR`
    /// (100%) so a caller mistake here cannot underflow the subtraction below.
    /// @dev W5 EIP-170 size-relief (2026-10-01): thin wrapper. Body moved verbatim to
    /// {SwapExecutionLib.minReturnForStableLeg} — see that library's header comment for why
    /// (PassiveBucket runtime margin went to -1,446 B after this function's own addition).
    /// `heldBalance`/`srcDec`/`dstDec` are no longer pre-computed and passed in here — see
    /// {SwapExecutionLib.validateSwapLeg}'s comment for why an earlier version of that sibling
    /// wrapper's eager pre-computation was an ordering bug, fixed the same way on both.
    function _minReturnForStableLeg(address srcToken, address dstToken, uint256 amount, uint256 maxSlippageBps)
        internal
        view
        returns (uint256 minReturn)
    {
        return SwapExecutionLib.minReturnForStableLeg(_bucketInfo(), srcToken, dstToken, amount, maxSlippageBps);
    }

    /// @dev Shared per-caller AND global cooldown, enforced on every swap/rebalance action —
    /// the 1inch path (via `_execute1inchSwap` above) and PassiveBucket.rebalanceByDefi (called
    /// directly from that function, since it never routes through this helper). Residual
    /// ambiguity: the plan did not specify a duration; `CALLER_SWAP_COOLDOWN` /
    /// `GLOBAL_SWAP_COOLDOWN` below are this wave's documented defaults — see
    /// W2-SC-SWAP-REPORT.md "Residual ambiguities with a default".
    function _enforceSwapCooldown(address caller) internal {
        // W5 EIP-170 size-relief (2026-10-01): thin wrapper around
        // {SwapExecutionLib.enforceSwapCooldown}, passing the cooldown state BY STORAGE
        // REFERENCE (see the `swapCooldown` field comment above). This is a DIFFERENT signature
        // from the "4 value params + 2 return values" shape tried and reverted earlier this
        // session (that one measured WORSE) — a storage ref ABI-encodes as a single word and the
        // library mutates it in place, no return-value marshaling at all. Re-measured via
        // `forge build --sizes` after this change, per hard rule 13 — not assumed. See
        // GovernanceLib.sol's header comment for the extractions that DID work.
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        SwapExecutionLib.enforceSwapCooldown($.swapCooldown, caller);
    }

    /// @dev Cumulative per-epoch value-loss budget, independent of (and in addition to) the
    /// per-call MAX_VALUE_LOSS_BPS bound. Rolls over to a fresh epoch/budget once
    /// VALUE_LOSS_EPOCH_LENGTH has elapsed since the current epoch started. Called both from
    /// `_execute1inchSwap` above and directly from PassiveBucket.rebalanceByDefi.
    ///
    /// W5 EIP-170 size-relief (2026-10-01): thin wrapper around
    /// {SwapExecutionLib.consumeEpochValueLossBudget}, now passing the epoch-budget fields BY
    /// STORAGE REFERENCE (see the `epochLossBudget` field comment above) rather than by value.
    /// This is a DIFFERENT signature from the one tried and reverted earlier this session (that
    /// attempt passed/returned several plain `uint256`s, which measured worse) — a storage ref
    /// ABI-encodes as a single word and the library mutates it in place, so there is no
    /// return-value marshaling cost at all. Re-measured via `forge build --sizes` after this
    /// change, per hard rule 13 — not assumed.
    function _consumeEpochValueLossBudget(uint256 totalValueBeforeCall, uint256 lossUsd) internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        SwapExecutionLib.consumeEpochValueLossBudget($.epochLossBudget, totalValueBeforeCall, lossUsd);
    }

    // ============================================================
    // Held-tokens registry — NEW shared infrastructure
    //
    // Neither ActiveBucket nor PassiveBucket tracks which tokens it currently holds a nonzero
    // balance of today; both instead iterate the FULL BucketInfo whitelist on every value
    // calculation (see `_calculateTotalValue` above). This registry is new state, backed by OZ
    // `EnumerableSet.AddressSet` in the ERC-7201 namespaced slot declared above, so it can be
    // added without touching either child's existing linear storage.
    //
    // ⚠ DEFERRED, EXPLICITLY: this registry is built and MAINTAINED (kept accurate across
    // deposit/swap) by this wave (W1, sc-refactor-base), but it is NOT wired into `redeem`'s
    // payout loop. `redeem` in both children keeps iterating its existing token source
    // (`getWhitelistedTokens()` for ActiveBucket, `_bucketDistributions` for PassiveBucket)
    // completely unchanged by this refactor. Consuming this registry inside `redeem` — e.g. to
    // pay out only tokens actually held, or to bound gas by held-token count instead of full
    // whitelist size — is future W2 work for `sc-vault-exit`. This preserves INV-1 (redemption
    // depends on nothing but share arithmetic) as a property to be reasoned about fresh in W2,
    // rather than silently changed as a side effect of this wave.
    //
    // Callers (each child's `deposit`/swap functions) are responsible for calling
    // `_registerHeldToken`/`_syncHeldTokenByBalance` at the right points; this base contract
    // does not call them automatically from anywhere; per the deferral above, nothing yet reads
    // this registry as ground truth for a monetary action.
    // ============================================================

    /// @dev Adds `token` to the held-tokens set if this contract currently holds a nonzero
    /// balance of it. Idempotent (EnumerableSet.add is a no-op if already present).
    function _registerHeldToken(address token) internal {
        if (_getTokenBalance(token) > 0) {
            _getBucketVaultBaseStorage().heldTokens.add(token);
        }
    }

    /// @dev Re-derives held/not-held for `token` from its current on-contract balance: adds it
    /// if balance > 0, removes it if balance == 0. Use after a swap that may have zeroed out or
    /// newly acquired a token.
    /// @dev W5 (sc-oracle, size relief): delegates to {PayoutLib} -- pure bytecode relocation,
    /// same body, same semantics. See {PayoutLib}'s header comment.
    function _syncHeldTokenByBalance(address token) internal {
        PayoutLib.syncHeldTokenByBalance(_getBucketVaultBaseStorage().heldTokens, token);
    }

    /// @dev Re-syncs every currently-whitelisted token's held/not-held status. Bounded by
    /// whitelist size, same as `_calculateTotalValue` — intended for use after a rebalance that
    /// may touch any whitelisted token (e.g. PassiveBucket.rebalanceByDefi).
    /// @dev W5 (sc-oracle, size relief): delegates to {PayoutLib} -- pure bytecode relocation.
    function _syncAllHeldTokensFromWhitelist() internal {
        PayoutLib.syncAllHeldTokensFromWhitelist(
            _getBucketVaultBaseStorage().heldTokens, _bucketInfo().getWhitelistedTokens()
        );
    }

    /// @notice Number of tokens currently tracked as held by this vault.
    function heldTokensCount() external view returns (uint256) {
        return _getBucketVaultBaseStorage().heldTokens.length();
    }

    /// @notice The held token at `index` (0-based, order not guaranteed stable across removals).
    function heldTokenAt(uint256 index) external view returns (address) {
        return _getBucketVaultBaseStorage().heldTokens.at(index);
    }

    /// @notice Whether `token` is currently tracked as held by this vault.
    function isHeldToken(address token) external view returns (bool) {
        return _getBucketVaultBaseStorage().heldTokens.contains(token);
    }

    /// @notice All tokens currently tracked as held by this vault.
    function getHeldTokens() external view returns (address[] memory) {
        return _getBucketVaultBaseStorage().heldTokens.values();
    }

    /// @dev Internal counterpart to {getHeldTokens}, for children's own logic (W2,
    /// sc-vault-exit: `redeem()`'s payout loop). A separate wrapper exists because
    /// `_getBucketVaultBaseStorage()` is `private` to this contract, not `internal`.
    function _heldTokensList() internal view returns (address[] memory) {
        return _getBucketVaultBaseStorage().heldTokens.values();
    }

    /// @notice Whether any currently-held token was flagged by BucketInfo as potentially
    /// outpriced AS OF THE LAST state-changing call (deposit/redeem/swap/rebalance) that invoked
    /// {_syncOutpricedStatus} — a cached read of `outpricedTracker.lastKnownOutpriced`, NOT a
    /// fresh on-chain recomputation.
    /// @dev Deliberately cheap (a single storage read, no loop, no external call) rather than
    /// delegating to {OraclePricingLib.isAnyOutpriced} on every call — EIP-170 size relief:
    /// PassiveBucket's runtime margin cannot absorb a third loop-based oracle view alongside
    /// {getOutpricedHeldTokens}/{getManualPricedHeldTokens} below, which DO recompute live and
    /// are the authoritative source if a caller needs this instant's true state rather than the
    /// state as of the vault's last interaction. In practice these coincide for any token whose
    /// price only goes stale through time (not through a vault-side mutation) only until someone
    /// next deposits/redeems/swaps — the same gap already exists for every other on-chain
    /// statistic nothing continuously repolls.
    function isAnyHeldTokenPotentiallyOutpriced() external view returns (bool) {
        return _getBucketVaultBaseStorage().outpricedTracker.lastKnownOutpriced;
    }

    /// @notice The subset of currently-held tokens flagged by BucketInfo as potentially
    /// outpriced (stale/invalid Chainlink data) — W5 (sc-oracle, returning), the plan's §5.1
    /// "which tokens" inventory, as opposed to {isAnyHeldTokenPotentiallyOutpriced}'s cached
    /// boolean.
    /// @dev Delegates to {OraclePricingLib} (EIP-170 size relief) — measured via
    /// `forge build --sizes` that an inline copy of this loop cost PassiveBucket substantially
    /// MORE bytecode than the library DELEGATECALL version, the opposite of what an inline
    /// `isAnyHeldTokenPotentiallyOutpriced`-shaped loop would suggest. Kept delegated on direct
    /// measurement, not assumption.
    function getOutpricedHeldTokens() external view returns (address[] memory) {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        return OraclePricingLib.getOutpricedHeldTokens(_bucketInfo(), $.heldTokens);
    }

    /// @notice The subset of currently-held tokens with no Chainlink feed configured at all
    /// (manually priced) — W5 (sc-oracle, returning), the plan's §5.1 manual-price inventory
    /// view. See {OraclePricingLib}'s header comment for why this is a DIFFERENT set from
    /// {getOutpricedHeldTokens}, not a subset or superset of it in general.
    /// @dev Delegates to {OraclePricingLib} (EIP-170 size relief). Deliberately kept as a
    /// SEPARATE function from {getOutpricedHeldTokens} rather than combined into one
    /// two-array-returning function: measured that combining the two INCREASED PassiveBucket's
    /// compiled size relative to two separate single-array-returning delegated functions — the
    /// opposite of the intended size relief. Kept separate and delegated on direct measurement.
    function getManualPricedHeldTokens() external view returns (address[] memory) {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        return OraclePricingLib.getManualPricedHeldTokens(_bucketInfo(), $.heldTokens);
    }

    /// @dev Thin wrapper so children (ActiveBucket/PassiveBucket) can trigger the
    /// aggregate-outpriced-status sync without reaching into this contract's `private` storage
    /// getter directly. All loop logic and the {OraclePricingLib.OutpricedStatusChanged} emission
    /// live in {OraclePricingLib} (EIP-170 size relief, protecting PassiveBucket's tight runtime
    /// margin — see that library's header). Call exactly ONCE per state-changing function, after
    /// its own per-token loop/registry-sync work completes: see the four call sites in this file,
    /// `ActiveBucket.sol`, and `PassiveBucket.sol` (deposit finalization above; each vault's
    /// redeem payout loop; each vault's swap/rebalance held-token resync).
    function _syncOutpricedStatus() internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        OraclePricingLib.syncOutpricedStatus($.outpricedTracker, _bucketInfo(), $.heldTokens);
    }

    /// @notice W5 (sc-oracle, size relief): thin wrapper so each child's `redeem()` can run its
    /// payout-transfer loop via {PayoutLib} without reaching into this contract's `private`
    /// storage getter directly — same reason {_syncOutpricedStatus} exists.
    /// @dev Pure bytecode relocation. Before this extraction, `ActiveBucket.redeem` and
    /// `PassiveBucket.redeem` each ran an IDENTICAL inline loop here (transfer each nonzero
    /// amount via {_transferToken}, {_syncHeldTokenByBalance}, emit `TokenReturned`) — the W5
    /// oracle inventory views ({OraclePricingLib}) pushed PassiveBucket's `forge build --sizes`
    /// margin negative even after that extraction alone, and this duplicated loop (a real
    /// external-call-per-iteration loop, not a trivial getter) was the next-cheapest real win.
    /// See {PayoutLib}'s header comment for the full rationale and the DELEGATECALL
    /// `address(this)` precedent this relies on.
    function _payoutAndSync(address to, address[] memory tokens, uint256[] memory returnAmounts) internal {
        PayoutLib.payoutAndSync(_getBucketVaultBaseStorage().heldTokens, to, tokens, returnAmounts);
    }

    // ============================================================
    // Stable-exit redemption — W5 (sc-stable-exit, SC-9, task #64)
    //
    // `00-EXECUTIVE-SUMMARY-USER-REPLY.md:22` / `04-CONTRACTS-IMPLEMENTATION-PLAN.md:1046`:
    // redeem shares for a SINGLE stable token instead of the raw multi-token basket, by swapping
    // the redeemer's basket portion into that token within a caller-chosen slippage tolerance.
    // SIBLING of `redeem()`, never a replacement (`04:222-226`) — `redeem()` stays the guaranteed,
    // oracle-independent exit that works even if every price feed and the router itself are down;
    // this additional path trades that guarantee for convenience (needs a live oracle AND a live,
    // successful router call for every non-`dstToken` leg) and is scoped to `base/` only
    // (`04:1160`'s file-ownership table), so it is written ONCE here and inherited by both
    // children unchanged (INV-9) rather than duplicated per vault the way `redeem()` itself is.
    //
    // ⚠ PotentialRugpull scoping, flagged for the W5 report, NOT resolved here: `00:22` names
    // "rugpull" alongside "passive or active" for this feature, but `PotentialRugpull.sol` does
    // NOT inherit `BucketVaultBase` (see its own DECISION 1 header) and so does not gain this
    // function via inheritance. `04:1160`'s own scoping table says "base/ stable-exit function
    // only," which this implementation follows literally. Recorded as a conflict for task #67,
    // not silently decided — PotentialRugpull's single-cashRatio-variable constructor and
    // non-upgradeable architecture make an equivalent function there a materially different
    // design exercise, not a copy-paste of this one, so it is deliberately left out of THIS task.
    // ============================================================

    /**
     * @notice Redeem `shares` for a single stable token (`dstToken`) instead of the raw basket —
     * swaps the redeemer's proportional basket portion into `dstToken` within `maxSlippageBps`,
     * then sends the combined `dstToken` proceeds to the caller.
     * @dev Shares/supply/held-token enumeration is `_previewRedeemCore` — byte-identical to what
     * `redeem()` itself uses, so the amounts owed per token are exactly what a plain `redeem()`
     * call would have paid out. Each nonzero, non-`dstToken` leg is swapped via the cooldown-free
     * back half of `_execute1inchSwap` (`_executeSwapNoCooldown`, reached via `_validateSwapLeg`
     * first — see both functions' doc comments for the extraction that made this possible) — no
     * new calldata-construction surface, and hard rule 12 is satisfied structurally: that function
     * is the SAME code every other swap entry point in this codebase uses, and it never grants
     * the router an allowance, for any token, under any condition. An ERC20 leg therefore fails
     * exactly the way every ERC20 1inch swap in this codebase fails today (A4) until the calldata
     * integration itself goes live.
     *
     * The cooldown is charged exactly ONCE for this entire call (`_enforceSwapCooldown`, right
     * after the burn, before the per-leg loop) — NOT once per leg. A naive implementation calling
     * `_execute1inchSwap` directly per leg would charge the cooldown on the first leg and then
     * have every subsequent leg in the SAME transaction revert `SwapCooldownActive`, since
     * `block.timestamp` cannot advance within one transaction — making this function structurally
     * able to redeem at most one non-`dstToken` asset per call. This is why `redeemForStable`
     * cannot simply call `_execute1inchSwap`, and why that function was split in this same task.
     *
     * Reverts, never partially fills: there is no try/catch anywhere in this function, so a
     * failure on ANY leg (bad floor, router revert, value-loss cap, insufficient balance) reverts
     * the WHOLE call, burn included — the caller never ends up holding a half-swapped mix of
     * basket tokens and `dstToken`.
     *
     * `dstToken` clears the same `isTokenValid` whitelist precondition every other swap leg in
     * this codebase clears — there is no separate "is this really a stablecoin" check; the
     * platform whitelist is the only gate, exactly as for every other token this contract moves.
     *
     * ⚠ Owner-accountability parity, a DELIBERATE deviation flagged for the W5 report: this
     * function applies PassiveBucket's existing `isBucketAccountable()` / `MIN_OWNER_BPS`
     * before-AND-after guard UNCONDITIONALLY to both vault types — `ActiveBucket.redeem()` has no
     * such guard at all today. Because this function lives ONLY in `base/` and is therefore
     * shared verbatim by both children, applying the STRICTER of the two existing `redeem()`
     * behaviours everywhere is the only choice that cannot turn this new function into an
     * accidental bypass of PassiveBucket's existing accountability floor. Net effect: an
     * ActiveBucket owner redeeming via this function is held to a restriction `redeem()` itself
     * does not impose on them for that vault type — strictly more conservative, never less.
     *
     * @param shares Shares to redeem — identical validity rules to `redeem(shares)`.
     * @param dstToken The single stable token to receive. Must be `isTokenValid`.
     * @param maxSlippageBps Caller's own slippage tolerance (bps), applied per leg via
     * `_minReturnForStableLeg`. Can only tighten the protocol's existing per-swap floor, never
     * loosen it — see that function's doc comment.
     * @return totalStableOut Total `dstToken` transferred to the caller.
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

        // Owner accountability check (before) — see this function's doc comment on why this is
        // applied unconditionally to both vault types, mirroring PassiveBucket.redeem().
        bool isOwnerCaller = (msg.sender == owner());
        if (isOwnerCaller && !isBucketAccountable()) revert OwnerNotAccountable();

        (address[] memory tokens, uint256[] memory amounts) = _previewRedeemCore(shares);

        // Burn shares (effect) — before any swap, exactly as `redeem()` burns before its payout
        // loop, so a swap failure below reverts a burn that already happened rather than leaving
        // shares burned with no corresponding payout (the revert unwinds the burn too).
        _burn(msg.sender, shares);

        // ONE cooldown charge for the whole call — see this function's doc comment and
        // `_execute1inchSwap`'s own doc comment for why charging it once here, rather than once
        // per leg via `_execute1inchSwap` itself, is what makes a multi-token basket redeemable
        // via this path at all.
        _enforceSwapCooldown(msg.sender);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;

            if (tokens[i] == dstToken) {
                // Already the target stable token — no swap needed for this leg.
                totalStableOut += amount;
                continue;
            }

            uint256 legMinReturn = _minReturnForStableLeg(tokens[i], dstToken, amount, maxSlippageBps);
            _validateSwapLeg(tokens[i], dstToken, amount, legMinReturn);

            // Balance-delta measurement: `_executeSwapNoCooldown` returns vault-wide USD value,
            // not the per-leg token amount received, so the actual `dstToken` received for THIS
            // leg is measured directly off this contract's own balance before/after the call.
            uint256 dstBalBefore = _getTokenBalance(dstToken);
            _executeSwapNoCooldown(tokens[i], dstToken, amount, legMinReturn);
            uint256 received = _getTokenBalance(dstToken) - dstBalBefore;

            // Verifier fix (2026-10-04): `legMinReturn` above is only ever passed INTO the
            // router's own calldata (via `_executeSwapNoCooldown` -> `dispatchSwap`) -- it is
            // advisory to the router, not self-enforcing. `_executeSwapNoCooldown`'s own
            // post-hoc guard checks the WHOLE VAULT's value before/after against
            // `MAX_VALUE_LOSS_BPS`, which a router that short-pays THIS ONE leg can clear
            // comfortably if the leg is small relative to total vault value (e.g. a leg worth
            // 5% of the vault, short-paid 10%, is only a 0.5% whole-vault loss -- right at the
            // boundary -- and a smaller leg clears it with room to spare). `legMinReturn` is
            // already derived (via `_minReturnForStableLeg`) to be within the caller's own
            // `maxSlippageBps` of this leg's fair USD value, so checking the ACTUAL measured
            // `received` against it directly is what "make sure what investor receive is close
            // to what they withdraw in value" (owner's own instruction) requires for THIS
            // specific redemption, independent of the whole-vault check above. Reverts the
            // entire call (per this function's existing "reverts, never partially fills"
            // guarantee) rather than silently paying the redeemer less than they were quoted.
            if (received < legMinReturn) revert ReceivedBelowMinReturn(received, legMinReturn);

            totalStableOut += received;

            // Keep the held-tokens registry accurate for this leg's source token immediately —
            // mirrors the discipline `swapBy1inch`/`rebalanceBy1inch` already follow after every
            // swap, just targeted at the one token this leg actually touched.
            _syncHeldTokenByBalance(tokens[i]);
        }

        // Defensive re-check: `_previewRedeemCore` already reverts `NothingToRedeem` when every
        // basket amount is zero, so this should be unreachable in practice — kept anyway as a
        // belt-and-braces guard against ever transferring zero `dstToken` out, matching this
        // file's existing double-guard style elsewhere (e.g. `_assertMinReturnAboveFloor`'s own
        // defensive zero-price bound).
        if (totalStableOut == 0) revert NothingToRedeem();

        // Transfer the combined dstToken proceeds (interaction) — after every leg has settled,
        // so a later leg's failure still reverts this transfer along with everything else.
        _transferToken(dstToken, msg.sender, totalStableOut);
        _syncHeldTokenByBalance(dstToken);
        emit TokenReturned(msg.sender, dstToken, totalStableOut);

        // Owner accountability check (after) — mirrors PassiveBucket.redeem() exactly.
        if (isOwnerCaller && !isBucketAccountable()) revert OwnerNotAccountable();

        emit RedeemedForStable(msg.sender, shares, totalSupply(), dstToken, totalStableOut, tokens, amounts);

        // W5 (sc-oracle, returning): once per state-changing function, after all per-token work
        // above completes — never inside a loop, or this becomes O(n^2).
        _syncOutpricedStatus();
    }
}

