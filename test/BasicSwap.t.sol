// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {BasicSwap} from "../src/BasicSwap.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title Mock1inchRouter
 * @dev Mock 1inch router for testing swap functionality
 */
contract Mock1inchRouter {
    uint256 public exchangeRate; // How much ETH to return per USDT (scaled by 1e18)

    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    /**
     * @notice Mock swap function that simulates 1inch swap
     * @dev Accepts USDT and returns ETH based on exchange rate
     */
    function swap(
        address,
        /* executor */
        address,
        /* srcToken */
        uint256 amount,
        address,
        /* dstToken */
        address,
        /* dstReceiver */
        uint256 /* minReturnAmount */
    )
        external
        payable
        returns (uint256)
    {
        // Calculate ETH to return based on USDT amount and rate
        // USDT has 6 decimals, ETH has 18 decimals
        uint256 ethToReturn = (amount * exchangeRate) / 1e6;

        // Transfer ETH to caller (the BasicSwap contract)
        (bool success,) = msg.sender.call{value: ethToReturn}("");
        require(success, "ETH transfer failed");

        return ethToReturn;
    }

    /**
     * @notice Update exchange rate for testing
     */
    function setExchangeRate(uint256 _newRate) external {
        exchangeRate = _newRate;
    }

    /**
     * @notice Allow router to receive ETH
     */
    receive() external payable {}
}

/**
 * @title BasicSwapTest
 * @dev Comprehensive test suite for BasicSwap contract with 1inch integration
 */
contract BasicSwapTest is Test {
    BasicSwap public basicSwap;
    ERC20Mock public usdt;
    Mock1inchRouter public oneInchRouter;

    address public owner;
    address public user1;
    address public user2;

    // Constants
    uint256 constant INITIAL_EXCHANGE_RATE = 0.0005 ether; // 1 USDT = 0.0005 ETH (2000 USDT per ETH)
    uint256 constant USDT_DECIMALS = 6;
    uint256 constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 constant INITIAL_USDT_BALANCE = 10000 * 10 ** USDT_DECIMALS; // 10,000 USDT

    // Events to test
    event Deposited(address indexed user, uint256 amount);
    event Swapped(uint256 usdtAmount, uint256 ethReceived);
    event USDTWithdrawn(address indexed recipient, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event OneInchRouterUpdated(address indexed newRouter);

    function setUp() public {
        // Setup accounts
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock USDT token
        usdt = new ERC20Mock();

        // Deploy mock 1inch router with initial exchange rate
        oneInchRouter = new Mock1inchRouter(INITIAL_EXCHANGE_RATE);

        // Fund mock router with ETH
        vm.deal(address(oneInchRouter), INITIAL_ETH_BALANCE);

        // Deploy BasicSwap contract
        basicSwap = new BasicSwap(address(usdt), address(oneInchRouter));

        // Mint USDT to users
        usdt.mint(user1, INITIAL_USDT_BALANCE);
        usdt.mint(user2, INITIAL_USDT_BALANCE);

        // Log initial state
        console.log("=== Test Setup Complete ===");
        console.log("BasicSwap deployed at:", address(basicSwap));
        console.log("Mock USDT deployed at:", address(usdt));
        console.log("Mock 1inch router deployed at:", address(oneInchRouter));
        console.log("Router ETH balance:", address(oneInchRouter).balance);
        console.log("User1 USDT balance:", usdt.balanceOf(user1));
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(address(basicSwap.usdt()), address(usdt));
        assertEq(basicSwap.oneInchRouter(), address(oneInchRouter));
        assertEq(basicSwap.owner(), owner);
        assertEq(basicSwap.totalUSDTDeposited(), 0);
    }

    function test_ConstructorRevertsWithInvalidUSDT() public {
        vm.expectRevert("Invalid USDT address");
        new BasicSwap(address(0), address(oneInchRouter));
    }

    function test_ConstructorRevertsWithInvalidRouter() public {
        vm.expectRevert("Invalid 1inch router address");
        new BasicSwap(address(usdt), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositUSDT() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS; // 1000 USDT

        vm.startPrank(user1);

        // Approve BasicSwap to spend USDT
        usdt.approve(address(basicSwap), depositAmount);

        // Expect Deposited event
        vm.expectEmit(true, false, false, true);
        emit Deposited(user1, depositAmount);

        // Deposit USDT
        basicSwap.depositUSDT(depositAmount);

        vm.stopPrank();

        // Verify balances
        assertEq(basicSwap.getUserBalance(user1), depositAmount);
        assertEq(basicSwap.totalUSDTDeposited(), depositAmount);
        assertEq(usdt.balanceOf(address(basicSwap)), depositAmount);
        assertEq(usdt.balanceOf(user1), INITIAL_USDT_BALANCE - depositAmount);
    }

    function test_DepositUSDTMultipleUsers() public {
        uint256 depositAmount1 = 1000 * 10 ** USDT_DECIMALS;
        uint256 depositAmount2 = 2000 * 10 ** USDT_DECIMALS;

        // User1 deposits
        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount1);
        basicSwap.depositUSDT(depositAmount1);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        usdt.approve(address(basicSwap), depositAmount2);
        basicSwap.depositUSDT(depositAmount2);
        vm.stopPrank();

        // Verify individual balances
        assertEq(basicSwap.getUserBalance(user1), depositAmount1);
        assertEq(basicSwap.getUserBalance(user2), depositAmount2);

        // Verify total
        assertEq(basicSwap.totalUSDTDeposited(), depositAmount1 + depositAmount2);
        assertEq(usdt.balanceOf(address(basicSwap)), depositAmount1 + depositAmount2);
    }

    function test_DepositUSDTRevertsWithZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert("Amount must be greater than 0");
        basicSwap.depositUSDT(0);

        vm.stopPrank();
    }

    function test_DepositUSDTRevertsWithoutApproval() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);

        // Don't approve - should revert
        vm.expectRevert();
        basicSwap.depositUSDT(depositAmount);

        vm.stopPrank();
    }

    function test_DepositUSDTRevertsWithInsufficientBalance() public {
        uint256 depositAmount = INITIAL_USDT_BALANCE + 1;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);

        vm.expectRevert();
        basicSwap.depositUSDT(depositAmount);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapWith1inch() public {
        // Setup: User1 deposits 2000 USDT
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // Calculate expected values
        uint256 expectedUSDTSwapped = depositAmount / 2; // 50% = 1000 USDT
        uint256 expectedETHReceived = (expectedUSDTSwapped * INITIAL_EXCHANGE_RATE) / (10 ** USDT_DECIMALS);

        // Build 1inch swap calldata
        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0), // executor (not used in mock)
            address(usdt), // srcToken
            expectedUSDTSwapped, // amount
            address(0), // dstToken (ETH)
            address(basicSwap), // dstReceiver
            0 // minReturnAmount
        );

        // Approve router to spend USDT (this happens inside swap function)
        // The contract will approve the router

        // Expect Swapped event
        vm.expectEmit(false, false, false, true);
        emit Swapped(expectedUSDTSwapped, expectedETHReceived);

        // Execute swap as owner
        (uint256 usdtSwapped, uint256 ethReceived) = basicSwap.swap(swapCalldata);

        // Verify returned values
        assertEq(usdtSwapped, expectedUSDTSwapped);
        assertEq(ethReceived, expectedETHReceived);

        // Verify contract received ETH
        assertEq(address(basicSwap).balance, expectedETHReceived);

        console.log("USDT swapped:", usdtSwapped);
        console.log("ETH received:", ethReceived);
    }

    function test_SwapWithLargeAmount() public {
        // Deposit 10000 USDT
        uint256 depositAmount = 10000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        uint256 contractBalanceBefore = usdt.balanceOf(address(basicSwap));
        uint256 expectedUSDTSwapped = depositAmount / 2;

        // Build swap calldata
        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            expectedUSDTSwapped,
            address(0),
            address(basicSwap),
            0
        );

        // Execute swap
        (uint256 usdtSwapped, uint256 ethReceived) = basicSwap.swap(swapCalldata);

        // Verify 50% was swapped
        assertEq(usdtSwapped, depositAmount / 2);
        assertEq(usdtSwapped, contractBalanceBefore / 2);

        // Verify ETH received
        uint256 expectedETH = (usdtSwapped * INITIAL_EXCHANGE_RATE) / (10 ** USDT_DECIMALS);
        assertEq(ethReceived, expectedETH);
    }

    function test_SwapRevertsWhenNotOwner() public {
        // Setup: deposit some USDT
        vm.startPrank(user1);
        usdt.approve(address(basicSwap), 1000 * 10 ** USDT_DECIMALS);
        basicSwap.depositUSDT(1000 * 10 ** USDT_DECIMALS);
        vm.stopPrank();

        // Build swap calldata
        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            500 * 10 ** USDT_DECIMALS,
            address(0),
            address(basicSwap),
            0
        );

        // Try to swap as non-owner
        vm.prank(user1);
        vm.expectRevert();
        basicSwap.swap(swapCalldata);
    }

    function test_SwapRevertsWithNoUSDT() public {
        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            100,
            address(0),
            address(basicSwap),
            0
        );

        // Try to swap with no USDT in contract
        vm.expectRevert("No USDT to swap");
        basicSwap.swap(swapCalldata);
    }

    function test_SwapRevertsWithVerySmallAmount() public {
        // Deposit only 1 unit of USDT (smallest amount)
        vm.startPrank(user1);
        usdt.approve(address(basicSwap), 1);
        basicSwap.depositUSDT(1);
        vm.stopPrank();

        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            0,
            address(0),
            address(basicSwap),
            0
        );

        // 50% of 1 = 0, should revert
        vm.expectRevert("Swap amount too small");
        basicSwap.swap(swapCalldata);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetOneInchRouter() public {
        address newRouter = makeAddr("newRouter");

        vm.expectEmit(true, false, false, false);
        emit OneInchRouterUpdated(newRouter);

        basicSwap.setOneInchRouter(newRouter);

        assertEq(basicSwap.oneInchRouter(), newRouter);
    }

    function test_SetOneInchRouterRevertsWhenNotOwner() public {
        address newRouter = makeAddr("newRouter");

        vm.prank(user1);
        vm.expectRevert();
        basicSwap.setOneInchRouter(newRouter);
    }

    function test_SetOneInchRouterRevertsWithZeroAddress() public {
        vm.expectRevert("Invalid router address");
        basicSwap.setOneInchRouter(address(0));
    }

    function test_WithdrawUSDT() public {
        // Setup: deposit USDT
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        uint256 withdrawAmount = 500 * 10 ** USDT_DECIMALS;

        vm.expectEmit(true, false, false, true);
        emit USDTWithdrawn(user2, withdrawAmount);

        basicSwap.withdrawUSDT(user2, withdrawAmount);

        assertEq(usdt.balanceOf(user2), INITIAL_USDT_BALANCE + withdrawAmount);
    }

    function test_WithdrawUSDTRevertsWhenNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        basicSwap.withdrawUSDT(user2, 100 * 10 ** USDT_DECIMALS);
    }

    function test_WithdrawUSDTRevertsWithInvalidRecipient() public {
        vm.expectRevert("Invalid recipient");
        basicSwap.withdrawUSDT(address(0), 100 * 10 ** USDT_DECIMALS);
    }

    function test_WithdrawUSDTRevertsWithZeroAmount() public {
        vm.expectRevert("Amount must be greater than 0");
        basicSwap.withdrawUSDT(user1, 0);
    }

    function test_WithdrawUSDTRevertsWithInsufficientBalance() public {
        vm.expectRevert("Insufficient USDT balance");
        basicSwap.withdrawUSDT(user1, 1000 * 10 ** USDT_DECIMALS);
    }

    function test_WithdrawETH() public {
        // First do a swap to get ETH in the contract
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            depositAmount / 2,
            address(0),
            address(basicSwap),
            0
        );

        basicSwap.swap(swapCalldata);

        // Now withdraw ETH
        uint256 withdrawAmount = 0.1 ether;
        uint256 balanceBefore = user2.balance;

        vm.expectEmit(true, false, false, true);
        emit ETHWithdrawn(user2, withdrawAmount);

        basicSwap.withdrawETH(payable(user2), withdrawAmount);

        assertEq(user2.balance, balanceBefore + withdrawAmount);
    }

    function test_WithdrawETHRevertsWhenNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        basicSwap.withdrawETH(payable(user2), 1 ether);
    }

    function test_WithdrawETHRevertsWithInvalidRecipient() public {
        vm.expectRevert("Invalid recipient");
        basicSwap.withdrawETH(payable(address(0)), 1 ether);
    }

    function test_WithdrawETHRevertsWithZeroAmount() public {
        vm.expectRevert("Amount must be greater than 0");
        basicSwap.withdrawETH(payable(user1), 0);
    }

    function test_WithdrawETHRevertsWithInsufficientBalance() public {
        vm.expectRevert("Insufficient ETH balance");
        basicSwap.withdrawETH(payable(user1), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUserBalance() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        assertEq(basicSwap.getUserBalance(user1), depositAmount);
        assertEq(basicSwap.getUserBalance(user2), 0);
    }

    function test_GetContractUSDTBalance() public {
        uint256 depositAmount = 1000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        assertEq(basicSwap.getContractUSDTBalance(), depositAmount);
    }

    function test_GetContractETHBalance() public {
        // Deposit and swap to get ETH
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            depositAmount / 2,
            address(0),
            address(basicSwap),
            0
        );

        (, uint256 ethReceived) = basicSwap.swap(swapCalldata);

        assertEq(basicSwap.getContractETHBalance(), ethReceived);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH() public {
        uint256 sendAmount = 10 ether;
        uint256 balanceBefore = address(basicSwap).balance;

        // Send ETH to contract
        (bool success,) = address(basicSwap).call{value: sendAmount}("");
        assertTrue(success);

        assertEq(address(basicSwap).balance, balanceBefore + sendAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullWorkflow() public {
        console.log("\n=== Full Workflow Test ===");

        // 1. User deposits USDT
        uint256 depositAmount = 4000 * 10 ** USDT_DECIMALS;
        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();
        console.log("1. User deposited:", depositAmount / 10 ** USDT_DECIMALS, "USDT");

        // 2. Owner swaps 50% via 1inch
        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            depositAmount / 2,
            address(0),
            address(basicSwap),
            0
        );

        (uint256 usdtSwapped, uint256 ethReceived) = basicSwap.swap(swapCalldata);
        console.log("2. Swapped:", usdtSwapped / 10 ** USDT_DECIMALS, "USDT");
        console.log("   Received:", ethReceived, "wei ETH");

        // 3. Verify contract state
        assertEq(basicSwap.getUserBalance(user1), depositAmount);
        assertEq(basicSwap.getContractETHBalance(), ethReceived);
        console.log("3. Contract ETH balance:", basicSwap.getContractETHBalance());
        console.log("   Contract USDT balance:", basicSwap.getContractUSDTBalance() / 10 ** USDT_DECIMALS, "USDT");

        // 4. Owner withdraws some USDT
        uint256 withdrawAmount = 1000 * 10 ** USDT_DECIMALS;
        basicSwap.withdrawUSDT(owner, withdrawAmount);
        console.log("4. Owner withdrew:", withdrawAmount / 10 ** USDT_DECIMALS, "USDT");

        // 5. Verify final state
        assertEq(usdt.balanceOf(owner), withdrawAmount);
        console.log("5. Owner USDT balance:", usdt.balanceOf(owner) / 10 ** USDT_DECIMALS, "USDT");
    }

    function test_MultipleSwaps() public {
        // Deposit large amount
        uint256 depositAmount = 8000 * 10 ** USDT_DECIMALS;

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // First swap - contract calculates 50% of current balance (8000)
        uint256 expectedFirstSwap = depositAmount / 2; // 4000 USDT
        bytes memory swapCalldata1 = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            expectedFirstSwap,
            address(0),
            address(basicSwap),
            0
        );

        (uint256 usdtSwapped1, uint256 ethReceived1) = basicSwap.swap(swapCalldata1);
        assertEq(usdtSwapped1, expectedFirstSwap);

        // After first swap, contract still has 8000 USDT (mock doesn't actually transfer)
        // Second swap - contract calculates 50% of current balance (still 8000)
        // Note: In mock, USDT isn't actually transferred, so balance stays same
        uint256 currentBalance = usdt.balanceOf(address(basicSwap));
        uint256 expectedSecondSwap = currentBalance / 2; // 4000 USDT again
        bytes memory swapCalldata2 = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            expectedSecondSwap,
            address(0),
            address(basicSwap),
            0
        );

        (uint256 usdtSwapped2, uint256 ethReceived2) = basicSwap.swap(swapCalldata2);
        assertEq(usdtSwapped2, expectedSecondSwap);

        // Verify total ETH received
        assertEq(basicSwap.getContractETHBalance(), ethReceived1 + ethReceived2);
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositUSDT(uint256 amount) public {
        // Bound amount to reasonable range
        amount = bound(amount, 1, INITIAL_USDT_BALANCE);

        vm.startPrank(user1);
        usdt.approve(address(basicSwap), amount);
        basicSwap.depositUSDT(amount);
        vm.stopPrank();

        assertEq(basicSwap.getUserBalance(user1), amount);
        assertEq(basicSwap.totalUSDTDeposited(), amount);
    }

    function testFuzz_SwapWithDifferentExchangeRates(uint256 exchangeRate) public {
        // Bound exchange rate to reasonable range (0.0001 to 10 ETH per USDT)
        exchangeRate = bound(exchangeRate, 0.0001 ether, 10 ether);

        // Update router exchange rate
        oneInchRouter.setExchangeRate(exchangeRate);

        // Make sure router has enough ETH for the swap
        uint256 depositAmount = 2000 * 10 ** USDT_DECIMALS;
        uint256 swapAmount = depositAmount / 2;
        uint256 expectedETH = (swapAmount * exchangeRate) / 1e6;

        // Fund router with enough ETH if needed
        if (address(oneInchRouter).balance < expectedETH) {
            vm.deal(address(oneInchRouter), expectedETH + 1 ether);
        }

        // Deposit USDT
        vm.startPrank(user1);
        usdt.approve(address(basicSwap), depositAmount);
        basicSwap.depositUSDT(depositAmount);
        vm.stopPrank();

        // Swap
        bytes memory swapCalldata = abi.encodeWithSignature(
            "swap(address,address,uint256,address,address,uint256)",
            address(0),
            address(usdt),
            swapAmount,
            address(0),
            address(basicSwap),
            0
        );

        (, uint256 ethReceived) = basicSwap.swap(swapCalldata);

        // Verify ETH received matches exchange rate
        assertEq(ethReceived, expectedETH);
    }
}
