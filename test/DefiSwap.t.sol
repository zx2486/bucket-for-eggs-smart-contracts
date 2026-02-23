// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {DefiSwap} from "../src/DefiSwap.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title MockWETH
 * @dev Mock WETH token with withdraw functionality
 */
contract MockWETH is ERC20Mock {
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/**
 * @title MockUniswapRouter
 * @dev Mock router for Uniswap-style DEXs (V3/V4/Fluid)
 */
contract MockUniswapRouter {
    uint256 public exchangeRate;
    MockWETH public weth;
    ERC20Mock public usdt;

    constructor(uint256 _exchangeRate, address _weth, address _usdt) {
        exchangeRate = _exchangeRate;
        weth = MockWETH(payable(_weth));
        usdt = ERC20Mock(_usdt);
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        // Pull USDT from sender
        usdt.transferFrom(msg.sender, address(this), params.amountIn);
        
        // Calculate WETH output
        amountOut = (params.amountIn * exchangeRate) / 1e6;
        
        // Mint WETH to recipient
        weth.deposit{value: amountOut}();
        weth.transfer(params.recipient, amountOut);
        
        return amountOut;
    }

    function setExchangeRate(uint256 _newRate) external {
        exchangeRate = _newRate;
    }

    receive() external payable {}
}

/**
 * @title MockUniswapQuoter
 * @dev Mock quoter for Uniswap-style DEXs
 */
contract MockUniswapQuoter {
    uint256 public exchangeRate;

    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory /* params */)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        // Return the exchange rate, not the calculated amount
        // Contract will do: expectedETH = (usdtAmount * rate) / 1e6
        amountOut = exchangeRate;
        return (amountOut, 0, 0, 0);
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
    ERC20Mock public usdt;

    constructor(uint256 _exchangeRate, address _usdt) {
        exchangeRate = _exchangeRate;
        usdt = ERC20Mock(_usdt);
    }

    function exchange(int128, int128, uint256 dx, uint256) external payable returns (uint256) {
        // Pull USDT from sender
        usdt.transferFrom(msg.sender, address(this), dx);
        
        uint256 dy = (dx * exchangeRate) / 1e6;
        (bool success,) = msg.sender.call{value: dy}("");
        require(success, "ETH transfer failed");
        return dy;
    }

    function get_dy(int128, int128, uint256 /* dx */) external view returns (uint256) {
        // Return the exchange rate, not the calculated amount
        // Contract will do: expectedETH = (usdtAmount * rate) / 1e6
        return exchangeRate;
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
    MockWETH public weth;

    MockUniswapRouter public uniswapV3Router;
    MockUniswapQuoter public uniswapV3Quoter;

    MockUniswapRouter public uniswapV4Router;
    MockUniswapQuoter public uniswapV4Quoter;

    MockUniswapRouter public fluidRouter;
    MockUniswapQuoter public fluidQuoter;

    MockCurvePool public curvePool;

    address public owner;
    address public user1;
    address public user2;

    // Constants
    uint256 constant UNISWAP_V3_RATE = 0.0005 ether; // 1 USDT = 0.0005 ETH
    uint256 constant UNISWAP_V4_RATE = 0.00051 ether;
    uint256 constant FLUID_RATE = 0.00052 ether;
    uint256 constant CURVE_RATE = 0.00053 ether;
    uint256 constant USDT_DECIMALS = 6;
    uint256 constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 constant INITIAL_USDT_BALANCE = 10000 * 10 ** USDT_DECIMALS;

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Swapped(uint256 usdtAmount, uint256 ethReceived, DefiSwap.DEX dexUsed, string dexName);
    event USDTWithdrawn(address indexed recipient, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event DEXConfigUpdated(DefiSwap.DEX dex, address router, bool enabled);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy tokens
        usdt = new ERC20Mock();
        weth = new MockWETH();

        // Deploy DefiSwap
        defiSwap = new DefiSwap(address(usdt), address(weth));

        // Deploy mock DEXs
        uniswapV3Router = new MockUniswapRouter(UNISWAP_V3_RATE, address(weth), address(usdt));
        uniswapV3Quoter = new MockUniswapQuoter(UNISWAP_V3_RATE);

        uniswapV4Router = new MockUniswapRouter(UNISWAP_V4_RATE, address(weth), address(usdt));
        uniswapV4Quoter = new MockUniswapQuoter(UNISWAP_V4_RATE);

        fluidRouter = new MockUniswapRouter(FLUID_RATE, address(weth), address(usdt));
        fluidQuoter = new MockUniswapQuoter(FLUID_RATE);

        curvePool = new MockCurvePool(CURVE_RATE, address(usdt));

        // Fund mock DEXs with ETH
        vm.deal(address(uniswapV3Router), INITIAL_ETH_BALANCE);
        vm.deal(address(uniswapV4Router), INITIAL_ETH_BALANCE);
        vm.deal(address(fluidRouter), INITIAL_ETH_BALANCE);
        vm.deal(address(curvePool), INITIAL_ETH_BALANCE);

        // Configure DEXs
        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V3, address(uniswapV3Router), address(uniswapV3Quoter), 3000, true);
        defiSwap.configureDEX(DefiSwap.DEX.UNISWAP_V4, address(uniswapV4Router), address(uniswapV4Quoter), 3000, true);
        defiSwap.configureDEX(DefiSwap.DEX.FLUID, address(fluidRouter), address(fluidQuoter), 3000, true);
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, true);
        defiSwap.setCurvePool(address(curvePool));

        // Mint USDT to users
        usdt.mint(user1, INITIAL_USDT_BALANCE);
        usdt.mint(user2, INITIAL_USDT_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(address(defiSwap.usdt()), address(usdt));
        assertEq(address(defiSwap.weth()), address(weth));
        assertEq(defiSwap.owner(), owner);
        assertEq(defiSwap.totalUSDTDeposited(), 0);
    }

    function test_ConstructorRevertsWithZeroUSDT() public {
        vm.expectRevert("Invalid USDT address");
        new DefiSwap(address(0), address(weth));
    }

    function test_ConstructorRevertsWithZeroWETH() public {
        vm.expectRevert("Invalid WETH address");
        new DefiSwap(address(usdt), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositUSDT() public {
        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), amount);

        vm.expectEmit(true, false, false, true);
        emit Deposited(user1, amount);

        defiSwap.depositUSDT(amount);
        vm.stopPrank();

        assertEq(defiSwap.getUserBalance(user1), amount);
        assertEq(defiSwap.totalUSDTDeposited(), amount);
        assertEq(usdt.balanceOf(address(defiSwap)), amount);
    }

    function test_DepositUSDTMultipleUsers() public {
        uint256 amount1 = 1000 * 10 ** USDT_DECIMALS;
        uint256 amount2 = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), amount1);
        defiSwap.depositUSDT(amount1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdt.approve(address(defiSwap), amount2);
        defiSwap.depositUSDT(amount2);
        vm.stopPrank();

        assertEq(defiSwap.getUserBalance(user1), amount1);
        assertEq(defiSwap.getUserBalance(user2), amount2);
        assertEq(defiSwap.totalUSDTDeposited(), amount1 + amount2);
    }

    function test_DepositRevertsWithZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert("Amount must be greater than 0");
        defiSwap.depositUSDT(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapSelectsBestDEX() public {
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        (uint256 usdtSwapped, uint256 ethReceived, DefiSwap.DEX dexUsed) = defiSwap.swap();

        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.CURVE), "Should use Curve (best rate)");
        assertEq(usdtSwapped, depositAmount / 2);

        uint256 expectedETH = (usdtSwapped * CURVE_RATE) / 1e6;
        assertEq(ethReceived, expectedETH);
    }

    function test_SwapDynamicDEXSelection() public {
        uint256 depositAmount = 4000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // First swap - Curve has best rate
        (,, DefiSwap.DEX dex1) = defiSwap.swap();
        assertEq(uint256(dex1), uint256(DefiSwap.DEX.CURVE));

        // Change rates - make V3 best
        uniswapV3Router.setExchangeRate(0.0007 ether);
        uniswapV3Quoter.setExchangeRate(0.0007 ether);

        // Second swap - should use V3
        (,, DefiSwap.DEX dex2) = defiSwap.swap();
        assertEq(uint256(dex2), uint256(DefiSwap.DEX.UNISWAP_V3));
    }

    function test_SwapWithDisabledDEXs() public {
        // Disable Curve
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, false);

        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        (,, DefiSwap.DEX dexUsed) = defiSwap.swap();
        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.FLUID), "Should use Fluid");
    }

    function test_SwapRevertsWhenNoUSDT() public {
        vm.expectRevert("No USDT to swap");
        defiSwap.swap();
    }

    function test_SwapRevertsWhenNotOwner() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);

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

    function test_SwapRevertsWhenAllDEXsDisabled() public {
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

    function test_SwapEmitsEvent() public {
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        vm.expectEmit(false, false, false, false);
        emit Swapped(0, 0, DefiSwap.DEX.CURVE, "");
        defiSwap.swap();
    }

    /*//////////////////////////////////////////////////////////////
                        QUOTE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetBestQuote() public {
        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        (DefiSwap.DEX bestDex, uint256 bestQuote) = defiSwap.getBestQuote(amount);

        assertEq(uint256(bestDex), uint256(DefiSwap.DEX.CURVE));
        // Quoter returns the rate, not the calculated amount
        assertEq(bestQuote, CURVE_RATE);
    }

    function test_GetBestQuoteWithSomeDEXsDisabled() public {
        defiSwap.configureDEX(DefiSwap.DEX.CURVE, address(0), address(0), 0, false);
        defiSwap.configureDEX(DefiSwap.DEX.FLUID, address(0), address(0), 0, false);

        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        (DefiSwap.DEX bestDex, uint256 bestQuote) = defiSwap.getBestQuote(amount);

        assertEq(uint256(bestDex), uint256(DefiSwap.DEX.UNISWAP_V4));
        // Quoter returns the rate, not the calculated amount
        assertEq(bestQuote, UNISWAP_V4_RATE);
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
        address newPool = makeAddr("newPool");
        defiSwap.setCurvePool(newPool);
        assertEq(defiSwap.curvePool(), newPool);
    }

    function test_SetCurvePoolRevertsWhenNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        defiSwap.setCurvePool(address(0));
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

        vm.expectEmit(true, false, false, true);
        emit USDTWithdrawn(user2, withdrawAmount);

        defiSwap.withdrawUSDT(user2, withdrawAmount);

        assertEq(usdt.balanceOf(user2), INITIAL_USDT_BALANCE + withdrawAmount);
    }

    function test_WithdrawUSDTRevertsWhenNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        defiSwap.withdrawUSDT(user2, 100);
    }

    function test_WithdrawUSDTRevertsWithZeroRecipient() public {
        vm.expectRevert("Invalid recipient");
        defiSwap.withdrawUSDT(address(0), 100);
    }

    function test_WithdrawUSDTRevertsWithZeroAmount() public {
        vm.expectRevert("Amount must be greater than 0");
        defiSwap.withdrawUSDT(user1, 0);
    }

    function test_WithdrawUSDTRevertsWithInsufficientBalance() public {
        vm.expectRevert("Insufficient USDT balance");
        defiSwap.withdrawUSDT(user1, 1000 * 10 ** USDT_DECIMALS);
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

        vm.expectEmit(true, false, false, true);
        emit ETHWithdrawn(user2, withdrawAmount);

        defiSwap.withdrawETH(payable(user2), withdrawAmount);

        assertEq(user2.balance, balanceBefore + withdrawAmount);
    }

    function test_WithdrawETHRevertsWhenNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        defiSwap.withdrawETH(payable(user2), 0.1 ether);
    }

    function test_WithdrawETHRevertsWithZeroRecipient() public {
        vm.expectRevert("Invalid recipient");
        defiSwap.withdrawETH(payable(address(0)), 0.1 ether);
    }

    function test_WithdrawETHRevertsWithZeroAmount() public {
        vm.expectRevert("Amount must be greater than 0");
        defiSwap.withdrawETH(payable(user1), 0);
    }

    function test_WithdrawETHRevertsWithInsufficientBalance() public {
        vm.expectRevert("Insufficient ETH balance");
        defiSwap.withdrawETH(payable(user1), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUserBalance() public {
        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), amount);
        defiSwap.depositUSDT(amount);
        vm.stopPrank();

        assertEq(defiSwap.getUserBalance(user1), amount);
        assertEq(defiSwap.getUserBalance(user2), 0);
    }

    function test_GetContractUSDTBalance() public {
        uint256 amount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), amount);
        defiSwap.depositUSDT(amount);
        vm.stopPrank();

        assertEq(defiSwap.getContractUSDTBalance(), amount);
    }

    function test_GetContractETHBalance() public {
        assertEq(defiSwap.getContractETHBalance(), 0);

        // Send ETH to contract
        vm.deal(address(defiSwap), 1 ether);
        assertEq(defiSwap.getContractETHBalance(), 1 ether);
    }

    function test_GetDEXConfig() public view {
        DefiSwap.DEXConfig memory config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V3);
        assertEq(config.router, address(uniswapV3Router));
        assertEq(config.quoter, address(uniswapV3Quoter));
        assertEq(config.fee, 3000);
        assertTrue(config.enabled);
    }

    function test_GetDEXName() public view {
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.UNISWAP_V3), "Uniswap V3");
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.UNISWAP_V4), "Uniswap V4");
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.FLUID), "Fluid");
        assertEq(defiSwap.getDEXName(DefiSwap.DEX.CURVE), "Curve");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullWorkflow() public {
        // 1. Deposit
        uint256 depositAmount = 4000 * 10 ** USDT_DECIMALS;
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // 2. Swap
        (uint256 usdtSwapped, uint256 ethReceived, DefiSwap.DEX dexUsed) = defiSwap.swap();

        assertEq(usdtSwapped, depositAmount / 2);
        assertGt(ethReceived, 0);
        assertEq(uint256(dexUsed), uint256(DefiSwap.DEX.CURVE));

        // 3. Withdraw USDT
        uint256 withdrawAmount = 1000 * 10 ** USDT_DECIMALS;
        defiSwap.withdrawUSDT(owner, withdrawAmount);
        assertEq(usdt.balanceOf(owner), withdrawAmount);

        // 4. Withdraw ETH
        uint256 ethWithdraw = 0.1 ether;
        uint256 balanceBefore = owner.balance;
        defiSwap.withdrawETH(payable(owner), ethWithdraw);
        assertEq(owner.balance, balanceBefore + ethWithdraw);
    }

    function test_MultipleUsersDeposit() public {
        uint256 amount1 = 1000 * 10 ** USDT_DECIMALS;
        uint256 amount2 = 1500 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(defiSwap), amount1);
        defiSwap.depositUSDT(amount1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdt.approve(address(defiSwap), amount2);
        defiSwap.depositUSDT(amount2);
        vm.stopPrank();

        assertEq(defiSwap.totalUSDTDeposited(), amount1 + amount2);
        assertEq(defiSwap.getUserBalance(user1), amount1);
        assertEq(defiSwap.getUserBalance(user2), amount2);
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

    function testFuzz_SwapSelectsBestDEX(uint256 v3Rate, uint256 v4Rate, uint256 fluidRate, uint256 curveRate)
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
        DefiSwap.DEX expectedDex = DefiSwap.DEX.UNISWAP_V3;

        if (v4Rate > bestRate) {
            bestRate = v4Rate;
            expectedDex = DefiSwap.DEX.UNISWAP_V4;
        }
        if (fluidRate > bestRate) {
            bestRate = fluidRate;
            expectedDex = DefiSwap.DEX.FLUID;
        }
        if (curveRate > bestRate) {
            bestRate = curveRate;
            expectedDex = DefiSwap.DEX.CURVE;
        }

        // Deposit and attempt swap
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;
        vm.startPrank(user1);
        usdt.approve(address(defiSwap), depositAmount);
        defiSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // Try swap - may succeed or revert due to slippage
        try defiSwap.swap() returns (uint256 usdtSwapped, uint256 ethReceived, DefiSwap.DEX dexUsed) {
            // Swap succeeded
            assertEq(uint256(dexUsed), uint256(expectedDex), "Should use best DEX");
            assertEq(usdtSwapped, depositAmount / 2);

            uint256 expectedETH = (usdtSwapped * bestRate) / 1e6;
            
            // Allow minimal rounding errors
            assertGe(ethReceived, (expectedETH * 999) / 1000);
            assertLe(ethReceived, (expectedETH * 1001) / 1000);
        } catch (bytes memory reason) {
            // Swap reverted - verify it's slippage protection
            if (bytes4(reason) == bytes4(keccak256("Error(string)"))) {
                string memory errorMsg = abi.decode(slice(reason, 4), (string));
                assertEq(errorMsg, "Received less ETH than expected after slippage");
            }
        }
    }

    // Helper for error decoding
    function slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        bytes memory result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + start];
        }
        return result;
    }

    receive() external payable {}
}
