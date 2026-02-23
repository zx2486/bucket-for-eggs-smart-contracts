// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ISwapRouter
 * @dev Interface for Uniswap V3 SwapRouter02
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
 * @title ICurvePool
 * @dev Interface for Curve pools
 */
interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/**
 * @title IQuoter
 * @dev Interface for Uniswap V3 QuoterV2
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
 * @dev Interface for Wrapped Ether
 */
interface IWETH {
    function withdraw(uint256) external;

    function deposit() external payable;

    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}

/**
 * @title DefiSwap
 * @dev Contract for depositing USDT and swapping 50% to native ETH using the best DEX
 * @notice Automatically selects the DEX with the best price from Uniswap V3/V4, Fluid, and Curve
 */
contract DefiSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    enum DEX {
        UNISWAP_V3,
        UNISWAP_V4,
        FLUID,
        CURVE
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed user, uint256 amount);
    event Swapped(uint256 usdtAmount, uint256 ethReceived, DEX dexUsed, string dexName);
    event USDTWithdrawn(address indexed recipient, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event DEXConfigUpdated(DEX dex, address router, bool enabled);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev USDT token contract
    IERC20 public immutable usdt;

    /// @dev WETH token contract (needed for Uniswap swaps)
    IWETH public immutable weth;

    /// @dev Total USDT deposited by all users
    uint256 public totalUSDTDeposited;

    /// @dev Mapping of user address to their USDT balance
    mapping(address => uint256) public userBalances;

    /// @dev USDT has 6 decimals
    uint256 private constant USDT_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////
                        DEX CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    struct DEXConfig {
        address router;
        address quoter;
        uint24 fee; // For Uniswap (3000 = 0.3%)
        bool enabled;
    }

    mapping(DEX => DEXConfig) public dexConfigs;

    /// @dev Curve pool address (if using Curve)
    address public curvePool;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the DefiSwap contract
     * @param _usdt Address of the USDT token contract
     * @param _weth Address of the WETH token contract
     */
    constructor(address _usdt, address _weth) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT address");
        require(_weth != address(0), "Invalid WETH address");

        usdt = IERC20(_usdt);
        weth = IWETH(_weth);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit USDT into the contract
     * @param amount Amount of USDT to deposit (with 6 decimals)
     */
    function depositUSDT(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer USDT from user to contract
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        userBalances[msg.sender] += amount;
        totalUSDTDeposited += amount;

        emit Deposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swap 50% of contract's USDT holdings to native ETH using the best DEX
     * @dev Automatically queries all enabled DEXs and uses the one with best price
     * @return usdtSwapped Amount of USDT swapped
     * @return ethReceived Amount of native ETH received
     * @return bestDex The DEX that provided the best rate
     */
    function swap() external onlyOwner nonReentrant returns (uint256 usdtSwapped, uint256 ethReceived, DEX bestDex) {
        uint256 contractBalance = usdt.balanceOf(address(this));
        require(contractBalance > 0, "No USDT to swap");

        // Calculate 50% of holdings
        usdtSwapped = contractBalance / 2;
        require(usdtSwapped > 0, "Swap amount too small");

        // Find best DEX
        uint256 bestQuote;
        (bestDex, bestQuote) = getBestQuote(usdtSwapped);
        require(bestQuote > 0, "No valid quotes found");

        // Execute swap on best DEX
        uint256 ethBalanceBefore = address(this).balance;
        executeSwap(bestDex, usdtSwapped, bestQuote);
        ethReceived = address(this).balance - ethBalanceBefore;

        require(ethReceived > 0, "No ETH received from swap");

        string memory dexName = getDEXName(bestDex);
        emit Swapped(usdtSwapped, ethReceived, bestDex, dexName);

        return (usdtSwapped, ethReceived, bestDex);
    }

    /**
     * @notice Get quotes from all enabled DEXs and find the best one
     * @param amount Amount of USDT to swap
     * @return bestDex The DEX with the best quote
     * @return bestQuote The best quote amount in ETH
     */
    function getBestQuote(uint256 amount) public returns (DEX bestDex, uint256 bestQuote) {
        bestQuote = 0;
        bestDex = DEX.UNISWAP_V3; // default

        // Check Uniswap V3
        if (dexConfigs[DEX.UNISWAP_V3].enabled) {
            uint256 quote = getUniswapQuote(DEX.UNISWAP_V3, amount);
            if (quote > bestQuote) {
                bestQuote = quote;
                bestDex = DEX.UNISWAP_V3;
            }
        }

        // Check Uniswap V4
        if (dexConfigs[DEX.UNISWAP_V4].enabled) {
            uint256 quote = getUniswapQuote(DEX.UNISWAP_V4, amount);
            if (quote > bestQuote) {
                bestQuote = quote;
                bestDex = DEX.UNISWAP_V4;
            }
        }

        // Check Fluid
        if (dexConfigs[DEX.FLUID].enabled) {
            uint256 quote = getUniswapQuote(DEX.FLUID, amount);
            if (quote > bestQuote) {
                bestQuote = quote;
                bestDex = DEX.FLUID;
            }
        }

        // Check Curve
        if (dexConfigs[DEX.CURVE].enabled && curvePool != address(0)) {
            uint256 quote = getCurveQuote(amount);
            if (quote > bestQuote) {
                bestQuote = quote;
                bestDex = DEX.CURVE;
            }
        }

        return (bestDex, bestQuote);
    }

    /**
     * @notice Get quote from Uniswap-style DEXs (V3, V4, Fluid)
     * @param dex The DEX to query
     * @param amount Amount of USDT
     * @return quote Expected WETH output
     */
    function getUniswapQuote(DEX dex, uint256 amount) internal returns (uint256 quote) {
        DEXConfig memory config = dexConfigs[dex];
        if (config.quoter == address(0)) return 0;

        try IQuoter(config.quoter)
            .quoteExactInputSingle(
                IQuoter.QuoteExactInputSingleParams({
                    tokenIn: address(usdt),
                    tokenOut: address(weth),
                    amountIn: amount,
                    fee: config.fee,
                    sqrtPriceLimitX96: 0
                })
            ) returns (
            uint256 amountOut, uint160, uint32, uint256
        ) {
            return amountOut;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Get quote from Curve pool
     * @param amount Amount of USDT
     * @return quote Expected ETH output
     */
    function getCurveQuote(uint256 amount) internal view returns (uint256) {
        if (curvePool == address(0)) return 0;

        try ICurvePool(curvePool).get_dy(0, 1, amount) returns (uint256 amountOut) {
            return amountOut;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Execute swap on the selected DEX
     * @param dex The DEX to use
     * @param amountIn Amount of USDT to swap
     * @param minAmountOut Minimum ETH to receive (from quote)
     */
    function executeSwap(DEX dex, uint256 amountIn, uint256 minAmountOut) internal {
        if (dex == DEX.CURVE) {
            executeSwapCurve(amountIn, minAmountOut);
        } else {
            executeSwapUniswap(dex, amountIn, minAmountOut);
        }
    }

    /**
     * @notice Execute swap on Uniswap-style DEX (USDT -> WETH -> ETH)
     * @dev First swaps USDT to WETH via router, then unwraps WETH to native ETH
     */
    function executeSwapUniswap(DEX dex, uint256 amountIn, uint256 minAmountOut) internal {
        DEXConfig memory config = dexConfigs[dex];
        require(config.router != address(0), "Router not configured");

        // Approve router to spend USDT
        usdt.forceApprove(config.router, amountIn);

        // Execute swap: USDT -> WETH using struct params
        uint256 wethReceived = ISwapRouter(config.router)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(usdt),
                    tokenOut: address(weth),
                    fee: config.fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: (minAmountOut * 95) / 100, // 5% slippage tolerance
                    sqrtPriceLimitX96: 0
                })
            );

        // Reset USDT approval
        usdt.forceApprove(config.router, 0);

        require(wethReceived > 0, "No WETH received from swap");

        // Unwrap WETH to native ETH
        weth.withdraw(wethReceived);
    }

    /**
     * @notice Execute swap on Curve (direct USDT -> native ETH)
     */
    function executeSwapCurve(uint256 amountIn, uint256 minAmountOut) internal {
        require(curvePool != address(0), "Curve pool not configured");

        // Approve pool to spend USDT
        usdt.forceApprove(curvePool, amountIn);

        // Execute swap (0 = USDT, 1 = ETH)
        // Curve returns native ETH directly
        ICurvePool(curvePool)
            .exchange(
                0,
                1,
                amountIn,
                (minAmountOut * 95) / 100 // 5% slippage tolerance
            );

        // Reset USDT approval
        usdt.forceApprove(curvePool, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure a DEX
     * @param dex The DEX to configure
     * @param router Router address
     * @param quoter Quoter address
     * @param fee Fee tier (for Uniswap-style DEXs)
     * @param enabled Whether the DEX is enabled
     */
    function configureDEX(DEX dex, address router, address quoter, uint24 fee, bool enabled) external onlyOwner {
        dexConfigs[dex] = DEXConfig({router: router, quoter: quoter, fee: fee, enabled: enabled});

        emit DEXConfigUpdated(dex, router, enabled);
    }

    /**
     * @notice Set Curve pool address
     * @param _curvePool Curve pool address
     */
    function setCurvePool(address _curvePool) external onlyOwner {
        curvePool = _curvePool;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw USDT from contract (owner only)
     * @param recipient Address to receive USDT
     * @param amount Amount of USDT to withdraw
     */
    function withdrawUSDT(address recipient, uint256 amount) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");

        uint256 contractBalance = usdt.balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient USDT balance");

        usdt.safeTransfer(recipient, amount);
        emit USDTWithdrawn(recipient, amount);
    }

    /**
     * @notice Withdraw ETH from contract (owner only)
     * @param recipient Address to receive ETH
     * @param amount Amount of ETH to withdraw
     */
    function withdrawETH(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        (bool success,) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit ETHWithdrawn(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get user's USDT balance
     * @param user Address of the user
     * @return User's USDT balance
     */
    function getUserBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }

    /**
     * @notice Get contract's USDT balance
     * @return Contract's USDT balance
     */
    function getContractUSDTBalance() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    /**
     * @notice Get contract's ETH balance
     * @return Contract's ETH balance
     */
    function getContractETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Get DEX configuration
     * @param dex The DEX to query
     * @return config The DEX configuration
     */
    function getDEXConfig(DEX dex) external view returns (DEXConfig memory config) {
        return dexConfigs[dex];
    }

    /**
     * @notice Get DEX name as string
     * @param dex The DEX enum value
     * @return name The DEX name
     */
    function getDEXName(DEX dex) public pure returns (string memory) {
        if (dex == DEX.UNISWAP_V3) return "Uniswap V3";
        if (dex == DEX.UNISWAP_V4) return "Uniswap V4";
        if (dex == DEX.FLUID) return "Fluid";
        if (dex == DEX.CURVE) return "Curve";
        return "Unknown";
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
}
