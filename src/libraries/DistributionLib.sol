// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PassiveBucket} from "../PassiveBucket.sol";

// ============================================================
// DistributionLib — W3/W48 (size-reduction). Same rationale as DexSwapLib.sol's doc comment:
// an `external` library function's bytecode is deployed once, separately, and reached via a
// linked CALL/DELEGATECALL, instead of being copied into every contract that calls it. Unlike
// DexSwapLib's functions, this one touches no storage (it only reads a `calldata` array and
// makes one external view call), so no `storage` parameter is needed and solc links this as a
// plain external `CALL` rather than a `DELEGATECALL` — semantics are unaffected either way, since
// the function has no side effects of its own beyond its return value and its reverts.
//
// This was moved out of `PassiveBucket._validateAndStoreDistributions` specifically (not the
// whole function) to shrink PassiveBucket's own runtime bytecode back under the EIP-170 limit
// (task #48) without touching the `PassiveBucket.BucketDistribution` struct's declaration or its
// storage — `_bucketDistributions` (the `delete`+`push` loop and the `BucketDistributionsUpdated`
// event) stays in `PassiveBucket.sol`, since that part needs `storage` access and has only two
// call sites there already, so extracting it would not pay for its own dispatch overhead the way
// this validation loop's four revert paths do.
//
// The struct type itself is referenced here via `PassiveBucket.BucketDistribution`, imported
// from `PassiveBucket.sol` — this file and `PassiveBucket.sol` therefore import each other
// (`PassiveBucket.sol` imports this library to call {validateDistributions}). Solidity resolves
// this without issue: import cycles between a contract and a library that only reference each
// other's *type declarations* (not constructors/inheritance) are not circular in the sense the
// compiler forbids. Confirmed by `forge build` succeeding with this file in place.
//
// The four custom errors below are redeclared rather than referenced qualified off
// `PassiveBucket`/`BucketVaultBase` (where `InvalidToken` already lives) — a custom error's
// selector is `keccak256("Name(types)")` regardless of which contract or library declares it, so
// this library's `InvalidToken(address)` reverts with the exact same 4-byte selector and encoded
// data as `BucketVaultBase.InvalidToken`. Any caller or test decoding by selector sees no
// difference. Declaring them locally avoids depending on inherited-error qualified-name
// resolution working a particular way across a library boundary.
// ============================================================

library DistributionLib {
    /// @notice Read-only rebalance context, packed into one struct so
    /// {classifyAndSizeRebalanceTrades} and {_classifyOneToken} keep a low enough parameter
    /// count to stay under solc's non-`--via-ir` stack-depth limit — see that function's doc
    /// comment. `distributions` is the vault's stored target distribution
    /// (`_bucketDistributions`); `totalValueBefore` is the vault's total USD value at the start
    /// of the rebalance call; `weightSum` is the vault's `WEIGHT_SUM` constant (100), passed in
    /// rather than hardcoded so this library carries no PassiveBucket-specific constant of its
    /// own; `bucketInfo` is the vault's BucketInfo, for `tryGetTokenPrice`.
    struct RebalanceContext {
        PassiveBucket.BucketDistribution[] distributions;
        uint256 totalValueBefore;
        uint256 weightSum;
        IBucketInfo bucketInfo;
    }

    error EmptyDistributions();
    error InvalidToken(address token);
    error InvalidDistributions();
    error DuplicateToken(address token);
    error WeightSumMismatch(uint256 totalWeight);

    /// @dev Validates a candidate distribution array against BucketInfo's whitelist and the
    /// vault's weight-sum invariant, exactly as `PassiveBucket._validateAndStoreDistributions`
    /// used to inline: every token must be currently whitelisted, no token may repeat, no weight
    /// may be zero, and the weights must sum to exactly `weightSum` (the caller's `WEIGHT_SUM`
    /// constant, passed in rather than hardcoded so this library carries no PassiveBucket-specific
    /// constant of its own). Reverts on the first violation found; returns the validated total
    /// weight (always `== weightSum` on success, so callers may ignore the return value or use it
    /// for an event/assertion).
    function validateDistributions(
        PassiveBucket.BucketDistribution[] calldata distributions,
        IBucketInfo bucketInfo,
        uint256 weightSum
    ) external view returns (uint256 totalWeight) {
        if (distributions.length == 0) revert EmptyDistributions();

        for (uint256 i = 0; i < distributions.length; i++) {
            if (!bucketInfo.isTokenValid(distributions[i].token)) {
                revert InvalidToken(distributions[i].token);
            }
            if (distributions[i].weight == 0) revert InvalidDistributions();

            for (uint256 j = 0; j < i; j++) {
                if (distributions[j].token == distributions[i].token) {
                    revert DuplicateToken(distributions[i].token);
                }
            }

            totalWeight += distributions[i].weight;
        }

        if (totalWeight != weightSum) revert WeightSumMismatch(totalWeight);
    }

    /// @dev Classifies every whitelisted token as a rebalance seller (overweight) or buyer
    /// (underweight) against the target distribution, and sizes each sell leg in token-native
    /// units. Moved out of `PassiveBucket.rebalanceByDefi` (task #48, same size-reduction
    /// rationale as {validateDistributions} and DexSwapLib's functions above) — this is the
    /// double loop that used to run inline there, byte-for-byte the same logic, split at the one
    /// seam that needs the CALLING contract's own storage/balance state
    /// (`_getTokenValue`/`_getTokenBalance`, both `address(this)`-dependent and therefore not
    /// safely movable into a library called via a plain external `CALL`): the caller precomputes
    /// `currentValuesUsd[i] = _getTokenValue(tokens[i])` for every token BEFORE calling this
    /// function, and passes the results in. Nothing else this function does depends on
    /// `address(this)` — `bucketInfo.tryGetTokenPrice` and `IERC20Metadata(token).decimals()` are
    /// both plain external calls keyed on `token`, not on the caller's own address — so the
    /// target-weight lookup, the USD-deficit/excess arithmetic, and the excess-USD-to-token-units
    /// conversion all move here safely.
    /// @param tokens The full whitelisted-token set (`bucketInfo.getWhitelistedTokens()`), same
    /// array the caller already fetched.
    /// @param currentValuesUsd `currentValuesUsd[i]` is `_getTokenValue(tokens[i])`, i.e. this
    /// vault's current USD-8-decimal holding value of `tokens[i]`, precomputed by the caller.
    /// @param ctx The vault's stored distribution plus the rest of the read-only context
    /// (`totalValueBefore`, `WEIGHT_SUM`, `bucketInfo`) packed into one struct — see {RebalanceContext}.
    /// Packed into a struct, rather than passed as four separate parameters, purely to keep this
    /// function's own parameter count low enough for solc's non-`--via-ir` stack-depth limit (a
    /// memory struct is one stack slot — a pointer — no matter how many fields it carries); this
    /// codebase's `foundry.toml` does not enable `via_ir` and turning it on is a build-wide change
    /// out of this task's scope.
    /// @return sellTokens Tokens to sell (overweight), length `countAndDeficit[0]`.
    /// @return sellAmounts Token-native amounts to sell, parallel to `sellTokens`.
    /// @return buyTokens Tokens to buy (underweight), length `countAndDeficit[1]`.
    /// @return buyDeficits USD-8-decimal deficits to fill, parallel to `buyTokens`.
    /// @return countAndDeficit A 3-element `[sellCount, buyCount, totalDeficit]` pack — same
    /// stack-depth workaround the original inline code already used for the same reason as `ctx`
    /// above: three more named `uint256` returns would have put this function back over the
    /// limit, so they are packed into one array instead, exactly as the code being moved here
    /// already did with its own `countAndDeficit` local.
    function classifyAndSizeRebalanceTrades(
        address[] memory tokens,
        uint256[] memory currentValuesUsd,
        RebalanceContext memory ctx
    )
        external
        view
        returns (
            address[] memory sellTokens,
            uint256[] memory sellAmounts,
            address[] memory buyTokens,
            uint256[] memory buyDeficits,
            uint256[3] memory countAndDeficit
        )
    {
        uint256 len = tokens.length;
        sellTokens = new address[](len);
        sellAmounts = new uint256[](len);
        buyTokens = new address[](len);
        buyDeficits = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            // W3/W48 (stack-too-deep workaround): the per-token classification used to be
            // written out inline here too, but the outer loop already carries this function's
            // params + named returns + its own loop index, which alone sits at solc's non-viaIR
            // stack limit — adding the half-dozen locals the per-token math needs (targetWeight,
            // j, targetValueUSD, excessUSD, priceOk, price, dec, excessTokens, deficitUSD) pushed
            // it over. Splitting that math into {_classifyOneToken} gives it its OWN call frame,
            // so none of those intermediates are ever live at the same time as this loop's own
            // locals. Same logic, same order, same tie-breaking — just called instead of inlined.
            (bool isSell, uint256 sellAmount, bool isBuy, uint256 deficitUsd) =
                _classifyOneToken(tokens[i], currentValuesUsd[i], ctx);
            if (isSell) {
                sellTokens[countAndDeficit[0]] = tokens[i];
                sellAmounts[countAndDeficit[0]] = sellAmount;
                countAndDeficit[0]++;
            } else if (isBuy) {
                buyTokens[countAndDeficit[1]] = tokens[i];
                buyDeficits[countAndDeficit[1]] = deficitUsd;
                countAndDeficit[2] += deficitUsd;
                countAndDeficit[1]++;
            }
        }
    }

    /// @dev The single-token half of {classifyAndSizeRebalanceTrades}'s loop body, split out
    /// purely to give its locals their own stack frame (see the call site's comment). Returns
    /// `(isSell, sellAmount, isBuy, deficitUsd)`: at most one of `isSell`/`isBuy` is ever true,
    /// mirroring the original inline `if / else if` — a token that is priced ok-but-zero-excess,
    /// or whose price lookup fails (`!priceOk`), returns all-false/zero, exactly as the original
    /// `continue`/no-op fell through without recording a sell.
    // W3/W48 (size-reduction): a fifth extraction candidate, `PassiveBucket._isDistributionValid`'s
    // tolerance-check loop, was tried here and MEASURED to make PassiveBucket's own runtime
    // bytecode LARGER, not smaller (-285B margin -> -524B margin, confirmed via
    // `forge build --sizes`) — the loop body is too thin (one multiply-divide plus a two-sided
    // compare) for the external-call dispatch/marshaling overhead to pay for itself, the same
    // failure mode root CLAUDE.md's `TimelockedAdmin.sol` externalization experiment hit earlier
    // this wave. Reverted; `_isDistributionValid` stays inline in `PassiveBucket.sol`. Left as a
    // comment, not silently dropped, so nobody re-attempts the same measured-negative extraction.

    function _classifyOneToken(address token, uint256 currentValueUsd, RebalanceContext memory ctx)
        private
        view
        returns (bool isSell, uint256 sellAmount, bool isBuy, uint256 deficitUsd)
    {
        uint256 targetWeight = 0;
        for (uint256 j = 0; j < ctx.distributions.length; j++) {
            if (ctx.distributions[j].token == token) {
                targetWeight = ctx.distributions[j].weight;
                break;
            }
        }
        uint256 targetValueUSD = (ctx.totalValueBefore * targetWeight) / ctx.weightSum;

        if (currentValueUsd > targetValueUSD) {
            uint256 excessUSD = currentValueUsd - targetValueUSD;
            (bool priceOk, uint256 price) = ctx.bucketInfo.tryGetTokenPrice(token);
            if (!priceOk) return (false, 0, false, 0);
            uint8 dec = token == address(0) ? 18 : IERC20Metadata(token).decimals();
            uint256 excessTokens = (excessUSD * (10 ** dec)) / price;
            if (excessTokens > 0) {
                return (true, excessTokens, false, 0);
            }
        } else if (targetValueUSD > currentValueUsd) {
            return (false, 0, true, targetValueUSD - currentValueUsd);
        }
    }
}
