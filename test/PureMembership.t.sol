// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForMembership {
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

    function PRICE_DECIMALS() external pure returns (uint256) { return 8; }
    function platformFee() external view returns (uint256) { return feeRate; }

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

    receive() external payable {}
}

contract MockERC20ForMembership {
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
//                      TEST CONTRACT
// ============================================================

contract PureMembershipTest is Test {
    PureMembership public implementation;
    PureMembership public membership;
    MockBucketInfoForMembership public bucketInfo;
    MockERC20ForMembership public payToken;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant PAY_TOKEN_PRICE = 1e8; // $1 USD

    // Membership configs
    uint256 constant BASIC_ID = 1;
    uint256 constant BASIC_LEVEL = 1;
    uint256 constant BASIC_PRICE = 10e8; // $10 USD
    uint256 constant BASIC_DURATION = 30 days;

    uint256 constant PREMIUM_ID = 2;
    uint256 constant PREMIUM_LEVEL = 2;
    uint256 constant PREMIUM_PRICE = 50e8; // $50 USD
    uint256 constant PREMIUM_DURATION = 365 days;

    uint256 constant VIP_ID = 3;
    uint256 constant VIP_LEVEL = 3;
    uint256 constant VIP_PRICE = 200e8; // $200 USD
    uint256 constant VIP_DURATION = 365 days;

    event MembershipPurchased(
        address indexed user, uint256 indexed tokenId, uint256 level,
        address payToken, uint256 payAmount, uint256 expiryTime
    );
    event MembershipRenewed(
        address indexed user, uint256 indexed tokenId, uint256 level,
        address payToken, uint256 payAmount, uint256 newExpiryTime
    );
    event MembershipCancelled(address indexed user, uint256 indexed tokenId, uint256 level);
    event RevenueWithdrawn(address indexed to, address indexed token, uint256 amount, uint256 fee);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        bucketInfo = new MockBucketInfoForMembership();
        payToken = new MockERC20ForMembership("USD Coin", "USDC", 6);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(payToken), PAY_TOKEN_PRICE);

        implementation = new PureMembership();

        // Prepare membership configs
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](3);
        configs[0] = PureMembership.MembershipConfig(BASIC_ID, BASIC_LEVEL, "Basic", BASIC_PRICE, BASIC_DURATION);
        configs[1] = PureMembership.MembershipConfig(PREMIUM_ID, PREMIUM_LEVEL, "Premium", PREMIUM_PRICE, PREMIUM_DURATION);
        configs[2] = PureMembership.MembershipConfig(VIP_ID, VIP_LEVEL, "VIP", VIP_PRICE, VIP_DURATION);

        bytes memory initData = abi.encodeWithSelector(
            PureMembership.initialize.selector, configs, address(bucketInfo)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        membership = PureMembership(payable(address(proxy)));

        // Fund users
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        payToken.mint(user1, 100000e6);
        payToken.mint(user2, 100000e6);
        payToken.mint(user3, 100000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialization() public view {
        assertEq(membership.owner(), owner);
        assertEq(address(membership.bucketInfo()), address(bucketInfo));
        assertEq(membership.getConfiguredTokenIdCount(), 3);
    }

    function test_MembershipConfigs() public view {
        PureMembership.MembershipConfig memory basic = membership.getMembershipInfo(BASIC_ID);
        assertEq(basic.tokenId, BASIC_ID);
        assertEq(basic.level, BASIC_LEVEL);
        assertEq(keccak256(bytes(basic.name)), keccak256("Basic"));
        assertEq(basic.price, BASIC_PRICE);
        assertEq(basic.duration, BASIC_DURATION);

        PureMembership.MembershipConfig memory premium = membership.getMembershipInfo(PREMIUM_ID);
        assertEq(premium.level, PREMIUM_LEVEL);
        assertEq(premium.price, PREMIUM_PRICE);
    }

    function test_RevertInitializeZeroAddress() public {
        PureMembership impl = new PureMembership();
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](0);

        vm.expectRevert(PureMembership.ZeroAddress.selector);
        bytes memory initData = abi.encodeWithSelector(
            PureMembership.initialize.selector, configs, address(0)
        );
        new ERC1967Proxy(address(impl), initData);
    }

    /*//////////////////////////////////////////////////////////////
                    BUY MEMBERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BuyMembershipWithERC20() public {
        // Price: $10, Token price: $1, Decimals: 6
        // paymentAmount = 10e8 * 1e6 / 1e8 = 10e6 (10 USDC)
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        assertEq(membership.balanceOf(user1, BASIC_ID), 1);
        assertTrue(membership.membershipExpiry(user1, BASIC_ID) > block.timestamp);
        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment);
        assertEq(membership.activeMembershipCount(BASIC_LEVEL), 1);
    }

    function test_BuyMembershipWithETH() public {
        // Price: $10, ETH price: $2000, Decimals: 18
        // paymentAmount = 10e8 * 1e18 / 2000e8 = 0.005 ETH = 5e15 wei
        uint256 expectedPayment = 5e15;

        vm.prank(user1);
        membership.buyMembership{value: expectedPayment}(BASIC_ID, address(0));

        assertEq(membership.balanceOf(user1, BASIC_ID), 1);
        assertTrue(membership.membershipExpiry(user1, BASIC_ID) > block.timestamp);
    }

    function test_BuyMembershipWithETHRefundExcess() public {
        uint256 expectedPayment = 5e15;
        uint256 overpay = 1 ether;

        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        membership.buyMembership{value: overpay}(BASIC_ID, address(0));

        // Should refund overpay - expectedPayment
        uint256 ethSpent = ethBefore - user1.balance;
        assertEq(ethSpent, expectedPayment);
    }

    function test_RevertBuyMembershipInsufficientETH() public {
        uint256 expectedPayment = 5e15;

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(PureMembership.InsufficientPayment.selector, expectedPayment, 1)
        );
        membership.buyMembership{value: 1}(BASIC_ID, address(0));
    }

    function test_RevertBuyMembershipInvalidTokenId() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InvalidTokenId.selector, 999));
        membership.buyMembership{value: 1 ether}(999, address(0));
    }

    function test_RevertBuyMembershipInvalidPayToken() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InvalidToken.selector, fakeToken));
        membership.buyMembership(BASIC_ID, fakeToken);
    }

    function test_RevertBuyMembershipPaused() public {
        membership.pause();

        vm.prank(user1);
        vm.expectRevert();
        membership.buyMembership{value: 1 ether}(BASIC_ID, address(0));
    }

    function test_RevertBuyMembershipPlatformDown() public {
        bucketInfo.setOperational(false);

        vm.prank(user1);
        vm.expectRevert(PureMembership.PlatformNotOperational.selector);
        membership.buyMembership{value: 1 ether}(BASIC_ID, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    RENEW MEMBERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenewMembership() public {
        uint256 expectedPayment = 10e6;

        // First purchase
        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment * 2);
        membership.buyMembership(BASIC_ID, address(payToken));

        uint256 firstExpiry = membership.membershipExpiry(user1, BASIC_ID);

        // Advance time but still within membership
        vm.warp(block.timestamp + 15 days);

        // Renew
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        uint256 newExpiry = membership.membershipExpiry(user1, BASIC_ID);
        // Should extend from first expiry, not from current time
        assertEq(newExpiry, firstExpiry + BASIC_DURATION);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment * 2);
        // Active count should still be 1 (not double counted)
        assertEq(membership.activeMembershipCount(BASIC_LEVEL), 1);
    }

    function test_BuyAfterExpired() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment * 2);
        membership.buyMembership(BASIC_ID, address(payToken));

        // Advance past expiry
        vm.warp(block.timestamp + BASIC_DURATION + 1);

        // Buy again (not renew since expired) - user already has token
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        // Expiry should be from current time
        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION);
    }

    /*//////////////////////////////////////////////////////////////
                    CHECK MEMBERSHIP STATUS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CheckMembershipStatusActive() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        assertTrue(membership.checkMembershipStatus(user1, BASIC_LEVEL));
        assertTrue(membership.checkMembershipStatus(user1, 0)); // Level 0 should also pass
    }

    function test_CheckMembershipStatusHigherLevel() public {
        // Buy premium (level 2)
        uint256 expectedPayment = 50e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(PREMIUM_ID, address(payToken));
        vm.stopPrank();

        assertTrue(membership.checkMembershipStatus(user1, PREMIUM_LEVEL));
        assertTrue(membership.checkMembershipStatus(user1, BASIC_LEVEL)); // Should also pass for lower level
        assertFalse(membership.checkMembershipStatus(user1, VIP_LEVEL)); // Should fail for higher level
    }

    function test_CheckMembershipStatusExpired() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        // Advance past expiry
        vm.warp(block.timestamp + BASIC_DURATION + 1);

        assertFalse(membership.checkMembershipStatus(user1, BASIC_LEVEL));
    }

    function test_CheckMembershipStatusNoMembership() public view {
        assertFalse(membership.checkMembershipStatus(user1, BASIC_LEVEL));
    }

    /*//////////////////////////////////////////////////////////////
                    CANCEL MEMBERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CancelMembership() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));

        membership.cancelMembership(BASIC_ID);
        vm.stopPrank();

        assertEq(membership.balanceOf(user1, BASIC_ID), 0);
        assertEq(membership.membershipExpiry(user1, BASIC_ID), 0);
        assertEq(membership.activeMembershipCount(BASIC_LEVEL), 0);
    }

    function test_RevertCancelNoMembership() public {
        vm.prank(user1);
        vm.expectRevert(PureMembership.NoActiveMembership.selector);
        membership.cancelMembership(BASIC_ID);
    }

    function test_RevertCancelExpiredMembership() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        vm.warp(block.timestamp + BASIC_DURATION + 1);

        vm.prank(user1);
        vm.expectRevert(PureMembership.MembershipExpired.selector);
        membership.cancelMembership(BASIC_ID);
    }

    /*//////////////////////////////////////////////////////////////
                    GET USER MEMBERSHIPS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUserMemberships() public {
        // Buy basic and premium
        vm.startPrank(user1);
        payToken.approve(address(membership), 60e6);
        membership.buyMembership(BASIC_ID, address(payToken));
        membership.buyMembership(PREMIUM_ID, address(payToken));
        vm.stopPrank();

        PureMembership.UserMembership[] memory memberships = membership.getUserMemberships(user1);
        assertEq(memberships.length, 2);
        assertTrue(memberships[0].isActive);
        assertTrue(memberships[1].isActive);
    }

    function test_GetUserMembershipsEmpty() public view {
        PureMembership.UserMembership[] memory memberships = membership.getUserMemberships(user1);
        assertEq(memberships.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    REVENUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetMembershipRevenue() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        (address[] memory tokens, uint256[] memory amounts) = membership.getMembershipRevenue();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(payToken));
        assertEq(amounts[0], expectedPayment);
    }

    function test_WithdrawRevenue() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        uint256 withdrawAmount = expectedPayment;
        uint256 fee = (withdrawAmount * 100) / 10000; // 1% fee
        uint256 ownerAmount = withdrawAmount - fee;

        address recipient = makeAddr("recipient");
        membership.withdrawRevenue(recipient, address(payToken), withdrawAmount);

        assertEq(payToken.balanceOf(recipient), ownerAmount);
        assertEq(payToken.balanceOf(address(bucketInfo)), fee);
        assertEq(membership.withdrawnByToken(address(payToken)), withdrawAmount);
    }

    function test_RevertWithdrawRevenueNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        membership.withdrawRevenue(user1, address(payToken), 100);
    }

    function test_RevertWithdrawRevenueInvalidToken() public {
        address fakeToken = makeAddr("fakeToken");
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InvalidToken.selector, fakeToken));
        membership.withdrawRevenue(user1, fakeToken, 100);
    }

    function test_RevertWithdrawRevenueInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InsufficientContractBalance.selector, 1000e6, 0));
        membership.withdrawRevenue(user1, address(payToken), 1000e6);
    }

    function test_RevertWithdrawRevenuePlatformDown() public {
        bucketInfo.setOperational(false);

        vm.expectRevert(PureMembership.PlatformNotOperational.selector);
        membership.withdrawRevenue(user1, address(payToken), 100);
    }

    /*//////////////////////////////////////////////////////////////
                    RECOVER TOKENS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RecoverTokens() public {
        MockERC20ForMembership rogue = new MockERC20ForMembership("Rogue", "RGT", 18);
        rogue.mint(address(membership), 500e18);

        membership.recoverTokens(address(rogue), 500e18, user1);
        assertEq(rogue.balanceOf(user1), 500e18);
    }

    function test_RevertRecoverWhitelistedToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(PureMembership.CannotRecoverWhitelistedToken.selector, address(payToken))
        );
        membership.recoverTokens(address(payToken), 100e6, user1);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PauseUnpause() public {
        membership.pause();
        assertTrue(membership.paused());

        membership.unpause();
        assertFalse(membership.paused());
    }

    function test_RevertPauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        membership.pause();
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BuyMembershipWithETH(uint256 extraETH) public {
        uint256 expectedPayment = 5e15; // $10 at $2000/ETH
        extraETH = bound(extraETH, 0, 10 ether);

        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        membership.buyMembership{value: expectedPayment + extraETH}(BASIC_ID, address(0));

        // Excess should be refunded
        uint256 ethSpent = ethBefore - user1.balance;
        assertEq(ethSpent, expectedPayment);
        assertTrue(membership.checkMembershipStatus(user1, BASIC_LEVEL));
    }

    function testFuzz_MultipleUsersBuyMemberships(uint8 numUsers) public {
        numUsers = uint8(bound(numUsers, 1, 10));
        uint256 expectedPayment = 10e6;

        for (uint8 i = 0; i < numUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("fuzzUser", i)));
            payToken.mint(user, expectedPayment);

            vm.startPrank(user);
            payToken.approve(address(membership), expectedPayment);
            membership.buyMembership(BASIC_ID, address(payToken));
            vm.stopPrank();

            assertTrue(membership.checkMembershipStatus(user, BASIC_LEVEL));
        }

        assertEq(membership.activeMembershipCount(BASIC_LEVEL), numUsers);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment * numUsers);
    }
}
