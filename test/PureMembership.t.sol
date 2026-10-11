// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForMembership {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
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

    // --- W4.2b regression fix (task #61): see PassiveBucket.t.sol's MockBucketInfoForPassive
    // for the full explanation -- PureMembership's own _update override (task #55) routes
    // through the same _isBlacklistedFailClosed fail-closed helper, so this mock needed the
    // identical fix. Defaults to false.
    mapping(address => bool) public blacklisted;

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    // --- W5-oracle regression fix (same class as task #61's isBlacklisted gap): see
    // PassiveBucket.t.sol's MockBucketInfoForPassive for the full explanation.
    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
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
    // W3.3: platform-owned registry PureMembership's immutable constructor parameter now
    // requires. Not exercised by most tests here -- deployed purely so
    // `new PureMembership(address)` compiles; queue/cancel/authorize tests approve into it directly.
    ImplementationRegistry public registry;

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
        address indexed user,
        uint256 indexed tokenId,
        uint256 level,
        address payToken,
        uint256 payAmount,
        uint256 expiryTime
    );
    event MembershipRenewed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 level,
        address payToken,
        uint256 payAmount,
        uint256 newExpiryTime
    );
    event MembershipCancelled(address indexed user, uint256 indexed tokenId, uint256 level);
    event RevenueWithdrawn(address indexed to, address indexed token, uint256 amount, uint256 fee);
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);
    event MaxPaymentAmountUpdated(uint256 oldMax, uint256 newMax);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        bucketInfo = new MockBucketInfoForMembership();
        payToken = new MockERC20ForMembership("USD Coin", "USDC", 6);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(payToken), PAY_TOKEN_PRICE);

        registry = new ImplementationRegistry(owner);
        implementation = new PureMembership(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test suite deploys proxies directly
        // (not through `PureMembershipFactory`), so the test contract itself must be an
        // authorized "factory" from the registry's point of view, or every `initialize()` call
        // below reverts with `UnauthorizedInitializer()`.
        registry.setAuthorizedFactory(address(this), true);

        // Prepare membership configs
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](3);
        configs[0] = PureMembership.MembershipConfig(BASIC_ID, BASIC_LEVEL, "Basic", BASIC_PRICE, BASIC_DURATION);
        configs[1] =
            PureMembership.MembershipConfig(PREMIUM_ID, PREMIUM_LEVEL, "Premium", PREMIUM_PRICE, PREMIUM_DURATION);
        configs[2] = PureMembership.MembershipConfig(VIP_ID, VIP_LEVEL, "VIP", VIP_PRICE, VIP_DURATION);

        bytes memory initData =
            abi.encodeWithSelector(PureMembership.initialize.selector, configs, address(bucketInfo), "");
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
        PureMembership impl = new PureMembership(address(registry));
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](0);

        vm.expectRevert(PureMembership.ZeroAddress.selector);
        bytes memory initData = abi.encodeWithSelector(PureMembership.initialize.selector, configs, address(0), "");
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
        membership.buyMembership(BASIC_ID, address(payToken), 0);
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
        membership.buyMembership{value: expectedPayment}(BASIC_ID, address(0), 0);

        assertEq(membership.balanceOf(user1, BASIC_ID), 1);
        assertTrue(membership.membershipExpiry(user1, BASIC_ID) > block.timestamp);
    }

    function test_BuyMembershipWithETHRefundExcess() public {
        uint256 expectedPayment = 5e15;
        uint256 overpay = 1 ether;

        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        membership.buyMembership{value: overpay}(BASIC_ID, address(0), 0);

        // Should refund overpay - expectedPayment
        uint256 ethSpent = ethBefore - user1.balance;
        assertEq(ethSpent, expectedPayment);
    }

    function test_RevertBuyMembershipInsufficientETH() public {
        uint256 expectedPayment = 5e15;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InsufficientPayment.selector, expectedPayment, 1));
        membership.buyMembership{value: 1}(BASIC_ID, address(0), 0);
    }

    function test_RevertBuyMembershipInvalidTokenId() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InvalidTokenId.selector, 999));
        membership.buyMembership{value: 1 ether}(999, address(0), 0);
    }

    function test_RevertBuyMembershipInvalidPayToken() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.InvalidToken.selector, fakeToken));
        membership.buyMembership(BASIC_ID, fakeToken, 0);
    }

    function test_RevertBuyMembershipPaused() public {
        membership.pause();

        vm.prank(user1);
        vm.expectRevert();
        membership.buyMembership{value: 1 ether}(BASIC_ID, address(0), 0);
    }

    function test_RevertBuyMembershipPlatformDown() public {
        bucketInfo.setOperational(false);

        vm.prank(user1);
        vm.expectRevert(PureMembership.PlatformNotOperational.selector);
        membership.buyMembership{value: 1 ether}(BASIC_ID, address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    RENEW MEMBERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RenewMembership() public {
        uint256 expectedPayment = 10e6;

        // First purchase
        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment * 2);
        membership.buyMembership(BASIC_ID, address(payToken), 0);

        uint256 firstExpiry = membership.membershipExpiry(user1, BASIC_ID);

        // Advance time but still within membership
        vm.warp(block.timestamp + 15 days);

        // Renew
        membership.buyMembership(BASIC_ID, address(payToken), 0);
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
        membership.buyMembership(BASIC_ID, address(payToken), 0);

        // Advance past expiry
        vm.warp(block.timestamp + BASIC_DURATION + 1);

        // Buy again (not renew since expired) - user already has token
        membership.buyMembership(BASIC_ID, address(payToken), 0);
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
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        assertTrue(membership.checkMembershipStatus(user1, BASIC_LEVEL));
        assertTrue(membership.checkMembershipStatus(user1, 0)); // Level 0 should also pass
    }

    function test_CheckMembershipStatusHigherLevel() public {
        // Buy premium (level 2)
        uint256 expectedPayment = 50e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(PREMIUM_ID, address(payToken), 0);
        vm.stopPrank();

        assertTrue(membership.checkMembershipStatus(user1, PREMIUM_LEVEL));
        assertTrue(membership.checkMembershipStatus(user1, BASIC_LEVEL)); // Should also pass for lower level
        assertFalse(membership.checkMembershipStatus(user1, VIP_LEVEL)); // Should fail for higher level
    }

    function test_CheckMembershipStatusExpired() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
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
        membership.buyMembership(BASIC_ID, address(payToken), 0);

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
        membership.buyMembership(BASIC_ID, address(payToken), 0);
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
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        membership.buyMembership(PREMIUM_ID, address(payToken), 0);
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
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        (address[] memory tokens, uint256[] memory amounts) = membership.getMembershipRevenue();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(payToken));
        assertEq(amounts[0], expectedPayment);
    }

    function test_WithdrawRevenue() public {
        // VIP costs $200 → 200e6 USDC. First withdrawal requires >= $100 USD.
        uint256 expectedPayment = 200e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(VIP_ID, address(payToken), 0);
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

    /// @dev Parity gap vs. `test/ActiveBucket.t.sol`'s `test_RevertUnpauseNotOwner` -- task #42
    /// (W3.5). Unlike ActiveBucket/PassiveBucket, PureMembership has no accountability concept
    /// at all (`grep -n "isBucketAccountable\|MIN_OWNER_BPS\|onlyAccountableOwner" src/PureMembership.sol`
    /// returns zero hits) -- both `pause()` and `unpause()` are plain `onlyOwner` (`:554`, `:559`),
    /// so the dilution-lockout scenario tested on the other two vaults does not apply here; this
    /// closes only the not-owner-revert parity gap.
    function test_RevertUnpauseNotOwner() public {
        membership.pause();

        vm.prank(user1);
        vm.expectRevert();
        membership.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    UPDATE BUCKETINFO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateBucketInfo() public {
        // Create new BucketInfo
        MockBucketInfoForMembership newBucketInfo = new MockBucketInfoForMembership();
        newBucketInfo.addToken(address(0), ETH_PRICE);
        newBucketInfo.addToken(address(payToken), PAY_TOKEN_PRICE);

        address oldBucketInfo = address(membership.bucketInfo());

        // Set bucketInfo owner to owner (test contract)
        bucketInfo.setOwner(owner);

        // Propose is gated on the CURRENT BucketInfo's owner.
        membership.proposeUpdateBucketInfo(address(newBucketInfo));
        vm.warp(block.timestamp + membership.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());

        // Execute is permissionless once the delay has elapsed and no veto arrived.
        vm.expectEmit(true, true, true, true);
        emit BucketInfoUpdated(oldBucketInfo, address(newBucketInfo), address(this));

        membership.executeUpdateBucketInfo();

        assertEq(address(membership.bucketInfo()), address(newBucketInfo));
    }

    function test_UpdateBucketInfoFromBucketInfoOwner() public {
        // Create new BucketInfo
        MockBucketInfoForMembership newBucketInfo = new MockBucketInfoForMembership();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        // Set bucketInfo owner to user1
        bucketInfo.setOwner(user1);

        // user1 should be able to propose
        vm.prank(user1);
        membership.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.warp(block.timestamp + membership.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        // execute is permissionless -- anyone may apply it once the delay has elapsed
        membership.executeUpdateBucketInfo();

        assertEq(address(membership.bucketInfo()), address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoUnauthorized() public {
        MockBucketInfoForMembership newBucketInfo = new MockBucketInfoForMembership();

        // Set bucketInfo owner to owner (test contract)
        bucketInfo.setOwner(owner);

        // user1 is not bucketInfo owner, should revert
        vm.prank(user1);
        vm.expectRevert(PureMembership.UnauthorizedBucketInfoUpdate.selector);
        membership.proposeUpdateBucketInfo(address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoZeroAddress() public {
        bucketInfo.setOwner(owner);

        vm.expectRevert(PureMembership.ZeroAddress.selector);
        membership.proposeUpdateBucketInfo(address(0));
    }

    function test_RevertExecuteUpdateBucketInfoBeforeTimelockElapsed() public {
        MockBucketInfoForMembership newBucketInfo = new MockBucketInfoForMembership();
        bucketInfo.setOwner(owner);

        membership.proposeUpdateBucketInfo(address(newBucketInfo));

        (, uint256 eta) = membership.pendingBucketInfoUpdate();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        membership.executeUpdateBucketInfo();
    }

    function test_RevertExecuteUpdateBucketInfoWithNothingPending() public {
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        membership.executeUpdateBucketInfo();
    }

    /// @notice D3's veto window: this contract's OWN owner may cancel a proposed repoint
    /// before it executes.
    function test_VetoUpdateBucketInfoByOwner() public {
        MockBucketInfoForMembership newBucketInfo = new MockBucketInfoForMembership();
        bucketInfo.setOwner(owner);

        membership.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.prank(owner); // membership.owner()
        membership.vetoUpdateBucketInfo();

        vm.warp(block.timestamp + membership.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        membership.executeUpdateBucketInfo();

        assertTrue(address(membership.bucketInfo()) != address(newBucketInfo));
    }

    function test_RevertVetoUpdateBucketInfoByNonOwner() public {
        MockBucketInfoForMembership newBucketInfo = new MockBucketInfoForMembership();
        bucketInfo.setOwner(owner);
        membership.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.prank(user1); // user1 is not membership.owner()
        vm.expectRevert(); // OwnableUpgradeable.OwnableUnauthorizedAccount
        membership.vetoUpdateBucketInfo();
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BuyMembershipWithETH(uint256 extraEth) public {
        uint256 expectedPayment = 5e15; // $10 at $2000/ETH
        extraEth = bound(extraEth, 0, 10 ether);

        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        membership.buyMembership{value: expectedPayment + extraEth}(BASIC_ID, address(0), 0);

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
            membership.buyMembership(BASIC_ID, address(payToken), 0);
            vm.stopPrank();

            assertTrue(membership.checkMembershipStatus(user, BASIC_LEVEL));
        }

        assertEq(membership.activeMembershipCount(BASIC_LEVEL), numUsers);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment * numUsers);
    }

    /*//////////////////////////////////////////////////////////////
                RENEWAL BOUNDARY TEST (max(expiry, now))
    //////////////////////////////////////////////////////////////*/

    /// @notice At the exact instant membershipExpiry == block.timestamp, buyMembership
    /// must take the "new purchase" branch (expiry = now + duration), not the "renew"
    /// branch -- i.e. max(existingExpiry, block.timestamp) resolves to block.timestamp,
    /// not to a stale existingExpiry that equals it. This is the boundary the existing
    /// test_RenewMembership (renew-while-active) and test_BuyAfterExpired (renew-after-
    /// expiry) tests do not exercise: both warp strictly past expiry, never exactly to it.
    function test_BuyMembershipExactlyAtExpiryBoundary() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment * 2);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        uint256 firstExpiry = membership.membershipExpiry(user1, BASIC_ID);

        // Warp to exactly the first expiry timestamp (neither before nor after it).
        vm.warp(firstExpiry);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        uint256 secondExpiry = membership.membershipExpiry(user1, BASIC_ID);
        // max(firstExpiry, block.timestamp) == max(firstExpiry, firstExpiry) == firstExpiry,
        // so the new expiry is block.timestamp + duration == firstExpiry + duration -- the
        // same arithmetic result as compounding, confirming the boundary is not a lost-time
        // or back-dating defect either way.
        assertEq(secondExpiry, block.timestamp + BASIC_DURATION);
        assertEq(secondExpiry, firstExpiry + BASIC_DURATION);
    }

    /*//////////////////////////////////////////////////////////////
                    MAX PAYMENT AMOUNT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MaxPaymentAmountDefaultsToUnlimited() public view {
        // Storage default is 0, which this contract treats as "no owner-side cap".
        assertEq(membership.maxPaymentAmount(), 0);
    }

    function test_SetMaxPaymentAmount() public {
        vm.expectEmit(false, false, false, true, address(membership));
        emit MaxPaymentAmountUpdated(0, 10e6);
        membership.setMaxPaymentAmount(10e6);
        assertEq(membership.maxPaymentAmount(), 10e6);
    }

    function test_RevertSetMaxPaymentAmountNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        membership.setMaxPaymentAmount(10e6);
    }

    function test_BuyMembershipWithinOwnerCap() public {
        uint256 expectedPayment = 10e6;
        membership.setMaxPaymentAmount(expectedPayment); // exactly equal to payment: allowed

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        assertEq(membership.balanceOf(user1, BASIC_ID), 1);
    }

    function test_RevertBuyMembershipExceedsOwnerCap() public {
        uint256 expectedPayment = 10e6;
        membership.setMaxPaymentAmount(expectedPayment - 1); // one unit below the real cost

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        vm.expectRevert(
            abi.encodeWithSelector(
                PureMembership.PaymentExceedsMaxAmount.selector, expectedPayment, expectedPayment - 1
            )
        );
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();
    }

    function test_BuyMembershipPaySectionZeroDefaultsToOne() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment);
    }

    function test_BuyMembershipOmittedPaySectionDefaultsToOne() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken));
        vm.stopPrank();

        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment);
    }

    function test_BuyMembershipMultiplePaySections() public {
        uint256 paySections = 3;
        uint256 expectedPayment = 10e6 * paySections;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken), paySections);
        vm.stopPrank();

        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION * paySections);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment);
    }

    function test_BuyMembershipExistingCallWithThirdArgumentZeroDefaultsToOne() public {
        uint256 expectedPayment = 10e6;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment);
    }

    function test_BuyMembershipMultiplePaySectionsWithETH() public {
        uint256 paySections = 2;
        uint256 expectedPayment = 5e15 * paySections;
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        membership.buyMembership{value: expectedPayment}(BASIC_ID, address(0), paySections);

        assertEq(user1.balance, ethBefore - expectedPayment);
        assertEq(membership.membershipExpiry(user1, BASIC_ID), block.timestamp + BASIC_DURATION * paySections);
        assertEq(membership.revenueByToken(address(0)), expectedPayment);
    }

    function test_RenewMembershipMultiplePaySections() public {
        uint256 expectedPayment = 10e6 * 4;

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        membership.buyMembership(BASIC_ID, address(payToken), 1);
        uint256 firstExpiry = membership.membershipExpiry(user1, BASIC_ID);
        membership.buyMembership(BASIC_ID, address(payToken), 3);
        vm.stopPrank();

        assertEq(membership.membershipExpiry(user1, BASIC_ID), firstExpiry + BASIC_DURATION * 3);
        assertEq(membership.revenueByToken(address(payToken)), expectedPayment);
    }

    function test_OwnerCapAppliesToTotalPaySectionAmount() public {
        uint256 expectedPayment = 20e6;
        membership.setMaxPaymentAmount(expectedPayment - 1);

        vm.startPrank(user1);
        payToken.approve(address(membership), expectedPayment);
        vm.expectRevert(
            abi.encodeWithSelector(
                PureMembership.PaymentExceedsMaxAmount.selector, expectedPayment, expectedPayment - 1
            )
        );
        membership.buyMembership(BASIC_ID, address(payToken), 2);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                UPGRADE GOVERNANCE TESTS — W3.3 (basic)
    //////////////////////////////////////////////////////////////*/
    // Basic happy-path/revert-path coverage for {queueUpgrade}/{cancelUpgrade}/{_authorizeUpgrade}
    // per `09-DECISION-LOG.md` §10.1, mirroring ActiveBucket.t.sol/PassiveBucket.t.sol. This
    // contract carries its OWN standalone copy of the errors (PureMembership.sol has no shared
    // base to call into), so `PureMembership.UpgradeImplementationMismatch` /
    // `PureMembership.UpgradeNotApproved`, not `BucketVaultBase`'s. The exhaustive adversarial
    // suite (namespace isolation, factory-handover regression, renounceOwnership/Ownable2Step
    // semantics) is task #45's own gate suite, not duplicated here.

    function _deployApprovedPureMembershipImplementation() internal returns (address newImpl) {
        newImpl = address(new PureMembership(address(registry)));
        registry.approve(IImplementationRegistry.Kind.PureMembership, newImpl);
    }

    function test_QueueUpgrade_SetsPendingAndEta() public {
        address newImpl = _deployApprovedPureMembershipImplementation();

        membership.queueUpgrade(newImpl);

        assertEq(membership.pendingImplementation(), newImpl);
        assertEq(membership.upgradeEta(), block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());
    }

    function test_RevertQueueUpgradeNotOwner() public {
        address newImpl = _deployApprovedPureMembershipImplementation();

        vm.prank(user1);
        vm.expectRevert();
        membership.queueUpgrade(newImpl);
    }

    function test_RevertQueueUpgradeZeroAddress() public {
        vm.expectRevert(PureMembership.ZeroAddress.selector);
        membership.queueUpgrade(address(0));
    }

    function test_UpgradeSucceeds_AfterQueueApprovalAndElapsedDelay() public {
        address newImpl = _deployApprovedPureMembershipImplementation();

        membership.queueUpgrade(newImpl);
        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        membership.upgradeToAndCall(newImpl, "");

        assertEq(membership.pendingImplementation(), address(0));
        assertEq(membership.upgradeEta(), 0);
    }

    function test_RevertUpgrade_BeforeTimelockElapsed() public {
        address newImpl = _deployApprovedPureMembershipImplementation();
        membership.queueUpgrade(newImpl);

        uint256 eta = membership.upgradeEta();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        membership.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NothingQueued() public {
        address newImpl = _deployApprovedPureMembershipImplementation();

        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        membership.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ImplementationMismatch() public {
        address queuedImpl = _deployApprovedPureMembershipImplementation();
        address otherImpl = _deployApprovedPureMembershipImplementation();

        membership.queueUpgrade(queuedImpl);
        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(PureMembership.UpgradeImplementationMismatch.selector, queuedImpl, otherImpl)
        );
        membership.upgradeToAndCall(otherImpl, "");
    }

    /// @notice Registry approval is re-checked at EXECUTION time, not just at queue time — a
    /// mid-window platform revocation actually blocks the upgrade (the plan's own "test 3",
    /// 04 §5.6.1/§10.1). This is the scenario most likely to be omitted.
    function test_RevertUpgrade_RegistryApprovalRevokedMidWindow() public {
        address newImpl = _deployApprovedPureMembershipImplementation();

        membership.queueUpgrade(newImpl);
        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        registry.revoke(IImplementationRegistry.Kind.PureMembership, newImpl);

        vm.expectRevert(abi.encodeWithSelector(PureMembership.UpgradeNotApproved.selector, newImpl));
        membership.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NeverApproved() public {
        address newImpl = address(new PureMembership(address(registry)));

        membership.queueUpgrade(newImpl);
        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(PureMembership.UpgradeNotApproved.selector, newImpl));
        membership.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_ClearsPendingState() public {
        address newImpl = _deployApprovedPureMembershipImplementation();
        membership.queueUpgrade(newImpl);

        membership.cancelUpgrade();

        assertEq(membership.pendingImplementation(), address(0));
        assertEq(membership.upgradeEta(), 0);

        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        membership.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_NoOpWhenNothingPending() public {
        membership.cancelUpgrade();
        assertEq(membership.pendingImplementation(), address(0));
    }

    function test_RevertCancelUpgradeNotOwner() public {
        address newImpl = _deployApprovedPureMembershipImplementation();
        membership.queueUpgrade(newImpl);

        vm.prank(user1);
        vm.expectRevert();
        membership.cancelUpgrade();
    }

    function test_RevertUpgrade_NotOwner() public {
        address newImpl = _deployApprovedPureMembershipImplementation();
        membership.queueUpgrade(newImpl);
        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        vm.prank(user1);
        vm.expectRevert();
        membership.upgradeToAndCall(newImpl, "");
    }

    /*//////////////////////////////////////////////////////////////
                UPGRADE GOVERNANCE TESTS — W3 GATE (task #45)
    //////////////////////////////////////////////////////////////*/
    // Replicated from `ActiveBucket.t.sol`/`PassiveBucket.t.sol`'s equivalent block -- see
    // ActiveBucket.t.sol's comment header for the full rationale (namespace isolation,
    // platform-cannot-trigger, renounceOwnership/single-step-Ownable semantics, pause-during-
    // queue independence). This contract carries its OWN standalone copy of the errors
    // (PureMembership.sol has no shared base to call into) -- `PureMembership.
    // RenounceOwnershipDisabled` / `PureMembership.UpgradeNotApproved`, not `BucketVaultBase`'s.
    // Factory-handover regression (owner() == msg.sender inside the creation transaction) is
    // already covered by `PureMembershipFactory.t.sol`'s `test_Create_OwnerIsCallerNotFactory` /
    // `test_Create_OwnerIsNotFactory` -- not duplicated here.

    function test_RevertRenounceOwnership() public {
        vm.expectRevert(PureMembership.RenounceOwnershipDisabled.selector);
        membership.renounceOwnership();
    }

    function test_TransferOwnershipIsSingleStepNotTwoStep() public {
        membership.transferOwnership(user1);
        assertEq(
            membership.owner(),
            user1,
            "single-step Ownable must hand over ownership immediately, with no acceptOwnership() call"
        );
    }

    function test_RevertUpgrade_PlatformCannotTrigger() public {
        // Reconstruct the same membership configs setUp() builds locally (not stored state).
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](3);
        configs[0] = PureMembership.MembershipConfig(BASIC_ID, BASIC_LEVEL, "Basic", BASIC_PRICE, BASIC_DURATION);
        configs[1] =
            PureMembership.MembershipConfig(PREMIUM_ID, PREMIUM_LEVEL, "Premium", PREMIUM_PRICE, PREMIUM_DURATION);
        configs[2] = PureMembership.MembershipConfig(VIP_ID, VIP_LEVEL, "VIP", VIP_PRICE, VIP_DURATION);

        bytes memory initData =
            abi.encodeWithSelector(PureMembership.initialize.selector, configs, address(bucketInfo), "");
        // Task #33: this test deliberately simulates a customer deploying their own proxy
        // directly (not through the factory) to get a vault the platform does not own. That is
        // now exactly the shape the bypass fix blocks by default, so `user2` must be explicitly
        // authorized here -- the point of this test is upgrade-authority, not the bypass itself.
        registry.setAuthorizedFactory(user2, true);
        vm.prank(user2);
        ERC1967Proxy customerProxy = new ERC1967Proxy(address(implementation), initData);
        PureMembership customerMembership = PureMembership(payable(address(customerProxy)));
        assertEq(
            customerMembership.owner(), user2, "customerMembership must be owned by the customer, not the platform"
        );

        address newImpl = address(new PureMembership(address(registry)));
        registry.approve(IImplementationRegistry.Kind.PureMembership, newImpl);

        vm.expectRevert();
        customerMembership.queueUpgrade(newImpl);

        vm.prank(user2);
        customerMembership.queueUpgrade(newImpl);
        vm.warp(block.timestamp + customerMembership.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert();
        customerMembership.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ApprovedForWrongKind() public {
        address newImpl = address(new PureMembership(address(registry)));
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, newImpl);

        membership.queueUpgrade(newImpl);
        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(PureMembership.UpgradeNotApproved.selector, newImpl));
        membership.upgradeToAndCall(newImpl, "");
    }

    function test_UpgradeQueued_PlatformPauseDoesNotBlockIt() public {
        address newImpl = _deployApprovedPureMembershipImplementation();
        membership.queueUpgrade(newImpl);

        bucketInfo.setOperational(false);
        assertFalse(bucketInfo.isPlatformOperational());

        vm.warp(block.timestamp + membership.UPGRADE_TIMELOCK_DELAY());

        membership.upgradeToAndCall(newImpl, "");
        assertEq(membership.pendingImplementation(), address(0));
    }
}
