// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {BucketInfo} from "../src/BucketInfo.sol";

contract MockBucketInfoRFS {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
    address public owner;

    constructor() {
        owner = msg.sender;
    }

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

    function tryGetTokenPrice(address token) external view returns (bool, uint256) {
        if (!whitelisted[token]) return (false, 0);
        return (true, prices[token]);
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

contract MockERC20RFS {
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

contract FairValueOneInchRouter {
    mapping(address => uint256) public price; // 8-decimal USD price; address(0) = native ETH
    mapping(address => uint8) public tokenDecimals;

    function setPrice(address token, uint256 price_, uint8 decimals_) external {
        price[token] = price_;
        tokenDecimals[token] = decimals_;
    }

    function execute1inchSwap(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 amount,
        uint256 minReturn
    ) external payable returns (uint256 amountOut) {
        if (srcToken == address(0)) {
            require(msg.value == amount, "router: bad native value");
        } else {
            MockERC20RFS(srcToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 srcPrice = price[srcToken];
        uint256 dstPrice = price[dstToken];
        require(srcPrice > 0 && dstPrice > 0, "router: no price set");
        uint8 srcDec = tokenDecimals[srcToken];
        uint8 dstDec = tokenDecimals[dstToken];

        amountOut = (amount * srcPrice * (10 ** dstDec)) / ((10 ** srcDec) * dstPrice);
        require(amountOut >= minReturn, "router: below minReturn");

        if (dstToken == address(0)) {
            (bool ok,) = dstReceiver.call{value: amountOut}("");
            require(ok, "router: ETH send failed");
        } else {
            require(MockERC20RFS(dstToken).transfer(dstReceiver, amountOut), "router: transfer failed");
        }
    }

    receive() external payable {}
}

contract RedeemForStableTest is Test {
    BucketInfo public feeBucketInfo;
    MockBucketInfoRFS public bucketInfo;
    MockERC20RFS public tokenA; // 18 decimals — "volatile" basket asset
    MockERC20RFS public stable; // 6 decimals — redemption target
    FairValueOneInchRouter public router;
    ImplementationRegistry public registry;

    PassiveBucket public passiveImpl;
    PassiveBucket public passive;
    ActiveBucket public activeImpl;
    ActiveBucket public active;

    address public owner;
    address public user1;

    receive() external payable {}

    uint256 constant ETH_PRICE = 2000e8; // $2000, 8-decimal USD
    uint256 constant TOKEN_A_PRICE = 50e8; // $50
    uint256 constant STABLE_PRICE = 1e8; // $1

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        vm.deal(owner, 1000 ether);
        vm.deal(user1, 1000 ether);

        bucketInfo = new MockBucketInfoRFS();
        feeBucketInfo = new BucketInfo();
        tokenA = new MockERC20RFS("Token A", "TKA", 18);
        stable = new MockERC20RFS("Stable", "STB", 6);
        router = new FairValueOneInchRouter();

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(stable), STABLE_PRICE);

        router.setPrice(address(0), ETH_PRICE, 18);
        router.setPrice(address(tokenA), TOKEN_A_PRICE, 18);
        router.setPrice(address(stable), STABLE_PRICE, 6);

        registry = new ImplementationRegistry(owner);
        registry.setAuthorizedFactory(address(this), true);
    }

    function _deployPassive() internal {
        passiveImpl = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(stable), 20);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(router), "Passive Share", "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(passiveImpl), initData);
        passive = PassiveBucket(payable(address(proxy)));
    }

    function _deployActive() internal {
        activeImpl = new ActiveBucket(address(registry));
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), address(router), "Active Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(activeImpl), initData);
        active = ActiveBucket(payable(address(proxy)));
    }

    function _deployFeeWithdrawalPassive() internal returns (PassiveBucket bucket) {
        PassiveBucket implementation = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(stable), 50);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(router), "Fee Share", "fBKT"
        );
        bucket = PassiveBucket(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _depositAndTransferSharesToBucketInfo(PassiveBucket bucket, uint256 ethAmount, uint256 stableAmount)
        internal
        returns (uint256 shares)
    {
        stable.mint(user1, stableAmount);
        vm.startPrank(user1);
        if (ethAmount > 0) bucket.deposit{value: ethAmount}(address(0), 0);
        if (stableAmount > 0) {
            stable.approve(address(bucket), stableAmount);
            bucket.deposit(address(stable), stableAmount);
        }
        vm.stopPrank();

        shares = bucket.balanceOf(user1);
        vm.prank(user1);
        bucket.transfer(address(feeBucketInfo), shares);
    }

    function _setUpFeeWithdrawalPrices() internal {
        feeBucketInfo.proposeWhitelistAddition(address(stable));
        vm.warp(block.timestamp + feeBucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        feeBucketInfo.executeWhitelistAddition(address(stable));
        router.setPrice(address(feeBucketInfo), 1e8, 18);
        router.setPrice(address(stable), STABLE_PRICE, 6);
        stable.mint(address(router), 1_000_000e6);
    }

    function test_RedeemForStable_MultiLegRedemption_Success() public {
        _deployPassive();
        stable.mint(address(router), 1_000_000e6);

        stable.mint(user1, 100_000e6);
        vm.startPrank(user1);
        passive.deposit{value: 10 ether}(address(0), 0);
        stable.approve(address(passive), 20_000e6);
        passive.deposit(address(stable), 20_000e6);
        vm.stopPrank();

        uint256 shares = passive.balanceOf(user1);
        uint256 supply = passive.totalSupply();

        uint256 ethAmount = (address(passive).balance * shares) / supply;
        uint256 stableAmount = (stable.balanceOf(address(passive)) * shares) / supply;

        uint256 ethLegOut = (ethAmount * ETH_PRICE * (10 ** 6)) / ((10 ** 18) * STABLE_PRICE);
        uint256 expectedTotal = stableAmount + ethLegOut;

        uint256 stableBefore = stable.balanceOf(user1);

        vm.prank(user1);
        uint256 totalStableOut = passive.redeemForStable(shares, address(stable), 50);

        assertEq(totalStableOut, expectedTotal, "returned total must match independent fair-value computation");
        assertEq(stable.balanceOf(user1) - stableBefore, expectedTotal, "actual transfer must match returned total");
        assertEq(passive.balanceOf(user1), 0, "all redeemed shares must be burned");
    }

    function test_WithdrawAccumulatedFeesToStable_RedeemsAndTransfers() public {
        _setUpFeeWithdrawalPrices();
        PassiveBucket bucket = _deployFeeWithdrawalPassive();
        uint256 shares = _depositAndTransferSharesToBucketInfo(bucket, 1 ether, 2_000e6);
        address[] memory vaults = new address[](1);
        vaults[0] = address(bucket);

        uint256 stableBefore = stable.balanceOf(user1);
        vm.expectEmit(true, true, false, true, address(feeBucketInfo));
        emit BucketInfo.FeesWithdrawn(address(stable), user1, 3_999e6);
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);

        assertEq(stable.balanceOf(user1) - stableBefore, 3_999e6);
        assertEq(bucket.balanceOf(address(feeBucketInfo)), 0);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(bucket)), shares);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(stable)), 0);
    }

    function test_WithdrawAccumulatedFeesToStable_SkipsVaultWithoutShares() public {
        _setUpFeeWithdrawalPrices();
        PassiveBucket emptyBucket = _deployFeeWithdrawalPassive();
        PassiveBucket fundedBucket = _deployFeeWithdrawalPassive();
        uint256 shares = _depositAndTransferSharesToBucketInfo(fundedBucket, 1 ether, 2_000e6);
        address[] memory vaults = new address[](2);
        vaults[0] = address(emptyBucket);
        vaults[1] = address(fundedBucket);

        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);

        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(emptyBucket)), 0);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(fundedBucket)), shares);
        assertEq(stable.balanceOf(user1), 3_999e6);
    }

    function test_WithdrawAccumulatedFeesToStable_RevertsWhenNoSharesToRedeem() public {
        _setUpFeeWithdrawalPrices();
        PassiveBucket emptyBucket = _deployFeeWithdrawalPassive();
        address[] memory vaults = new address[](1);
        vaults[0] = address(emptyBucket);

        vm.expectRevert(bytes("No fees to withdraw"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);
    }

    function test_WithdrawAccumulatedFeesToStable_RevertsForNonOwner() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(0xBEEF);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);
    }

    function test_WithdrawAccumulatedFeesToStable_RejectsInvalidArguments() public {
        _setUpFeeWithdrawalPrices();
        address[] memory noVaults = new address[](0);
        vm.expectRevert(bytes("Invalid recipient"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(address(0), noVaults, address(stable), 50);

        vm.expectRevert(bytes("No tokens specified"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, noVaults, address(stable), 50);

        address[] memory vaults = new address[](1);
        vaults[0] = address(0xBEEF);
        vm.expectRevert(bytes("Invalid destination token"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(0), 50);

        vm.expectRevert(bytes("Destination token not whitelisted"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, user1, 50);

        vm.expectRevert(bytes("Invalid max slippage"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 0);
    }

    function test_WithdrawAccumulatedFeesToStable_FailedVaultRedemptionIsAtomic() public {
        PassiveBucket bucket = _deployFeeWithdrawalPassive();
        uint256 shares = _depositAndTransferSharesToBucketInfo(bucket, 1 ether, 2_000e6);
        address[] memory vaults = new address[](1);
        vaults[0] = address(bucket);
        uint256 stableBefore = stable.balanceOf(user1);

        vm.expectRevert();
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);

        assertEq(bucket.balanceOf(address(feeBucketInfo)), shares);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(bucket)), 0);
        assertEq(stable.balanceOf(user1), stableBefore);
    }

    function test_RedeemForStable_RevertsIfDstTokenNotWhitelisted() public {
        _deployPassive();

        vm.prank(user1);
        passive.deposit{value: 1 ether}(address(0), 0);

        address notWhitelisted = address(0xBEEF);
        uint256 shares = passive.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, notWhitelisted));
        passive.redeemForStable(shares, notWhitelisted, 100);
    }

    function test_RedeemForStable_DstTokenWhitelistPrecondition_ActiveBucket() public {
        _deployActive();

        vm.prank(user1);
        active.deposit{value: 1 ether}(address(0), 0);

        address notWhitelisted = address(0xBEEF);
        uint256 shares = active.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, notWhitelisted));
        active.redeemForStable(shares, notWhitelisted, 100);
    }

    function test_RedeemForStable_TighterSlippage_Succeeds() public {
        _deployPassive();
        stable.mint(address(router), 1_000_000e6);

        vm.prank(user1);
        passive.deposit{value: 5 ether}(address(0), 0);

        uint256 shares = passive.balanceOf(user1);
        uint256 supply = passive.totalSupply();
        uint256 ethAmount = (address(passive).balance * shares) / supply;
        uint256 expectedOut = (ethAmount * ETH_PRICE * (10 ** 6)) / ((10 ** 18) * STABLE_PRICE);

        vm.prank(user1);
        uint256 totalStableOut = passive.redeemForStable(shares, address(stable), 10);

        assertEq(totalStableOut, expectedOut, "tighter-than-floor tolerance must still succeed at fair value");
    }

    function test_RedeemForStable_LooserSlippageThanPlatformFloor_Reverts() public {
        _deployPassive();

        vm.prank(user1);
        passive.deposit{value: 5 ether}(address(0), 0);

        uint256 shares = passive.balanceOf(user1);

        vm.prank(user1);
        vm.expectPartialRevert(BucketVaultBase.MinReturnBelowFloor.selector);
        passive.redeemForStable(shares, address(stable), 500);
    }

    function test_RedeemForStable_RevertsNotPartialFill_WhenLegSwapFails() public {
        _deployPassive();

        tokenA.mint(user1, 100e18);
        vm.startPrank(user1);
        passive.deposit{value: 5 ether}(address(0), 0);
        tokenA.approve(address(passive), 20e18);
        passive.deposit(address(tokenA), 20e18);
        vm.stopPrank();

        uint256 sharesBefore = passive.balanceOf(user1);
        uint256 ethBefore = address(passive).balance;
        uint256 tokenABefore = tokenA.balanceOf(address(passive));

        vm.prank(user1);
        vm.expectRevert();
        passive.redeemForStable(sharesBefore, address(stable), 100);

        assertEq(passive.balanceOf(user1), sharesBefore, "shares must not be burned on a failed leg");
        assertEq(address(passive).balance, ethBefore, "ETH balance must be unchanged after revert");
        assertEq(tokenA.balanceOf(address(passive)), tokenABefore, "tokenA balance must be unchanged after revert");
    }

    function test_RedeemForStable_OwnerAccountabilityParity_PassiveBucket() public {
        _deployPassive();

        passive.deposit{value: 10 ether}(address(0), 0);
        vm.prank(user1);
        passive.deposit{value: 100 ether}(address(0), 0);

        uint256 minOwnerBps = passive.MIN_OWNER_BPS();
        uint256 bpsDenom = passive.BPS_DENOMINATOR();

        uint256 ownerShares = passive.balanceOf(owner);

        uint256 smallRedeem = ownerShares / 4;
        passive.redeemForStable(smallRedeem, address(0), 100);
        assertTrue(passive.isBucketAccountable(), "owner should still be accountable after small redeem");

        vm.warp(block.timestamp + 5 minutes + 1);

        uint256 remainingOwner = passive.balanceOf(owner);
        uint256 newSupply = passive.totalSupply();
        uint256 threshold = ((remainingOwner * bpsDenom) - (newSupply * minOwnerBps)) / (bpsDenom - minOwnerBps);
        uint256 tooMuch = threshold + 1e18;

        if (tooMuch <= remainingOwner) {
            vm.expectRevert(BucketVaultBase.OwnerNotAccountable.selector);
            passive.redeemForStable(tooMuch, address(0), 100);
        }
    }

    function test_RedeemForStable_OwnerAccountabilityNowApplies_ActiveBucket() public {
        _deployActive();

        active.deposit{value: 10 ether}(address(0), 0);
        vm.prank(user1);
        active.deposit{value: 100 ether}(address(0), 0);

        uint256 minOwnerBps = active.MIN_OWNER_BPS();
        uint256 bpsDenom = active.BPS_DENOMINATOR();

        uint256 ownerShares = active.balanceOf(owner);

        uint256 smallRedeem = ownerShares / 4;
        active.redeemForStable(smallRedeem, address(0), 100);
        assertTrue(active.isBucketAccountable(), "owner should still be accountable after small redeem");

        vm.warp(block.timestamp + 5 minutes + 1);

        uint256 remainingOwner = active.balanceOf(owner);
        uint256 newSupply = active.totalSupply();
        uint256 threshold = ((remainingOwner * bpsDenom) - (newSupply * minOwnerBps)) / (bpsDenom - minOwnerBps);
        uint256 tooMuch = threshold + 1e18;

        if (tooMuch <= remainingOwner) {
            vm.expectRevert(BucketVaultBase.OwnerNotAccountable.selector);
            active.redeemForStable(tooMuch, address(0), 100);
        }
    }
}
