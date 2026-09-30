// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ISwapRouter
 * @dev Interface for Uniswap V3 SwapRouter02. Moved here unchanged from PassiveBucket.sol
 * (W3 size-reduction extraction) — only its physical location changed.
 */
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

/**
 * @title IQuoter
 * @dev Interface for Uniswap V3 QuoterV2. Moved here unchanged from PassiveBucket.sol
 * (W3 size-reduction extraction) — only its physical location changed.
 */
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

/**
 * @title IWETH
 * @dev Interface for Wrapped Ether. Moved here from PassiveBucket.sol (W3 size-reduction
 * extraction), which still imports and uses it directly for its own ETH<->WETH legs in
 * `rebalanceByDefi` (outside `_executeBestSwap`) — only the declaration's physical location
 * changed, not its usage.
 */
interface IWETH {
    function withdraw(uint256) external;

    function deposit() external payable;

    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}

/// @notice DEX router configuration for rebalancing. Moved here from inside the `PassiveBucket`
/// contract (W3 size-reduction extraction) so this file's library and `PassiveBucket.sol`'s
/// `dexConfigs` mapping share one identical declared type, without either file importing the
/// other (which the old arrangement — struct nested inside `PassiveBucket` — would have required,
/// creating a circular import between this library and the contract it serves). No field changed;
/// `PassiveBucket.sol` imports this type and keeps declaring `mapping(uint8 => DexConfig) public
/// dexConfigs` exactly as before, so the mapping's storage layout and its public getter's ABI
/// (a 4-tuple of router/quoter/fee/enabled) are unaffected by where the type is declared.
struct DexConfig {
    address router;
    address quoter;
    uint24 fee;
    bool enabled;
}

/**
 * @title DexSwapLib
 * @notice W3 EIP-170 size-reduction extraction. `PassiveBucket`'s own runtime bytecode exceeded
 * the EIP-170 24,576-byte limit (measured via `forge build --sizes` at 26,983 bytes, margin
 * -2,407 bytes, immediately after the unrelated 1inch-allowance fix — see the note on
 * `BucketVaultBase._execute1inchSwap` — which only shaved ~86 bytes and left the contract still
 * over the limit). This library moves the self-contained "quote every configured DEX, execute on
 * the best one" logic — previously `PassiveBucket._executeBestSwap`, an `internal` function whose
 * full bytecode was inlined at each of its three call sites inside `rebalanceByDefi` — out of
 * `PassiveBucket`'s own bytecode and into a SEPARATELY DEPLOYED library with an `external`
 * function.
 * @dev Foundry/solc links a call to an `external` (or `public`) library function as a
 * DELEGATECALL to the library's own deployed bytecode — this is what actually removes the bytes
 * from `PassiveBucket`'s own runtime size. An `internal` library function would instead be
 * copied/inlined right back into every caller with NO size benefit, which is why this function is
 * `external`, not `internal` (the technique only works one way). `forge build`/`forge test`
 * resolve and deploy the library automatically; no address is hardcoded anywhere, and nothing
 * here is deployed or broadcast by this change itself (root `CLAUDE.md` hard rule 1) —
 * library deployment happens the same way any other contract's deployment would, later, in a
 * human-gated deploy step.
 * @dev DELEGATECALL preserves `address(this)` and `msg.sender` exactly as they were when this
 * logic ran inline inside `PassiveBucket` — every external call this function makes
 * (`IWETH.deposit`, `IERC20.forceApprove`, `IQuoter.quoteExactInputSingle`,
 * `ISwapRouter.exactInputSingle`, `IWETH.withdraw`) still executes with the VAULT as
 * `address(this)`/the caller, identically to before. This is a pure bytecode-location change:
 * every line of logic below — validation order, the best-quote selection loop, the
 * approve/swap/revoke sequence, the WETH-unwrap tail — is copied unchanged from the
 * `_executeBestSwap` it replaces. No behavior, ordering, or control flow differs.
 * @dev Unrelated to hard rule 12 / R-V1 (`09-DECISION-LOG.md` §4.2/§4.2a): that rule, and the W2
 * fix removing the scoped `forceApprove` from `BucketVaultBase._execute1inchSwap`, are both
 * specifically about the 1inch aggregation router. This library's own `forceApprove`/
 * `forceApprove(0)` pair targets a Uniswap-V3-style router registered via `configureDEX`
 * (owner-controlled, never the 1inch router) — pre-existing behavior carried over unchanged from
 * `_executeBestSwap`, not a new grant and not the one hard rule 12 is about.
 */
library DexSwapLib {
    using SafeERC20 for IERC20;

    /// @dev Identical body to the former `PassiveBucket._executeBestSwap`, just parameterized
    /// over the caller's own `dexConfigs`/`dexCount`/`weth` instead of reading them as this
    /// contract's own state — a library function has no state of its own, so the caller's
    /// storage mapping is passed by reference (delegatecall means it resolves against the
    /// caller's own storage, exactly like an internal function reading `dexConfigs` directly
    /// would have).
    /// @dev `public`, not `external`: called both from outside the library (PassiveBucket,
    /// which still triggers the size-reducing DELEGATECALL/linking exactly as `external` would)
    /// AND from {executeRebalanceTrades} below, in the SAME library — a same-library call to a
    /// `public` function is a plain internal jump (no second delegatecall, no behavior change),
    /// whereas `external` cannot be called by its bare name from within the same unit at all.
    function executeBestSwap(
        mapping(uint8 => DexConfig) storage dexConfigs,
        uint8 dexCount,
        address weth,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) public {
        // Handle ETH -> WETH wrapping if needed
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

        // Find best DEX
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

        // Execute on best DEX
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

        // Unwrap WETH -> ETH if needed
        if (tokenOut == address(0)) {
            uint256 wethBal = IWETH(weth).balanceOf(address(this));
            if (wethBal > 0) {
                IWETH(weth).withdraw(wethBal);
            }
        }
    }

    /// @dev Identical body to the trade-execution block formerly inline in
    /// `PassiveBucket.rebalanceByDefi` (the "sell every overweight token to WETH, then buy every
    /// underweight token from WETH" loop pair) — moved here for the same size-reduction reason as
    /// {executeBestSwap}, and safe to move for the same reason: it makes no call to any
    /// BucketVaultBase-inherited internal function, only to `IWETH`/DEX routers (external
    /// contracts) and to {executeBestSwap} above (a same-library internal jump). `sellCount`/
    /// `buyCount`/`totalDeficit` are `countAndDeficit[0]`/`[1]`/`[2]` at the call site, passed by
    /// value since they are plain counters, not storage.
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
                    // if it is eth, just deposit into weth
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
                        // if it is eth, just withdraw from weth
                        IWETH(weth).withdraw(amountToBuy);
                        continue;
                    }
                    executeBestSwap(dexConfigs, dexCount, weth, weth, buyTokens[j], amountToBuy, 0);
                }
            }
        }
    }
}
