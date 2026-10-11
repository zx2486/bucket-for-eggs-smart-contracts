// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Calculates fees and penalties for a passive-vault rebalance.

library RebalanceFeeLib {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant INITIAL_TOKEN_PRICE = 1e8;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_LOCAL_PLATFORM_FEE_BPS = 1000;
    /// @dev Maximum allowed post-rebalance price deviation, in percent.
    uint256 private constant MAX_PRICE_DEVIATION_PCT = 20;

    error InvalidPriceAfterRebalance();
    error PriceDeviationTooHigh();

    /// @notice Fee and penalty amounts calculated for a rebalance.
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
    /// fee/penalty legs.
    /// @param ownerBalance `balanceOf(owner())`, snapshotted by the caller before this call.
    /// @param totalSupplyBefore `totalSupply()`, snapshotted by the caller before this call and
    /// before any of the mints/burns this rebalance will perform.
    /// @param rawPlatformFee `bucketInfo.calculateFee(valueDifference)` — the caller computes
    /// `valueDifference` itself since it is needed as an input to this call.
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

    /// @notice Recalculate the post-fee share price and enforce its deviation limit.
    function validatePriceAfterRebalance(uint256 totalValueNow, uint256 totalSupplyNow, uint256 newPrice)
        external
        pure
        returns (uint256 priceAfterRebalance)
    {
        priceAfterRebalance = (totalSupplyNow > 0) ? (totalValueNow * PRECISION) / totalSupplyNow : INITIAL_TOKEN_PRICE;
        if (priceAfterRebalance == 0) revert InvalidPriceAfterRebalance();
        uint256 priceChange =
            priceAfterRebalance > newPrice ? priceAfterRebalance - newPrice : newPrice - priceAfterRebalance;
        if (priceChange > (newPrice * MAX_PRICE_DEVIATION_PCT) / 100) revert PriceDeviationTooHigh();
    }
}
