// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

contract MockBucketInfoForPassive {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
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
    address public tokenIn;
    address public tokenOut;
    uint256 public rate; // how much tokenOut per tokenIn (in tokenOut units per tokenIn unit)

    function setSwap(address _tokenIn, address _tokenOut, uint256 _rate) external {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        rate = _rate;
    }

    fallback() external payable {}

    receive() external payable {}
}

contract PassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA; // 18 decimals (like WETH)
    MockERC20 public tokenB; // 6 decimals (like USDT)
    MockOneInchRouter public oneInchRouter;
    ImplementationRegistry public registry;

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
    event Redeemed(address indexed user, uint256 shares, uint256 supply, address[] tokens, uint256[] amounts);
    event BucketDistributionsUpdated(PassiveBucket.BucketDistribution[] distributions);
    event SwapPauseChanged(bool paused);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        oneInchRouter = new MockOneInchRouter();

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        registry = new ImplementationRegistry(owner);
        implementation = new PassiveBucket(address(registry));
        registry.setAuthorizedFactory(address(this), true);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

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

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        tokenA.mint(user1, 100e18);
        tokenA.mint(user2, 100e18);
        tokenB.mint(user1, 100000e6);
        tokenB.mint(user2, 100000e6);
    }

    function test_Initialization() public view {
        assertEq(bucket.name(), "PassiveBucket Share");
        assertEq(bucket.symbol(), "pBKT");
        assertEq(bucket.owner(), owner);
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), address(oneInchRouter));
        assertEq(bucket.tokenPrice(), 0);
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
        PassiveBucket impl = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(0), dists, address(oneInchRouter), "Test", "TST"
        );
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeInvalidWeights() public {
        PassiveBucket impl = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 40);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter), "Test", "TST"
        );
        vm.expectRevert(abi.encodeWithSelector(PassiveBucket.WeightSumMismatch.selector, 90));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeDuplicateTokens() public {
        PassiveBucket impl = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(0), 50);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter), "Test", "TST"
        );
        vm.expectRevert(abi.encodeWithSelector(PassiveBucket.DuplicateToken.selector, address(0)));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeEmptyDistributions() public {
        PassiveBucket impl = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](0);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter), "Test", "TST"
        );
        vm.expectRevert(PassiveBucket.EmptyDistributions.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_DepositETH() public {
        uint256 depositAmount = 1 ether;

        vm.prank(user1);
        bucket.deposit{value: depositAmount}(address(0), 0);

        assertEq(bucket.tokenPrice(), 1e8);

        uint256 rawExpectedShares = (((depositAmount * ETH_PRICE) / 1e18) * 1e18) / 1e8;
        assertEq(bucket.balanceOf(user1), rawExpectedShares - bucket.DEAD_SHARES());
        assertEq(bucket.totalDepositValue(), 2000e8);
        assertEq(address(bucket).balance, depositAmount);
    }

    function test_DepositERC20() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(user1);
        tokenB.approve(address(bucket), depositAmount);
        bucket.deposit(address(tokenB), depositAmount);
        vm.stopPrank();

        uint256 rawExpectedShares = (((depositAmount * TOKEN_B_PRICE) / 1e6) * 1e18) / 1e8;
        assertEq(bucket.balanceOf(user1), rawExpectedShares - bucket.DEAD_SHARES());
        assertEq(bucket.totalDepositValue(), 1000e8);
    }

    function test_DepositMultipleUsers() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 user1Shares = bucket.balanceOf(user1);
        assertTrue(user1Shares > 0);

        vm.startPrank(user2);
        tokenB.approve(address(bucket), 2000e6);
        bucket.deposit(address(tokenB), 2000e6);
        vm.stopPrank();

        uint256 user2Shares = bucket.balanceOf(user2);
        assertApproxEqAbs(user1Shares + bucket.DEAD_SHARES(), user2Shares, 1);
    }

    function test_RevertDepositZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.ZeroAmount.selector);
        bucket.deposit{value: 0}(address(0), 0);
    }

    function test_RevertDepositInvalidToken() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, fakeToken));
        bucket.deposit(fakeToken, 100);
    }

    function test_RevertDepositWhenPaused() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pause();
        vm.prank(user1);
        vm.expectRevert();
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_RevertDepositWhenPlatformNotOperational() public {
        bucketInfo.setOperational(false);
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_RedeemShares() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares / 2);

        assertEq(bucket.balanceOf(user1), shares / 2);
        assertTrue(user1.balance > ethBefore);
    }

    function test_RevertRedeemZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InvalidRedeemAmount.selector);
        bucket.redeem(0);
    }

    function test_RevertRedeemMoreThanBalance() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InvalidRedeemAmount.selector);
        bucket.redeem(shares + 1);
    }

    function test_RedeemTracksWithdrawValue() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

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

    function test_OwnerRedeemAccountabilityCheck() public {
        // Owner deposits
        bucket.deposit{value: 10 ether}(address(0), 0);

        // User deposits more
        vm.prank(user1);
        bucket.deposit{value: 100 ether}(address(0), 0);

        uint256 minOwnerBps = bucket.MIN_OWNER_BPS();
        uint256 bpsDenom = bucket.BPS_DENOMINATOR();

        uint256 ownerShares = bucket.balanceOf(owner);

        // Owner holds ~9.09%. Redeem a small portion so owner stays above the MIN_OWNER_BPS floor
        // (comfortably true for any floor at or below ~9%, which covers both 500 and 100 bps).
        uint256 smallRedeem = ownerShares / 4;
        bucket.redeem(smallRedeem);

        assertTrue(bucket.isBucketAccountable(), "Owner should still be accountable after small redeem");

        // Now try to redeem enough to drop below the MIN_OWNER_BPS floor — should revert.
        uint256 remainingOwner = bucket.balanceOf(owner);
        uint256 newSupply = bucket.totalSupply();

        uint256 threshold = ((remainingOwner * bpsDenom) - (newSupply * minOwnerBps)) / (bpsDenom - minOwnerBps);
        uint256 tooMuch = threshold + 1e18; // safely over the limit

        if (tooMuch <= remainingOwner) {
            vm.expectRevert(BucketVaultBase.OwnerNotAccountable.selector);
            bucket.redeem(tooMuch);
        }
    }

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
        // User deposits so owner owns 0% -- below MIN_OWNER_BPS regardless of its current value
        vm.prank(user1);
        bucket.deposit{value: 100 ether}(address(0), 0);

        // Owner has 0 shares, not accountable
        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](1);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.expectRevert(BucketVaultBase.OwnerNotAccountable.selector);
        bucket.updateBucketDistributions(newDists);
    }

    function test_RevertUpdateDistributionsPlatformNotOperational() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucketInfo.setOperational(false);

        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](1);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.updateBucketDistributions(newDists);
    }

    function test_MaxValueLossBpsDefaultsToFiftyBpsWhenUnset() public view {
        // Zero means "use the hardcoded 0.5% default" — never zero itself.
        assertEq(bucket.maxValueLossBps(), 50);
    }

    function test_EpochValueLossBudgetBpsDefaultsToOneFiftyBpsWhenUnset() public view {
        // Zero means "use the hardcoded 1.5%/day default" — never zero itself.
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_SetMaxValueLossBpsUpdatesGetter() public {
        bucket.setMaxValueLossBps(300, 0); // 3% per-call, leave epoch budget at default
        assertEq(bucket.maxValueLossBps(), 300);
    }

    function test_SetMaxValueLossBpsUpdatesEpochBudgetGetter() public {
        bucket.setMaxValueLossBps(0, 700); // leave per-call at default, 7%/day epoch budget
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
        // Exactly 1000 bps (10%) is the ceiling, not an off-by-one boundary that reverts.
        bucket.setMaxValueLossBps(1000, 1000);
        assertEq(bucket.maxValueLossBps(), 1000);
        assertEq(bucket.epochValueLossBudgetBps(), 1000);
    }

    function test_RevertSetMaxValueLossBpsAboveCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.MaxValueLossBpsExceedsCeiling.selector, 1001));
        bucket.setMaxValueLossBps(1001, 0);
    }

    function test_RevertSetEpochValueLossBudgetBpsAboveCeiling() public {
        // The epoch budget field is checked against the same ceiling, independently of the
        // per-call field — a valid per-call value does not excuse an over-ceiling epoch budget.
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.MaxValueLossBpsExceedsCeiling.selector, 1001));
        bucket.setMaxValueLossBps(300, 1001);
    }

    function test_SetMaxValueLossBpsBackToZeroRestoresDefault() public {
        bucket.setMaxValueLossBps(1000, 1000);
        assertEq(bucket.maxValueLossBps(), 1000);
        assertEq(bucket.epochValueLossBudgetBps(), 1000);

        // Owner can lower it again, including back down to 0 (which re-resolves to each field's
        // own default rather than permanently sticking at whatever ceiling was last set) — and
        // the two fields restore independently, not jointly.
        bucket.setMaxValueLossBps(0, 0);
        assertEq(bucket.maxValueLossBps(), 50);
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_SetMaxValueLossBpsZeroRestoresOnlyThatFieldIndependently() public {
        bucket.setMaxValueLossBps(500, 700);

        // Restoring only the per-call bound to default must not disturb the epoch budget.
        bucket.setMaxValueLossBps(0, 700);
        assertEq(bucket.maxValueLossBps(), 50);
        assertEq(bucket.epochValueLossBudgetBps(), 700);

        // And vice versa: restoring only the epoch budget must not disturb the per-call bound.
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
        // onlyOwnerNotBlacklisted: the owner itself, if blacklisted, is locked out of its own
        // risk-tolerance control just like every other admin function on this base.
        bucketInfo.setBlacklisted(owner, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, owner));
        bucket.setMaxValueLossBps(300, 0);
    }

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

    function test_RevertUnpauseNotOwner() public {
        bucket.deposit{value: 10 ether}(address(0), 0);
        bucket.pause();

        vm.prank(user1);
        vm.expectRevert();
        bucket.unpause();
    }

    function test_UnpauseSucceedsWhenOwnerNotAccountable() public {
        bucket.deposit{value: 10 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());

        bucket.pause();
        assertTrue(bucket.paused());

        uint256 ownerShares = bucket.balanceOf(address(this));
        bucket.transfer(user1, ownerShares - (ownerShares / 1000));
        assertFalse(bucket.isBucketAccountable());

        bucket.unpause();
        assertFalse(bucket.paused());
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
        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.pauseSwap();
    }

    function test_RevertUnpauseSwapNotPaused() public {
        bucket.deposit{value: 10 ether}(address(0), 0);

        vm.expectRevert(BucketVaultBase.SwapNotPaused.selector);
        bucket.unpauseSwap();
    }

    function test_RecoverNonWhitelistedTokens() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        uint256 balBefore = rogue.balanceOf(user1);
        bucket.recoverTokens(address(rogue), 1000e18, user1);
        assertEq(rogue.balanceOf(user1), balBefore + 1000e18);
    }

    function test_RevertRecoverWhitelistedTokens() public {
        tokenA.mint(address(bucket), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.CannotRecoverWhitelistedToken.selector, address(tokenA)));
        bucket.recoverTokens(address(tokenA), 1000e18, user1);
    }

    function test_RevertRecoverNotOwner() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 100e18);

        vm.prank(user1);
        vm.expectRevert();
        bucket.recoverTokens(address(rogue), 100e18, user1);
    }

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

    function test_RevertRebalanceBy1inchNoShares() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InsufficientShares.selector);
        bucket.rebalanceBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertRebalanceBy1inchSwapPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        bucket.deposit{value: 10 ether}(address(0), 0); // owner for accountability

        bucket.pauseSwap();

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.rebalanceBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertRebalanceBy1inchPlatformPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        bucketInfo.setOperational(false);

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.rebalanceBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertRebalanceByDefiSwapPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        bucket.deposit{value: 10 ether}(address(0), 0); // owner

        bucket.pauseSwap();

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.rebalanceByDefi();
    }

    function test_SetWETH() public {
        address wethAddr = makeAddr("weth");
        bucket.setWETH(wethAddr);
        assertEq(bucket.weth(), wethAddr);
    }

    function test_RevertSetWETHZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.setWETH(address(0));
    }

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
        uint256 supply = bucket.totalSupply();
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.balanceOf(user1), 0);
        uint256 ethReceived = user1.balance - ethBefore;
        uint256 expected = (depositAmount * shares) / supply;
        assertApproxEqAbs(ethReceived, expected, 1);
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

        if (amount2 > 0 && shares2 > 0) {
            uint256 ratio1 = ((shares1 + bucket.DEAD_SHARES()) * 1e18) / shares2;
            uint256 ratio2 = (amount1 * 1e18) / amount2;
            assertApproxEqRel(ratio1, ratio2, 1e15);
        }
    }

    function test_ReceiveETH() public {
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        (bool success,) = address(bucket).call{value: 1 ether}("");
        assertTrue(success);
    }

    function test_UpdateBucketInfo() public {
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        bucket.executeUpdateBucketInfo();

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_UpdateBucketInfoFromBucketInfoOwner() public {
        bucketInfo.setOwner(user1);

        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        vm.prank(user1);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());

        bucket.executeUpdateBucketInfo();

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoUnauthorized() public {
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.UnauthorizedBucketInfoUpdate.selector);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.proposeUpdateBucketInfo(address(0));
    }

    function test_RevertExecuteUpdateBucketInfoBeforeTimelockElapsed() public {
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
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
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
        bucket.vetoUpdateBucketInfo();

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.executeUpdateBucketInfo();

        assertTrue(address(bucket.bucketInfo()) != address(newBucketInfo));
    }

    function test_RevertVetoUpdateBucketInfoByNonVaultOwner() public {
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.prank(user1);
        vm.expectRevert();
        bucket.vetoUpdateBucketInfo();
    }

    function test_InflationAttack_MitigatedByDeadShares() public {
        address attacker = makeAddr("attacker");
        tokenA.mint(attacker, 10_000e18);

        vm.startPrank(attacker);
        tokenA.approve(address(bucket), 0.0005005e18);
        bucket.deposit(address(tokenA), 0.0005005e18);
        vm.stopPrank();

        uint256 attackerShares = bucket.balanceOf(attacker);
        assertEq(attackerShares, 0.001e18, "attacker's real (post-carve-out) stake must be exactly 0.001e18");

        vm.prank(attacker);
        tokenA.transfer(address(bucket), 5_000e18);

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

    function _deployApprovedPassiveBucketImplementation() internal returns (address newImpl) {
        newImpl = address(new PassiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.PassiveBucket, newImpl);
    }

    function test_QueueUpgrade_SetsPendingAndEta() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();

        bucket.queueUpgrade(newImpl);

        assertEq(bucket.pendingImplementation(), newImpl);
        assertEq(bucket.upgradeEta(), block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());
    }

    function test_RevertQueueUpgradeNotOwner() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();

        vm.prank(user1);
        vm.expectRevert();
        bucket.queueUpgrade(newImpl);
    }

    function test_RevertQueueUpgradeZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.queueUpgrade(address(0));
    }

    function test_UpgradeSucceeds_AfterQueueApprovalAndElapsedDelay() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        bucket.upgradeToAndCall(newImpl, "");

        assertEq(bucket.pendingImplementation(), address(0));
        assertEq(bucket.upgradeEta(), 0);
    }

    function test_RevertUpgrade_BeforeTimelockElapsed() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        uint256 eta = bucket.upgradeEta();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NothingQueued() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();

        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ImplementationMismatch() public {
        address queuedImpl = _deployApprovedPassiveBucketImplementation();
        address otherImpl = _deployApprovedPassiveBucketImplementation();

        bucket.queueUpgrade(queuedImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(BucketVaultBase.UpgradeImplementationMismatch.selector, queuedImpl, otherImpl)
        );
        bucket.upgradeToAndCall(otherImpl, "");
    }

    function test_RevertUpgrade_RegistryApprovalRevokedMidWindow() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        registry.revoke(IImplementationRegistry.Kind.PassiveBucket, newImpl);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NeverApproved() public {
        address newImpl = address(new PassiveBucket(address(registry)));

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_ClearsPendingState() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();
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
        address newImpl = _deployApprovedPassiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        vm.prank(user1);
        vm.expectRevert();
        bucket.cancelUpgrade();
    }

    function test_RevertUpgrade_NotOwner() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();
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
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(oneInchRouter),
            "PassiveBucket Share",
            "pBKT"
        );
        registry.setAuthorizedFactory(user2, true);
        vm.prank(user2);
        ERC1967Proxy customerProxy = new ERC1967Proxy(address(implementation), initData);
        PassiveBucket customerBucket = PassiveBucket(payable(address(customerProxy)));
        assertEq(customerBucket.owner(), user2, "customerBucket must be owned by the customer, not the platform");

        address newImpl = address(new PassiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.PassiveBucket, newImpl);

        vm.expectRevert();
        customerBucket.queueUpgrade(newImpl);

        vm.prank(user2);
        customerBucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + customerBucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert();
        customerBucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ApprovedForWrongKind() public {
        address newImpl = address(new PassiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, newImpl);

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_UpgradeQueued_PlatformPauseDoesNotBlockIt() public {
        address newImpl = _deployApprovedPassiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        bucketInfo.setOperational(false);
        assertFalse(bucketInfo.isPlatformOperational());

        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        bucket.upgradeToAndCall(newImpl, "");
        assertEq(bucket.pendingImplementation(), address(0));
    }

    // Allow test contract (owner) to receive ETH from redeem
    receive() external payable {}
}
