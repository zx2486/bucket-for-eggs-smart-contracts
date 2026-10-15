// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PotentialRugpull} from "../src/PotentialRugpull.sol";
import {PotentialRugpullFactory} from "../src/PotentialRugpullFactory.sol";
import {SeizureLib} from "../src/libraries/SeizureLib.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";

contract MockBucketInfoForRugpull {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    mapping(address => bool) public priceFeedSet;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100;
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

    function getPriceFeed(address token) external view returns (address) {
        return priceFeedSet[token] ? address(0xFEED) : address(0);
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

    function isBlacklisted(address account) external view returns (bool) {
        if (blacklistCheckReverts) revert("MockBucketInfoForRugpull: isBlacklisted unreachable");
        return blacklisted[account];
    }

    function addToken(address token, uint256 price) external {
        if (!whitelisted[token]) {
            whitelisted[token] = true;
            whitelistedList.push(token);
        }
        prices[token] = price;
        priceFeedSet[token] = true;
    }

    function setHasPriceFeed(address token, bool hasFeed) external {
        priceFeedSet[token] = hasFeed;
    }

    function setOperational(bool _operational) external {
        operational = _operational;
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function setBlacklistCheckReverts(bool status) external {
        blacklistCheckReverts = status;
    }

    receive() external payable {}
}

contract RugpullMockERC20 {
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

contract PotentialRugpullTest is Test {
    PotentialRugpullFactory public factory;
    MockBucketInfoForRugpull public bucketInfo;
    RugpullMockERC20 public token;

    address public ownerAddr;
    address public user1;
    address public user2;
    address public custody;

    uint256 constant TOKEN_PRICE = 1e8; // $1, 8 decimals
    uint256 constant CASH_RATIO = 50;
    uint256 constant USER_DEPOSIT = 1_000e18; // 1000 tokens @ $1 = $1000 USD8
    bytes32 constant COURT_ORDER_HASH = keccak256("court-order");

    PotentialRugpull public rugpull;

    function setUp() public {
        ownerAddr = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        custody = makeAddr("custody");

        bucketInfo = new MockBucketInfoForRugpull();
        token = new RugpullMockERC20("Token", "TKN", 18);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        token.mint(ownerAddr, 1_000_000e18);
        token.mint(user1, 1_000_000e18);
        token.mint(user2, 1_000_000e18);

        factory = new PotentialRugpullFactory(address(bucketInfo));

        address instance = factory.createPotentialRugpull(CASH_RATIO, "Rugpull Share", "RUG");
        rugpull = PotentialRugpull(payable(instance));
    }

    function test_Initialize_WiresFactoryOwnerAndDefaults() public view {
        assertEq(address(rugpull.bucketInfo()), address(bucketInfo));
        assertEq(rugpull.owner(), ownerAddr);
        assertEq(rugpull.totalSupply(), 1e18);
        assertEq(rugpull.balanceOf(ownerAddr), 1e18);
        assertEq(rugpull.assertedPortfolioValue(), 1e8);
        assertEq(rugpull.name(), "Rugpull Share");
        assertEq(rugpull.symbol(), "RUG");
        assertEq(rugpull.cashRatio(), CASH_RATIO);
        assertEq(rugpull.FACTORY(), address(factory));
        assertTrue(rugpull.initialized());
    }

    function test_Initialize_RevertsIfCalledTwice() public {
        vm.prank(address(factory));
        vm.expectRevert(PotentialRugpull.AlreadyInitialized.selector);
        rugpull.initialize(address(bucketInfo), ownerAddr, "x", "y");
    }

    function test_Initialize_OnlyFactoryCanCall() public {
        PotentialRugpull fresh = new PotentialRugpull(CASH_RATIO);
        vm.prank(user1);
        vm.expectRevert(PotentialRugpull.OnlyFactory.selector);
        fresh.initialize(address(bucketInfo), user1, "x", "y");
    }

    function test_Initialize_MintsToRealOwnerNeverToFactory() public view {
        assertEq(rugpull.balanceOf(address(factory)), 0);
        assertEq(rugpull.balanceOf(ownerAddr), 1e18);
    }

    function test_Constructor_RevertsBelowMinCashRatio() public {
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.InvalidCashRatio.selector, 9));
        new PotentialRugpull(9);
    }

    function test_Constructor_RevertsAboveMaxCashRatio() public {
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.InvalidCashRatio.selector, 91));
        new PotentialRugpull(91);
    }

    function test_Constructor_AcceptsBoundaryValues() public {
        PotentialRugpull low = new PotentialRugpull(10);
        PotentialRugpull high = new PotentialRugpull(90);
        assertEq(low.cashRatio(), 10);
        assertEq(high.cashRatio(), 90);
    }

    function test_Deposit_MintsSharesAndIncrementsLedger() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 expectedValueUsd8 = 1_000e8;
        assertEq(rugpull.netInvestorDeposits(), expectedValueUsd8);
        assertGt(rugpull.balanceOf(user1), 0);
    }

    function test_Deposit_RevertsOnManuallyPricedToken() public {
        bucketInfo.setHasPriceFeed(address(token), false);
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.InvalidToken.selector, address(token)));
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_Deposit_RevertsOnZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(PotentialRugpull.ZeroAmount.selector);
        rugpull.deposit(address(token), 0);
    }

    function test_Deposit_RevertsWhenPlatformNotOperational() public {
        bucketInfo.setOperational(false);
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(PotentialRugpull.PlatformNotOperational.selector);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_OwnerDeposit_DoesNotMintSharesOrTouchLedger() public {
        uint256 supplyBefore = rugpull.totalSupply();
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.ownerDeposit(address(token), USER_DEPOSIT);

        assertEq(rugpull.totalSupply(), supplyBefore);
        assertEq(rugpull.netInvestorDeposits(), 0);
        assertEq(token.balanceOf(address(rugpull)), USER_DEPOSIT);
    }

    function test_OwnerDeposit_RevertsForNonOwner() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        rugpull.ownerDeposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_Redeem_FullExit_DrainsLedgerToZero() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        assertGt(rugpull.netInvestorDeposits(), 0);

        vm.prank(user1);
        rugpull.redeem(shares);

        assertEq(rugpull.netInvestorDeposits(), 0);
        assertEq(rugpull.balanceOf(user1), 0);
        assertGt(token.balanceOf(user1), 1_000_000e18 - USER_DEPOSIT);
    }

    function test_Redeem_PartialExit_DrainsLedgerProportionally() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        uint256 ledgerBefore = rugpull.netInvestorDeposits();

        vm.prank(user1);
        rugpull.redeem(shares / 2);

        uint256 ledgerAfter = rugpull.netInvestorDeposits();
        assertApproxEqAbs(ledgerAfter, ledgerBefore / 2, 1);
        assertGt(ledgerAfter, 0);
    }

    function test_Redeem_OwnerRedeemingOwnShares_DoesNotTouchLedger() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 ledgerBefore = rugpull.netInvestorDeposits();
        uint256 ownerShares = rugpull.balanceOf(ownerAddr);

        rugpull.redeem(ownerShares);

        assertEq(rugpull.netInvestorDeposits(), ledgerBefore);
    }

    function test_Redeem_RevertsOnInsufficientShares() public {
        vm.prank(user1);
        vm.expectRevert(PotentialRugpull.InsufficientShares.selector);
        rugpull.redeem(1);
    }

    function test_Redeem_RevertsOnZeroShares() public {
        vm.expectRevert(PotentialRugpull.ZeroAmount.selector);
        rugpull.redeem(0);
    }

    function test_OwnerWithdraw_RevertsWhenBreachingFloor() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertEq(required, 500e8);

        uint256 tooMuch = 600e18;
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 400e8, 500e8));
        rugpull.ownerWithdraw(address(token), tooMuch);
    }

    function test_OwnerWithdraw_SucceedsAtExactFloor() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 ledgerBefore = rugpull.netInvestorDeposits();

        rugpull.ownerWithdraw(address(token), 500e18);

        assertEq(rugpull.netInvestorDeposits(), ledgerBefore);
        assertEq(rugpull.ownerWithdrawnValueUsd8(), 500e8);
    }

    function test_OwnerWithdraw_SucceedsWithinFloorAndTracksOwnerWithdrawnLedger() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 depositLedgerBefore = rugpull.netInvestorDeposits();
        uint256 withdrawnLedgerBefore = rugpull.ownerWithdrawnValueUsd8();
        rugpull.ownerWithdraw(address(token), 100e18);
        assertEq(rugpull.netInvestorDeposits(), depositLedgerBefore);
        assertEq(rugpull.ownerWithdrawnValueUsd8(), withdrawnLedgerBefore + 100e8);
        assertEq(token.balanceOf(ownerAddr) > 0, true);
    }

    function test_OwnerWithdraw_RevertsForNonOwner() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        rugpull.ownerWithdraw(address(token), 1e18);
    }

    function test_W5R1_NoLockout_FloorRelaxesAfterInvestorExit() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 400e8, 500e8));
        rugpull.ownerWithdraw(address(token), 600e18);

        vm.prank(user1);
        rugpull.redeem(shares);

        assertEq(rugpull.netInvestorDeposits(), 0);
        assertEq(rugpull.ownerWithdrawalFloorRequired(), 0.5e8);

        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 0, 0.5e8));
        rugpull.ownerWithdraw(address(token), 1e14);
    }

    function test_W5R1_NoLockout_FloorRelaxesProportionallyOnPartialExit() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        uint256 requiredBefore = rugpull.ownerWithdrawalFloorRequired();

        vm.prank(user1);
        rugpull.redeem(shares / 2);

        uint256 requiredAfter = rugpull.ownerWithdrawalFloorRequired();
        assertLt(requiredAfter, requiredBefore);
    }

    function test_OwnerWithdraw_RevertsWhenNoInvestorCushionYet_EdgeCase() public {
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.ownerDeposit(address(token), USER_DEPOSIT);

        assertEq(rugpull.netInvestorDeposits(), 0);
        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertGt(required, 0);

        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 0, required));
        rugpull.ownerWithdraw(address(token), 1e18);
    }

    function test_SetAssertedPortfolioValue_UpdatesAndEmits() public {
        vm.expectEmit(true, true, true, true, address(rugpull));
        emit PotentialRugpull.AssertedPortfolioValueUpdated(1e8, 5e8);
        rugpull.setAssertedPortfolioValue(5e8);
        assertEq(rugpull.assertedPortfolioValue(), 5e8);
    }

    function test_SetAssertedPortfolioValue_RevertsOnZero() public {
        vm.expectRevert(PotentialRugpull.ZeroPortfolioValue.selector);
        rugpull.setAssertedPortfolioValue(0);
    }

    function test_SetAssertedPortfolioValue_RevertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        rugpull.setAssertedPortfolioValue(5e8);
    }

    function test_Blacklisted_CannotDeposit() public {
        bucketInfo.setBlacklisted(user1, true);
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.Blacklisted.selector, user1));
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_Blacklisted_CannotRedeem() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.Blacklisted.selector, user1));
        rugpull.redeem(shares);
    }

    function test_Blacklisted_CannotTransferShares() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.Blacklisted.selector, user1));
        rugpull.transfer(user2, shares / 2);
    }

    function test_FailClosed_RevertingBucketInfo_BlocksDeposit() public {
        bucketInfo.setBlacklistCheckReverts(true);
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.Blacklisted.selector, user1));
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    function test_Seizure_MovesBalanceAndEmitsDocumentHashAndBalances() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        rugpull.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (address pendingTo, bytes32 pendingHash, uint256 eta) = rugpull.pendingSeizure(user1);
        assertEq(pendingTo, custody);
        assertEq(pendingHash, COURT_ORDER_HASH);
        assertGt(eta, block.timestamp);

        vm.warp(eta);

        vm.expectEmit(true, true, false, true, address(rugpull));
        emit SeizureLib.SeizureExecuted(user1, custody, COURT_ORDER_HASH, shares, 0);
        rugpull.executeSeizure(user1);

        assertEq(rugpull.balanceOf(user1), 0);
        assertEq(rugpull.balanceOf(custody), shares);
    }

    function test_Seizure_RespectsTimelock() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
        bucketInfo.setBlacklisted(user1, true);

        rugpull.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = rugpull.pendingSeizure(user1);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        rugpull.executeSeizure(user1);
    }

    function test_Seizure_ProposeAndCancel_ArePlatformOwnerGated() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(SeizureLib.UnauthorizedSeizure.selector);
        rugpull.proposeSeizure(user1, custody, COURT_ORDER_HASH);

        rugpull.proposeSeizure(user1, custody, COURT_ORDER_HASH);

        vm.prank(user1);
        vm.expectRevert(SeizureLib.UnauthorizedSeizure.selector);
        rugpull.cancelSeizure(user1);
    }

    function test_RenounceOwnership_AlwaysReverts() public {
        vm.expectRevert(PotentialRugpull.RenounceOwnershipDisabled.selector);
        rugpull.renounceOwnership();
    }

    function test_NameSymbol_PerInstanceOverride() public {
        address instance2 = factory.createPotentialRugpull(20, "Second Rugpull", "RUG2");
        PotentialRugpull second = PotentialRugpull(payable(instance2));

        assertEq(rugpull.name(), "Rugpull Share");
        assertEq(rugpull.symbol(), "RUG");
        assertEq(second.name(), "Second Rugpull");
        assertEq(second.symbol(), "RUG2");
        assertEq(second.cashRatio(), 20);
    }
}

contract PotentialRugpullFactoryTest is Test {
    PotentialRugpullFactory public factory;
    MockBucketInfoForRugpull public bucketInfo;

    function setUp() public {
        bucketInfo = new MockBucketInfoForRugpull();
        factory = new PotentialRugpullFactory(address(bucketInfo));
    }

    function test_Constructor_RevertsOnZeroBucketInfo() public {
        vm.expectRevert(PotentialRugpullFactory.InvalidBucketInfo.selector);
        new PotentialRugpullFactory(address(0));
    }

    function test_CreatePotentialRugpull_CallerBecomesOwnerSameTransaction() public {
        address user = makeAddr("creator");
        vm.prank(user);
        address instance = factory.createPotentialRugpull(50, "X", "Y");

        PotentialRugpull rp = PotentialRugpull(payable(instance));
        assertEq(rp.owner(), user);
        assertEq(rp.balanceOf(user), 1e18);
        assertEq(rp.balanceOf(address(factory)), 0);
    }

    function test_CreatePotentialRugpull_AllInstancesShareFactoryBucketInfo() public {
        address instance1 = factory.createPotentialRugpull(50, "A", "A");
        address instance2 = factory.createPotentialRugpull(30, "B", "B");

        assertEq(address(PotentialRugpull(payable(instance1)).bucketInfo()), address(bucketInfo));
        assertEq(address(PotentialRugpull(payable(instance2)).bucketInfo()), address(bucketInfo));
    }

    function test_CreatePotentialRugpull_TracksDeployedInstances() public {
        address instance1 = factory.createPotentialRugpull(50, "A", "A");
        address instance2 = factory.createPotentialRugpull(30, "B", "B");

        assertEq(factory.getDeployedRugpullsCount(), 2);
        address[] memory all = factory.getAllDeployedRugpulls();
        assertEq(all.length, 2);
        assertEq(all[0], instance1);
        assertEq(all[1], instance2);
    }

    function test_CreatePotentialRugpull_RevertsOnInvalidCashRatio() public {
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.InvalidCashRatio.selector, 5));
        factory.createPotentialRugpull(5, "A", "A");
    }
}
