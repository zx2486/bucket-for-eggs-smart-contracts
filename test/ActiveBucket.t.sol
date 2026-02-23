// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForActive {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100;

    function isTokenValid(address token) external view returns (bool) {
        return whitelisted[token] && operational;
    }

    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelisted[token];
    }

    function getTokenPrice(address token) external view returns (uint256) {
        require(whitelisted[token], "Not whitelisted");
        return prices[token];
    }

    function isPlatformOperational() external view returns (bool) {
        return operational;
    }

    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * feeRate) / 10000;
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedList;
    }

    function PRICE_DECIMALS() external pure returns (uint256) {
        return 8;
    }

    function platformFee() external view returns (uint256) {
        return feeRate;
    }

    function addToken(address token, uint256 price) external {
        if (!whitelisted[token]) {
            whitelisted[token] = true;
            whitelistedList.push(token);
        }
        prices[token] = price;
    }

    function setOperational(bool _operational) external {
        operational = _operational;
    }

    function removeToken(address token) external {
        whitelisted[token] = false;
        for (uint256 i = 0; i < whitelistedList.length; i++) {
            if (whitelistedList[i] == token) {
                whitelistedList[i] = whitelistedList[whitelistedList.length - 1];
                whitelistedList.pop();
                break;
            }
        }
    }

    receive() external payable {}
}

contract MockERC20ForActive {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Flash loan receiver that properly repays with interest
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bool public shouldRepay = true;

    function setShouldRepay(bool _shouldRepay) external {
        shouldRepay = _shouldRepay;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata) external override {
        if (!shouldRepay) return;

        uint256 totalOwed = amount + fee;
        if (token == address(0)) {
            // Repay ETH
            (bool success,) = msg.sender.call{value: totalOwed}("");
            require(success, "ETH repay failed");
        } else {
            // Repay ERC-20
            MockERC20ForActive(token).transfer(msg.sender, totalOwed);
        }
    }

    receive() external payable {}
}

/// @dev Flash loan receiver that does NOT repay
contract BadFlashLoanReceiver is IFlashLoanReceiver {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external override {
        // Do nothing - don't repay
    }

    receive() external payable {}
}

// ============================================================
//                      TEST CONTRACT
// ============================================================

contract ActiveBucketTest is Test {
    ActiveBucket public implementation;
    ActiveBucket public bucket;
    MockBucketInfoForActive public bucketInfo;
    MockERC20ForActive public tokenA;
    MockERC20ForActive public tokenB;
    address public oneInchRouter;

    address public owner;
    address public user1;
    address public user2;

    string constant NAME = "Active Bucket Share";
    string constant SYMBOL = "ABS";

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 50e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        bucketInfo = new MockBucketInfoForActive();
        tokenA = new MockERC20ForActive("Token A", "TKA", 18);
        tokenB = new MockERC20ForActive("Token B", "TKB", 6);
        oneInchRouter = makeAddr("oneInchRouter");

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        implementation = new ActiveBucket();

        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, NAME, SYMBOL);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = ActiveBucket(payable(address(proxy)));

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        tokenA.mint(user1, 1000e18);
        tokenA.mint(user2, 1000e18);
        tokenB.mint(user1, 100000e6);
        tokenB.mint(user2, 100000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialization() public view {
        assertEq(bucket.name(), NAME);
        assertEq(bucket.symbol(), SYMBOL);
        assertEq(bucket.owner(), owner);
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), oneInchRouter);
        assertEq(bucket.performanceFeeBps(), 500); // 5% default
        assertEq(bucket.tokenPrice(), 0); // not set until first deposit
    }

    function test_RevertInitializeZeroBucketInfo() public {
        ActiveBucket impl = new ActiveBucket();

        vm.expectRevert(ActiveBucket.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(0), oneInchRouter, NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeZeroOneInch() public {
        ActiveBucket impl = new ActiveBucket();

        vm.expectRevert(ActiveBucket.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), address(0), NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertDoubleInitialize() public {
        vm.expectRevert();
        bucket.initialize(address(bucketInfo), oneInchRouter, NAME, SYMBOL);
    }

    function test_InitializeCustomNameAndSymbol() public {
        ActiveBucket impl = new ActiveBucket();
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, "My Active Bucket", "MAB"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        ActiveBucket customBucket = ActiveBucket(payable(address(proxy)));

        assertEq(customBucket.name(), "My Active Bucket");
        assertEq(customBucket.symbol(), "MAB");
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositETH() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.tokenPrice(), 1e8);
        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(address(bucket).balance, 1 ether);
        assertEq(bucket.totalDepositValue(), 2000e8);
    }

    function test_DepositERC20() public {
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(bucket.totalDepositValue(), 500e8); // 10 * $50
    }

    function test_DepositMultipleTokens() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(bucket.totalDepositValue(), 2500e8); // 2000 + 500
    }

    function test_DepositSetsTokenPriceOnFirstDeposit() public {
        assertEq(bucket.tokenPrice(), 0);

        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.tokenPrice(), 1e8); // INITIAL_TOKEN_PRICE
    }

    function test_RevertDepositZero() public {
        vm.prank(user1);
        vm.expectRevert(ActiveBucket.ZeroAmount.selector);
        bucket.deposit{value: 0}(address(0), 0);
    }

    function test_RevertDepositInvalidToken() public {
        address fake = makeAddr("fake");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ActiveBucket.InvalidToken.selector, fake));
        bucket.deposit(fake, 100);
    }

    function test_RevertDepositPlatformDown() public {
        bucketInfo.setOperational(false);
        vm.prank(user1);
        vm.expectRevert(ActiveBucket.PlatformNotOperational.selector);
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_RevertDepositWhenPaused() public {
        bucket.pause();
        vm.prank(user1);
        vm.expectRevert();
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_DepositMultipleUsers() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares1 = bucket.balanceOf(user1);

        vm.prank(user2);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares2 = bucket.balanceOf(user2);

        // Both users deposited equal amounts, should get equal shares
        assertApproxEqAbs(shares1, shares2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RedeemShares() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.balanceOf(user1), 0);
        // Should get back approximately 2 ETH
        assertApproxEqAbs(user1.balance - ethBefore, 2 ether, 1);
    }

    function test_RedeemPartial() public {
        vm.prank(user1);
        bucket.deposit{value: 4 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares / 2);

        assertEq(bucket.balanceOf(user1), shares / 2);
    }

    function test_RedeemTracksWithdrawValue() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares);

        assertTrue(bucket.totalWithdrawValue() > 0);
    }

    function test_RedeemMultipleTokens() public {
        // Deposit ETH and ERC20
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;
        uint256 tokenABefore = tokenA.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares);

        // Should receive both ETH and Token A back
        assertTrue(user1.balance > ethBefore);
        assertTrue(tokenA.balanceOf(user1) > tokenABefore);
    }

    function test_RevertRedeemZero() public {
        vm.prank(user1);
        vm.expectRevert(ActiveBucket.InvalidRedeemAmount.selector);
        bucket.redeem(0);
    }

    function test_RevertRedeemTooMuch() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(ActiveBucket.InvalidRedeemAmount.selector);
        bucket.redeem(shares + 1);
    }

    function test_RevertRedeemWhenPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        bucket.pause();

        uint256 shares = bucket.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        bucket.redeem(shares);
    }

    function test_RevertRedeemPlatformDown() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        bucketInfo.setOperational(false);

        uint256 shares = bucket.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert(ActiveBucket.PlatformNotOperational.selector);
        bucket.redeem(shares);
    }

    /*//////////////////////////////////////////////////////////////
                        FLASH LOAN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FlashLoanERC20() public {
        // Setup: deposit tokens into bucket
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 100e18);
        bucket.deposit(address(tokenA), 100e18);
        vm.stopPrank();

        // Create flash loan receiver and fund it with enough to cover interest
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        tokenA.mint(address(receiver), 10e18); // Extra for interest

        uint256 loanAmount = 50e18;
        uint256 expectedFee = (loanAmount * 200) / 10000; // 2% = 1e18

        uint256 bucketBalBefore = tokenA.balanceOf(address(bucket));

        bucket.flashLoan(address(tokenA), loanAmount, address(receiver), bytes(""));

        uint256 bucketBalAfter = tokenA.balanceOf(address(bucket));
        assertGe(bucketBalAfter, bucketBalBefore + expectedFee);
    }

    function test_FlashLoanETH() public {
        // Deposit ETH
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether); // Extra for interest

        uint256 loanAmount = 5 ether;
        uint256 expectedFee = (loanAmount * 200) / 10000; // 2% = 0.1 ether

        uint256 bucketBalBefore = address(bucket).balance;

        bucket.flashLoan(address(0), loanAmount, address(receiver), bytes(""));

        uint256 bucketBalAfter = address(bucket).balance;
        assertGe(bucketBalAfter, bucketBalBefore + expectedFee);
    }

    function test_FlashLoanEmitsEvent() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether);

        uint256 loanAmount = 5 ether;
        uint256 expectedFee = (loanAmount * 200) / 10000;

        vm.expectEmit(true, true, true, true);
        emit ActiveBucket.FlashLoan(address(this), address(receiver), address(0), loanAmount, expectedFee);
        bucket.flashLoan(address(0), loanAmount, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanInsufficientRepayment() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        BadFlashLoanReceiver badReceiver = new BadFlashLoanReceiver();
        vm.deal(address(badReceiver), 1 ether);

        vm.expectRevert();
        bucket.flashLoan(address(0), 5 ether, address(badReceiver), bytes(""));
    }

    function test_RevertFlashLoanNotOwner() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.prank(user1);
        vm.expectRevert();
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroAmount() public {
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(ActiveBucket.ZeroAmount.selector);
        bucket.flashLoan(address(0), 0, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroReceiver() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        vm.expectRevert(ActiveBucket.ZeroAddress.selector);
        bucket.flashLoan(address(0), 1 ether, address(0), bytes(""));
    }

    function test_RevertFlashLoanInsufficientBalance() public {
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(ActiveBucket.InsufficientBalance.selector);
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanPlatformDown() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucketInfo.setOperational(false);
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(ActiveBucket.PlatformNotOperational.selector);
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanWhenPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pause();

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.expectRevert();
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PauseUnpause() public {
        bucket.pause();
        assertTrue(bucket.paused());

        bucket.unpause();
        assertFalse(bucket.paused());
    }

    function test_PauseSwap() public {
        bucket.pauseSwap();
        assertTrue(bucket.swapPaused());

        bucket.unpauseSwap();
        assertFalse(bucket.swapPaused());
    }

    function test_RevertPauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.pause();
    }

    function test_RevertUnpauseNotOwner() public {
        bucket.pause();
        vm.prank(user1);
        vm.expectRevert();
        bucket.unpause();
    }

    function test_RevertPauseSwapNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.pauseSwap();
    }

    function test_RevertPauseSwapAlreadyPaused() public {
        bucket.pauseSwap();
        vm.expectRevert(ActiveBucket.SwapIsPaused.selector);
        bucket.pauseSwap();
    }

    function test_RevertUnpauseSwapNotPaused() public {
        vm.expectRevert(ActiveBucket.SwapNotPaused.selector);
        bucket.unpauseSwap();
    }

    function test_RevertUnpauseSwapNotOwner() public {
        bucket.pauseSwap();
        vm.prank(user1);
        vm.expectRevert();
        bucket.unpauseSwap();
    }

    /*//////////////////////////////////////////////////////////////
                      RECOVER TOKENS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RecoverTokens() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        bucket.recoverTokens(address(rogue), 1000e18, user1);
        assertEq(rogue.balanceOf(user1), 1000e18);
    }

    function test_RecoverETH() public {
        // ETH is whitelisted in our setup, so this should revert
        vm.expectRevert(abi.encodeWithSelector(ActiveBucket.CannotRecoverWhitelistedToken.selector, address(0)));
        bucket.recoverTokens(address(0), 1 ether, user1);
    }

    function test_RevertRecoverWhitelistedToken() public {
        vm.expectRevert(abi.encodeWithSelector(ActiveBucket.CannotRecoverWhitelistedToken.selector, address(tokenA)));
        bucket.recoverTokens(address(tokenA), 100e18, user1);
    }

    function test_RevertRecoverZeroAddress() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        vm.expectRevert(ActiveBucket.ZeroAddress.selector);
        bucket.recoverTokens(address(rogue), 1000e18, address(0));
    }

    function test_RevertRecoverNotOwner() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        vm.prank(user1);
        vm.expectRevert();
        bucket.recoverTokens(address(rogue), 1000e18, user1);
    }

    /*//////////////////////////////////////////////////////////////
                    SWAP BY 1INCH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertSwapBy1inchNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.swapBy1inch(bytes("test"));
    }

    function test_RevertSwapBy1inchSwapPaused() public {
        bucket.pauseSwap();

        vm.expectRevert(ActiveBucket.SwapIsPaused.selector);
        bucket.swapBy1inch(bytes("test"));
    }

    function test_RevertSwapBy1inchPlatformDown() public {
        bucketInfo.setOperational(false);

        vm.expectRevert(ActiveBucket.PlatformNotOperational.selector);
        bucket.swapBy1inch(bytes("test"));
    }

    function test_RevertSwapBy1inchWhenContractPaused() public {
        bucket.pause();

        vm.expectRevert();
        bucket.swapBy1inch(bytes("test"));
    }

    /*//////////////////////////////////////////////////////////////
                    SET ONEINCH ROUTER
    //////////////////////////////////////////////////////////////*/

    function test_SetOneInchRouter() public {
        address newRouter = makeAddr("newRouter");
        bucket.setOneInchRouter(newRouter);
        assertEq(bucket.oneInchRouter(), newRouter);
    }

    function test_SetOneInchRouterEmitsEvent() public {
        address newRouter = makeAddr("newRouter");
        vm.expectEmit(true, false, false, false);
        emit ActiveBucket.OneInchRouterUpdated(newRouter);
        bucket.setOneInchRouter(newRouter);
    }

    function test_RevertSetOneInchRouterZero() public {
        vm.expectRevert(ActiveBucket.ZeroAddress.selector);
        bucket.setOneInchRouter(address(0));
    }

    function test_RevertSetOneInchRouterNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setOneInchRouter(makeAddr("newRouter"));
    }

    /*//////////////////////////////////////////////////////////////
                    PERFORMANCE FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetPerformanceFee() public {
        bucket.setPerformanceFee(1000); // 10%
        assertEq(bucket.performanceFeeBps(), 1000);
    }

    function test_SetPerformanceFeeEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ActiveBucket.PerformanceFeeUpdated(1000);
        bucket.setPerformanceFee(1000);
    }

    function test_RevertSetPerformanceFeeExceeds100() public {
        vm.expectRevert("Fee exceeds 100%");
        bucket.setPerformanceFee(10001);
    }

    function test_RevertSetPerformanceFeeNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setPerformanceFee(1000);
    }

    function test_SetPerformanceFeeBoundary() public {
        // 0% is valid
        bucket.setPerformanceFee(0);
        assertEq(bucket.performanceFeeBps(), 0);

        // 100% is valid
        bucket.setPerformanceFee(10000);
        assertEq(bucket.performanceFeeBps(), 10000);
    }

    /*//////////////////////////////////////////////////////////////
                    ACCOUNTABILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_IsBucketAccountableNoSupply() public view {
        // With no supply, accountability is trivially true
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHolds100Pct() public {
        // Owner deposits — holds 100% of supply
        bucket.deposit{value: 1 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHoldsMinimum() public {
        // Owner deposits first
        bucket.deposit{value: 1 ether}(address(0), 0);

        // User deposits 19x more (owner will hold ~5%)
        vm.prank(user1);
        bucket.deposit{value: 19 ether}(address(0), 0);

        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerBelowMinimum() public {
        // Owner deposits
        bucket.deposit{value: 0.04 ether}(address(0), 0);

        // User deposits way more (owner will hold < 5%)
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        assertFalse(bucket.isBucketAccountable());
    }

    /*//////////////////////////////////////////////////////////////
                      TOTAL VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TotalValueEmpty() public view {
        assertEq(bucket.calculateTotalValue(), 0);
    }

    function test_TotalValueAfterDeposit() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.calculateTotalValue(), 2000e8);
    }

    function test_TotalValueMultipleTokens() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        // 1 ETH = $2000, 10 TKA = $500
        assertEq(bucket.calculateTotalValue(), 2500e8);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTANTS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constants() public view {
        assertEq(bucket.PRECISION(), 1e18);
        assertEq(bucket.INITIAL_TOKEN_PRICE(), 1e8);
        assertEq(bucket.BPS_DENOMINATOR(), 10000);
        assertEq(bucket.MAX_VALUE_LOSS_BPS(), 50);
        assertEq(bucket.FLASH_LOAN_FEE_BPS(), 200);
        assertEq(bucket.MIN_OWNER_BPS(), 500);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositETH(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 50 ether);

        vm.prank(user1);
        bucket.deposit{value: amount}(address(0), 0);

        assertTrue(bucket.balanceOf(user1) > 0);
    }

    function testFuzz_DepositAndRedeem(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 50 ether);

        vm.prank(user1);
        bucket.deposit{value: amount}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        uint256 ethReceived = user1.balance - ethBefore;
        assertApproxEqAbs(ethReceived, amount, 1);
    }

    function testFuzz_FlashLoanFee(uint256 amount) public {
        amount = bound(amount, 0.1 ether, 10 ether);
        vm.deal(address(this), amount + 10 ether);

        bucket.deposit{value: amount + 1 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether);

        uint256 balBefore = address(bucket).balance;

        bucket.flashLoan(address(0), amount, address(receiver), bytes(""));

        uint256 balAfter = address(bucket).balance;
        uint256 expectedFee = (amount * 200) / 10000;
        assertGe(balAfter, balBefore + expectedFee);
    }

    function testFuzz_PerformanceFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, 10000);
        bucket.setPerformanceFee(feeBps);
        assertEq(bucket.performanceFeeBps(), feeBps);
    }

    function testFuzz_MultipleDepositsAndRedeemPartial(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 0.01 ether, 25 ether);
        amount2 = bound(amount2, 0.01 ether, 25 ether);

        vm.prank(user1);
        bucket.deposit{value: amount1}(address(0), 0);

        vm.prank(user2);
        bucket.deposit{value: amount2}(address(0), 0);

        uint256 shares1 = bucket.balanceOf(user1);
        uint256 shares2 = bucket.balanceOf(user2);

        // Each user redeems half
        vm.prank(user1);
        bucket.redeem(shares1 / 2);

        vm.prank(user2);
        bucket.redeem(shares2 / 2);

        // Remaining shares should be approximately half
        assertApproxEqAbs(bucket.balanceOf(user1), shares1 / 2, 1);
        assertApproxEqAbs(bucket.balanceOf(user2), shares2 / 2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                    RECEIVE ETH TEST
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH() public {
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        (bool success,) = address(bucket).call{value: 1 ether}("");
        assertTrue(success);
    }
}
