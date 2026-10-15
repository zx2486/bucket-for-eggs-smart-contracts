// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// closed blocks the redemption). D2 accepts this consciously; INV-7 is the mitigation (the check

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {SeizureLib} from "../src/libraries/SeizureLib.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";

// ============================================================
// ============================================================

contract GateMockBucketInfo {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 0;
    address public owner;

    mapping(address => bool) public blacklisted;
    bool public blacklistCheckReverts;

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

    function tryGetTokenPrice(address token) external view returns (bool ok, uint256 price) {
        if (!whitelisted[token]) return (false, 0);
        return (true, prices[token]);
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
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

    function isBlacklisted(address account) external view returns (bool) {
        if (blacklistCheckReverts) revert("GateMockBucketInfo: isBlacklisted unreachable");
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function setBlacklistCheckReverts(bool status) external {
        blacklistCheckReverts = status;
    }

    receive() external payable {}
}

contract GateMockERC20 {
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

// ============================================================
// ============================================================

contract W4GateActiveBucketTest is Test {
    ActiveBucket public implementation;
    ActiveBucket public bucket;
    GateMockBucketInfo public bucketInfo;
    GateMockERC20 public token;

    address public depositor;
    address public user1;
    address public custody;

    uint256 constant TOKEN_PRICE = 1e8;
    uint256 constant SEED_DEPOSIT = 1_000_000e6;
    uint256 constant USER_DEPOSIT = 10_000e6;

    function setUp() public {
        depositor = address(this);
        user1 = makeAddr("user1");
        custody = makeAddr("custody");

        bucketInfo = new GateMockBucketInfo();
        token = new GateMockERC20("Token", "TKN", 6);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new ActiveBucket(address(registry));
        registry.setAuthorizedFactory(address(this), true);

        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), address(0xBEEF), "ActiveBucket Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = ActiveBucket(payable(address(proxy)));

        token.mint(depositor, SEED_DEPOSIT);
        token.mint(user1, USER_DEPOSIT);

        token.approve(address(bucket), SEED_DEPOSIT);
        bucket.deposit(address(token), SEED_DEPOSIT);
    }

    function test_G1_Blacklisted_CannotDeposit() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_G1_Blacklisted_CannotRedeem() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.redeem(shares);
    }

    function test_G1_Blacklisted_CannotTransferShares() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        vm.stopPrank();

        address user2 = makeAddr("user2");

        bucketInfo.setBlacklisted(user1, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.transfer(user2, shares / 2);
        bucketInfo.setBlacklisted(user1, false);

        bucketInfo.setBlacklisted(user2, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user2));
        bucket.transfer(user2, shares / 2);
    }

    function test_G2_Blacklisted_CannotSwapBy1inch() public {
        bucketInfo.setBlacklisted(depositor, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, depositor));
        bucket.swapBy1inch(address(token), address(token), 1, 0);
    }

    function test_G4_FailClosed_RevertingBucketInfo_BlocksDeposit() public {
        bucketInfo.setBlacklistCheckReverts(true);

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_G6_Blacklisted_CannotApprove() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.approve(custody, USER_DEPOSIT);

        assertEq(bucket.allowance(user1, custody), 0);
    }

    function test_G6_Blacklisted_SpenderCannotTransferFrom() public {
        address recipient = makeAddr("recipient");

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(custody, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(custody, true);

        vm.prank(custody);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, custody));
        bucket.transferFrom(user1, recipient, shares);

        assertEq(bucket.balanceOf(user1), shares);
        assertEq(bucket.allowance(user1, custody), shares);
    }

    function test_G6_Blacklisted_SpenderCannotBurnFrom() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(custody, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(custody, true);

        vm.prank(custody);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, custody));
        bucket.burnFrom(user1, shares);

        assertEq(bucket.balanceOf(user1), shares);
    }

    function test_G6_Blacklisted_OwnerCannotCallAdminFunction() public {
        bucketInfo.setBlacklisted(depositor, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, depositor));
        bucket.pause();

        assertFalse(bucket.paused());
    }
}

// ============================================================
// ============================================================

contract W4GatePassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    GateMockBucketInfo public bucketInfo;
    GateMockERC20 public token;

    address public depositor;
    address public user1;
    address public user2;
    address public custody;

    uint256 constant TOKEN_PRICE = 1e8;
    uint256 constant SEED_DEPOSIT = 1_000_000e6;
    uint256 constant USER_DEPOSIT = 10_000e6;
    bytes32 constant COURT_ORDER_HASH = keccak256("case-2026-W4-001");

    function setUp() public {
        depositor = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        custody = makeAddr("custody");

        bucketInfo = new GateMockBucketInfo();
        token = new GateMockERC20("Token", "TKN", 6);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new PassiveBucket(address(registry));
        registry.setAuthorizedFactory(address(this), true);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(token), 100);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(0xBEEF),
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        token.mint(depositor, SEED_DEPOSIT);
        token.mint(user1, USER_DEPOSIT);
        token.mint(user2, USER_DEPOSIT);

        token.approve(address(bucket), SEED_DEPOSIT);
        bucket.deposit(address(token), SEED_DEPOSIT);
    }

    function test_G1_Blacklisted_CannotDeposit() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_G1_Blacklisted_CannotRedeem() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.redeem(shares);
    }

    function test_G2_Blacklisted_CannotRebalanceByDefi() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.rebalanceByDefi();
    }

    function test_G2_Blacklisted_CannotRebalanceBy1inch() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.rebalanceBy1inch(address(token), address(token), 1, 0);
    }

    function test_G4_FailClosed_RevertingBucketInfo_BlocksRedeem() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklistCheckReverts(true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.redeem(shares);
    }

    // --------------------------------------------------------------
    // --------------------------------------------------------------

    function _blacklistAndDeposit(address user) internal returns (uint256 shares) {
        vm.startPrank(user);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        shares = bucket.balanceOf(user);
        vm.stopPrank();
        bucketInfo.setBlacklisted(user, true);
    }

    function test_G5_Seizure_MovesBalanceAndEmitsDocumentHashAndBalances() public {
        uint256 shares = _blacklistAndDeposit(user1);

        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (address pendingTo, bytes32 pendingHash, uint256 eta) = bucket.pendingSeizure(user1);
        assertEq(pendingTo, custody);
        assertEq(pendingHash, COURT_ORDER_HASH);
        assertGt(eta, block.timestamp);

        vm.warp(eta);

        vm.expectEmit(true, true, false, true, address(bucket));
        emit SeizureLib.SeizureExecuted(user1, custody, COURT_ORDER_HASH, shares, 0);
        bucket.executeSeizure(user1);

        assertEq(bucket.balanceOf(user1), 0);
        assertEq(bucket.balanceOf(custody), shares);
    }

    function test_G5_Seizure_RespectsTimelock() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.executeSeizure(user1);
    }

    function test_G5_Seizure_RevertsIfNotConfirmedBlacklistedAtExecution() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        bucketInfo.setBlacklisted(user1, false);
        vm.warp(eta);

        vm.expectRevert(abi.encodeWithSelector(SeizureLib.NotBlacklisted.selector, user1));
        bucket.executeSeizure(user1);

        assertEq(bucket.balanceOf(custody), 0);
    }

    function test_G5_Seizure_AbortsIfBucketInfoUnreachableAtExecution_ReversedFailClosed() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        bucketInfo.setBlacklistCheckReverts(true);
        vm.warp(eta);

        vm.expectRevert(abi.encodeWithSelector(SeizureLib.BucketInfoUnreachableForSeizure.selector, user1));
        bucket.executeSeizure(user1);

        assertEq(bucket.balanceOf(custody), 0);
        bucketInfo.setBlacklistCheckReverts(false);
        (,, uint256 stillPendingEta) = bucket.pendingSeizure(user1);
        assertEq(stillPendingEta, eta);
    }

    function test_G5_Seizure_RevertsIfDestinationBlacklistedAtExecution() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        bucketInfo.setBlacklisted(custody, true);
        vm.warp(eta);

        vm.expectRevert(abi.encodeWithSelector(SeizureLib.Blacklisted.selector, custody));
        bucket.executeSeizure(user1);
    }

    function test_G5_Seizure_ProposeAndCancel_ArePlatformOwnerGated() public {
        _blacklistAndDeposit(user1);

        vm.prank(user1);
        vm.expectRevert(SeizureLib.UnauthorizedSeizure.selector);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);

        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);

        vm.prank(user1);
        vm.expectRevert(SeizureLib.UnauthorizedSeizure.selector);
        bucket.cancelSeizure(user1);
    }

    function test_G6_Blacklisted_CannotApprove() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.approve(custody, USER_DEPOSIT);

        assertEq(bucket.allowance(user1, custody), 0);
    }

    function test_G6_Blacklisted_SpenderCannotTransferFrom() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(user2, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user2, true);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user2));
        bucket.transferFrom(user1, custody, shares);

        assertEq(bucket.balanceOf(user1), shares);
        assertEq(bucket.allowance(user1, user2), shares);
    }

    function test_G6_Blacklisted_SpenderCannotBurnFrom() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(user2, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user2, true);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user2));
        bucket.burnFrom(user1, shares);

        assertEq(bucket.balanceOf(user1), shares);
    }

    function test_G6_Blacklisted_OwnerCannotCallAdminFunction() public {
        bucket.pause();
        bucketInfo.setBlacklisted(depositor, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, depositor));
        bucket.unpause();

        assertTrue(bucket.paused());
    }
}

// ============================================================
// ============================================================

contract W4GatePureMembershipTest is Test {
    PureMembership public implementation;
    PureMembership public membership;
    GateMockBucketInfo public bucketInfo;
    GateMockERC20 public payToken;
    ImplementationRegistry public registry;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant PAY_TOKEN_PRICE = 1e8; // $1 USD

    uint256 constant BASIC_ID = 1;
    uint256 constant BASIC_LEVEL = 1;
    uint256 constant BASIC_PRICE = 10e8; // $10 USD
    uint256 constant BASIC_DURATION = 30 days;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        bucketInfo = new GateMockBucketInfo();
        payToken = new GateMockERC20("USD Coin", "USDC", 6);
        bucketInfo.addToken(address(payToken), PAY_TOKEN_PRICE);

        registry = new ImplementationRegistry(owner);
        implementation = new PureMembership(address(registry));
        registry.setAuthorizedFactory(address(this), true);

        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](1);
        configs[0] = PureMembership.MembershipConfig(BASIC_ID, BASIC_LEVEL, "Basic", BASIC_PRICE, BASIC_DURATION);

        bytes memory initData =
            abi.encodeWithSelector(PureMembership.initialize.selector, configs, address(bucketInfo), "");
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        membership = PureMembership(payable(address(proxy)));

        payToken.mint(user1, 100_000e6);
        payToken.mint(user2, 100_000e6);
    }

    function test_G1_Blacklisted_CannotBuyNewMembership() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, user1));
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();
    }

    function test_G1_Blacklisted_CannotRenewMembership() public {
        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, user1));
        membership.buyMembership(BASIC_ID, address(payToken), 0);
    }

    function test_G3_Soulbound_BlocksHolderToHolderTransfer_RegardlessOfBlacklist() public {
        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        assertFalse(bucketInfo.blacklisted(user1));
        assertFalse(bucketInfo.blacklisted(user2));

        vm.prank(user1);
        vm.expectRevert(PureMembership.MembershipNotTransferable.selector);
        membership.safeTransferFrom(user1, user2, BASIC_ID, 1, "");
    }

    function test_G3_Soulbound_StillGovernsEvenWhenAlsoBlacklisted() public {
        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user2, true);

        vm.prank(user1);
        vm.expectRevert(PureMembership.MembershipNotTransferable.selector);
        membership.safeTransferFrom(user1, user2, BASIC_ID, 1, "");
    }

    function test_G4_FailClosed_RevertingBucketInfo_BlocksBuyMembership() public {
        bucketInfo.setBlacklistCheckReverts(true);

        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, user1));
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();
    }

    function test_G6_Blacklisted_OwnerCannotCallAdminFunction() public {
        bucketInfo.setBlacklisted(owner, true);

        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, owner));
        membership.pause();

        assertFalse(membership.paused());
    }
}
