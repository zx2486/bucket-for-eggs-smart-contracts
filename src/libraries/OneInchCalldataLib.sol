// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBucketInfo} from "../interfaces/IBucketInfo.sol";

/// @notice Validates and executes caller-supplied 1inch V6 swap calldata.
library OneInchCalldataLib {
    using SafeERC20 for IERC20;

    bytes4 public constant SWAP_SELECTOR = 0x07ed2379;
    address private constant ONEINCH_NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 private constant PARTIAL_FILL_FLAG = 1;

    error InvalidSwapSelector(bytes4 selector);
    error MalformedSwapPayload();
    error PartialFillNotAllowed();
    error SwapFailed();
    error SourceSpentAboveAmount(uint256 spent, uint256 amount);
    error ReceivedBelowMinimum(uint256 received, uint256 minimum);
    error UnexpectedTokenBalanceDecrease(address token, uint256 beforeBalance, uint256 afterBalance);
    error ResidualRouterAllowance(address token, uint256 allowance);

    struct SwapDescription {
        address srcToken;
        address dstToken;
        address srcReceiver;
        address dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    struct SwapRequest {
        address router;
        address srcToken;
        address dstToken;
        uint256 amount;
        uint256 minReturn;
        bytes routerCalldata;
    }

    struct BalanceSnapshot {
        address[] tokens;
        uint256[] balances;
    }

    /// @notice Validate that V6 swap calldata describes the typed intent.
    function validateSwapCalldata(
        bytes calldata routerCalldata,
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 minReturn
    ) public view {
        if (routerCalldata.length < 4) revert MalformedSwapPayload();
        bytes4 selector = bytes4(routerCalldata[:4]);
        if (selector != SWAP_SELECTOR) revert InvalidSwapSelector(selector);
        if (routerCalldata.length < 4 + 10 * 32) revert MalformedSwapPayload();

        (, SwapDescription memory desc,) = abi.decode(routerCalldata[4:], (address, SwapDescription, bytes));

        if (
            _normaliseToken(desc.srcToken) != srcToken || _normaliseToken(desc.dstToken) != dstToken
                || desc.dstReceiver != address(this) || desc.amount != amount || desc.minReturnAmount < minReturn
        ) {
            revert MalformedSwapPayload();
        }
        if ((desc.flags & PARTIAL_FILL_FLAG) != 0) revert PartialFillNotAllowed();
    }

    /// @notice Execute a bound V6 swap, clearing any ERC-20 allowance in the same transaction.
    /// @dev `protectedTokens` must contain every held token; the complete whitelist is also added here.
    function executeSwap(IBucketInfo bucketInfo, address[] calldata protectedTokens, SwapRequest calldata request)
        public
        returns (uint256 srcSpent, uint256 dstReceived)
    {
        validateSwapCalldata(
            request.routerCalldata, request.srcToken, request.dstToken, request.amount, request.minReturn
        );

        BalanceSnapshot memory snapshot = _snapshot(bucketInfo, protectedTokens);
        uint256 srcBalanceBefore = _balanceOf(request.srcToken);
        uint256 dstBalanceBefore = _balanceOf(request.dstToken);

        if (request.srcToken == address(0)) {
            _callRouter(request.router, request.routerCalldata, request.amount);
        } else {
            IERC20(request.srcToken).forceApprove(request.router, request.amount);
            _callRouter(request.router, request.routerCalldata, 0);
            IERC20(request.srcToken).forceApprove(request.router, 0);
            uint256 remainingAllowance = IERC20(request.srcToken).allowance(address(this), request.router);
            if (remainingAllowance != 0) {
                revert ResidualRouterAllowance(request.srcToken, remainingAllowance);
            }
        }

        srcSpent = _sourceSpent(request.srcToken, srcBalanceBefore, request.amount);
        dstReceived = _destinationReceived(request.dstToken, dstBalanceBefore, request.minReturn);
        _assertSnapshot(snapshot, request.srcToken);
    }

    function _snapshot(IBucketInfo bucketInfo, address[] calldata protectedTokens)
        private
        view
        returns (BalanceSnapshot memory snapshot)
    {
        address[] memory whitelistedTokens = bucketInfo.getWhitelistedTokens();
        snapshot.tokens = new address[](whitelistedTokens.length + protectedTokens.length);
        snapshot.balances = new uint256[](snapshot.tokens.length);
        for (uint256 i; i < whitelistedTokens.length; ++i) {
            snapshot.tokens[i] = whitelistedTokens[i];
        }
        for (uint256 i; i < protectedTokens.length; ++i) {
            snapshot.tokens[whitelistedTokens.length + i] = protectedTokens[i];
        }
        for (uint256 i; i < snapshot.tokens.length; ++i) {
            snapshot.balances[i] = _balanceOf(snapshot.tokens[i]);
        }
    }

    function _sourceSpent(address srcToken, uint256 balanceBefore, uint256 amount)
        private
        view
        returns (uint256 spent)
    {
        uint256 balanceAfter = _balanceOf(srcToken);
        spent = balanceAfter < balanceBefore ? balanceBefore - balanceAfter : 0;
        if (spent > amount) revert SourceSpentAboveAmount(spent, amount);
    }

    function _destinationReceived(address dstToken, uint256 balanceBefore, uint256 minReturn)
        private
        view
        returns (uint256 received)
    {
        uint256 balanceAfter = _balanceOf(dstToken);
        received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received < minReturn) revert ReceivedBelowMinimum(received, minReturn);
    }

    function _assertSnapshot(BalanceSnapshot memory snapshot, address srcToken) private view {
        for (uint256 i; i < snapshot.tokens.length; ++i) {
            _assertNotDecreased(snapshot.tokens[i], snapshot.balances[i], srcToken);
        }
    }

    function _callRouter(address router, bytes calldata routerCalldata, uint256 value) private {
        (bool success, bytes memory returndata) = router.call{value: value}(routerCalldata);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
            revert SwapFailed();
        }
    }

    function _assertNotDecreased(address token, uint256 beforeBalance, address srcToken) private view {
        if (token == srcToken) return;
        uint256 afterBalance = _balanceOf(token);
        if (afterBalance < beforeBalance) {
            revert UnexpectedTokenBalanceDecrease(token, beforeBalance, afterBalance);
        }
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _normaliseToken(address token) private pure returns (address) {
        return token == ONEINCH_NATIVE_TOKEN ? address(0) : token;
    }
}
