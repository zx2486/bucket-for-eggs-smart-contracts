// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title SwapExecutionLib
/// @notice EIP-170 size-relief extraction (W5, sc-stable-exit, task #64 follow-up), same
/// motivation and shape as {DexSwapLib} / {PayoutLib}: `redeemForStable()`'s per-leg loop pushed
/// `BucketVaultBase`'s shared swap-execution logic over the 24,576-byte runtime limit on
/// `PassiveBucket` (confirmed by `forge build --sizes`: Runtime Margin -1,446 B). Moving the
/// genuinely external-call-heavy / arithmetic-heavy pieces of that logic into a separately
/// deployed `library` with `public` functions links each call site as a DELEGATECALL to the
/// library's own bytecode instead of inlining it into every inheriting contract, which is what
/// actually removes bytes from `ActiveBucket`'s and `PassiveBucket`'s own runtime size.
///
/// DELEGATECALL preserves `address(this)` and `msg.sender` exactly as if this logic still ran
/// inline inside the vault, so this is a PURE bytecode-location change: no behavior, ordering,
/// bound, or control-flow difference from what `BucketVaultBase` ran inline before. Hard rule 12
/// / R-V1 applies identically here as it did inline: {dispatchSwap} is the SAME code
/// `_executeSwapNoCooldown` always ran, byte-for-byte — it still NEVER grants the router an
/// allowance, for any token, under any condition.
///
/// `_enforceSwapCooldown` and `_consumeEpochValueLossBudget` (below, as {enforceSwapCooldown} /
/// {consumeEpochValueLossBudget}) have a two-stage history worth recording. Each was FIRST tried
/// in a (now-deleted) `SwapRiskLib` earlier this session, passing/returning several plain
/// `uint256` values, and MEASURED (not assumed, per hard rule 13) to make PassiveBucket's margin
/// WORSE, not better — the ABI-marshaling cost of those value parameters at the call sites
/// exceeded the small amount of logic replaced, so that attempt was reverted. Each was then
/// RE-ATTEMPTED here with a materially different ABI shape — a `storage` reference to a small
/// named struct wrapping their state, mutated in place with no return value at all — and THAT
/// shape was separately measured via `forge build --sizes` to improve the margin, so both now
/// live here as {enforceSwapCooldown} / {consumeEpochValueLossBudget}. `_calculateTotalValue` is
/// still left in place: it is called from many unrelated sites (deposit, redeem, sharePrice) and
/// extracting it is a materially larger, riskier change than this fix requires.
///
/// Only the functions below were moved, because each is reached from `_execute1inchSwap`'s two
/// pre-existing callers (`ActiveBucket.swapBy1inch`, `PassiveBucket.rebalanceBy1inch`) AND from
/// `redeemForStable`'s new per-leg loop — so the extraction wins size on BOTH vault types, not
/// just the one that happened to go over the limit first.
library SwapExecutionLib {
    // ============================================================
    // Errors — selector-identical duplicates of `BucketVaultBase`'s own declarations (same
    // pattern as `PayoutLib.ETHTransferFailed` / `SeizureLib.Blacklisted`). Solidity derives an
    // error's 4-byte selector purely from its name + parameter types, so these revert with the
    // IDENTICAL selector `BucketVaultBase`'s own error of the same signature would — existing
    // tests asserting `vm.expectRevert(BucketVaultBase.X.selector)` are unaffected. A library has
    // no inheritance relationship to `BucketVaultBase`, so (unlike a derived contract
    // re-declaring an inherited error) this is not a duplicate-declaration compile error.
    // ============================================================
    error SameToken();
    error ZeroAmount();
    error InvalidToken(address token);
    error AmountExceedsHeldBalance(uint256 amount, uint256 heldBalance);
    error MinReturnBelowFloor(uint256 minReturnValueUsd, uint256 floorValueUsd);
    error MalformedSwapPayload();
    error SwapFailed();
    error EpochValueLossBudgetExceeded(uint256 projectedLossUsd, uint256 budgetUsd);
    error SwapCooldownActive(uint256 cooldownUntil);

    // ============================================================
    // Constants needed by the functions below, duplicated from `BucketVaultBase` (same
    // literal values — these are platform-wide constants, not per-vault config).
    // ============================================================
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_RETURN_FLOOR_TOLERANCE_BPS = 100;
    uint256 public constant VALUE_LOSS_EPOCH_LENGTH = 1 days;
    uint256 public constant EPOCH_VALUE_LOSS_BUDGET_BPS = 150;
    uint256 public constant CALLER_SWAP_COOLDOWN = 5 minutes;
    uint256 public constant GLOBAL_SWAP_COOLDOWN = 1 minutes;

    /// @dev Mirrors the mapping + scalar `_enforceSwapCooldown` used to keep directly inside
    /// `BucketVaultBaseStorage` — wrapped into a named struct purely so they can be passed to
    /// {enforceSwapCooldown} below BY STORAGE REFERENCE. See that struct field's own comment in
    /// `BucketVaultBase.sol` for why this is layout-safe.
    struct SwapCooldownState {
        mapping(address => uint256) callerSwapCooldownUntil;
        uint256 globalSwapCooldownUntil;
    }

    /// @dev Moved verbatim out of `BucketVaultBase._enforceSwapCooldown`, now taking `state` BY
    /// STORAGE REFERENCE instead of operating directly on a `BucketVaultBaseStorage storage $`
    /// the library cannot reach. Mutates `state` in place; there is no return value to marshal.
    /// See this file's header comment: an EARLIER attempt at extracting this function (passing
    /// the two values by-value and returning them) was measured to make PassiveBucket's margin
    /// WORSE and was reverted — this storage-ref signature is a materially different, cheaper ABI
    /// shape and was separately measured via `forge build --sizes` before being kept.
    function enforceSwapCooldown(SwapCooldownState storage state, address caller) public {
        uint256 nowTs = block.timestamp;
        if (nowTs < state.globalSwapCooldownUntil) {
            revert SwapCooldownActive(state.globalSwapCooldownUntil);
        }
        uint256 callerUntil = state.callerSwapCooldownUntil[caller];
        if (nowTs < callerUntil) {
            revert SwapCooldownActive(callerUntil);
        }
        state.globalSwapCooldownUntil = nowTs + GLOBAL_SWAP_COOLDOWN;
        state.callerSwapCooldownUntil[caller] = nowTs + CALLER_SWAP_COOLDOWN;
    }

    /// @dev Mirrors the two scalar fields `_consumeEpochValueLossBudget` used to keep directly
    /// inside `BucketVaultBaseStorage` — wrapped into a named struct purely so they can be
    /// passed to {consumeEpochValueLossBudget} below BY STORAGE REFERENCE. See that struct
    /// field's own comment in `BucketVaultBase.sol` for why this is layout-safe.
    struct EpochLossBudget {
        uint256 currentEpochStart;
        uint256 currentEpochValueLossUsd;
    }

    /// @dev The front half of `_execute1inchSwap`'s per-leg checks, moved verbatim out of
    /// `BucketVaultBase._validateSwapLeg` (which folded in its own `_assertMinReturnAboveFloor`,
    /// the only call site of that helper).
    ///
    /// ⚠ Bug found and fixed 2026-10-01 (caught by
    /// `OneInchSwapSecurity.t.sol:test_PostFix_RebalanceBy1inch_RejectsUnwhitelistedDestination`,
    /// hard rule 13 — a green build is not evidence): the FIRST version of this extraction took
    /// `heldBalance`/`srcDec`/`dstDec` as plain parameters, pre-computed by the caller
    /// (`BucketVaultBase._validateSwapLeg`) via `_getTokenBalance(srcToken)` /
    /// `_getTokenDecimals(srcToken)` / `_getTokenDecimals(dstToken)`. Solidity evaluates a
    /// function call's arguments BEFORE making the call, so `_getTokenDecimals(dstToken)` —
    /// an external call to `dstToken.decimals()` — ran before this function's own
    /// `isTokenValid(dstToken)` check ever executed, breaking the pre-extraction invariant that
    /// NO external call ever touches an attacker-supplied `dstToken` before its whitelist status
    /// is confirmed. A non-contract `dstToken` then reverted with empty returndata from the
    /// failed external call, instead of `InvalidToken(dstToken)`. Fixed by taking only the raw
    /// addresses here and fetching `heldBalance`/`srcDec`/`dstDec` INSIDE this function, ordered
    /// strictly after both `isTokenValid` checks — restoring the original ordering exactly rather
    /// than merely making the bytecode smaller. `_balanceOf`/`_decimalsOf` below duplicate
    /// `BucketVaultBase._getTokenBalance`/`_getTokenDecimals` (same pattern as this library's
    /// duplicated errors): both are pure/stateless, and `address(this)` resolves correctly here
    /// because DELEGATECALL preserves it.
    function validateSwapLeg(
        IBucketInfo bucketInfo,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn
    ) public view {
        if (srcToken == dstToken) revert SameToken();
        if (amount == 0) revert ZeroAmount();

        // B3 / INV-2: both legs must be on the platform whitelist AND the platform must be
        // operational — `isTokenValid`, not the weaker `isTokenWhitelisted`. MUST run before any
        // external call that touches `srcToken`/`dstToken` directly (see bug note above).
        if (!bucketInfo.isTokenValid(srcToken)) revert InvalidToken(srcToken);
        if (!bucketInfo.isTokenValid(dstToken)) revert InvalidToken(dstToken);

        // Only safe to touch srcToken/dstToken directly now that both are confirmed whitelisted.
        uint256 heldBalance = _balanceOf(srcToken);
        uint8 srcDec = _decimalsOf(srcToken);
        uint8 dstDec = _decimalsOf(dstToken);

        // Bound `amount` by what this vault actually holds of srcToken.
        if (amount > heldBalance) revert AmountExceedsHeldBalance(amount, heldBalance);

        // Pre-commitment minReturn floor, oracle-derived, checked BEFORE the swap executes —
        // independent of, and in addition to, the post-hoc MAX_VALUE_LOSS_BPS check the caller
        // runs after the swap below.
        uint256 srcPrice = bucketInfo.getTokenPrice(srcToken);
        uint256 dstPrice = bucketInfo.getTokenPrice(dstToken);
        // W3.6: defensive bound on a zero price read — left unguarded, a zero `srcPrice` would
        // collapse `floorValueUsd` to 0, making the floor check vacuously pass instead of
        // reverting, i.e. silently disabling slippage protection on the exact call meant to
        // enforce it.
        if (srcPrice == 0) revert InvalidToken(srcToken);
        if (dstPrice == 0) revert InvalidToken(dstToken);

        // Multiply before dividing (workspace CLAUDE.md §6).
        uint256 srcValueUsd = (amount * srcPrice) / (10 ** srcDec);
        uint256 minReturnValueUsd = (minReturn * dstPrice) / (10 ** dstDec);
        uint256 floorValueUsd = (srcValueUsd * (BPS_DENOMINATOR - MIN_RETURN_FLOOR_TOLERANCE_BPS)) / BPS_DENOMINATOR;

        if (minReturnValueUsd < floorValueUsd) {
            revert MinReturnBelowFloor(minReturnValueUsd, floorValueUsd);
        }
    }

    /// @dev Mirrors `BucketVaultBase._getTokenBalance` exactly (native ETH at `address(0)` ->
    /// `address(this).balance`). Duplicated here, not called via the host, because a library
    /// cannot call the host contract's `internal` functions — see this file's header comment.
    function _balanceOf(address token) private view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Mirrors `BucketVaultBase._getTokenDecimals` exactly (native ETH treated as
    /// 18-decimal). Duplicated here for the same reason as {_balanceOf} above.
    function _decimalsOf(address token) private view returns (uint8) {
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    /// @dev W5 (sc-stable-exit, task #64): per-leg `minReturn` for `redeemForStable()`, derived
    /// from the CALLER's own slippage tolerance (`maxSlippageBps`) instead of the hardcoded
    /// `MIN_RETURN_FLOOR_TOLERANCE_BPS` constant used by {validateSwapLeg} above — moved verbatim
    /// out of `BucketVaultBase._minReturnForStableLeg`. Same "can only tighten, never loosen" the
    /// platform's hardcoded floor property as before: {validateSwapLeg} always re-derives and
    /// enforces its own 1% floor regardless of the `minReturn` this function hands it.
    ///
    /// ⚠ Same ordering fix as {validateSwapLeg} above, applied here too even though no test
    /// currently exercises it through this call site (`redeemForStable` already checks
    /// `isTokenValid(dstToken)` once before its per-leg loop, and every `srcToken` in that loop
    /// comes from the vault's own held-tokens registry, so neither argument can actually be a
    /// non-contract address on the only path that reaches this function today) — fixing it only
    /// where a test happens to reach it and leaving the identical hazard live here would be
    /// exactly the kind of latent bug this workspace's hard rule 13 exists to prevent.
    function minReturnForStableLeg(
        IBucketInfo bucketInfo,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 maxSlippageBps
    ) public view returns (uint256 minReturn) {
        if (!bucketInfo.isTokenValid(srcToken)) revert InvalidToken(srcToken);
        if (!bucketInfo.isTokenValid(dstToken)) revert InvalidToken(dstToken);

        uint8 srcDec = _decimalsOf(srcToken);
        uint8 dstDec = _decimalsOf(dstToken);

        uint256 srcPrice = bucketInfo.getTokenPrice(srcToken);
        uint256 dstPrice = bucketInfo.getTokenPrice(dstToken);
        // Same defensive zero-price bound as {validateSwapLeg} — a zero price here would
        // silently collapse `minReturn` to 0, i.e. no slippage protection at all, instead of
        // blocking the leg.
        if (srcPrice == 0) revert InvalidToken(srcToken);
        if (dstPrice == 0) revert InvalidToken(dstToken);

        uint256 toleranceBps = maxSlippageBps > BPS_DENOMINATOR ? BPS_DENOMINATOR : maxSlippageBps;

        // Multiply before dividing (workspace CLAUDE.md §6).
        uint256 srcValueUsd = (amount * srcPrice) / (10 ** srcDec);
        uint256 minReturnValueUsd = (srcValueUsd * (BPS_DENOMINATOR - toleranceBps)) / BPS_DENOMINATOR;
        minReturn = (minReturnValueUsd * (10 ** dstDec)) / dstPrice;
    }

    /// @dev The router-call-dispatch core of `_executeSwapNoCooldown`, moved verbatim (folding in
    /// the former `_decodeSwapReceiver`, its only call site). Deliberately excludes the
    /// before/after `_calculateTotalValue()` value-loss accounting — that stays in
    /// `BucketVaultBase` because `_calculateTotalValue` itself is not moved (see this file's
    /// header comment) and because the post-hoc budget check needs this contract's own storage.
    /// Hard rule 12 / R-V1: this function NEVER grants the router an allowance, for any token,
    /// under any condition — see the header comment above for the full history of that guarantee.
    /// @param router The vault's own `_oneInchRouter()`, computed and passed in by the caller
    /// (a library cannot call that virtual internal function directly).
    /// @param selector The vault's own `ONEINCH_SWAP_SELECTOR`, passed in for the same reason.
    function dispatchSwap(
        address router,
        bytes4 selector,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn
    ) public {
        bytes memory routerCalldata =
            abi.encodeWithSelector(selector, srcToken, dstToken, address(this), amount, minReturn);

        // Belt-and-braces (never the primary control — the primary control is that this
        // contract alone constructs every byte of `routerCalldata`, so no caller-supplied value
        // can ever occupy the receiver position): decode the calldata just built and assert the
        // embedded receiver really is `address(this)`. Can only fail if a future edit to the
        // encoding above breaks the invariant. Layout after the 4-byte selector: srcToken(32)
        // dstToken(32) dstReceiver(32) amount(32) minReturn(32) — all ABI-encoded as full
        // 32-byte words, so the receiver word's absolute start is `payload + 32 + 68 = payload + 100`.
        if (routerCalldata.length < 4 + 32 * 3) revert MalformedSwapPayload();
        address receiver;
        assembly {
            receiver := mload(add(routerCalldata, 100))
        }
        if (receiver != address(this)) revert MalformedSwapPayload();

        // Hard rule 12 / R-V1 (`09-DECISION-LOG.md` §4.2a): NO allowance is ever granted here,
        // for any token, under any condition. Native ETH (srcToken == address(0)) has no
        // allowance concept; the call carries `value: amount` instead. An ERC20 srcToken has no
        // allowance either: the call below will reach the router with zero approved balance, and
        // the router's own `transferFrom` is expected to revert, which is caught and bubbled
        // (N6) exactly like any other router-side failure.
        bool isNativeSrc = (srcToken == address(0));

        (bool success, bytes memory returndata) =
            isNativeSrc ? router.call{value: amount}(routerCalldata) : router.call(routerCalldata);

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
    }

    /// @dev Cumulative per-epoch value-loss budget, moved verbatim out of
    /// `BucketVaultBase._consumeEpochValueLossBudget`, now taking `budget` BY STORAGE REFERENCE
    /// instead of operating on a `BucketVaultBaseStorage storage $` the library cannot reach
    /// directly. This mutates `budget` in place; there is no return value to marshal. See this
    /// file's header comment: an EARLIER attempt at extracting this function (passing/returning
    /// several plain `uint256`s instead of a storage ref) was measured to make PassiveBucket's
    /// margin WORSE and was reverted — this storage-ref signature is a materially different,
    /// cheaper ABI shape and was separately measured via `forge build --sizes` before being kept.
    function consumeEpochValueLossBudget(EpochLossBudget storage budget, uint256 totalValueBeforeCall, uint256 lossUsd)
        public
    {
        uint256 nowTs = block.timestamp;
        if (nowTs >= budget.currentEpochStart + VALUE_LOSS_EPOCH_LENGTH) {
            budget.currentEpochStart = nowTs;
            budget.currentEpochValueLossUsd = 0;
        }
        uint256 budgetUsd = (totalValueBeforeCall * EPOCH_VALUE_LOSS_BUDGET_BPS) / BPS_DENOMINATOR;
        uint256 projected = budget.currentEpochValueLossUsd + lossUsd;
        if (projected > budgetUsd) {
            revert EpochValueLossBudgetExceeded(projected, budgetUsd);
        }
        budget.currentEpochValueLossUsd = projected;
    }
}
