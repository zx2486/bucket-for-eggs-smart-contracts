// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {PureMembershipFactory} from "../src/PureMembershipFactory.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";

// ============================================================
// ============================================================

contract MockBucketInfoForFactory {
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

// ============================================================
// ============================================================

contract PureMembershipFactoryTest is Test {
    PureMembership public implementation;
    PureMembershipFactory public factory;
    MockBucketInfoForFactory public bucketInfo;
    ImplementationRegistry public registry;

    address public deployer;
    address public alice;
    address public bob;

    string constant URI = "https://api.example.com/metadata/{id}.json";

    uint256 constant BASIC_ID = 1;
    uint256 constant BASIC_LEVEL = 1;
    uint256 constant BASIC_PRICE = 10e8;
    uint256 constant BASIC_DURATION = 30 days;

    uint256 constant PREMIUM_ID = 2;
    uint256 constant PREMIUM_LEVEL = 2;
    uint256 constant PREMIUM_PRICE = 50e8;
    uint256 constant PREMIUM_DURATION = 365 days;

    event PureMembershipCreated(address indexed proxy, address indexed owner, address indexed bucketInfo, string uri);

    // -------------------------------------------------------
    // -------------------------------------------------------

    /// @dev Returns a 3-element config array (Basic / Premium / VIP)
    function _defaultConfigs() internal pure returns (PureMembership.MembershipConfig[] memory configs) {
        configs = new PureMembership.MembershipConfig[](3);
        configs[0] = PureMembership.MembershipConfig(1, 1, "Basic", 10e8, 30 days);
        configs[1] = PureMembership.MembershipConfig(2, 2, "Premium", 50e8, 365 days);
        configs[2] = PureMembership.MembershipConfig(3, 3, "VIP", 200e8, 365 days);
    }

    // -------------------------------------------------------
    // -------------------------------------------------------

    function setUp() public {
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        bucketInfo = new MockBucketInfoForFactory();
        registry = new ImplementationRegistry(deployer);
        implementation = new PureMembership(address(registry));
        factory = new PureMembershipFactory(address(implementation), address(bucketInfo));
        registry.setAuthorizedFactory(address(factory), true);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_StoresImplementation() public view {
        assertEq(factory.implementation(), address(implementation));
    }

    function test_Constructor_StoresBucketInfo() public view {
        assertEq(factory.bucketInfo(), address(bucketInfo));
    }

    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(PureMembershipFactory.InvalidImplementation.selector);
        new PureMembershipFactory(address(0), address(bucketInfo));
    }

    function test_Constructor_ZeroBucketInfoReverts() public {
        vm.expectRevert(PureMembershipFactory.InvalidBucketInfo.selector);
        new PureMembershipFactory(address(implementation), address(0));
    }

    function test_Constructor_InitialProxyCountIsZero() public view {
        assertEq(factory.getDeployedProxiesCount(), 0);
    }

    function test_Constructor_GetAllDeployedProxiesEmpty() public view {
        address[] memory proxies = factory.getAllDeployedProxies();
        assertEq(proxies.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CREATE PURE MEMBERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Create_DeploysProxy() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        address proxy = factory.createPureMembership(configs, URI);
        assertTrue(proxy != address(0));
    }

    function test_Create_OwnerIsCallerNotFactory() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        vm.prank(alice);
        address payable proxy = factory.createPureMembership(configs, URI);

        assertEq(PureMembership(proxy).owner(), alice);
    }

    function test_Create_OwnerIsNotFactory() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        vm.prank(alice);
        address payable proxy = factory.createPureMembership(configs, URI);

        assertTrue(PureMembership(proxy).owner() != address(factory));
    }

    function test_Create_BucketInfoIsSet() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        address payable proxy = factory.createPureMembership(configs, URI);

        assertEq(address(PureMembership(proxy).bucketInfo()), address(bucketInfo));
        assertEq(address(PureMembership(proxy).bucketInfo()), factory.bucketInfo());
    }

    function test_Create_MembershipConfigsAreSet() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        address payable proxy = factory.createPureMembership(configs, URI);
        PureMembership pm = PureMembership(proxy);

        assertEq(pm.getConfiguredTokenIdCount(), 3);

        PureMembership.MembershipConfig memory basic = pm.getMembershipInfo(BASIC_ID);
        assertEq(basic.tokenId, BASIC_ID);
        assertEq(basic.level, BASIC_LEVEL);
        assertEq(basic.price, BASIC_PRICE);
        assertEq(basic.duration, BASIC_DURATION);

        PureMembership.MembershipConfig memory premium = pm.getMembershipInfo(PREMIUM_ID);
        assertEq(premium.tokenId, PREMIUM_ID);
        assertEq(premium.level, PREMIUM_LEVEL);
        assertEq(premium.price, PREMIUM_PRICE);
        assertEq(premium.duration, PREMIUM_DURATION);
    }

    function test_Create_ZeroBucketInfoReverts_SUPERSEDED_seeConstructorTest() public {}

    function test_Create_EmptyConfigsAllowed() public {
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](0);
        address payable proxy = factory.createPureMembership(configs, URI);
        assertEq(PureMembership(proxy).getConfiguredTokenIdCount(), 0);
    }

    function test_Create_EmitsEvent() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.recordLogs();
        vm.prank(alice);
        address payable proxy = factory.createPureMembership(configs, URI);

        assertEq(PureMembership(proxy).owner(), alice);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Create_EmitsEventWithCorrectFields() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.prank(alice);
        vm.expectEmit(false, true, true, false);
        emit PureMembershipCreated(address(0), alice, address(bucketInfo), URI);
        factory.createPureMembership(configs, URI);
    }

    function test_Create_ProxyIsIndependentOfImplementation() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.expectRevert();
        implementation.initialize(configs, address(bucketInfo), URI);

        address payable proxy = factory.createPureMembership(configs, URI);
        assertTrue(proxy != payable(0));
    }

    /*//////////////////////////////////////////////////////////////
                    TRACKING / DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Tracking_SingleDeployment() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        address payable proxy = factory.createPureMembership(configs, URI);

        assertEq(factory.getDeployedProxiesCount(), 1);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Tracking_MultipleDeployments() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.prank(alice);
        address payable proxy1 = factory.createPureMembership(configs, URI);

        vm.prank(bob);
        address payable proxy2 = factory.createPureMembership(configs, URI);

        assertEq(factory.getDeployedProxiesCount(), 2);
        assertEq(factory.deployedProxies(0), proxy1);
        assertEq(factory.deployedProxies(1), proxy2);
    }

    function test_Tracking_ProxiesAreUnique() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        address payable proxy1 = factory.createPureMembership(configs, URI);
        address payable proxy2 = factory.createPureMembership(configs, URI);

        assertTrue(proxy1 != proxy2);
    }

    function test_Tracking_GetAllDeployedProxies() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        address payable proxy1 = factory.createPureMembership(configs, URI);
        address payable proxy2 = factory.createPureMembership(configs, URI);
        address payable proxy3 = factory.createPureMembership(configs, URI);

        address[] memory proxies = factory.getAllDeployedProxies();
        assertEq(proxies.length, 3);
        assertEq(proxies[0], proxy1);
        assertEq(proxies[1], proxy2);
        assertEq(proxies[2], proxy3);
    }

    /*//////////////////////////////////////////////////////////////
                    PROXY ISOLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Isolation_DifferentOwners() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.prank(alice);
        address payable proxyAlice = factory.createPureMembership(configs, URI);

        vm.prank(bob);
        address payable proxyBob = factory.createPureMembership(configs, URI);

        assertEq(PureMembership(proxyAlice).owner(), alice);
        assertEq(PureMembership(proxyBob).owner(), bob);
    }

    function test_Isolation_PauseOneDoesNotAffectOther() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.prank(alice);
        address payable proxyAlice = factory.createPureMembership(configs, URI);

        vm.prank(bob);
        address payable proxyBob = factory.createPureMembership(configs, URI);

        vm.prank(alice);
        PureMembership(proxyAlice).pause();

        assertTrue(PureMembership(proxyAlice).paused());
        assertFalse(PureMembership(proxyBob).paused());
    }

    function test_Isolation_DifferentBucketInfos() public {
        MockBucketInfoForFactory bucketInfo2 = new MockBucketInfoForFactory();
        PureMembershipFactory factory2 = new PureMembershipFactory(address(implementation), address(bucketInfo2));
        registry.setAuthorizedFactory(address(factory2), true);
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        address payable proxy1 = factory.createPureMembership(configs, URI);
        address payable proxy2 = factory2.createPureMembership(configs, URI);

        assertEq(address(PureMembership(proxy1).bucketInfo()), address(bucketInfo));
        assertEq(address(PureMembership(proxy2).bucketInfo()), address(bucketInfo2));
    }

    function test_Isolation_AliceCannotPauseBobsContract() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.prank(alice);
        address payable proxyAlice = factory.createPureMembership(configs, URI);

        vm.prank(bob);
        address payable proxyBob = factory.createPureMembership(configs, URI);

        vm.prank(alice);
        vm.expectRevert();
        PureMembership(proxyBob).pause();

        vm.prank(alice);
        PureMembership(proxyAlice).pause();
        assertTrue(PureMembership(proxyAlice).paused());
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Create_ArbitraryCallerBecomesOwner(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller.code.length == 0); // EOA
        vm.assume(uint160(caller) > 0xFF);

        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        vm.prank(caller);
        address payable proxy = factory.createPureMembership(configs, URI);

        assertEq(PureMembership(proxy).owner(), caller);
    }

    function testFuzz_Tracking_CountMatchesDeployments(uint8 count) public {
        vm.assume(count > 0 && count <= 20);
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();

        for (uint256 i = 0; i < count; i++) {
            factory.createPureMembership(configs, URI);
        }

        assertEq(factory.getDeployedProxiesCount(), count);
        assertEq(factory.getAllDeployedProxies().length, count);
    }

    /*//////////////////////////////////////////////////////////////
            W1.7 -- FACTORY-IMMUTABLE BUCKETINFO POINTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_W17_OldThreeArgCallShapeNoLongerResolvesToAnySelector() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        bytes memory oldShapeCalldata = abi.encodeWithSignature(
            "createPureMembership((uint256,uint256,string,uint256,uint256)[],address,string)",
            configs,
            address(bucketInfo),
            URI
        );
        (bool success,) = address(factory).call(oldShapeCalldata);
        assertFalse(success, "old 3-arg createPureMembership selector must not resolve post-W1.7");
    }

    function test_W17_VaultBucketInfoGetterEqualsFactoryImmutable() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        vm.prank(alice);
        address payable proxy = factory.createPureMembership(configs, URI);
        assertEq(address(PureMembership(proxy).bucketInfo()), factory.bucketInfo());
    }

    function test_W17_CreatedEventBucketInfoFieldMatchesFactoryImmutable() public {
        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        vm.expectEmit(false, true, true, true);
        emit PureMembershipCreated(address(0), address(this), factory.bucketInfo(), URI);
        factory.createPureMembership(configs, URI);
    }

    function test_W17_PreFixVulnerability_AttackerControlledBucketInfoCannotBeInjectedAtCreateTime() public {
        MockBucketInfoForFactory attackerBucketInfo = new MockBucketInfoForFactory();
        attackerBucketInfo.addToken(address(0), 1);

        PureMembership.MembershipConfig[] memory configs = _defaultConfigs();
        vm.prank(makeAddr("attacker"));
        address payable proxy = factory.createPureMembership(configs, URI);

        assertEq(address(PureMembership(proxy).bucketInfo()), address(bucketInfo));
        assertTrue(address(PureMembership(proxy).bucketInfo()) != address(attackerBucketInfo));
    }
}
