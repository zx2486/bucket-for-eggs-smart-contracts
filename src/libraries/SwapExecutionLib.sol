// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Validates swaps, dispatches router calls, and tracks swap limits.
/// @dev Never grants the router an allowance.
library SwapExecutionLib {
    error SameToken();
    error ZeroAmount();
    error InvalidToken(address token);
    error AmountExceedsHeldBalance(uint256 amount, uint256 heldBalance);
    error MinReturnBelowFloor(uint256 minReturnValueUsd, uint256 floorValueUsd);
    error MalformedSwapPayload();
    error SwapFailed();
    error EpochValueLossBudgetExceeded(uint256 projectedLossUsd, uint256 budgetUsd);
    error SwapCooldownActive(uint256 cooldownUntil);

    error ValueLossTooHigh(uint256 valueBefore, uint256 valueAfter);
    error MaxValueLossBpsExceedsCeiling(uint256 requested);
    event MaxValueLossBpsUpdated(uint256 newBps, uint256 newEpochBudgetBps);
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_RETURN_FLOOR_TOLERANCE_BPS = 100;
    uint256 public constant VALUE_LOSS_EPOCH_LENGTH = 1 days;
    uint256 public constant EPOCH_VALUE_LOSS_BUDGET_BPS = 150;
    uint256 public constant CALLER_SWAP_COOLDOWN = 5 minutes;
    uint256 public constant GLOBAL_SWAP_COOLDOWN = 1 minutes;

    /// @dev Per-caller and global swap cooldown timestamps.
    struct SwapCooldownState {
        mapping(address => uint256) callerSwapCooldownUntil;
        uint256 globalSwapCooldownUntil;
    }

    /// @dev Enforce and update caller and global swap cooldowns.
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

    /// @dev Cumulative value loss tracked for the current epoch.
    struct EpochLossBudget {
        uint256 currentEpochStart;
        uint256 currentEpochValueLossUsd;
    }

    /// @dev Owner-adjustable per-swap and per-epoch loss limits.
    struct MaxValueLossBpsState {
        uint256 bps;
        uint256 epochBudgetBps;
    }

    /// @dev Maximum configurable loss limit, in basis points.
    uint256 public constant MAX_VALUE_LOSS_BPS_CEILING = 1000;

    /// @dev Update both loss limits.
    function setMaxValueLossBps(
        MaxValueLossBpsState storage state,
        uint256 newMaxValueLossBps,
        uint256 newEpochBudgetBps
    ) public {
        if (newMaxValueLossBps > MAX_VALUE_LOSS_BPS_CEILING) {
            revert MaxValueLossBpsExceedsCeiling(newMaxValueLossBps);
        }
        if (newEpochBudgetBps > MAX_VALUE_LOSS_BPS_CEILING) {
            revert MaxValueLossBpsExceedsCeiling(newEpochBudgetBps);
        }
        state.bps = newMaxValueLossBps;
        state.epochBudgetBps = newEpochBudgetBps;
        emit MaxValueLossBpsUpdated(newMaxValueLossBps, newEpochBudgetBps);
    }

    /// @dev Validates a single swap leg: token whitelist status, held balance, and a pre-commitment
    /// oracle-derived minReturn floor, checked before the swap executes.
    function validateSwapLeg(
        IBucketInfo bucketInfo,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn
    ) public view {
        if (srcToken == dstToken) revert SameToken();
        if (amount == 0) revert ZeroAmount();

        if (!bucketInfo.isTokenValid(srcToken)) revert InvalidToken(srcToken);
        if (!bucketInfo.isTokenValid(dstToken)) revert InvalidToken(dstToken);

        uint256 heldBalance = _balanceOf(srcToken);
        uint8 srcDec = _decimalsOf(srcToken);
        uint8 dstDec = _decimalsOf(dstToken);

        if (amount > heldBalance) revert AmountExceedsHeldBalance(amount, heldBalance);

        uint256 srcPrice = bucketInfo.getTokenPrice(srcToken);
        uint256 dstPrice = bucketInfo.getTokenPrice(dstToken);
        if (srcPrice == 0) revert InvalidToken(srcToken);
        if (dstPrice == 0) revert InvalidToken(dstToken);

        uint256 srcValueUsd = (amount * srcPrice) / (10 ** srcDec);
        uint256 minReturnValueUsd = (minReturn * dstPrice) / (10 ** dstDec);
        uint256 floorValueUsd = (srcValueUsd * (BPS_DENOMINATOR - MIN_RETURN_FLOOR_TOLERANCE_BPS)) / BPS_DENOMINATOR;

        if (minReturnValueUsd < floorValueUsd) {
            revert MinReturnBelowFloor(minReturnValueUsd, floorValueUsd);
        }
    }

    /// @dev Return a token balance or the native ETH balance.
    function _balanceOf(address token) private view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Return token decimals, treating native ETH as 18 decimals.
    function _decimalsOf(address token) private view returns (uint8) {
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    /// @dev Sum the USD value of all whitelisted token balances.
    function calculateTotalValue(IBucketInfo bucketInfo) public view returns (uint256 totalValue) {
        address[] memory tokens = bucketInfo.getWhitelistedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            totalValue += getTokenValue(bucketInfo, tokens[i]);
        }
    }

    /// @dev Return the USD value of a token balance.
    function getTokenValue(IBucketInfo bucketInfo, address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token);
        if (balance == 0) return 0;
        uint256 price = bucketInfo.getTokenPrice(token);
        uint8 dec = _decimalsOf(token);
        if (price == 0) revert InvalidToken(token);
        return (balance * price) / (10 ** dec);
    }

    /// @dev Calculate minimum output using the caller's slippage tolerance.
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
        if (srcPrice == 0) revert InvalidToken(srcToken);
        if (dstPrice == 0) revert InvalidToken(dstToken);

        uint256 toleranceBps = maxSlippageBps > BPS_DENOMINATOR ? BPS_DENOMINATOR : maxSlippageBps;

        uint256 srcValueUsd = (amount * srcPrice) / (10 ** srcDec);
        uint256 minReturnValueUsd = (srcValueUsd * (BPS_DENOMINATOR - toleranceBps)) / BPS_DENOMINATOR;
        minReturn = (minReturnValueUsd * (10 ** dstDec)) / dstPrice;
    }

    /// @dev Dispatch a typed swap call to the configured router.
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

        if (routerCalldata.length < 4 + 32 * 3) revert MalformedSwapPayload();
        address receiver;
        assembly {
            receiver := mload(add(routerCalldata, 100))
        }
        if (receiver != address(this)) revert MalformedSwapPayload();

        bool isNativeSrc = (srcToken == address(0));

        (bool success, bytes memory returndata) =
            isNativeSrc ? router.call{value: amount}(routerCalldata) : router.call(routerCalldata);

        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
            revert SwapFailed();
        }
    }

    /// @dev Add a loss to the current epoch budget.
    function consumeEpochValueLossBudget(
        EpochLossBudget storage budget,
        uint256 totalValueBeforeCall,
        uint256 lossUsd,
        uint256 epochBudgetBps
    ) public {
        uint256 nowTs = block.timestamp;
        if (nowTs >= budget.currentEpochStart + VALUE_LOSS_EPOCH_LENGTH) {
            budget.currentEpochStart = nowTs;
            budget.currentEpochValueLossUsd = 0;
        }
        uint256 budgetUsd = (totalValueBeforeCall * epochBudgetBps) / BPS_DENOMINATOR;
        uint256 projected = budget.currentEpochValueLossUsd + lossUsd;
        if (projected > budgetUsd) {
            revert EpochValueLossBudgetExceeded(projected, budgetUsd);
        }
        budget.currentEpochValueLossUsd = projected;
    }

    /// @dev Enforce per-swap and cumulative per-epoch value-loss limits.
    function checkValueLossAndConsumeBudget(
        EpochLossBudget storage budget,
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 maxValueLossBps,
        uint256 epochBudgetBps
    ) public {
        if (totalValueAfter < totalValueBefore) {
            uint256 loss = totalValueBefore - totalValueAfter;
            uint256 maxLoss = (totalValueBefore * maxValueLossBps) / BPS_DENOMINATOR;
            if (loss > maxLoss) {
                revert ValueLossTooHigh(totalValueBefore, totalValueAfter);
            }
            consumeEpochValueLossBudget(budget, totalValueBefore, loss, epochBudgetBps);
        }
    }
}
