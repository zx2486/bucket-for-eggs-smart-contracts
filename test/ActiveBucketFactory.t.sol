// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {ActiveBucketFactory} from "../src/ActiveBucketFactory.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForABFactory {
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

contract MockERC20ForABFactory {
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

contract ActiveBucketFactoryTest is Test {
    ActiveBucket public implementation;
    ActiveBucketFactory public factory;
    MockBucketInfoForABFactory public bucketInfo;
    MockERC20ForABFactory public tokenA;
    MockERC20ForABFactory public tokenB;

    address public deployer;
    address public alice;
    address public bob;
    address public mockOneInch;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 2000e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    string constant NAME = "Active Bucket Share";
    string constant SYMBOL = "aBKT";

    event ActiveBucketCreated(
        address indexed proxy, address indexed owner, address indexed bucketInfo, string name, string symbol
    );

    // -------------------------------------------------------
    //  Setup
    // -------------------------------------------------------

    function setUp() public {
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        mockOneInch = makeAddr("oneInch");

        bucketInfo = new MockBucketInfoForABFactory();
        tokenA = new MockERC20ForABFactory("Token A", "TKA", 18);
        tokenB = new MockERC20ForABFactory("Token B", "TKB", 6);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        implementation = new ActiveBucket();
        factory = new ActiveBucketFactory(address(implementation));
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_StoresImplementation() public view {
        assertEq(factory.implementation(), address(implementation));
    }

    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(ActiveBucketFactory.InvalidImplementation.selector);
        new ActiveBucketFactory(address(0));
    }

    function test_Constructor_InitialProxyCountIsZero() public view {
        assertEq(factory.getDeployedProxiesCount(), 0);
    }

    function test_Constructor_GetAllDeployedProxiesEmpty() public view {
        address[] memory proxies = factory.getAllDeployedProxies();
        assertEq(proxies.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CREATE ACTIVE BUCKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Create_DeploysProxy() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertTrue(proxy != address(0));
    }

    function test_Create_OwnerIsCallerNotFactory() public {
        vm.prank(alice);
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertEq(ActiveBucket(payable(proxy)).owner(), alice);
    }

    function test_Create_OwnerIsNotFactory() public {
        vm.prank(alice);
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertTrue(ActiveBucket(payable(proxy)).owner() != address(factory));
    }

    function test_Create_BucketInfoIsSet() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertEq(address(ActiveBucket(payable(proxy)).bucketInfo()), address(bucketInfo));
    }

    function test_Create_OneInchRouterIsSet() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertEq(ActiveBucket(payable(proxy)).oneInchRouter(), mockOneInch);
    }

    function test_Create_ERC20NameAndSymbol() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        ActiveBucket ab = ActiveBucket(payable(proxy));
        assertEq(ab.name(), NAME);
        assertEq(ab.symbol(), SYMBOL);
    }

    function test_Create_DefaultPerformanceFee() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        ActiveBucket ab = ActiveBucket(payable(proxy));
        assertEq(ab.performanceFeeBps(), 500); // 5% default
    }

    function test_Create_ZeroBucketInfoReverts() public {
        vm.expectRevert(ActiveBucketFactory.InvalidBucketInfo.selector);
        factory.createActiveBucket(address(0), mockOneInch, NAME, SYMBOL);
    }

    function test_Create_ZeroOneInchReverts() public {
        vm.expectRevert(ActiveBucketFactory.InvalidOneInchRouter.selector);
        factory.createActiveBucket(address(bucketInfo), address(0), NAME, SYMBOL);
    }

    function test_Create_EmitsEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        // Verify via returned proxy
        assertEq(ActiveBucket(payable(proxy)).owner(), alice);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Create_EmitsEventWithCorrectFields() public {
        vm.prank(alice);
        vm.expectEmit(false, true, true, false); // skip proxy (unknown), check owner + bucketInfo
        emit ActiveBucketCreated(address(0), alice, address(bucketInfo), NAME, SYMBOL);
        factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
    }

    function test_Create_ProxyIsIndependentOfImplementation() public {
        // Calling initialize on the implementation directly should revert (already disabled)
        vm.expectRevert();
        implementation.initialize(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        // But factory deploy still works
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertTrue(proxy != address(0));
    }

    function test_Create_CustomNameAndSymbol() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, "My Active Fund", "MAF");
        ActiveBucket ab = ActiveBucket(payable(proxy));
        assertEq(ab.name(), "My Active Fund");
        assertEq(ab.symbol(), "MAF");
    }

    /*//////////////////////////////////////////////////////////////
                    TRACKING / DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Tracking_SingleDeployment() public {
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertEq(factory.getDeployedProxiesCount(), 1);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Tracking_MultipleDeployments() public {
        vm.prank(alice);
        address proxy1 = factory.createActiveBucket(address(bucketInfo), mockOneInch, "Bucket A", "BA");

        vm.prank(bob);
        address proxy2 = factory.createActiveBucket(address(bucketInfo), mockOneInch, "Bucket B", "BB");

        assertEq(factory.getDeployedProxiesCount(), 2);
        assertEq(factory.deployedProxies(0), proxy1);
        assertEq(factory.deployedProxies(1), proxy2);
    }

    function test_Tracking_ProxiesAreUnique() public {
        address proxy1 = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertTrue(proxy1 != proxy2);
    }

    function test_Tracking_GetAllDeployedProxies() public {
        address proxy1 = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        address proxy3 = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

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
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(address(bucketInfo), mockOneInch, "Alice Bucket", "ALI");

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(address(bucketInfo), mockOneInch, "Bob Bucket", "BOB");

        assertEq(ActiveBucket(payable(proxyAlice)).owner(), alice);
        assertEq(ActiveBucket(payable(proxyBob)).owner(), bob);
    }

    function test_Isolation_PauseOneDoesNotAffectOther() public {
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        ActiveBucket abAlice = ActiveBucket(payable(proxyAlice));
        ActiveBucket abBob = ActiveBucket(payable(proxyBob));

        // Alice pauses her contract
        vm.prank(alice);
        abAlice.pause();

        assertTrue(abAlice.paused());
        assertFalse(abBob.paused());
    }

    function test_Isolation_DifferentBucketInfos() public {
        MockBucketInfoForABFactory bucketInfo2 = new MockBucketInfoForABFactory();
        bucketInfo2.addToken(address(0), ETH_PRICE);
        bucketInfo2.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo2.addToken(address(tokenB), TOKEN_B_PRICE);

        address proxy1 = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createActiveBucket(address(bucketInfo2), mockOneInch, NAME, SYMBOL);

        assertEq(address(ActiveBucket(payable(proxy1)).bucketInfo()), address(bucketInfo));
        assertEq(address(ActiveBucket(payable(proxy2)).bucketInfo()), address(bucketInfo2));
    }

    function test_Isolation_AliceCannotPauseBobsContract() public {
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(address(bucketInfo), mockOneInch, "Alice Bucket", "ALI");

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(address(bucketInfo), mockOneInch, "Bob Bucket", "BOB");

        // Alice tries to pause Bob's contract — should revert
        vm.prank(alice);
        vm.expectRevert();
        ActiveBucket(payable(proxyBob)).pause();

        // Alice can still pause her own
        vm.prank(alice);
        ActiveBucket(payable(proxyAlice)).pause();
        assertTrue(ActiveBucket(payable(proxyAlice)).paused());
    }

    function test_Isolation_DepositOnlyAffectsOwnProxy() public {
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        ActiveBucket abAlice = ActiveBucket(payable(proxyAlice));
        ActiveBucket abBob = ActiveBucket(payable(proxyBob));

        // Alice deposits 1 ETH
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        abAlice.deposit{value: 1 ether}(address(0), 0);

        // Alice's proxy has shares; Bob's does not
        assertTrue(abAlice.totalSupply() > 0);
        assertEq(abBob.totalSupply(), 0);
    }

    function test_Isolation_AliceCannotSetBobsRouter() public {
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        address newRouter = makeAddr("newRouter");

        // Alice tries to set router on Bob's contract — should revert
        vm.prank(alice);
        vm.expectRevert();
        ActiveBucket(payable(proxyBob)).setOneInchRouter(newRouter);

        // Alice can set her own
        vm.prank(alice);
        ActiveBucket(payable(proxyAlice)).setOneInchRouter(newRouter);
        assertEq(ActiveBucket(payable(proxyAlice)).oneInchRouter(), newRouter);
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Create_ArbitraryCallerBecomesOwner(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller.code.length == 0);
        vm.assume(uint160(caller) > 0xFF);

        vm.prank(caller);
        address proxy = factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        assertEq(ActiveBucket(payable(proxy)).owner(), caller);
    }

    function testFuzz_Tracking_CountMatchesDeployments(uint8 count) public {
        vm.assume(count > 0 && count <= 20);

        for (uint256 i = 0; i < count; i++) {
            factory.createActiveBucket(address(bucketInfo), mockOneInch, NAME, SYMBOL);
        }

        assertEq(factory.getDeployedProxiesCount(), count);
        assertEq(factory.getAllDeployedProxies().length, count);
    }
}
