// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {BucketVaultBase} from "./BucketVaultBase.sol";
import {OneInchCalldataLib} from "../libraries/OneInchCalldataLib.sol";
import {SwapExecutionLib} from "../libraries/SwapExecutionLib.sol";

/// @title 1inch swap and cooldown functionality for active vaults.
abstract contract BucketVaultSwapBase is BucketVaultBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    error EmptyLegs();

    /// @dev Return the implementation's fixed 1inch router.
    function _oneInchRouter() internal view virtual returns (address);

    function _lossBoundsForCallerCalldata() internal view virtual returns (uint256 perCallBps, uint256 epochBps) {
        return (maxValueLossBps(), epochValueLossBudgetBps());
    }

    /// @dev Execute a validated caller-calldata 1inch swap.
    function _execute1inchSwap(
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn,
        bytes calldata routerCalldata
    ) internal returns (uint256 totalValueBefore, uint256 totalValueAfter) {
        _validateSwapLeg(srcToken, dstToken, amount, minReturn);
        _enforceSwapCooldown(msg.sender);
        return _executeSwapWithCalldataNoCooldown(srcToken, dstToken, amount, minReturn, routerCalldata);
    }

    /// @dev One leg of a multi-leg swap: see `_executeMultiLegSwap`.
    struct SwapLeg {
        address srcToken;
        address dstToken;
        uint256 amount;
        uint256 minReturn;
        bytes routerCalldata;
    }

    /// @dev Execute several caller-calldata swap legs under one cooldown charge.
    function _executeMultiLegSwap(SwapLeg[] calldata legs)
        internal
        returns (uint256 totalValueBefore, uint256 totalValueAfter)
    {
        if (legs.length == 0) revert EmptyLegs();

        _enforceSwapCooldown(msg.sender);
        totalValueBefore = _calculateTotalValue();
        for (uint256 i; i < legs.length; ++i) {
            SwapLeg calldata leg = legs[i];
            _validateSwapLeg(leg.srcToken, leg.dstToken, leg.amount, leg.minReturn);
            _executeSwapWithCalldataNoCooldown(
                leg.srcToken, leg.dstToken, leg.amount, leg.minReturn, leg.routerCalldata
            );
        }
        totalValueAfter = _calculateTotalValue();
    }

    function _validateSwapLeg(address srcToken, address dstToken, uint256 amount, uint256 minReturn) internal view {
        SwapExecutionLib.validateSwapLeg(_bucketInfo(), srcToken, dstToken, amount, minReturn);
    }

    function _executeSwapWithCalldataNoCooldown(
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn,
        bytes calldata routerCalldata
    ) private returns (uint256 totalValueBefore, uint256 totalValueAfter) {
        totalValueBefore = _calculateTotalValue();
        address[] memory protectedTokens = _getBucketVaultBaseStorage().heldTokens.values();
        OneInchCalldataLib.SwapRequest memory request = OneInchCalldataLib.SwapRequest({
            router: _oneInchRouter(),
            srcToken: srcToken,
            dstToken: dstToken,
            amount: amount,
            minReturn: minReturn,
            routerCalldata: routerCalldata
        });
        OneInchCalldataLib.executeSwap(_bucketInfo(), protectedTokens, request);
        totalValueAfter = _calculateTotalValue();
        _checkCallerCalldataValueLossAndConsumeBudget(totalValueBefore, totalValueAfter);
    }

    function _checkCallerCalldataValueLossAndConsumeBudget(uint256 totalValueBefore, uint256 totalValueAfter) private {
        (uint256 perCallBps, uint256 epochBps) = _lossBoundsForCallerCalldata();
        SwapExecutionLib.checkValueLossAndConsumeBudget(
            _getBucketVaultBaseStorage().epochLossBudget, totalValueBefore, totalValueAfter, perCallBps, epochBps
        );
    }

    /// @dev Enforce caller and global swap cooldowns.
    function _enforceSwapCooldown(address caller) internal {
        BucketVaultBaseStorage storage $ = _getBucketVaultBaseStorage();
        SwapExecutionLib.enforceSwapCooldown($.swapCooldown, caller);
    }
}
