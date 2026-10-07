// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// RebalanceFeeLib — W3/W48 (size-reduction), same rationale as DistributionLib.sol's doc
// comment: an `external` library function's bytecode is deployed once, separately, instead of
// being copied into `PassiveBucket`'s own runtime bytecode.
//
// This was moved out of `PassiveBucket._handleRebalanceFees` — specifically the fee/penalty
// ARITHMETIC only (owner-fee, caller-fee, owner-penalty and platform-fee sizing), not the
// `_mint`/`_burn`/`emit` calls themselves. Those three stay in `PassiveBucket.sol` because
// `_mint`/`_burn` are `internal` functions inherited from OpenZeppelin's `ERC20Upgradeable` —
// they operate on THIS contract's own storage and are unreachable from a library linked via a
// plain external `CALL` (unlike `DistributionLib`'s functions, nothing here would even work as a
// `DELEGATECALL`, since a library has no ERC20 storage layout of its own to delegate into). So
// the seam is: the caller snapshots every value this computation reads (`accountable`,
// `balanceOf(owner())`, `totalSupply()`, and the raw platform fee from
// `bucketInfo.calculateFee(...)`) BEFORE calling this function, this function does every branch
// of arithmetic and returns a {FeeResult}, and the caller does the four `_mint`/`_burn`/`emit`
// calls afterward keyed off that struct. This is safe because none of the reads this function
// depends on are mutated by an EARLIER part of the same original function body — the
// increase/decrease branches are mutually exclusive (`if / else if`), so `balanceOf(owner())`
// is never stale by the time the original code reached the branch that used it, and
// `valueDifference`/the platform-fee raw value never depended on the increase/decrease branch's
// own mint/burn side effects either. Pure bytecode relocation: same order, same rounding
// (multiply-by-PRECISION before dividing, exactly as root CLAUDE.md §6 requires), same
// mutual-exclusivity, same missing `newPrice > 0` guard on the owner-penalty division (division
// by a zero `newPrice` in that branch reverts today, and this preserves that — not a behavior
// this task is fixing).
//
// PRECISION / INITIAL_TOKEN_PRICE / BPS_DENOMINATOR / MAX_LOCAL_PLATFORM_FEE_BPS are redeclared
// locally rather than referenced off `BucketVaultBase` (`BucketVaultBase.sol:152,157,183,195`)
// — they are `constant`, so there is no runtime drift risk, only an edit-time one: if any of
// those four values is ever changed in `BucketVaultBase.sol`, this library's copies must be
// updated to match, or the fee math here silently diverges from every other fee calculation in
// the system. Grep for the four names before touching either file.
// ============================================================

library RebalanceFeeLib {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant INITIAL_TOKEN_PRICE = 1e8;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_LOCAL_PLATFORM_FEE_BPS = 1000;

    /// @notice Every value `_handleRebalanceFees` used to compute inline, packed into one
    /// struct purely to keep {computeRebalanceFees}'s return list to one stack slot (a memory
    /// struct is one pointer) — seven-plus named returns alongside this function's eight
    /// parameters would put it back over solc's non-`--via-ir` stack-depth limit, the same
    /// constraint {DistributionLib.classifyAndSizeRebalanceTrades} hit. A zero value in any
    /// field means "this leg did not fire" (mirrors the original code's `if (...Shares > 0)`
    /// gates before each mint/burn) — the caller must still check `> 0` before minting/burning,
    /// exactly as the original inline code did.
    struct FeeResult {
        uint256 newPrice;
        uint256 ownerShares;
        uint256 ownerFeeValue;
        uint256 callerShares;
        uint256 callerFeeValue;
        uint256 sharesToBurn;
        uint256 penaltyValue;
        uint256 platformShares;
        uint256 platformFeeValue;
    }

    /// @param totalValueBefore Total USD-8-decimal value before the rebalance.
    /// @param totalValueAfter Total USD-8-decimal value after the rebalance.
    /// @param ownerFeeBps Owner fee in basis points.
    /// @param callerFeeBps Caller fee in basis points.
    /// @param accountable `isBucketAccountable()`, snapshotted by the caller — gates the owner
    /// fee/penalty legs exactly as the original inline `if (accountable)` did.
    /// @param ownerBalance `balanceOf(owner())`, snapshotted by the caller BEFORE this call —
    /// safe because the original code's owner-penalty branch (the only place this is read) is
    /// mutually exclusive with the owner-fee-mint branch (the only mutator), see this file's top
    /// doc comment.
    /// @param totalSupplyBefore `totalSupply()`, snapshotted by the caller BEFORE this call and
    /// before any of the four mints/burns this rebalance will perform.
    /// @param rawPlatformFee `bucketInfo.calculateFee(valueDifference)` — the caller computes
    /// `valueDifference` itself (`totalValueAfter > totalValueBefore ? ... : ...`, the same
    /// formula this function uses internally for its own returned bookkeeping) since it is
    /// needed as an input to this very call.
    function computeRebalanceFees(
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 ownerFeeBps,
        uint256 callerFeeBps,
        bool accountable,
        uint256 ownerBalance,
        uint256 totalSupplyBefore,
        uint256 rawPlatformFee
    ) external pure returns (FeeResult memory r) {
        r.newPrice = (totalSupplyBefore > 0) ? (totalValueAfter * PRECISION) / totalSupplyBefore : INITIAL_TOKEN_PRICE;
        uint256 valueDifference = totalValueAfter > totalValueBefore
            ? totalValueAfter - totalValueBefore
            : totalValueBefore - totalValueAfter;

        if (totalValueAfter > totalValueBefore) {
            uint256 increase = totalValueAfter - totalValueBefore;
            if (accountable) {
                uint256 ownerFeeValue = (increase * ownerFeeBps * PRECISION) / BPS_DENOMINATOR;
                if (ownerFeeValue > 0 && r.newPrice > 0) {
                    uint256 ownerShares = ownerFeeValue / r.newPrice;
                    ownerFeeValue = ownerFeeValue / PRECISION;
                    if (ownerShares > 0) {
                        r.ownerShares = ownerShares;
                        r.ownerFeeValue = ownerFeeValue;
                    }
                }
            }
            uint256 callerFeeValue = (increase * callerFeeBps * PRECISION) / BPS_DENOMINATOR;
            if (callerFeeValue > 0 && r.newPrice > 0) {
                uint256 callerShares = callerFeeValue / r.newPrice;
                callerFeeValue = callerFeeValue / PRECISION;
                if (callerShares > 0) {
                    r.callerShares = callerShares;
                    r.callerFeeValue = callerFeeValue;
                }
            }
        } else if (totalValueAfter < totalValueBefore) {
            uint256 decrease = totalValueBefore - totalValueAfter;
            if (accountable) {
                uint256 penaltyValue = (decrease * (callerFeeBps + ownerFeeBps) * PRECISION) / BPS_DENOMINATOR;
                uint256 sharesToBurn = penaltyValue / r.newPrice;
                penaltyValue = penaltyValue / PRECISION;
                if (sharesToBurn > ownerBalance) {
                    sharesToBurn = ownerBalance;
                }
                if (sharesToBurn > 0) {
                    r.sharesToBurn = sharesToBurn;
                    r.penaltyValue = penaltyValue;
                }
            }
        }

        uint256 platformFeeValue = rawPlatformFee > (valueDifference * MAX_LOCAL_PLATFORM_FEE_BPS) / BPS_DENOMINATOR
            ? (valueDifference * MAX_LOCAL_PLATFORM_FEE_BPS) / BPS_DENOMINATOR
            : rawPlatformFee;
        if (platformFeeValue > 0 && r.newPrice > 0) {
            uint256 platformShares = (platformFeeValue * PRECISION) / r.newPrice;
            if (platformShares > 0) {
                r.platformShares = platformShares;
                r.platformFeeValue = platformFeeValue;
            }
        }
    }
}
