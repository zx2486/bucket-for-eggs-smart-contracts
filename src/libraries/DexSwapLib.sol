// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Uniswap V3 SwapRouter02 interface.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Uniswap V3 QuoterV2 interface.
interface IQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @notice Wrapped Ether interface.
interface IWETH {
    function withdraw(uint256) external;

    function deposit() external payable;

    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}

/// @notice DEX router configuration for rebalancing.
struct DexConfig {
    address router;
    address quoter;
    uint24 fee;
    bool enabled;
}

/// @notice Quotes configured DEXes and executes rebalancing swaps.
library DexSwapLib {
    using SafeERC20 for IERC20;

    /// @dev Quotes every configured DEX for `tokenIn` -> `tokenOut` and executes on whichever
    /// quotes the best output, with ETH<->WETH wrapping handled transparently at the edges.
    /// @dev `public`, not `external`: called both from outside the library (PassiveBucket) and
    /// from {executeRebalanceTrades} below, in the SAME library — a same-library call to a
    /// `public` function is a plain internal jump, whereas `external` cannot be called by its
    /// bare name from within the same unit at all.
    function executeBestSwap(
        mapping(uint8 => DexConfig) storage dexConfigs,
        uint8 dexCount,
        address weth,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) public {
        address actualTokenIn = tokenIn;
        address actualTokenOut = tokenOut;

        if (tokenIn == address(0)) {
            require(weth != address(0), "WETH not set");
            IWETH(weth).deposit{value: amountIn}();
            actualTokenIn = weth;
        }
        if (tokenOut == address(0)) {
            require(weth != address(0), "WETH not set");
            actualTokenOut = weth;
        }

        uint8 bestDex = type(uint8).max;
        uint256 bestQuote = 0;

        for (uint8 i = 0; i < dexCount; i++) {
            DexConfig memory configTry = dexConfigs[i];
            if (!configTry.enabled || configTry.quoter == address(0)) continue;

            try IQuoter(configTry.quoter)
                .quoteExactInputSingle(
                    IQuoter.QuoteExactInputSingleParams({
                        tokenIn: actualTokenIn,
                        tokenOut: actualTokenOut,
                        amountIn: amountIn,
                        fee: configTry.fee,
                        sqrtPriceLimitX96: 0
                    })
                ) returns (
                uint256 amountOut, uint160, uint32, uint256
            ) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    bestDex = i;
                }
            } catch {}
        }

        require(bestDex != type(uint8).max, "No DEX available for pair");
        require(bestQuote > 0, "Zero quote from all DEXs");
        require(bestQuote > minAmountOut, "No sufficient quote found");

        DexConfig memory config = dexConfigs[bestDex];
        IERC20(actualTokenIn).forceApprove(config.router, amountIn);

        ISwapRouter(config.router)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: actualTokenIn,
                    tokenOut: actualTokenOut,
                    fee: config.fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: (bestQuote * 95) / 100,
                    sqrtPriceLimitX96: 0
                })
            );

        IERC20(actualTokenIn).forceApprove(config.router, 0);

        if (tokenOut == address(0)) {
            uint256 wethBal = IWETH(weth).balanceOf(address(this));
            if (wethBal > 0) {
                IWETH(weth).withdraw(wethBal);
            }
        }
    }

    /// @dev Executes the "sell every overweight token to WETH, then buy every underweight token
    /// from WETH" trade loop pair for a rebalance. Makes no call to any host-contract internal
    /// function, only to `IWETH`/DEX routers (external contracts) and to {executeBestSwap} above.
    function executeRebalanceTrades(
        mapping(uint8 => DexConfig) storage dexConfigs,
        uint8 dexCount,
        address weth,
        address[] memory sellTokens,
        uint256[] memory sellAmounts,
        address[] memory buyTokens,
        uint256[] memory buyDeficits,
        uint256 sellCount,
        uint256 buyCount,
        uint256 totalDeficit
    ) external {
        for (uint256 i = 0; i < sellCount; i++) {
            if (sellAmounts[i] > 0) {
                if (sellTokens[i] == address(0)) {
                    IWETH(weth).deposit{value: sellAmounts[i]}();
                    continue;
                }
                executeBestSwap(dexConfigs, dexCount, weth, sellTokens[i], weth, sellAmounts[i], 0);
            }
        }
        uint256 wethBalance = IWETH(weth).balanceOf(address(this));
        for (uint256 j = 0; j < buyCount; j++) {
            if (buyDeficits[j] > 0) {
                uint256 amountToBuy = (wethBalance * buyDeficits[j]) / totalDeficit;
                if (amountToBuy > 0) {
                    if (buyTokens[j] == address(0)) {
                        IWETH(weth).withdraw(amountToBuy);
                        continue;
                    }
                    executeBestSwap(dexConfigs, dexCount, weth, weth, buyTokens[j], amountToBuy, 0);
                }
            }
        }
    }
}
