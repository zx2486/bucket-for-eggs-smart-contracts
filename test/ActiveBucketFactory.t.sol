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
        factory = new ActiveBucketFactory(address(implementation), address(bucketInfo));
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_StoresImplementation() public view {
        assertEq(factory.implementation(), address(implementation));
    }

    // W1.7: bucketInfo is now a constructor parameter, stored immutable.
    function test_Constructor_StoresBucketInfo() public view {
        assertEq(factory.bucketInfo(), address(bucketInfo));
    }

    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(ActiveBucketFactory.InvalidImplementation.selector);
        new ActiveBucketFactory(address(0), address(bucketInfo));
    }

    // W1.7: the constructor's new second parameter gets its own zero-check, independent of
    // the implementation zero-check above.
    function test_Constructor_ZeroBucketInfoReverts() public {
        vm.expectRevert(ActiveBucketFactory.InvalidBucketInfo.selector);
        new ActiveBucketFactory(address(implementation), address(0));
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
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertTrue(proxy != address(0));
    }

    function test_Create_OwnerIsCallerNotFactory() public {
        vm.prank(alice);
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertEq(ActiveBucket(payable(proxy)).owner(), alice);
    }

    function test_Create_OwnerIsNotFactory() public {
        vm.prank(alice);
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertTrue(ActiveBucket(payable(proxy)).owner() != address(factory));
    }

    // W1.7: bucketInfo is no longer a caller-supplied createActiveBucket argument -- the created
    // vault's bucketInfo() getter must equal the FACTORY's own immutable value.
    function test_Create_BucketInfoIsSet() public {
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertEq(address(ActiveBucket(payable(proxy)).bucketInfo()), address(bucketInfo));
        assertEq(address(ActiveBucket(payable(proxy)).bucketInfo()), factory.bucketInfo());
    }

    function test_Create_OneInchRouterIsSet() public {
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertEq(ActiveBucket(payable(proxy)).oneInchRouter(), mockOneInch);
    }

    function test_Create_ERC20NameAndSymbol() public {
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        ActiveBucket ab = ActiveBucket(payable(proxy));
        assertEq(ab.name(), NAME);
        assertEq(ab.symbol(), SYMBOL);
    }

    function test_Create_DefaultPerformanceFee() public {
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        ActiveBucket ab = ActiveBucket(payable(proxy));
        assertEq(ab.performanceFeeBps(), 1400); // 14% default
    }

    // W1.7: InvalidBucketInfo now fires at construction time (see
    // test_Constructor_ZeroBucketInfoReverts), not at create-call time -- there is no longer a
    // bucketInfo parameter on createActiveBucket to be zero. Superseded, kept as a named marker
    // so a reader searching for the old test name finds this note instead of a silent deletion.
    function test_Create_ZeroBucketInfoReverts_SUPERSEDED_seeConstructorTest() public pure {
        // Intentionally empty: the behaviour this used to assert now lives in
        // test_Constructor_ZeroBucketInfoReverts.
    }

    function test_Create_ZeroOneInchReverts() public {
        vm.expectRevert(ActiveBucketFactory.InvalidOneInchRouter.selector);
        factory.createActiveBucket(address(0), NAME, SYMBOL);
    }

    function test_Create_EmitsEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

        // Verify via returned proxy
        assertEq(ActiveBucket(payable(proxy)).owner(), alice);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Create_EmitsEventWithCorrectFields() public {
        vm.prank(alice);
        vm.expectEmit(false, true, true, false); // skip proxy (unknown), check owner + bucketInfo
        emit ActiveBucketCreated(address(0), alice, address(bucketInfo), NAME, SYMBOL);
        factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
    }

    function test_Create_ProxyIsIndependentOfImplementation() public {
        // Calling initialize on the implementation directly should revert (already disabled)
        vm.expectRevert();
        implementation.initialize(address(bucketInfo), mockOneInch, NAME, SYMBOL);

        // But factory deploy still works
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertTrue(proxy != address(0));
    }

    function test_Create_CustomNameAndSymbol() public {
        address proxy = factory.createActiveBucket(mockOneInch, "My Active Fund", "MAF");
        ActiveBucket ab = ActiveBucket(payable(proxy));
        assertEq(ab.name(), "My Active Fund");
        assertEq(ab.symbol(), "MAF");
    }

    /*//////////////////////////////////////////////////////////////
                    TRACKING / DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Tracking_SingleDeployment() public {
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertEq(factory.getDeployedProxiesCount(), 1);
        assertEq(factory.deployedProxies(0), proxy);
    }

    function test_Tracking_MultipleDeployments() public {
        vm.prank(alice);
        address proxy1 = factory.createActiveBucket(mockOneInch, "Bucket A", "BA");

        vm.prank(bob);
        address proxy2 = factory.createActiveBucket(mockOneInch, "Bucket B", "BB");

        assertEq(factory.getDeployedProxiesCount(), 2);
        assertEq(factory.deployedProxies(0), proxy1);
        assertEq(factory.deployedProxies(1), proxy2);
    }

    function test_Tracking_ProxiesAreUnique() public {
        address proxy1 = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertTrue(proxy1 != proxy2);
    }

    function test_Tracking_GetAllDeployedProxies() public {
        address proxy1 = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        address proxy2 = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        address proxy3 = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

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
        address proxyAlice = factory.createActiveBucket(mockOneInch, "Alice Bucket", "ALI");

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(mockOneInch, "Bob Bucket", "BOB");

        assertEq(ActiveBucket(payable(proxyAlice)).owner(), alice);
        assertEq(ActiveBucket(payable(proxyBob)).owner(), bob);
    }

    function test_Isolation_PauseOneDoesNotAffectOther() public {
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

        ActiveBucket abAlice = ActiveBucket(payable(proxyAlice));
        ActiveBucket abBob = ActiveBucket(payable(proxyBob));

        // Alice pauses her contract
        vm.prank(alice);
        abAlice.pause();

        assertTrue(abAlice.paused());
        assertFalse(abBob.paused());
    }

    // W1.7: bucketInfo is factory-immutable, so two proxies with different bucketInfo values can
    // no longer come from the SAME factory instance (that per-call divergence was exactly the
    // vulnerability the fix closes -- see test_W17_PreFix_DifferentCallersCouldNotDivergeAnyway
    // below for the direct proof). Two different BucketInfo pointers now require two different
    // FACTORY instances, each with its own immutable value.
    function test_Isolation_DifferentBucketInfos() public {
        MockBucketInfoForABFactory bucketInfo2 = new MockBucketInfoForABFactory();
        bucketInfo2.addToken(address(0), ETH_PRICE);
        bucketInfo2.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo2.addToken(address(tokenB), TOKEN_B_PRICE);

        ActiveBucketFactory factory2 = new ActiveBucketFactory(address(implementation), address(bucketInfo2));

        address proxy1 = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        address proxy2 = factory2.createActiveBucket(mockOneInch, NAME, SYMBOL);

        assertEq(address(ActiveBucket(payable(proxy1)).bucketInfo()), address(bucketInfo));
        assertEq(address(ActiveBucket(payable(proxy2)).bucketInfo()), address(bucketInfo2));
    }

    function test_Isolation_AliceCannotPauseBobsContract() public {
        vm.prank(alice);
        address proxyAlice = factory.createActiveBucket(mockOneInch, "Alice Bucket", "ALI");

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(mockOneInch, "Bob Bucket", "BOB");

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
        address proxyAlice = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

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
        address proxyAlice = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

        vm.prank(bob);
        address proxyBob = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

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
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertEq(ActiveBucket(payable(proxy)).owner(), caller);
    }

    function testFuzz_Tracking_CountMatchesDeployments(uint8 count) public {
        vm.assume(count > 0 && count <= 20);

        for (uint256 i = 0; i < count; i++) {
            factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        }

        assertEq(factory.getDeployedProxiesCount(), count);
        assertEq(factory.getAllDeployedProxies().length, count);
    }

    /*//////////////////////////////////////////////////////////////
            W1.7 -- FACTORY-IMMUTABLE BUCKETINFO POINTER TESTS
       See root CLAUDE.md §1.1 (the precondition under the ownership table) and
       src/ActiveBucketFactory.sol `bucketInfo` doc comment for the full rationale.
    //////////////////////////////////////////////////////////////*/

    // (1) The old caller-supplied-bucketInfo call shape no longer exists as a Solidity function
    // signature -- every call site above in this file already had to drop the leading
    // `address(bucketInfo)` argument for the whole file to compile (see git diff on this file).
    // This test additionally proves it at the ABI level: encoding the OLD 4-argument call
    // (address,address,string,string) and sending it as raw calldata must revert, because no
    // function selector in the deployed factory matches it and the factory has no fallback.
    function test_W17_OldFourArgCallShapeNoLongerResolvesToAnySelector() public {
        bytes memory oldShapeCalldata = abi.encodeWithSignature(
            "createActiveBucket(address,address,string,string)", address(bucketInfo), mockOneInch, NAME, SYMBOL
        );
        (bool success,) = address(factory).call(oldShapeCalldata);
        assertFalse(success, "old 4-arg createActiveBucket selector must not resolve post-W1.7");
    }

    // (2) The created vault's bucketInfo() getter equals the FACTORY's own immutable value.
    // (Already covered functionally by test_Create_BucketInfoIsSet above; restated here under the
    // W1.7 name so the wave's required test list is directly greppable.)
    function test_W17_VaultBucketInfoGetterEqualsFactoryImmutable() public {
        vm.prank(alice);
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
        assertEq(address(ActiveBucket(payable(proxy)).bucketInfo()), factory.bucketInfo());
    }

    // (3) The ActiveBucketCreated event's bucketInfo field matches the factory's immutable value,
    // not any value the caller might have tried to supply.
    function test_W17_CreatedEventBucketInfoFieldMatchesFactoryImmutable() public {
        vm.expectEmit(false, true, true, true);
        emit ActiveBucketCreated(address(0), address(this), factory.bucketInfo(), NAME, SYMBOL);
        factory.createActiveBucket(mockOneInch, NAME, SYMBOL);
    }

    // (4) Pre-fix-vulnerability proof. Before W1.7, createActiveBucket accepted a caller-supplied
    // `bucketInfoAddr` with only a zero-address check (ActiveBucketFactory.sol, pre-fix :51/:56)
    // -- any caller could deploy a vault wired to a BucketInfo-shaped contract THEY control,
    // defeating the 00:44 oracle protection (root CLAUDE.md §1.1, updateBucketInfo is gated on
    // *BucketInfo's* owner precisely so a vault owner cannot swap the price feed). This test
    // constructs exactly such an attacker-controlled mock -- one that reports itself as
    // "operational" and would happily serve manipulated prices -- and demonstrates that under the
    // fixed factory there is NO parameter through which it can reach a created vault: every proxy
    // this factory creates is wired to `factory.bucketInfo()`, deployed once by whoever deployed
    // the factory (an untrusted vault customer per root CLAUDE.md §1.1's ownership table cannot
    // reach it at create-call time at all).
    function test_W17_PreFixVulnerability_AttackerControlledBucketInfoCannotBeInjectedAtCreateTime() public {
        // The attacker deploys their own BucketInfo-shaped contract, e.g. to serve a manipulated
        // price and rug-pull investors in a vault they trick into using it.
        MockBucketInfoForABFactory attackerBucketInfo = new MockBucketInfoForABFactory();
        attackerBucketInfo.addToken(address(0), 1); // attacker sets an absurd, self-serving price

        // Pre-fix, the attacker could call:
        //   factory.createActiveBucket(address(attackerBucketInfo), mockOneInch, NAME, SYMBOL)
        // and the resulting vault would be permanently wired to their hostile BucketInfo.
        // Post-fix, createActiveBucket has no bucketInfo parameter at all -- the attacker, acting
        // as an ordinary (untrusted) caller, can only ever get a vault wired to
        // `factory.bucketInfo()`, which was fixed at FACTORY DEPLOYMENT TIME by whoever deployed
        // the factory, not by them.
        vm.prank(makeAddr("attacker"));
        address proxy = factory.createActiveBucket(mockOneInch, NAME, SYMBOL);

        assertEq(address(ActiveBucket(payable(proxy)).bucketInfo()), address(bucketInfo));
        assertTrue(address(ActiveBucket(payable(proxy)).bucketInfo()) != address(attackerBucketInfo));
    }
}
