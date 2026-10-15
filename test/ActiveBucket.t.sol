// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForActive {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100;
    address public owner;
    bool public alwaysRevertPrice;

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address _owner) external {
        owner = _owner;
    }

    function setAlwaysRevertPrice(bool _alwaysRevertPrice) external {
        alwaysRevertPrice = _alwaysRevertPrice;
    }

    function isTokenValid(address token) external view returns (bool) {
        return whitelisted[token] && operational;
    }

    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelisted[token];
    }

    function getTokenPrice(address token) external view returns (uint256) {
        if (alwaysRevertPrice) revert("Oracle is down");
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

    mapping(address => bool) public blacklisted;

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
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

contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bool public shouldRepay = true;

    function setShouldRepay(bool _shouldRepay) external {
        shouldRepay = _shouldRepay;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata) external override {
        if (!shouldRepay) return;

        uint256 totalOwed = amount + fee;
        if (token == address(0)) {
            (bool success,) = msg.sender.call{value: totalOwed}("");
            require(success, "ETH repay failed");
        } else {
            MockERC20ForActive(token).transfer(msg.sender, totalOwed);
        }
    }

    receive() external payable {}
}

contract BadFlashLoanReceiver is IFlashLoanReceiver {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external override {}

    receive() external payable {}
}

contract ActiveBucketTest is Test {
    ActiveBucket public implementation;
    ActiveBucket public bucket;
    MockBucketInfoForActive public bucketInfo;
    MockERC20ForActive public tokenA;
    MockERC20ForActive public tokenB;
    address public oneInchRouter;
    ImplementationRegistry public registry;

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

        registry = new ImplementationRegistry(owner);
        implementation = new ActiveBucket(address(registry));
        registry.setAuthorizedFactory(address(this), true);

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

    function test_Initialization() public view {
        assertEq(bucket.name(), NAME);
        assertEq(bucket.symbol(), SYMBOL);
        assertEq(bucket.owner(), owner);
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), oneInchRouter);
        assertEq(bucket.performanceFeeBps(), 1300);
        assertEq(bucket.tokenPrice(), 0);
    }

    function test_RevertInitializeZeroBucketInfo() public {
        ActiveBucket impl = new ActiveBucket(address(registry));

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(0), oneInchRouter, NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeZeroOneInch() public {
        ActiveBucket impl = new ActiveBucket(address(registry));

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), address(0), NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertDoubleInitialize() public {
        vm.expectRevert();
        bucket.initialize(address(bucketInfo), oneInchRouter, NAME, SYMBOL);
    }

    function test_InitializeCustomNameAndSymbol() public {
        ActiveBucket impl = new ActiveBucket(address(registry));
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, "My Active Bucket", "MAB"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        ActiveBucket customBucket = ActiveBucket(payable(address(proxy)));

        assertEq(customBucket.name(), "My Active Bucket");
        assertEq(customBucket.symbol(), "MAB");
    }

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
        assertEq(bucket.totalDepositValue(), 500e8);
    }

    function test_DepositMultipleTokens() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(bucket.totalDepositValue(), 2500e8);
    }

    function test_DepositSetsTokenPriceOnFirstDeposit() public {
        assertEq(bucket.tokenPrice(), 0);

        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.tokenPrice(), 1e8);
    }

    function test_RevertDepositZero() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.ZeroAmount.selector);
        bucket.deposit{value: 0}(address(0), 0);
    }

    function test_RevertDepositInvalidToken() public {
        address fake = makeAddr("fake");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, fake));
        bucket.deposit(fake, 100);
    }

    function test_RevertDepositPlatformDown() public {
        bucketInfo.setOperational(false);
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
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

        assertApproxEqAbs(shares1 + bucket.DEAD_SHARES(), shares2, 1);
    }

    function test_RedeemShares() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 supply = bucket.totalSupply();
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.balanceOf(user1), 0);
        uint256 expected = (2 ether * shares) / supply;
        assertApproxEqAbs(user1.balance - ethBefore, expected, 1);
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

        assertEq(bucket.totalWithdrawValue(), 0, "totalWithdrawValue must stay frozen post-W2");
    }

    function test_RedeemEmitsTokensAndAmountsForOffChainValueStatistic() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 supply = bucket.totalSupply();

        address[] memory expectedTokens = new address[](1);
        expectedTokens[0] = address(0);
        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = (2 ether * shares) / supply;

        vm.expectEmit(true, true, true, true);
        emit BucketVaultBase.Redeemed(user1, shares, bucket.DEAD_SHARES(), expectedTokens, expectedAmounts);
        vm.prank(user1);
        bucket.redeem(shares);
    }

    function test_RedeemSucceedsWithOracleAlwaysReverting() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 5e18);
        bucket.deposit(address(tokenA), 5e18);
        vm.stopPrank();

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;
        uint256 tokenABefore = tokenA.balanceOf(user1);

        bucketInfo.setAlwaysRevertPrice(true);

        vm.expectRevert("Oracle is down");
        bucketInfo.getTokenPrice(address(0));

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.balanceOf(user1), 0);
        assertTrue(user1.balance > ethBefore, "ETH payout must succeed with oracle reverting");
        assertTrue(tokenA.balanceOf(user1) > tokenABefore, "token payout must succeed with oracle reverting");
    }

    function test_RedeemMultipleTokens() public {
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

        assertTrue(user1.balance > ethBefore);
        assertTrue(tokenA.balanceOf(user1) > tokenABefore);
    }

    function test_RevertRedeemZero() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InvalidRedeemAmount.selector);
        bucket.redeem(0);
    }

    function test_RevertRedeemTooMuch() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InvalidRedeemAmount.selector);
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
        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.redeem(shares);
    }

    function test_FlashLoanERC20() public {
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 100e18);
        bucket.deposit(address(tokenA), 100e18);
        vm.stopPrank();

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        tokenA.mint(address(receiver), 10e18);

        uint256 loanAmount = 50e18;
        uint256 expectedFee = (loanAmount * 200) / 10000;

        uint256 bucketBalBefore = tokenA.balanceOf(address(bucket));

        vm.prank(user1);
        bucket.flashLoan(address(tokenA), loanAmount, address(receiver), bytes(""));

        uint256 bucketBalAfter = tokenA.balanceOf(address(bucket));
        assertGe(bucketBalAfter, bucketBalBefore + expectedFee);
    }

    function test_FlashLoanETH() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether);

        uint256 loanAmount = 5 ether;
        uint256 expectedFee = (loanAmount * 200) / 10000;

        uint256 bucketBalBefore = address(bucket).balance;

        vm.prank(user1);
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
        emit ActiveBucket.FlashLoan(user1, address(receiver), address(0), loanAmount, expectedFee);
        vm.prank(user1);
        bucket.flashLoan(address(0), loanAmount, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanInsufficientRepayment() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        BadFlashLoanReceiver badReceiver = new BadFlashLoanReceiver();
        vm.deal(address(badReceiver), 1 ether);

        vm.prank(user1);
        vm.expectRevert();
        bucket.flashLoan(address(0), 5 ether, address(badReceiver), bytes(""));
    }

    function test_RevertFlashLoanNonHolderRejected() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.prank(user2);
        vm.expectRevert(BucketVaultBase.InsufficientShares.selector);
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroAmount() public {
        bucket.deposit{value: 1 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(BucketVaultBase.ZeroAmount.selector);
        bucket.flashLoan(address(0), 0, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroReceiver() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.flashLoan(address(0), 1 ether, address(0), bytes(""));
    }

    function test_RevertFlashLoanInsufficientBalance() public {
        bucket.deposit{value: 1 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(ActiveBucket.InsufficientBalance.selector);
        bucket.flashLoan(address(0), 2 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanPlatformDown() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucketInfo.setOperational(false);
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
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

    function test_UnpauseSucceedsWhenOwnerNotAccountable() public {
        bucket.deposit{value: 1 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());

        bucket.pause();
        assertTrue(bucket.paused());

        uint256 ownerShares = bucket.balanceOf(address(this));
        bucket.transfer(user1, ownerShares - (ownerShares / 1000));
        assertFalse(bucket.isBucketAccountable());

        bucket.unpause();
        assertFalse(bucket.paused());
    }

    function test_RevertPauseSwapNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.pauseSwap();
    }

    function test_RevertPauseSwapAlreadyPaused() public {
        bucket.pauseSwap();
        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.pauseSwap();
    }

    function test_RevertUnpauseSwapNotPaused() public {
        vm.expectRevert(BucketVaultBase.SwapNotPaused.selector);
        bucket.unpauseSwap();
    }

    function test_RevertUnpauseSwapNotOwner() public {
        bucket.pauseSwap();
        vm.prank(user1);
        vm.expectRevert();
        bucket.unpauseSwap();
    }

    function test_RecoverTokens() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        bucket.recoverTokens(address(rogue), 1000e18, user1);
        assertEq(rogue.balanceOf(user1), 1000e18);
    }

    function test_RecoverETH() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.CannotRecoverWhitelistedToken.selector, address(0)));
        bucket.recoverTokens(address(0), 1 ether, user1);
    }

    function test_RevertRecoverWhitelistedToken() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.CannotRecoverWhitelistedToken.selector, address(tokenA)));
        bucket.recoverTokens(address(tokenA), 100e18, user1);
    }

    function test_RevertRecoverZeroAddress() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.recoverTokens(address(rogue), 1000e18, address(0));
    }

    function test_RevertRecoverNotOwner() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        vm.prank(user1);
        vm.expectRevert();
        bucket.recoverTokens(address(rogue), 1000e18, user1);
    }

    function test_RevertSwapBy1inchNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertSwapBy1inchSwapPaused() public {
        bucket.pauseSwap();

        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertSwapBy1inchPlatformDown() public {
        bucketInfo.setOperational(false);

        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertSwapBy1inchWhenContractPaused() public {
        bucket.pause();

        vm.expectRevert();
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

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
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.setOneInchRouter(address(0));
    }

    function test_RevertSetOneInchRouterNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setOneInchRouter(makeAddr("newRouter"));
    }

    function test_SetPerformanceFee() public {
        bucket.setPerformanceFee(1000);
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
        bucket.setPerformanceFee(0);
        assertEq(bucket.performanceFeeBps(), 0);

        bucket.setPerformanceFee(10000);
        assertEq(bucket.performanceFeeBps(), 10000);
    }

    function test_MaxValueLossBpsDefaultsToFiftyBpsWhenUnset() public view {
        assertEq(bucket.maxValueLossBps(), 50);
    }

    function test_EpochValueLossBudgetBpsDefaultsToOneFiftyBpsWhenUnset() public view {
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_SetMaxValueLossBpsUpdatesGetter() public {
        bucket.setMaxValueLossBps(300, 0);
        assertEq(bucket.maxValueLossBps(), 300);
    }

    function test_SetMaxValueLossBpsUpdatesEpochBudgetGetter() public {
        bucket.setMaxValueLossBps(0, 700);
        assertEq(bucket.epochValueLossBudgetBps(), 700);
    }

    function test_SetMaxValueLossBpsSetsBothIndependentlyInOneCall() public {
        bucket.setMaxValueLossBps(500, 700);
        assertEq(bucket.maxValueLossBps(), 500);
        assertEq(bucket.epochValueLossBudgetBps(), 700);
    }

    function test_SetMaxValueLossBpsEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BucketVaultBase.MaxValueLossBpsUpdated(300, 700);
        bucket.setMaxValueLossBps(300, 700);
    }

    function test_SetMaxValueLossBpsAtCeilingSucceeds() public {
        bucket.setMaxValueLossBps(1000, 1000);
        assertEq(bucket.maxValueLossBps(), 1000);
        assertEq(bucket.epochValueLossBudgetBps(), 1000);
    }

    function test_RevertSetMaxValueLossBpsAboveCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.MaxValueLossBpsExceedsCeiling.selector, 1001));
        bucket.setMaxValueLossBps(1001, 0);
    }

    function test_RevertSetEpochValueLossBudgetBpsAboveCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.MaxValueLossBpsExceedsCeiling.selector, 1001));
        bucket.setMaxValueLossBps(300, 1001);
    }

    function test_SetMaxValueLossBpsBackToZeroRestoresDefault() public {
        bucket.setMaxValueLossBps(1000, 1000);
        assertEq(bucket.maxValueLossBps(), 1000);
        assertEq(bucket.epochValueLossBudgetBps(), 1000);

        bucket.setMaxValueLossBps(0, 0);
        assertEq(bucket.maxValueLossBps(), 50);
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_SetMaxValueLossBpsZeroRestoresOnlyThatFieldIndependently() public {
        bucket.setMaxValueLossBps(500, 700);

        bucket.setMaxValueLossBps(0, 700);
        assertEq(bucket.maxValueLossBps(), 50);
        assertEq(bucket.epochValueLossBudgetBps(), 700);

        bucket.setMaxValueLossBps(0, 0);
        bucket.setMaxValueLossBps(500, 700);
        bucket.setMaxValueLossBps(500, 0);
        assertEq(bucket.maxValueLossBps(), 500);
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_RevertSetMaxValueLossBpsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setMaxValueLossBps(300, 0);
    }

    function test_RevertSetMaxValueLossBpsBlacklistedOwner() public {
        bucketInfo.setBlacklisted(owner, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, owner));
        bucket.setMaxValueLossBps(300, 0);
    }

    function test_IsBucketAccountableNoSupply() public view {
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHolds100Pct() public {
        bucket.deposit{value: 1 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHoldsMinimum() public {
        bucket.deposit{value: 1 ether}(address(0), 0);

        vm.prank(user1);
        bucket.deposit{value: 18 ether}(address(0), 0);

        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerBelowMinimum() public {
        bucket.deposit{value: 0.04 ether}(address(0), 0);

        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        assertFalse(bucket.isBucketAccountable());
    }

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

        assertEq(bucket.calculateTotalValue(), 2500e8);
    }

    function test_Constants() public view {
        assertEq(bucket.PRECISION(), 1e18);
        assertEq(bucket.INITIAL_TOKEN_PRICE(), 1e8);
        assertEq(bucket.BPS_DENOMINATOR(), 10000);
        assertEq(bucket.MAX_VALUE_LOSS_BPS(), 50);
        assertEq(bucket.FLASH_LOAN_FEE_BPS(), 200);
        assertEq(bucket.MIN_OWNER_BPS(), 100);
    }

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
        uint256 supply = bucket.totalSupply();
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        uint256 ethReceived = user1.balance - ethBefore;
        uint256 expected = (amount * shares) / supply;
        assertApproxEqAbs(ethReceived, expected, 1);
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

        vm.prank(user1);
        bucket.redeem(shares1 / 2);

        vm.prank(user2);
        bucket.redeem(shares2 / 2);

        assertApproxEqAbs(bucket.balanceOf(user1), shares1 / 2, 1);
        assertApproxEqAbs(bucket.balanceOf(user2), shares2 / 2, 1);
    }

    function test_ReceiveETH() public {
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        (bool success,) = address(bucket).call{value: 1 ether}("");
        assertTrue(success);
    }

    function test_UpdateBucketInfo() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        bucket.executeUpdateBucketInfo();

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_UpdateBucketInfoFromBucketInfoOwner() public {
        bucketInfo.setOwner(user1);

        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        vm.prank(user1);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());

        bucket.executeUpdateBucketInfo();

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoUnauthorized() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.UnauthorizedBucketInfoUpdate.selector);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.proposeUpdateBucketInfo(address(0));
    }

    function test_RevertExecuteUpdateBucketInfoBeforeTimelockElapsed() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        (, uint256 eta) = bucket.pendingBucketInfoUpdate();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.executeUpdateBucketInfo();
    }

    function test_RevertExecuteUpdateBucketInfoWithNothingPending() public {
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.executeUpdateBucketInfo();
    }

    function test_VetoUpdateBucketInfoByVaultOwner() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
        bucket.vetoUpdateBucketInfo();

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.executeUpdateBucketInfo();

        assertTrue(address(bucket.bucketInfo()) != address(newBucketInfo));
    }

    function test_RevertVetoUpdateBucketInfoByNonVaultOwner() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.prank(user1);
        vm.expectRevert();
        bucket.vetoUpdateBucketInfo();
    }

    function test_InflationAttack_MitigatedByDeadShares() public {
        address attacker = makeAddr("attacker");
        tokenA.mint(attacker, 1_000_000e18);

        vm.startPrank(attacker);
        tokenA.approve(address(bucket), 0.02002e18);
        bucket.deposit(address(tokenA), 0.02002e18);
        vm.stopPrank();

        uint256 attackerShares = bucket.balanceOf(attacker);
        assertEq(attackerShares, 0.001e18, "attacker's real (post-carve-out) stake must be exactly 0.001e18");

        vm.prank(attacker);
        tokenA.transfer(address(bucket), 200_000e18);

        vm.startPrank(user1);
        tokenA.approve(address(bucket), 2e18);
        bucket.deposit(address(tokenA), 2e18);
        vm.stopPrank();

        uint256 victimShares = bucket.balanceOf(user1);
        assertGt(victimShares, 0, "INV-6: DEAD_SHARES must keep the victim's mint nonzero even after a huge donation");

        uint256 supply = bucket.totalSupply();
        uint256 totalValue = bucket.calculateTotalValue();
        uint256 attackerClaimValue = (totalValue * attackerShares) / supply;
        assertLt(
            attackerClaimValue * 100, totalValue, "attacker's claim must stay under 1% of the pool despite the donation"
        );
    }

    function test_PreviewDepositAgreesWithActualDeposit() public {
        (uint256 previewedShares1, uint256 previewedValue1) = bucket.previewDeposit(address(0), 1 ether);

        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        uint256 actualShares1 = bucket.balanceOf(user1);

        assertEq(previewedShares1, actualShares1, "previewDeposit must match actual mint on first deposit");
        assertEq(previewedValue1, ETH_PRICE, "previewDeposit's USD value must match the oracle-priced deposit value");

        (uint256 previewedShares2,) = bucket.previewDeposit(address(0), 3 ether);

        vm.prank(user2);
        bucket.deposit{value: 3 ether}(address(0), 0);
        uint256 actualShares2 = bucket.balanceOf(user2);

        assertEq(previewedShares2, actualShares2, "previewDeposit must match actual mint on a later deposit");
    }

    function test_PreviewRedeemAgreesWithActualRedeem() public {
        vm.startPrank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        uint256 shares = bucket.balanceOf(user1);
        uint256 partialShares = shares / 3;

        vm.prank(user1);
        (address[] memory previewTokens, uint256[] memory previewAmounts) = bucket.previewRedeem(partialShares);

        uint256 ethBefore = user1.balance;
        uint256 tokenABefore = tokenA.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(partialShares);

        uint256 ethReceived = user1.balance - ethBefore;
        uint256 tokenAReceived = tokenA.balanceOf(user1) - tokenABefore;

        bool sawEth = false;
        bool sawTokenA = false;
        for (uint256 i = 0; i < previewTokens.length; i++) {
            if (previewTokens[i] == address(0)) {
                assertEq(previewAmounts[i], ethReceived, "previewRedeem ETH amount must match actual payout");
                sawEth = true;
            } else if (previewTokens[i] == address(tokenA)) {
                assertEq(previewAmounts[i], tokenAReceived, "previewRedeem tokenA amount must match actual payout");
                sawTokenA = true;
            }
        }
        assertTrue(sawEth && sawTokenA, "preview must cover both held tokens");
    }

    function test_LiveNavNotStale_PriceMovesBetweenDepositsWithoutRebalance() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 stalePrice = bucket.tokenPrice();

        uint256 newEthPrice = ETH_PRICE * 2;
        bucketInfo.addToken(address(0), newEthPrice);

        vm.prank(user2);
        bucket.deposit{value: 1 ether}(address(0), 0);
        uint256 user2Shares = bucket.balanceOf(user2);

        uint256 depositValueAtNewPrice = (1 ether * newEthPrice) / 1e18;
        uint256 staleFormulaShares = (depositValueAtNewPrice * 1e18) / stalePrice;

        assertLt(user2Shares, staleFormulaShares, "deposit() must not mint against the stale tokenPrice");
        assertApproxEqAbs(
            user2Shares * 2, staleFormulaShares, 2, "live price move must be reflected exactly, not partially"
        );
    }

    function test_SharePrice_DefaultsToOneUsdOnEmptyVaultThenTracksLiveNav() public {
        assertEq(bucket.totalSupply(), 0);
        assertEq(bucket.sharePrice(), 1e8, "a fresh, empty vault must default to the $1 INITIAL_TOKEN_PRICE");

        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 supply = bucket.totalSupply();
        uint256 totalValue = bucket.calculateTotalValue();
        uint256 expectedPrice = (totalValue * 1e18) / supply;

        assertEq(bucket.sharePrice(), expectedPrice, "sharePrice() must match the live NAV formula post-deposit");
    }

    function _deployApprovedActiveBucketImplementation() internal returns (address newImpl) {
        newImpl = address(new ActiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, newImpl);
    }

    function test_QueueUpgrade_SetsPendingAndEta() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(newImpl);

        assertEq(bucket.pendingImplementation(), newImpl);
        assertEq(bucket.upgradeEta(), block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());
    }

    function test_RevertQueueUpgradeNotOwner() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        vm.prank(user1);
        vm.expectRevert();
        bucket.queueUpgrade(newImpl);
    }

    function test_RevertQueueUpgradeZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.queueUpgrade(address(0));
    }

    function test_UpgradeSucceeds_AfterQueueApprovalAndElapsedDelay() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        bucket.upgradeToAndCall(newImpl, "");

        assertEq(bucket.pendingImplementation(), address(0));
        assertEq(bucket.upgradeEta(), 0);
    }

    function test_RevertUpgrade_BeforeTimelockElapsed() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        uint256 eta = bucket.upgradeEta();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NothingQueued() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ImplementationMismatch() public {
        address queuedImpl = _deployApprovedActiveBucketImplementation();
        address otherImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(queuedImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(BucketVaultBase.UpgradeImplementationMismatch.selector, queuedImpl, otherImpl)
        );
        bucket.upgradeToAndCall(otherImpl, "");
    }

    function test_RevertUpgrade_RegistryApprovalRevokedMidWindow() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, newImpl);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NeverApproved() public {
        address newImpl = address(new ActiveBucket(address(registry)));

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_ClearsPendingState() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        bucket.cancelUpgrade();

        assertEq(bucket.pendingImplementation(), address(0));
        assertEq(bucket.upgradeEta(), 0);

        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_NoOpWhenNothingPending() public {
        bucket.cancelUpgrade();
        assertEq(bucket.pendingImplementation(), address(0));
    }

    function test_RevertCancelUpgradeNotOwner() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        vm.prank(user1);
        vm.expectRevert();
        bucket.cancelUpgrade();
    }

    function test_RevertUpgrade_NotOwner() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.prank(user1);
        vm.expectRevert();
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertRenounceOwnership() public {
        vm.expectRevert(BucketVaultBase.RenounceOwnershipDisabled.selector);
        bucket.renounceOwnership();
    }

    function test_TransferOwnershipIsSingleStepNotTwoStep() public {
        bucket.transferOwnership(user1);
        assertEq(
            bucket.owner(),
            user1,
            "single-step Ownable must hand over ownership immediately, with no acceptOwnership() call"
        );
    }

    function test_RevertUpgrade_PlatformCannotTrigger() public {
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, NAME, SYMBOL);
        registry.setAuthorizedFactory(user2, true);
        vm.prank(user2);
        ERC1967Proxy customerProxy = new ERC1967Proxy(address(implementation), initData);
        ActiveBucket customerBucket = ActiveBucket(payable(address(customerProxy)));
        assertEq(customerBucket.owner(), user2, "customerBucket must be owned by the customer, not the platform");

        address newImpl = address(new ActiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, newImpl);

        vm.expectRevert();
        customerBucket.queueUpgrade(newImpl);

        vm.prank(user2);
        customerBucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + customerBucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert();
        customerBucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ApprovedForWrongKind() public {
        address newImpl = address(new ActiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.PassiveBucket, newImpl);

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_UpgradeQueued_PlatformPauseDoesNotBlockIt() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        bucketInfo.setOperational(false);
        assertFalse(bucketInfo.isPlatformOperational());

        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        bucket.upgradeToAndCall(newImpl, "");
        assertEq(bucket.pendingImplementation(), address(0));
    }
}
