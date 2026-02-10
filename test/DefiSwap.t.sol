// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {DefiSwap} from "../src/DefiSwap.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title MockDEXRouter
 * @dev Mock DEX router for testing (Uniswap V3/V4/Fluid style)
 */
contract MockDEXRouter {
    uint256 public exchangeRate;

    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    function exactInputSingle(
        address,
        /* tokenIn */
        address,
        /* tokenOut */
        uint24,
        /* fee */
        address recipient,
        uint256 amountIn,
        uint256,
        /* amountOutMinimum */
        uint160 /* sqrtPriceLimitX96 */
    )
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = (amountIn * exchangeRate) / 1e6;
        (bool success,) = recipient.call{value: amountOut}("");
        require(success, "ETH transfer failed");
        return amountOut;
    }

    function setExchangeRate(uint256 _newRate) external {
        exchangeRate = _newRate;
    }

    receive() external payable {}
}

/**
 * @title MockQuoter
 * @dev Mock quoter for testing DEX quotes
 */
contract MockQuoter {
    uint256 public exchangeRate;

    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    function quoteExactInputSingle(
        address,
        /* tokenIn */
        address,
        /* tokenOut */
        uint24,
        /* fee */
        uint256 amountIn,
        uint160 /* sqrtPriceLimitX96 */
    )
        external
        view
        returns (uint256 amountOut)
    {
        return (amountIn * exchangeRate) / 1e6;
    }

    function setExchangeRate(uint256 _newRate) external {
        exchangeRate = _newRate;
    }
}

/**
 * @title MockCurvePool
 * @dev Mock Curve pool for testing
 */
contract MockCurvePool {
    uint256 public exchangeRate;

    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    function exchange(
        int128,
        /* i */
        int128,
        /* j */
        uint256 dx,
        uint256 /* min_dy */
    )
        external
        payable
        returns (uint256)
    {
        uint256 dy = (dx * exchangeRate) / 1e6;
        (bool success,) = msg.sender.call{value: dy}("");
        require(success, "ETH transfer failed");
        return dy;
    }

    function get_dy(
        int128,
        /* i */
        int128,
        /* j */
        uint256 dx
    )
        external
        view
        returns (uint256)
    {
        return (dx * exchangeRate) / 1e6;
    }

    function setExchangeRate(uint256 _newRate) external {
        exchangeRate = _newRate;
    }

    receive() external payable {}
}

/**
 * @title DefiSwapTest
 * @dev Comprehensive test suite for DefiSwap contract
 */
contract DefiSwapTest is Test {
    DefiSwap public defiSwap;
    ERC20Mock public usdt;
    ERC20Mock public weth;

    MockDEXRouter public uniswapV3Router;
    MockQuoter public uniswapV3Quoter;

    MockDEXRouter public uniswapV4Router;
    MockQuoter public uniswapV4Quoter;

    MockDEXRouter public fluidRouter;
    MockQuoter public fluidQuoter;

    MockCurvePool public curvePool;

    address public owner;
    address public user1;
    address public user2;

    // Constants
    uint256 constant UNISWAP_V3_RATE = 0.0005 ether; // 1 USDT = 0.0005 ETH (2000 USDT/ETH)
    uint256 constant UNISWAP_V4_RATE = 0.00051 ether; // Slightly better rate
    uint256 constant FLUID_RATE = 0.00052 ether; // Even better rate
    uint256 constant CURVE_RATE = 0.00053 ether; // Best rate
    uint256 constant USDT_DECIMALS = 6;
    uint256 constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 constant INITIAL_USDT_BALANCE = 10000 * 10 ** USDT_DECIMALS;

    // Events to test
    event Deposited(address indexed user, uint256 amount);
    event Swapped(uint256 usdtAmount, uint256 ethReceived, DefiSwap.DEX dexUsed, string dexName);
    event USDTWithdrawn(address indexed recipient, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event DEXConfigUpdated(DefiSwap.DEX dex, address router, bool enabled);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock tokens
        usdt = new ERC20Mock();
        weth = new ERC20Mock();

        // Deploy mock DEX routers and quoters
        uniswapV3Router = new MockDEXRouter(UNISWAP_V3_RATE);
        uniswapV3Quoter = new MockQuoter(UNISWAP_V3_RATE);

        uniswapV4Router = new MockDEXRouter(UNISWAP_V4_RATE);
        uniswapV4Quoter = new MockQuoter(UNISWAP_V4_RATE);

        fluidRouter = new MockDEXRouter(FLUID_RATE);
        fluidQuoter = new MockQuoter(FLUID_RATE);

        curvePool = new MockCurvePool(CURVE_RATE);

        // Fund mock DEXs with ETH
        vm.deal(address(uniswapV3Router), INITIAL_ETH_BALANCE);
        vm.deal(address(uniswapV4Router), INITIAL_ETH_BALANCE);
        vm.deal(address(fluidRouter), INITIAL_ETH_BALANCE);
        vm.deal(address(curvePool), INITIAL_ETH_BALANCE);

        // Deploy DefiSwap contract
        defiSwap = new DefiSwap(address(usdt), address(weth));

        // Configure DEXs
        defiSwap.configureDEX(
            DefiSwap.DEX.UNISWAP_V3,
            address(uniswapV3Router),
            address(uniswapV3Quoter),
            3000, // 0.3% fee
            true
        );

        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V4, address(uniswapV4Router), address(uniswapV4Quoter), 3000, true);

        defiSwap.configureDEX(DefiSwap.DEX.FLUID, address(fluidRouter), address(fluidQuoter), 3000, true);

        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, true);

        defiSwap.setCurvePool(address(curvePool));

        // Mint USDT to users
        usdt.mint(user1, INITIAL_USDT_BALANCE);
        usdt.mint(user2, INITIAL_USDT_BALANCE);

        console.log("=== Test Setup Complete ===");
        console.log("DefiSwap deployed at:", address(defiSwap));
        console.log("User1 USDT balance:", usdt.balanceOf(user1));
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(address(defiSwap.usdt()), address(usdt));
        assertEq(defiSwap.weth(), address(weth));
        assertEq(defiSwap.owner(), owner);
        assertEq(defiSwap.totalUSDTDeposited(), 0);
    }

    function test_ConstructorRevertsWithInvalidUSDT() public {
        vm.expectRevert("Invalid USDT address");
        new DefiSwap(address(0), address(weth));
    }

    function test_ConstructorRevertsWithInvalidWETH() public {
        vm.expectRevert("Invalid WETH address");
        new DefiSwap(address(usdt), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositUSDT() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);

        vm.expectEmit(true, false, false, true);
        emit Deposited(user1, depositAmount);

        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        assertEq(defiSwap.getUserBalance(user1), depositAmount);
        assertEq(defiSwap.totalUSDTDeposited(), depositAmount);
        assertEq(usdt.balanceOf(address(defiSwap)), depositAmount);
    }

    function test_DepositUSDTMultipleUsers() public {
        uint256 depositAmount1 = 1000 * 10 ** USDT_DECIMALS;
        uint256 depositAmount2 = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount1);
        defiSwap.depositUSDT(depositAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdt.approve(address(defiSwap), depositAmount2);
        defiSwap.depositUSDT(depositAmount2);
        vm.stopPrank();

        assertEq(defiSwap.getUserBalance(user1), depositAmount1);
        assertEq(defiSwap.getUserBalance(user2), depositAmount2);
        assertEq(defiSwap.totalUSDTDeposited(), depositAmount1 + depositAmount2);
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP TESTS - BEST PRICE SELECTION
    //////////////////////////////////////////////////////////////*/

    function test_SwapSelectsCurveWhenBestPrice() public {
        // Curve has best rate (0.00053 ETH per USDT)
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        (uint256 usdtSwapped, uint256 ethReceived, DefiSwap.DEX dexUsed) = defiSwap.swap();

        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.CURVE), "Should use Curve");
        assertEq(usdtSwapped, depositAmount / 2);

        // Verify ETH received matches Curve's rate
        uint256 expectedETH = (usdtSwapped * CURVE_RATE) / 1e6;
        assertEq(ethReceived, expectedETH);

        console.log("Used DEX:", defiSwap.getDEXName(dexUsed));
        console.log("ETH received:", ethReceived);
    }

    function test_SwapSelectsFluidWhenCurveDisabled() public {
        // Disable Curve
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, false);

        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        (,, DefiSwap.DEX dexUsed) = defiSwap.swap();

        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.FLUID), "Should use Fluid when Curve disabled");
    }

    function test_SwapSelectsUniswapV4WhenFluidAndCurveDisabled() public {
        // Disable Curve and Fluid
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, false);
        defiSwap.configureDEX(DefiSwap.DEX.FLUID, address(0), address(0), 0, false);

        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        (,, DefiSwap.DEX dexUsed) = defiSwap.swap();

        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.UNISWAP_V4), "Should use Uniswap V4");
    }

    function test_SwapDynamicPriceSelection() public {
        uint256 depositAmount = 4000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // First swap - should use Curve (best rate)
        (,, DefiSwap.DEX dex1) = defiSwap.swap();
        assertEq(uint256(dex1), uint256(DefiSwap.DEX.CURVE));

        // Change prices - make Uniswap V3 the best
        curvePool.setExchangeRate(0.0004 ether);
        fluidRouter.setExchangeRate(0.00045 ether);
        fluidQuoter.setExchangeRate(0.00045 ether);
        uniswapV4Router.setExchangeRate(0.00048 ether);
        uniswapV4Quoter.setExchangeRate(0.00048 ether);
        uniswapV3Router.setExchangeRate(0.0006 ether); // Best now!
        uniswapV3Quoter.setExchangeRate(0.0006 ether);

        // Second swap - should use Uniswap V3
        (,, DefiSwap.DEX dex2) = defiSwap.swap();
        assertEq(uint256(dex2), uint256(DefiSwap.DEX.UNISWAP_V3));

        console.log("First swap used:", defiSwap.getDEXName(dex1));
        console.log("Second swap used:", defiSwap.getDEXName(dex2));
    }

    /*//////////////////////////////////////////////////////////////
                        QUOTE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetBestQuote() public {
        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        (DefiSwap.DEX bestDex, uint256 bestQuote) = defiSwap.getBestQuote(amount);

        assertEq(uint256(bestDex), uint256(DefiSwap.DEX.CURVE), "Curve should have best quote");

        uint256 expectedQuote = (amount * CURVE_RATE) / 1e6;
        assertEq(bestQuote, expectedQuote);
    }

    function test_GetBestQuoteWithSomeDEXsDisabled() public {
        // Disable Curve and Fluid
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, false);
        defiSwap.configureDEX(DefiSwap.DEX.FLUID, address(0), address(0), 0, false);

        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        (DefiSwap.DEX bestDex, uint256 bestQuote) = defiSwap.getBestQuote(amount);

        assertEq(uint256(bestDex), uint256(DefiSwap.DEX.UNISWAP_V4), "Uniswap V4 should have best quote");

        uint256 expectedQuote = (amount * UNISWAP_V4_RATE) / 1e6;
        assertEq(bestQuote, expectedQuote);
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ConfigureDEX() public {
        address newRouter = makeAddr("newRouter");
        address newQuoter = makeAddr("newQuoter");

        vm.expectEmit(false, false, false, true);
        emit DEXConfigUpdated(DefiSwap.DEX.UNISWAP_V3, newRouter, true);

        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V3, newRouter, newQuoter, 5000, true);

        DefiSwap.DEXConfig memory config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V3);
        assertEq(config.router, newRouter);
        assertEq(config.quoter, newQuoter);
        assertEq(config.fee, 5000);
        assertTrue(config.enabled);
    }

    function test_ConfigureDEXRevertsWhenNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V3, address(0), address(0), 0, false);
    }

    function test_SetCurvePool() public {
        address newPool = makeAddr("newCurvePool");
        defiSwap.setCurvePool(newPool);
        assertEq(defiSwap.curvePool(), newPool);
    }

    /*//////////////////////////////////////////////////////////////
                        ERROR CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapRevertsWhenNoUSDT() public {
        vm.expectRevert("No USDT to swap");
        defiSwap.swap();
    }

    function test_SwapRevertsWhenNotOwner() public {
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), 1000 * 10 ** USDT_DECIMALS);
        defiSwap.depositUSDT(1000 * 10 ** USDT_DECIMALS);

        vm.expectRevert();
        defiSwap.swap();
        vm.stopPrank();
    }

    function test_SwapRevertsWhenAmountTooSmall() public {
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), 1);
        defiSwap.depositUSDT(1);
        vm.stopPrank();

        vm.expectRevert("Swap amount too small");
        defiSwap.swap();
    }

    function test_SwapRevertsWhenNoValidQuotes() public {
        // Disable all DEXs
        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V3, address(0), address(0), 0, false);
        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V4, address(0), address(0), 0, false);
        defiSwap.configureDEX(DefiSwap.DEX.FLUID, address(0), address(0), 0, false);
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, false);

        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        vm.expectRevert("No valid quotes found");
        defiSwap.swap();
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUSDT() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        uint256 withdrawAmount = 500 * 10 ** USDT_DECIMALS;
        defiSwap.withdrawUSDT(user2, withdrawAmount);

        assertEq(usdt.balanceOf(user2), INITIAL_USDT_BALANCE + withdrawAmount);
    }

    function test_WithdrawETH() public {
        // First do a swap to get ETH
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        defiSwap.swap();

        uint256 withdrawAmount = 0.1 ether;
        uint256 balanceBefore = user2.balance;

        defiSwap.withdrawETH(payable(user2), withdrawAmount);

        assertEq(user2.balance, balanceBefore + withdrawAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetDEXName() public view {
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.UNISWAP_V3), "Uniswap V3");
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.UNISWAP_V4), "Uniswap V4");
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.FLUID), "Fluid");
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.CURVE), "Curve");
    }

    function test_GetDEXConfig() public view {
        DefiSwap.DEXConfig memory config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V3);
        assertEq(config.router, address(uniswapV3Router));
        assertEq(config.quoter, address(uniswapV3Quoter));
        assertEq(config.fee, 3000);
        assertTrue(config.enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullWorkflow() public {
        console.log("\n=== Full Workflow Test ===");

        // 1. User deposits USDT
        uint256 depositAmount = 4000 * 10 ** USDT_DECIMALS;
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();
        console.log("1. User deposited:", depositAmount / 10 ** USDT_DECIMALS, "USDT");

        // 2. Owner swaps 50% (automatically selects best DEX)
        (uint256 usdtSwapped, uint256 ethReceived, DefiSwap.DEX dexUsed) = defiSwap.swap();
        console.log("2. Swapped:", usdtSwapped / 10 ** USDT_DECIMALS, "USDT");
        console.log("   Received:", ethReceived, "wei ETH");
        console.log("   Used DEX:", defiSwap.getDEXName(dexUsed));

        // 3. Verify state
        assertEq(defiSwap.getUserBalance(user1), depositAmount);
        assertEq(defiSwap.getContractETHBalance(), ethReceived);
        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.CURVE)); // Should use Curve (best rate)

        // 4. Owner withdraws
        uint256 withdrawAmount = 1000 * 10 ** USDT_DECIMALS;
        defiSwap.withdrawUSDT(owner, withdrawAmount);
        console.log("4. Owner withdrew:", withdrawAmount / 10 ** USDT_DECIMALS, "USDT");
    }

    function test_MultipleSwapsWithChangingPrices() public {
        uint256 depositAmount = 8000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // First swap
        (,, DefiSwap.DEX dex1) = defiSwap.swap();
        console.log("First swap used:", defiSwap.getDEXName(dex1));

        // Change market conditions - make Uniswap V3 best
        uniswapV3Router.setExchangeRate(0.0007 ether);
        uniswapV3Quoter.setExchangeRate(0.0007 ether);

        // Second swap
        (,, DefiSwap.DEX dex2) = defiSwap.swap();
        console.log("Second swap used:", defiSwap.getDEXName(dex2));

        assertEq(uint256(dex1), uint256(DefiSwap.DEX.CURVE));
        assertEq(uint256(dex2), uint256(DefiSwap.DEX.UNISWAP_V3));
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositUSDT(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_USDT_BALANCE);

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), amount);
        defiSwap.depositUSDT(amount);
        vm.stopPrank();

        assertEq(defiSwap.getUserBalance(user1), amount);
        assertEq(defiSwap.totalUSDTDeposited(), amount);
    }

    function testFuzz_SwapAlwaysSelectsBestPrice(uint256 v3Rate, uint256 v4Rate, uint256 fluidRate, uint256 curveRate)
        public
    {
        // Bound rates to reasonable range
        v3Rate = bound(v3Rate, 0.0001 ether, 0.001 ether);
        v4Rate = bound(v4Rate, 0.0001 ether, 0.001 ether);
        fluidRate = bound(fluidRate, 0.0001 ether, 0.001 ether);
        curveRate = bound(curveRate, 0.0001 ether, 0.001 ether);

        // Set rates
        uniswapV3Router.setExchangeRate(v3Rate);
        uniswapV3Quoter.setExchangeRate(v3Rate);
        uniswapV4Router.setExchangeRate(v4Rate);
        uniswapV4Quoter.setExchangeRate(v4Rate);
        fluidRouter.setExchangeRate(fluidRate);
        fluidQuoter.setExchangeRate(fluidRate);
        curvePool.setExchangeRate(curveRate);

        // Determine best rate
        uint256 bestRate = v3Rate;
        if (v4Rate > bestRate) bestRate = v4Rate;
        if (fluidRate > bestRate) bestRate = fluidRate;
        if (curveRate > bestRate) bestRate = curveRate;

        // Deposit and swap
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        (, uint256 ethReceived,) = defiSwap.swap();

        // Verify we got the best rate (within rounding)
        uint256 expectedETH = ((depositAmount / 2) * bestRate) / 1e6;
        uint256 minExpected = (expectedETH * 95) / 100; // Allow 5% slippage

        assertGe(ethReceived, minExpected, "Should receive at least best rate minus slippage");
    }
}
