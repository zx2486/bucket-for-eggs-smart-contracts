// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PassiveBucketFactory} from "../src/PassiveBucketFactory.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForPBFactory {
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

    receive() external payable {}
}

contract MockERC20ForPBFactory {
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

contract PassiveBucketFactoryTest is Test {
    PassiveBucket public implementation;
    PassiveBucketFactory public factory;
    MockBucketInfoForPBFactory public bucketInfo;
    MockERC20ForPBFactory public tokenA;
    MockERC20ForPBFactory public tokenB;

    address public deployer;
    address public alice;
    address public bob;
    address public mockOneInch;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 2000e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    string constant NAME = "PassiveBucket Share";
    string constant SYMBOL = "pBKT";

    event PassiveBucketCreated(
        address indexed proxy, address indexed owner, address indexed bucketInfo, string name, string symbol
    );

    // -------------------------------------------------------
    //  Helpers
    // -------------------------------------------------------

    /// @dev Default 3-token distribution: 50% ETH, 30% Token A, 20% Token B
    function _defaultDists() internal view returns (PassiveBucket.BucketDistribution[] memory dists) {
        dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);
    }

    // -------------------------------------------------------
    //  Setup
    // -------------------------------------------------------

    function setUp() public {
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        mockOneInch = makeAddr("oneInch");

        bucketInfo = new MockBucketInfoForPBFactory();
        tokenA = new MockERC20ForPBFactory("Token A", "TKA", 18);
        tokenB = new MockERC20ForPBFactory("Token B", "TKB", 6);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        implementation = new PassiveBucket();
        factory = new PassiveBucketFactory(address(implementation));
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_StoresImplementation() public view {
        assertEq(factory.implementation(), address(implementation));
    }

    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(PassiveBucketFactory.InvalidImplementation.selector);
        new PassiveBucketFactory(address(0));
    }

    function test_Constructor_InitialProxyCountIsZero() public view {
        assertEq(factory.getDeployedProxiesCount(), 0);
    }

    function test_Constructor_GetAllDeployedProxiesEmpty() public view {
        address[] memory proxies = factory.getAllDeployedProxies();
        assertEq(proxies.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CREATE PASSIVE BUCKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Create_DeploysProxy() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertTrue(proxy != address(0));
    }

    function test_Create_OwnerIsCallerNotFactory() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        vm.prank(alice);
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertEq(PassiveBucket(payable(proxy)).owner(), alice);
    }

    function test_Create_OwnerIsNotFactory() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        vm.prank(alice);
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertTrue(PassiveBucket(payable(proxy)).owner() != address(factory));
    }

    function test_Create_BucketInfoIsSet() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertEq(address(PassiveBucket(payable(proxy)).bucketInfo()), address(bucketInfo));
    }

    function test_Create_OneInchRouterIsSet() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertEq(PassiveBucket(payable(proxy)).oneInchRouter(), mockOneInch);
    }

    function test_Create_ERC20NameAndSymbol() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        PassiveBucket pb = PassiveBucket(payable(proxy));
        assertEq(pb.name(), NAME);
        assertEq(pb.symbol(), SYMBOL);
    }

    function test_Create_DistributionsAreStored() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        PassiveBucket pb = PassiveBucket(payable(proxy));

        PassiveBucket.BucketDistribution[] memory stored = pb.getBucketDistributions();
        assertEq(stored.length, 3);
        assertEq(stored[0].token, address(0));
        assertEq(stored[0].weight, 50);
        assertEq(stored[1].token, address(tokenA));
        assertEq(stored[1].weight, 30);
        assertEq(stored[2].token, address(tokenB));
        assertEq(stored[2].weight, 20);
    }

    function test_Create_ZeroBucketInfoReverts() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        vm.expectRevert(PassiveBucketFactory.InvalidBucketInfo.selector);
        factory.createPassiveBucket(address(0), dists, mockOneInch, NAME, SYMBOL);
    }

    function test_Create_ZeroOneInchReverts() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        vm.expectRevert(PassiveBucketFactory.InvalidOneInchRouter.selector);
        factory.createPassiveBucket(address(bucketInfo), dists, address(0), NAME, SYMBOL);
    }

    function test_Create_EmitsEvent() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.recordLogs();
        vm.prank(alice);
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        // Verify via returned proxy
        assertEq(PassiveBucket(payable(proxy)).owner(), alice);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Create_EmitsEventWithCorrectFields() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(alice);
        vm.expectEmit(false, true, true, false); // skip proxy (unknown), check owner + bucketInfo
        emit PassiveBucketCreated(address(0), alice, address(bucketInfo), NAME, SYMBOL);
        factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
    }

    function test_Create_ProxyIsIndependentOfImplementation() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        // Calling initialize on the implementation directly should revert (already disabled)
        vm.expectRevert();
        implementation.initialize(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        // But factory deploy still works
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertTrue(proxy != address(0));
    }

    function test_Create_CustomNameAndSymbol() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, "My Bucket", "MBK");
        PassiveBucket pb = PassiveBucket(payable(proxy));
        assertEq(pb.name(), "My Bucket");
        assertEq(pb.symbol(), "MBK");
    }

    /*//////////////////////////////////////////////////////////////
                    TRACKING / DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Tracking_SingleDeployment() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertEq(factory.getDeployedProxiesCount(), 1);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Tracking_MultipleDeployments() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(alice);
        address proxy1 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, "Bucket A", "BA");

        vm.prank(bob);
        address proxy2 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, "Bucket B", "BB");

        assertEq(factory.getDeployedProxiesCount(), 2);
        assertEq(factory.deployedProxies(0), proxy1);
        assertEq(factory.deployedProxies(1), proxy2);
    }

    function test_Tracking_ProxiesAreUnique() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        address proxy1 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertTrue(proxy1 != proxy2);
    }

    function test_Tracking_GetAllDeployedProxies() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        address proxy1 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        address proxy3 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

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
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(alice);
        address proxyAlice = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, "Alice Bucket", "ALI");

        vm.prank(bob);
        address proxyBob = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, "Bob Bucket", "BOB");

        assertEq(PassiveBucket(payable(proxyAlice)).owner(), alice);
        assertEq(PassiveBucket(payable(proxyBob)).owner(), bob);
    }

    function test_Isolation_PauseOneDoesNotAffectOther() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(alice);
        address proxyAlice = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        PassiveBucket pbAlice = PassiveBucket(payable(proxyAlice));
        PassiveBucket pbBob = PassiveBucket(payable(proxyBob));

        // Alice pauses her contract (need shares for accountability)
        // Deposit to build accountability first
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        pbAlice.deposit{value: 1 ether}(address(0), 0);

        vm.prank(alice);
        pbAlice.pause();

        assertTrue(pbAlice.paused());
        assertFalse(pbBob.paused());
    }

    function test_Isolation_DifferentBucketInfos() public {
        MockBucketInfoForPBFactory bucketInfo2 = new MockBucketInfoForPBFactory();
        bucketInfo2.addToken(address(0), ETH_PRICE);
        bucketInfo2.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo2.addToken(address(tokenB), TOKEN_B_PRICE);

        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        address proxy1 = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createPassiveBucket(address(bucketInfo2), dists, mockOneInch, NAME, SYMBOL);

        assertEq(address(PassiveBucket(payable(proxy1)).bucketInfo()), address(bucketInfo));
        assertEq(address(PassiveBucket(payable(proxy2)).bucketInfo()), address(bucketInfo2));
    }

    function test_Isolation_AliceCannotPauseBobsContract() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(alice);
        address proxyAlice = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        // Alice tries to pause Bob's contract — should revert
        vm.prank(alice);
        vm.expectRevert();
        PassiveBucket(payable(proxyBob)).pause();

        // Alice can still deposit+pause her own
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        PassiveBucket(payable(proxyAlice)).deposit{value: 1 ether}(address(0), 0);
        vm.prank(alice);
        PassiveBucket(payable(proxyAlice)).pause();
        assertTrue(PassiveBucket(payable(proxyAlice)).paused());
    }

    function test_Isolation_DepositOnlyAffectsOwnProxy() public {
        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(alice);
        address proxyAlice = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);

        PassiveBucket pbAlice = PassiveBucket(payable(proxyAlice));
        PassiveBucket pbBob = PassiveBucket(payable(proxyBob));

        // Alice deposits 1 ETH
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        pbAlice.deposit{value: 1 ether}(address(0), 0);

        // Alice's proxy has shares; Bob's does not
        assertTrue(pbAlice.totalSupply() > 0);
        assertEq(pbBob.totalSupply(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Create_ArbitraryCallerBecomesOwner(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller.code.length == 0);
        vm.assume(uint160(caller) > 0xFF);

        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        vm.prank(caller);
        address proxy = factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        assertEq(PassiveBucket(payable(proxy)).owner(), caller);
    }

    function testFuzz_Tracking_CountMatchesDeployments(uint8 count) public {
        vm.assume(count > 0 && count <= 20);

        PassiveBucket.BucketDistribution[] memory dists = _defaultDists();

        for (uint256 i = 0; i < count; i++) {
            factory.createPassiveBucket(address(bucketInfo), dists, mockOneInch, NAME, SYMBOL);
        }

        assertEq(factory.getDeployedProxiesCount(), count);
        assertEq(factory.getAllDeployedProxies().length, count);
    }
}
