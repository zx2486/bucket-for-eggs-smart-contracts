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
 *    `IFlashLoanReceiver` specific to ActiveBucket's owner-directed model.
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
        mapping(address => uint256) callerSwapCooldownUntil;
        uint256 globalSwapCooldownUntil;
        uint256 currentEpochStart;
        uint256 currentEpochValueLossUsd;
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

    /// @dev Floor on the owner's retained fee share in a rebalance fee split.
    uint256 public constant MIN_OWNER_BPS = 100;

    /// @dev Ceiling, in bps, on value lost across a single swap before it reverts.
    uint256 public constant MAX_VALUE_LOSS_BPS = 50;

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
    error ZeroAmount();
    error InvalidRedeemAmount();
    /// @dev W2 (sc-vault-exit): every per-token payout in `redeem()` rounded to zero (e.g.
    /// `shares` too small relative to the vault's held-token balances). Previously this burned
    /// the caller's shares and emitted `Redeemed` with no token transfer at all — a silent
    /// success that destroyed value and returned nothing. See ActiveBucket.redeem /
    /// PassiveBucket.redeem.
    error NothingToRedeem();
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
    event TokenReturned(address indexed user, address indexed token, uint256 amount);
    event SwapPauseChanged(bool paused);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);

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
     * @notice Check if the owner holds at least 5% of total supply
     * @return True if owner holds >= 5% or total supply is 0
     */
    function isBucketAccountable() public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return (balanceOf(owner()) * BPS_DENOMINATOR) / supply >= MIN_OWNER_BPS;
    }

    // ============================================================
    // N5 / A3 owner-holding floor — BUILT, UNIT-TESTED, ⚠ NOT WIRED INTO ANY redeem() ⚠
    //
    // Client requirement (04-CONTRACTS-IMPLEMENTATION-PLAN.md §5.5, N5/A3): the owner must hold
    // >= 20% of "total deposited value or portfolio" to withdraw. §5.5's own analysis flags this
    // as SOURCE DISAGREES on multiple points, which this implementation deliberately resolves
    // one specific way — flagged here for escalation, not silently decided as final:
    //   1. `totalDepositValue` (ActiveBucket.sol / PassiveBucket.sol) is a lifetime accumulator
    //      that is never decremented and is not investor-scoped — using it as the "20% of what"
    //      denominator produces "R1": after one full investor deposit-then-exit cycle, the
    //      owner's percentage of "total ever deposited" is permanently and falsely tiny, even
    //      though the vault's CURRENT total value may be exactly what it was before the cycle.
    //      That permanently locks the owner out of ever redeeming again. See
    //      `test_N5OwnerWithdrawalFloor_NoR1Lockout` in test/ActiveBucket.t.sol for the proof
    //      that the LIVE interpretation below does not have this defect.
    //   2. `MIN_OWNER_BPS` (100 = 1%, above) is a DIFFERENT quantity for a DIFFERENT purpose —
    //      fee/penalty eligibility in `_handleRebalanceFees` and PassiveBucket's pre-existing
    //      `isBucketAccountable()`-gated redeem check — not this N5 guard. Reusing it here would
    //      silently change its threshold everywhere else it is read; a separate constant
    //      (`OWNER_WITHDRAWAL_FLOOR_BPS`, 2000 = 20%) is used instead.
    //   3. ActiveBucket.redeem has ZERO owner-accountability check today; PassiveBucket.redeem
    //      has one, but it is the 5%-based `isBucketAccountable()` check above, not this 20%
    //      floor. Neither today's ActiveBucket nor today's PassiveBucket redeem() implements N5.
    //
    // RESOLUTION (this wave's deliberate substitution — needs client/verification-stream
    // confirmation before ever being wired live, per the sc-vault-exit brief): interpret "20% of
    // total deposited value or portfolio" as a LIVE quantity — the owner's share balance as a
    // fraction of CURRENT total supply — composing with the existing `isBucketAccountable()`
    // shape but at a 20% floor instead of 5%. Because share price is uniform across every
    // holder, `balanceOf(owner())/totalSupply()` is exactly the owner's fraction of the vault's
    // CURRENT total USD value too, without needing an oracle call to prove it — so this stays
    // INV-1-clean (pure share arithmetic) in case it is ever wired into an exit path. This is
    // NOT the literal wording ("total deposited value"), and that substitution is the thing to
    // escalate: an alternative literal reading ("20% of investor-attributable value", i.e.
    // excluding the owner's own stake from the denominator) is mathematically a DIFFERENT
    // ~16.67% share-ratio threshold, and this implementation did not choose that reading either.
    //
    // ⚠ UNWIRED, ON PURPOSE. Neither ActiveBucket.redeem nor PassiveBucket.redeem calls either
    // function below. Wiring this in is a deliberate, separate decision for whoever owns that
    // call after this interpretation is confirmed — not a silent side effect of this wave.
    // ============================================================

    /// @dev 20%, in bps. See the N5/A3 section doc comment above for why this is a distinct
    /// constant from `MIN_OWNER_BPS` (1%, a different guard for a different purpose).
    uint256 public constant OWNER_WITHDRAWAL_FLOOR_BPS = 2000;

    /// @notice Whether the owner CURRENTLY holds >= 20% of total share supply (the N5/A3 floor,
    /// LIVE-quantity interpretation), or supply is 0. Pure share arithmetic — no oracle call, no
    /// whitelist iteration. NOT called from any redeem() path as of W2 — see the section doc
    /// comment above.
    function isOwnerWithdrawalFloorMet() public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return (balanceOf(owner()) * BPS_DENOMINATOR) / supply >= OWNER_WITHDRAWAL_FLOOR_BPS;
    }

    /// @notice Whether the owner would still meet the 20% floor immediately AFTER redeeming
    /// `ownerShares` of their own shares, given the CURRENT total supply. Mirrors the
    /// before/after check shape PassiveBucket.redeem already uses for the 5%
    /// `isBucketAccountable()` guard, so a future wiring can compose identically. NOT called
    /// from any redeem() path as of W2 — see the section doc comment above.
    /// @param ownerShares Hypothetical number of shares the owner would redeem.
    function wouldOwnerMeetWithdrawalFloorAfterRedeem(uint256 ownerShares) public view returns (bool) {
        uint256 supply = totalSupply();
        uint256 ownerBalance = balanceOf(owner());
        if (ownerShares > ownerBalance) return false;
        uint256 remainingSupply = supply - ownerShares;
        if (remainingSupply == 0) return true;
        uint256 remainingOwnerBalance = ownerBalance - ownerShares;
        return (remainingOwnerBalance * BPS_DENOMINATOR) / remainingSupply >= OWNER_WITHDRAWAL_FLOOR_BPS;
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
    function recoverTokens(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (_bucketInfo().isTokenWhitelisted(token)) {
            revert CannotRecoverWhitelistedToken(token);
        }

        _transferToken(token, to, amount);

        emit TokensRecovered(token, to, amount);
    }

    /**
     * @notice Update the BucketInfo contract address
     * @dev Can only be called by the current owner of the BucketInfo contract being pointed away
     * from — NOT by this vault's own owner. See workspace CLAUDE.md §1.1: a vault owner must
     * never be able to swap its own price-feed source.
     * @param newBucketInfo The new BucketInfo contract address
     */
    function updateBucketInfo(address newBucketInfo) external {
        if (newBucketInfo == address(0)) revert ZeroAddress();

        // Only the current BucketInfo owner can update
        address bucketInfoOwner = IBucketInfo(address(_bucketInfo())).owner();
        if (msg.sender != bucketInfoOwner) revert UnauthorizedBucketInfoUpdate();

        address oldBucketInfo = address(_bucketInfo());
        _setBucketInfo(newBucketInfo);

        emit BucketInfoUpdated(oldBucketInfo, newBucketInfo, msg.sender);
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
        if (srcToken == dstToken) revert SameToken();
        if (amount == 0) revert ZeroAmount();

        // B3 / INV-2: both legs must be on the platform whitelist AND the platform must be
        // operational — `isTokenValid`, not the weaker `isTokenWhitelisted`.
        if (!_bucketInfo().isTokenValid(srcToken)) revert InvalidToken(srcToken);
        if (!_bucketInfo().isTokenValid(dstToken)) revert InvalidToken(dstToken);

        // Bound `amount` by what this vault actually holds of srcToken — the caller cannot ask
        // this helper to move more than the vault has, regardless of what the router does with
        // the (scoped, immediately-revoked) allowance below.
        uint256 heldBalance = _getTokenBalance(srcToken);
        if (amount > heldBalance) revert AmountExceedsHeldBalance(amount, heldBalance);

        // Pre-commitment minReturn floor, oracle-derived, checked BEFORE the swap executes —
        // independent of, and in addition to, the post-hoc MAX_VALUE_LOSS_BPS check below.
        _assertMinReturnAboveFloor(srcToken, dstToken, amount, minReturn);

        // Shared per-caller + global cooldown (also enforced by PassiveBucket.rebalanceByDefi,
        // which does not route through this helper — see that function's own call site).
        _enforceSwapCooldown(msg.sender);

        totalValueBefore = _calculateTotalValue();

        bytes memory routerCalldata =
            abi.encodeWithSelector(ONEINCH_SWAP_SELECTOR, srcToken, dstToken, address(this), amount, minReturn);
        // Belt-and-braces (never the primary control — the primary control is that this
        // contract alone constructs every byte of `routerCalldata`, so no caller-supplied value
        // can ever occupy the receiver position): decode the calldata just built and assert the
        // embedded receiver really is `address(this)`. Can only fail if a future edit to the
        // encoding above breaks the invariant.
        if (_decodeSwapReceiver(routerCalldata) != address(this)) revert MalformedSwapPayload();

        // Hard rule 12 / R-V1 (`09-DECISION-LOG.md` §4.2a): NO allowance is ever granted here,
        // for any token, under any condition — see the note above this function. Native ETH
        // (srcToken == address(0)) has no allowance concept; the call carries `value: amount`
        // instead. An ERC20 srcToken has no allowance either: the call below will reach the
        // router with zero approved balance, and the router's own `transferFrom` is expected to
        // revert, which is caught and bubbled (N6) exactly like any other router-side failure.
        bool isNativeSrc = (srcToken == address(0));

        (bool success, bytes memory returndata) =
            isNativeSrc ? _oneInchRouter().call{value: amount}(routerCalldata) : _oneInchRouter().call(routerCalldata);

        if (!success) {
            // N6: bubble the router's actual revert reason instead of collapsing to a generic
            // SwapFailed() — only falls back to SwapFailed() when the router reverted with no
            // returndata at all (e.g. an out-of-gas or a bare `revert()`).
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
            revert SwapFailed();
        }

        totalValueAfter = _calculateTotalValue();

        // Existing post-hoc bound: value loss < MAX_VALUE_LOSS_BPS (0.5%) for THIS call.
        if (totalValueAfter < totalValueBefore) {
            uint256 loss = totalValueBefore - totalValueAfter;
            uint256 maxLoss = (totalValueBefore * MAX_VALUE_LOSS_BPS) / BPS_DENOMINATOR;
            if (loss > maxLoss) {
                revert ValueLossTooHigh(totalValueBefore, totalValueAfter);
            }
            // New: cumulative per-epoch budget, independent of the per-call bound above.
            _consumeEpochValueLossBudget(totalValueBefore, loss);
        }
    }

    /// @dev Decodes the receiver field (3rd typed param) out of calldata built by this contract
    /// for `ONEINCH_SWAP_SELECTOR`. Layout after the 4-byte selector: srcToken(32) dstToken(32)
    /// dstReceiver(32) amount(32) minReturn(32) — all ABI-encoded as full 32-byte words.
    function _decodeSwapReceiver(bytes memory payload) internal pure returns (address receiver) {
        if (payload.length < 4 + 32 * 3) revert MalformedSwapPayload();
        assembly {
            // `payload` points at the length word; data starts at `payload + 32`. The receiver
            // word spans data-relative bytes [68,100) (after 4-byte selector + 2 full words), so
            // its absolute start is `payload + 32 + 68 = payload + 100`.
            receiver := mload(add(payload, 100))
        }
    }

    /// @dev Oracle-derived pre-commitment floor on `minReturn`, checked BEFORE the swap. Reverts
    /// (does not gracefully skip) on a bad price — unlike rebalanceByDefi's per-token graceful
    /// skip, this call concerns a single caller-chosen pair, so a bad price here should block
    /// the swap outright rather than silently proceed with an unverifiable floor.
    function _assertMinReturnAboveFloor(address srcToken, address dstToken, uint256 amount, uint256 minReturn)
        internal
        view
    {
        uint256 srcPrice = _bucketInfo().getTokenPrice(srcToken);
        uint256 dstPrice = _bucketInfo().getTokenPrice(dstToken);
        uint8 srcDec = _getTokenDecimals(srcToken);
        uint8 dstDec = _getTokenDecimals(dstToken);

        // Multiply before dividing (workspace CLAUDE.md §6).
        uint256 srcValueUsd = (amount * srcPrice) / (10 ** srcDec);
        uint256 minReturnValueUsd = (minReturn * dstPrice) / (10 ** dstDec);
        uint256 floorValueUsd = (srcValueUsd * (BPS_DENOMINATOR - MIN_RETURN_FLOOR_TOLERANCE_BPS)) / BPS_DENOMINATOR;

        if (minReturnValueUsd < floorValueUsd) {
            revert MinReturnBelowFloor(minReturnValueUsd, floorValueUsd);
        }
    }

    /// @dev Shared per-caller AND global cooldown, enforced on every swap/rebalance action —
    /// the 1inch path (via `_execute1inchSwap` above) and PassiveBucket.rebalanceByDefi (called
    /// directly from that function, since it never routes through this helper). Residual
    /// ambiguity: the plan did not specify a duration; `CALLER_SWAP_COOLDOWN` /
    /// `GLOBAL_SWAP_COOLDOWN` below are this wave's documented defaults — see
    /// W2-SC-SWAP-REPORT.md "Residual ambiguities with a default".
    function _enforceSwapCooldown(address caller) internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        uint256 nowTs = block.timestamp;
        if (nowTs < $.globalSwapCooldownUntil) {
            revert SwapCooldownActive($.globalSwapCooldownUntil);
        }
        uint256 callerUntil = $.callerSwapCooldownUntil[caller];
        if (nowTs < callerUntil) {
            revert SwapCooldownActive(callerUntil);
        }
        $.globalSwapCooldownUntil = nowTs + GLOBAL_SWAP_COOLDOWN;
        $.callerSwapCooldownUntil[caller] = nowTs + CALLER_SWAP_COOLDOWN;
    }

    /// @dev Cumulative per-epoch value-loss budget, independent of (and in addition to) the
    /// per-call MAX_VALUE_LOSS_BPS bound. Rolls over to a fresh epoch/budget once
    /// VALUE_LOSS_EPOCH_LENGTH has elapsed since the current epoch started. Called both from
    /// `_execute1inchSwap` above and directly from PassiveBucket.rebalanceByDefi.
    function _consumeEpochValueLossBudget(uint256 totalValueBeforeCall, uint256 lossUsd) internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        uint256 nowTs = block.timestamp;
        if (nowTs >= $.currentEpochStart + VALUE_LOSS_EPOCH_LENGTH) {
            $.currentEpochStart = nowTs;
            $.currentEpochValueLossUsd = 0;
        }
        uint256 budget = (totalValueBeforeCall * EPOCH_VALUE_LOSS_BUDGET_BPS) / BPS_DENOMINATOR;
        uint256 projected = $.currentEpochValueLossUsd + lossUsd;
        if (projected > budget) {
            revert EpochValueLossBudgetExceeded(projected, budget);
        }
        $.currentEpochValueLossUsd = projected;
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
    function _syncHeldTokenByBalance(address token) internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        if (_getTokenBalance(token) == 0) {
            $.heldTokens.remove(token);
        } else {
            $.heldTokens.add(token);
        }
    }

    /// @dev Re-syncs every currently-whitelisted token's held/not-held status. Bounded by
    /// whitelist size, same as `_calculateTotalValue` — intended for use after a rebalance that
    /// may touch any whitelisted token (e.g. PassiveBucket.rebalanceByDefi).
    function _syncAllHeldTokensFromWhitelist() internal {
        address[] memory tokens = _bucketInfo().getWhitelistedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _syncHeldTokenByBalance(tokens[i]);
        }
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

    /// @notice Whether any currently-held token is flagged by BucketInfo as potentially
    /// outpriced. Uses the frozen, per-token oracle interface
    /// (`isPotentiallyOutpriced(address)`, `IBucketInfo`/`BucketInfo.sol:352`), OR'd across the
    /// held-tokens set — not a bucket-wide flag, since `BucketInfo` exposes none.
    function isAnyHeldTokenPotentiallyOutpriced() external view returns (bool) {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        uint256 n = $.heldTokens.length();
        for (uint256 i = 0; i < n; i++) {
            if (_bucketInfo().isPotentiallyOutpriced($.heldTokens.at(i))) {
                return true;
            }
        }
        return false;
    }
}
