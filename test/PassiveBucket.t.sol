// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForPassive {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%

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

    // --- Helpers for tests ---
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

    function setFeeRate(uint256 _feeRate) external {
        feeRate = _feeRate;
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

contract MockERC20 {
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

contract MockOneInchRouter {
    // Simulates a swap by taking tokenIn and giving tokenOut
    address public tokenIn;
    address public tokenOut;
    uint256 public rate; // how much tokenOut per tokenIn (in tokenOut units per tokenIn unit)

    function setSwap(address _tokenIn, address _tokenOut, uint256 _rate) external {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        rate = _rate;
    }

    fallback() external payable {
        // Simple mock: transfer tokenOut to the caller based on rate
        // Assumes tokens are pre-funded
    }

    receive() external payable {}
}

// ============================================================
//                      TEST CONTRACT
// ============================================================

contract PassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA; // 18 decimals (like WETH)
    MockERC20 public tokenB; // 6 decimals (like USDT)
    MockOneInchRouter public oneInchRouter;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 constant ETH_PRICE = 2000e8; // $2000 USD (8 decimals)
    uint256 constant TOKEN_A_PRICE = 2000e8; // $2000 USD
    uint256 constant TOKEN_B_PRICE = 1e8; // $1 USD

    event Deposited(
        address indexed user, address indexed token, uint256 amount, uint256 sharesMinted, uint256 depositValueUSD
    );
    event Redeemed(address indexed user, uint256 sharesRedeemed);
    event BucketDistributionsUpdated(PassiveBucket.BucketDistribution[] distributions);
    event SwapPauseChanged(bool paused);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mocks
        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        oneInchRouter = new MockOneInchRouter();

        // Setup BucketInfo
        bucketInfo.addToken(address(0), ETH_PRICE); // ETH
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE); // Token A
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE); // Token B

        // Deploy implementation
        implementation = new PassiveBucket();

        // Prepare distributions: 50% ETH, 30% Token A, 20% Token B
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(oneInchRouter),
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        // Fund test accounts
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        tokenA.mint(user1, 100e18);
        tokenA.mint(user2, 100e18);
        tokenB.mint(user1, 100000e6);
        tokenB.mint(user2, 100000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialization() public view {
        assertEq(bucket.name(), "Passive Bucket Share");
        assertEq(bucket.symbol(), "PBS");
        assertEq(bucket.owner(), owner);
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), address(oneInchRouter));
        assertEq(bucket.tokenPrice(), 0); // Not yet set
        assertFalse(bucket.swapPaused());
        assertEq(bucket.totalDepositValue(), 0);
        assertEq(bucket.totalWithdrawValue(), 0);
    }

    function test_InitialDistributions() public view {
        PassiveBucket.BucketDistribution[] memory dists = bucket.getBucketDistributions();
        assertEq(dists.length, 3);
        assertEq(dists[0].token, address(0));
        assertEq(dists[0].weight, 50);
        assertEq(dists[1].token, address(tokenA));
        assertEq(dists[1].weight, 30);
        assertEq(dists[2].token, address(tokenB));
        assertEq(dists[2].weight, 20);
    }

    function test_RevertInitializeZeroAddress() public {
        PassiveBucket impl = new PassiveBucket();
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        // Zero bucketInfo
        vm.expectRevert(PassiveBucket.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(PassiveBucket.initialize.selector, address(0), dists, address(oneInchRouter));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeInvalidWeights() public {
        PassiveBucket impl = new PassiveBucket();
        // Weights sum to 90 instead of 100
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 40);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter)
        );
        vm.expectRevert(abi.encodeWithSelector(PassiveBucket.WeightSumMismatch.selector, 90));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeDuplicateTokens() public {
        PassiveBucket impl = new PassiveBucket();
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(0), 50);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter)
        );
        vm.expectRevert(abi.encodeWithSelector(PassiveBucket.DuplicateToken.selector, address(0)));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeEmptyDistributions() public {
        PassiveBucket impl = new PassiveBucket();
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](0);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter)
        );
        vm.expectRevert(PassiveBucket.EmptyDistributions.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositETH() public {
        uint256 depositAmount = 1 ether;

        vm.prank(user1);
        bucket.deposit{value: depositAmount}(address(0), 0);

        // tokenPrice should be initialized to 1e8
        assertEq(bucket.tokenPrice(), 1e8);

        // shares = (1e18 * 2000e8 / 1e18) * 1e18 / 1e8 = 2000e8 * 1e18 / 1e8 = 2000e18
        uint256 expectedShares = (((depositAmount * ETH_PRICE) / 1e18) * 1e18) / 1e8;
        assertEq(bucket.balanceOf(user1), expectedShares);
        assertEq(bucket.totalDepositValue(), 2000e8);
        assertEq(address(bucket).balance, depositAmount);
    }

    function test_DepositERC20() public {
        uint256 depositAmount = 1000e6; // 1000 USDT

        vm.startPrank(user1);
        tokenB.approve(address(bucket), depositAmount);
        bucket.deposit(address(tokenB), depositAmount);
        vm.stopPrank();

        // shares = (1000e6 * 1e8 / 1e6) * 1e18 / 1e8 = 1000e8 * 1e18 / 1e8 = 1000e18
        uint256 expectedShares = (((depositAmount * TOKEN_B_PRICE) / 1e6) * 1e18) / 1e8;
        assertEq(bucket.balanceOf(user1), expectedShares);
        assertEq(bucket.totalDepositValue(), 1000e8);
    }

    function test_DepositMultipleUsers() public {
        // User1 deposits 1 ETH
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 user1Shares = bucket.balanceOf(user1);
        assertTrue(user1Shares > 0);

        // User2 deposits 2000 USDT (same value as 1 ETH)
        vm.startPrank(user2);
        tokenB.approve(address(bucket), 2000e6);
        bucket.deposit(address(tokenB), 2000e6);
        vm.stopPrank();

        uint256 user2Shares = bucket.balanceOf(user2);
        // Both deposited $2000 worth, so same shares
        assertEq(user1Shares, user2Shares);
    }

    function test_RevertDepositZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(PassiveBucket.ZeroAmount.selector);
        bucket.deposit{value: 0}(address(0), 0);
    }

    function test_RevertDepositInvalidToken() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PassiveBucket.InvalidToken.selector, fakeToken));
        bucket.deposit(fakeToken, 100);
    }

    function test_RevertDepositWhenPaused() public {
        // Owner needs shares for accountability
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pause();
        vm.prank(user1);
        vm.expectRevert();
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_RevertDepositWhenPlatformNotOperational() public {
        bucketInfo.setOperational(false);
        vm.prank(user1);
        vm.expectRevert(PassiveBucket.PlatformNotOperational.selector);
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RedeemShares() public {
        // Deposit ETH
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        // Redeem half
        vm.prank(user1);
        bucket.redeem(shares / 2);

        assertEq(bucket.balanceOf(user1), shares / 2);
        // Should have received ~1 ETH back (from distribution token: ETH)
        assertTrue(user1.balance > ethBefore);
    }

    function test_RevertRedeemZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(PassiveBucket.InvalidRedeemAmount.selector);
        bucket.redeem(0);
    }

    function test_RevertRedeemMoreThanBalance() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(PassiveBucket.InvalidRedeemAmount.selector);
        bucket.redeem(shares + 1);
    }

    function test_RedeemTracksWithdrawValue() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares);

        assertTrue(bucket.totalWithdrawValue() > 0);
    }

    function test_OwnerRedeemAccountabilityCheck() public {
        // Owner deposits
        bucket.deposit{value: 10 ether}(address(0), 0);

        // User deposits more
        vm.prank(user1);
        bucket.deposit{value: 100 ether}(address(0), 0);

        uint256 ownerShares = bucket.balanceOf(owner);
        uint256 supply = bucket.totalSupply();

        // Owner holds ~9.09%. Try to redeem enough to go below 5%
        // Need to retain 5% of new supply
        // Can redeem at most: ownerShares - (supply - redeemAmount) * 5%
        // Let's redeem half owner shares
        uint256 redeemAmount = ownerShares / 2;

        // After: owner has ownerShares/2, supply = supply - redeemAmount
        // ownerPct = (ownerShares/2) / (supply - redeemAmount)
        // This should still be > 5%
        bucket.redeem(redeemAmount);

        // Try to redeem too much (would drop below 5%)
        uint256 remainingOwner = bucket.balanceOf(owner);
        uint256 newSupply = bucket.totalSupply();

        // Check if remaining + a bit is still accountable
        if ((remainingOwner * 10000) / newSupply < 500) {
            // Already below 5%, next redeem should fail
            vm.expectRevert(PassiveBucket.OwnerNotAccountable.selector);
            bucket.redeem(1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    BUCKET DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateBucketDistributions() public {
        // Owner must have shares for accountability
        bucket.deposit{value: 10 ether}(address(0), 0);

        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](2);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 60);
        newDists[1] = PassiveBucket.BucketDistribution(address(tokenA), 40);

        bucket.updateBucketDistributions(newDists);

        PassiveBucket.BucketDistribution[] memory stored = bucket.getBucketDistributions();
        assertEq(stored.length, 2);
        assertEq(stored[0].weight, 60);
        assertEq(stored[1].weight, 40);
    }

    function test_RevertUpdateDistributionsNotOwner() public {
        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](1);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.prank(user1);
        vm.expectRevert();
        bucket.updateBucketDistributions(newDists);
    }

    function test_RevertUpdateDistributionsNotAccountable() public {
        // Owner has no shares initially  - needs to deposit first
        // User deposits so owner owns < 5%
        vm.prank(user1);
        bucket.deposit{value: 100 ether}(address(0), 0);

        // Owner has 0 shares, not accountable
        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](1);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.expectRevert(PassiveBucket.OwnerNotAccountable.selector);
        bucket.updateBucketDistributions(newDists);
    }

    function test_RevertUpdateDistributionsPlatformNotOperational() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucketInfo.setOperational(false);

        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](1);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.expectRevert(PassiveBucket.PlatformNotOperational.selector);
        bucket.updateBucketDistributions(newDists);
    }

    /*//////////////////////////////////////////////////////////////
                      ACCOUNTABILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_IsBucketAccountableNoSupply() public view {
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHasEnough() public {
        // Owner deposits (has all supply)
        bucket.deposit{value: 10 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerBelow5Percent() public {
        // User deposits large amount, owner has nothing
        vm.prank(user1);
        bucket.deposit{value: 100 ether}(address(0), 0);

        assertFalse(bucket.isBucketAccountable());
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PauseUnpause() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pause();
        assertTrue(bucket.paused());

        bucket.unpause();
        assertFalse(bucket.paused());
    }

    function test_RevertPauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.pause();
    }

    function test_PauseSwap() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pauseSwap();
        assertTrue(bucket.swapPaused());

        bucket.unpauseSwap();
        assertFalse(bucket.swapPaused());
    }

    function test_RevertPauseSwapAlreadyPaused() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pauseSwap();
        vm.expectRevert(PassiveBucket.SwapIsPaused.selector);
        bucket.pauseSwap();
    }

    function test_RevertUnpauseSwapNotPaused() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        vm.expectRevert(PassiveBucket.SwapNotPaused.selector);
        bucket.unpauseSwap();
    }

    /*//////////////////////////////////////////////////////////////
                      RECOVER TOKENS TEST
    //////////////////////////////////////////////////////////////*/

    function test_RecoverNonWhitelistedTokens() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        uint256 balBefore = rogue.balanceOf(user1);
        bucket.recoverTokens(address(rogue), 1000e18, user1);
        assertEq(rogue.balanceOf(user1), balBefore + 1000e18);
    }

    function test_RevertRecoverWhitelistedTokens() public {
        tokenA.mint(address(bucket), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(PassiveBucket.CannotRecoverWhitelistedToken.selector, address(tokenA)));
        bucket.recoverTokens(address(tokenA), 1000e18, user1);
    }

    function test_RevertRecoverNotOwner() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 100e18);

        vm.prank(user1);
        vm.expectRevert();
        bucket.recoverTokens(address(rogue), 100e18, user1);
    }

    /*//////////////////////////////////////////////////////////////
                      TOTAL VALUE CALCULATION
    //////////////////////////////////////////////////////////////*/

    function test_CalculateTotalValue() public {
        // Deposit 1 ETH ($2000)
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 totalValue = bucket.calculateTotalValue();
        assertEq(totalValue, 2000e8);
    }

    function test_CalculateTotalValueMultipleTokens() public {
        // Deposit 1 ETH ($2000)
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        // Deposit 500 USDT ($500)
        vm.startPrank(user2);
        tokenB.approve(address(bucket), 500e6);
        bucket.deposit(address(tokenB), 500e6);
        vm.stopPrank();

        uint256 totalValue = bucket.calculateTotalValue();
        assertEq(totalValue, 2500e8);
    }

    /*//////////////////////////////////////////////////////////////
                      DEX CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_ConfigureDEX() public {
        address router = makeAddr("router");
        address quoter = makeAddr("quoter");

        bucket.configureDEX(0, router, quoter, 3000, true);

        (address r, address q, uint24 f, bool e) = bucket.dexConfigs(0);
        assertEq(r, router);
        assertEq(q, quoter);
        assertEq(f, 3000);
        assertTrue(e);
        assertEq(bucket.dexCount(), 1);
    }

    function test_RevertConfigureDEXNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.configureDEX(0, makeAddr("router"), makeAddr("quoter"), 3000, true);
    }

    /*//////////////////////////////////////////////////////////////
                    REBALANCE BY 1INCH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertRebalanceBy1inchNoShares() public {
        vm.prank(user1);
        vm.expectRevert(PassiveBucket.InsufficientShares.selector);
        bucket.rebalanceBy1inch(bytes(""));
    }

    function test_RevertRebalanceBy1inchSwapPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        bucket.deposit{value: 10 ether}(address(0), 0); // owner for accountability

        bucket.pauseSwap();

        vm.prank(user1);
        vm.expectRevert(PassiveBucket.SwapIsPaused.selector);
        bucket.rebalanceBy1inch(bytes("test"));
    }

    function test_RevertRebalanceBy1inchPlatformPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        bucketInfo.setOperational(false);

        vm.prank(user1);
        vm.expectRevert(PassiveBucket.PlatformNotOperational.selector);
        bucket.rebalanceBy1inch(bytes("test"));
    }

    /*//////////////////////////////////////////////////////////////
                    REBALANCE BY DEFI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertRebalanceByDefiNoShares() public {
        PassiveBucket.RebalanceOrder[] memory orders = new PassiveBucket.RebalanceOrder[](0);

        vm.prank(user1);
        vm.expectRevert(PassiveBucket.InsufficientShares.selector);
        bucket.rebalanceByDefi(orders);
    }

    function test_RevertRebalanceByDefiSwapPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        bucket.deposit{value: 10 ether}(address(0), 0); // owner

        bucket.pauseSwap();

        PassiveBucket.RebalanceOrder[] memory orders = new PassiveBucket.RebalanceOrder[](0);

        vm.prank(user1);
        vm.expectRevert(PassiveBucket.SwapIsPaused.selector);
        bucket.rebalanceByDefi(orders);
    }

    /*//////////////////////////////////////////////////////////////
                          WETH MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_SetWETH() public {
        address wethAddr = makeAddr("weth");
        bucket.setWETH(wethAddr);
        assertEq(bucket.weth(), wethAddr);
    }

    function test_RevertSetWETHZeroAddress() public {
        vm.expectRevert(PassiveBucket.ZeroAddress.selector);
        bucket.setWETH(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositETH(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 50 ether);

        vm.prank(user1);
        bucket.deposit{value: amount}(address(0), 0);

        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(address(bucket).balance, amount);
    }

    function testFuzz_DepositAndRedeem(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.01 ether, 50 ether);

        vm.prank(user1);
        bucket.deposit{value: depositAmount}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.balanceOf(user1), 0);
        // User should get back approximately what they deposited (just ETH since that's the only holding)
        uint256 ethReceived = user1.balance - ethBefore;
        // Allow 1 wei rounding error
        assertApproxEqAbs(ethReceived, depositAmount, 1);
    }

    function testFuzz_MultipleDepositsAndRedeems(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 0.01 ether, 25 ether);
        amount2 = bound(amount2, 0.01 ether, 25 ether);

        vm.prank(user1);
        bucket.deposit{value: amount1}(address(0), 0);

        vm.prank(user2);
        bucket.deposit{value: amount2}(address(0), 0);

        uint256 shares1 = bucket.balanceOf(user1);
        uint256 shares2 = bucket.balanceOf(user2);

        assertTrue(shares1 > 0);
        assertTrue(shares2 > 0);

        // Shares should be proportional to deposits
        // shares1 / shares2 ≈ amount1 / amount2
        if (amount2 > 0 && shares2 > 0) {
            uint256 ratio1 = (shares1 * 1e18) / shares2;
            uint256 ratio2 = (amount1 * 1e18) / amount2;
            assertApproxEqRel(ratio1, ratio2, 1e15); // 0.1% tolerance
        }
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
