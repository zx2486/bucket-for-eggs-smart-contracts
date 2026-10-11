// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PassiveBucket} from "../PassiveBucket.sol";

/// @notice Validates target distributions and classifies rebalance trades.

library DistributionLib {
    /// @notice Read-only inputs used to classify rebalance trades.
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

    /// @notice Validate tokens, weights, and total weight in a target distribution.
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

    /// @notice Classify whitelisted tokens and size rebalance trades.
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

    /// @dev Classify one token as a seller or buyer against its target weight.
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
