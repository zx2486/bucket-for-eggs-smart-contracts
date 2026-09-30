// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForPassive {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
    address public owner;
    /// @dev W2 (sc-vault-exit): lets a test make every `getTokenPrice` call revert regardless of
    /// whitelist status, to prove `redeem()` no longer calls the oracle at all (INV-1).
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

    // --- Helpers for tests ---
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
    // Simulates a swap by taking tokenIn and giving tokenOut
    address public tokenIn;
    address public tokenOut;
    uint256 public rate; // how much tokenOut per tokenIn (in tokenOut units per tokenIn unit)

    function setSwap(address _tokenIn, address _tokenOut, uint256 _rate) external {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        rate = _rate;
    }

    fallback() external payable {
        // Simple mock: transfer tokenOut to the caller based on rate
        // Assumes tokens are pre-funded
    }

    receive() external payable {}
}

// ============================================================
//                      TEST CONTRACT
// ============================================================

contract PassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA; // 18 decimals (like WETH)
    MockERC20 public tokenB; // 6 decimals (like USDT)
    MockOneInchRouter public oneInchRouter;

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
    // W2 (sc-vault-exit): kept in sync with the real, redesigned `BucketVaultBase.Redeemed` event
    // (was a stale 2-field signature). Unused directly in this file (no `vm.expectEmit` matches
    // it, unlike `Deposited` above) — tests instead reference `BucketVaultBase.Redeemed` directly.
    event Redeemed(address indexed user, uint256 shares, uint256 supply, address[] tokens, uint256[] amounts);
    event BucketDistributionsUpdated(PassiveBucket.BucketDistribution[] distributions);
    event SwapPauseChanged(bool paused);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mocks
        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        oneInchRouter = new MockOneInchRouter();

        // Setup BucketInfo
        bucketInfo.addToken(address(0), ETH_PRICE); // ETH
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE); // Token A
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE); // Token B

        // Deploy implementation
        implementation = new PassiveBucket();

        // Prepare distributions: 50% ETH, 30% Token A, 20% Token B
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

        // Deploy proxy
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

        // Fund test accounts
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        tokenA.mint(user1, 100e18);
        tokenA.mint(user2, 100e18);
        tokenB.mint(user1, 100000e6);
        tokenB.mint(user2, 100000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialization() public view {
        assertEq(bucket.name(), "PassiveBucket Share");
        assertEq(bucket.symbol(), "pBKT");
        assertEq(bucket.owner(), owner);
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), address(oneInchRouter));
        assertEq(bucket.tokenPrice(), 0); // Not yet set
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
        PassiveBucket impl = new PassiveBucket();
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        // Zero bucketInfo
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(0), dists, address(oneInchRouter), "Test", "TST"
        );
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeInvalidWeights() public {
        PassiveBucket impl = new PassiveBucket();
        // Weights sum to 90 instead of 100
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
        PassiveBucket impl = new PassiveBucket();
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
        PassiveBucket impl = new PassiveBucket();
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](0);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(oneInchRouter), "Test", "TST"
        );
        vm.expectRevert(PassiveBucket.EmptyDistributions.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositETH() public {
        uint256 depositAmount = 1 ether;

        vm.prank(user1);
        bucket.deposit{value: depositAmount}(address(0), 0);

        // tokenPrice should be initialized to 1e8
        assertEq(bucket.tokenPrice(), 1e8);

        // shares = (1e18 * 2000e8 / 1e18) * 1e18 / 1e8 = 2000e8 * 1e18 / 1e8 = 2000e18
        // W2 (sc-vault-entry): this is the vault's FIRST deposit, so `DEAD_SHARES` (INV-6) was
        // carved out of user1's own mint (see BucketVaultBase.DEAD_SHARES) — user1 nets
        // rawExpectedShares - DEAD_SHARES, not the full raw amount.
        uint256 rawExpectedShares = (((depositAmount * ETH_PRICE) / 1e18) * 1e18) / 1e8;
        assertEq(bucket.balanceOf(user1), rawExpectedShares - bucket.DEAD_SHARES());
        assertEq(bucket.totalDepositValue(), 2000e8);
        assertEq(address(bucket).balance, depositAmount);
    }

    function test_DepositERC20() public {
        uint256 depositAmount = 1000e6; // 1000 USDT

        vm.startPrank(user1);
        tokenB.approve(address(bucket), depositAmount);
        bucket.deposit(address(tokenB), depositAmount);
        vm.stopPrank();

        // shares = (1000e6 * 1e8 / 1e6) * 1e18 / 1e8 = 1000e8 * 1e18 / 1e8 = 1000e18
        // W2 (sc-vault-entry): first deposit on a fresh bucket, so `DEAD_SHARES` is carved out —
        // see test_DepositETH's comment immediately above.
        uint256 rawExpectedShares = (((depositAmount * TOKEN_B_PRICE) / 1e6) * 1e18) / 1e8;
        assertEq(bucket.balanceOf(user1), rawExpectedShares - bucket.DEAD_SHARES());
        assertEq(bucket.totalDepositValue(), 1000e8);
    }

    function test_DepositMultipleUsers() public {
        // User1 deposits 1 ETH
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 user1Shares = bucket.balanceOf(user1);
        assertTrue(user1Shares > 0);

        // User2 deposits 2000 USDT (same value as 1 ETH)
        vm.startPrank(user2);
        tokenB.approve(address(bucket), 2000e6);
        bucket.deposit(address(tokenB), 2000e6);
        vm.stopPrank();

        uint256 user2Shares = bucket.balanceOf(user2);
        // W2 (sc-vault-entry): user1 was the FIRST depositor, so `DEAD_SHARES` (INV-6) was
        // carved out of THEIR mint only (see BucketVaultBase.DEAD_SHARES). Both deposited $2000
        // worth at an unchanged live price, so user1's shares plus the one-time dead-share floor
        // should equal user2's shares exactly (up to 1 wei of integer-division rounding).
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
        // Owner needs shares for accountability
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

    /*//////////////////////////////////////////////////////////////
                          REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RedeemShares() public {
        // Deposit ETH
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        // Redeem half
        vm.prank(user1);
        bucket.redeem(shares / 2);

        assertEq(bucket.balanceOf(user1), shares / 2);
        // Should have received ~1 ETH back (from distribution token: ETH)
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

    // CHARACTERISATION: changed in W2 (sc-vault-exit). `redeem()` no longer computes a USD
    // value on-chain at all (that required an oracle call, forbidden by INV-1), so
    // `totalWithdrawValue` is no longer incremented and stays frozen at 0 across this vault's
    // lifetime from this wave onward — see PassiveBucket.sol's doc comment on the state
    // variable. The statistic itself is preserved off-chain via the redesigned `Redeemed`
    // event, asserted below instead of the old on-chain accumulator.
    function test_RedeemTracksWithdrawValue() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.totalWithdrawValue(), 0, "totalWithdrawValue must stay frozen post-W2");
    }

    /// @notice W2 (sc-vault-exit): the `Redeemed` event's `tokens`/`amounts` are the off-chain
    /// replacement for the on-chain `totalWithdrawValue` accumulation this test used to check.
    /// UPDATED in W2 (sc-vault-entry): single depositor, full redeem no longer means shares ==
    /// supply, because the FIRST deposit's mint is net of the permanent `DEAD_SHARES` floor
    /// (INV-6) — so the payout is balance*shares/supply, not the flat deposited amount. The
    /// expected event amount below is computed from live on-chain state, not hardcoded, so this
    /// still asserts the FULL event body exactly.
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
        // `supply` param: after the full redeem, `totalSupply()` is `DEAD_SHARES`, not 0 — the
        // dead-shares floor (INV-6) is permanently unredeemable.
        emit BucketVaultBase.Redeemed(user1, shares, bucket.DEAD_SHARES(), expectedTokens, expectedAmounts);
        vm.prank(user1);
        bucket.redeem(shares);
    }

    /// @notice THE most important test in this wave (INV-1): redemption must succeed even if
    /// the price feed reverts on every single call. Proves `redeem()` makes zero oracle calls.
    function test_RedeemSucceedsWithOracleAlwaysReverting() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 5e18);
        bucket.deposit(address(tokenA), 5e18);
        vm.stopPrank();

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;
        uint256 tokenABefore = tokenA.balanceOf(user1);

        // Make every oracle call revert, unconditionally, for every token.
        bucketInfo.setAlwaysRevertPrice(true);

        // A sanity check that the oracle really is unusable now, so this test cannot pass
        // vacuously.
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

        uint256 ownerShares = bucket.balanceOf(owner);
        uint256 supply = bucket.totalSupply();

        // Owner holds ~9.09%. Redeem a small portion so owner stays above 5%.
        // Max redeemable while staying >= 5%:
        //   ownerShares - x >= 0.05 * (supply - x)  =>  x <= (ownerShares - 0.05*supply) / 0.95
        // Use a quarter of owner shares (~4.5% of remaining supply ≈ 6.98%)
        uint256 smallRedeem = ownerShares / 4;
        bucket.redeem(smallRedeem);

        assertTrue(bucket.isBucketAccountable(), "Owner should still be accountable after small redeem");

        // Now try to redeem enough to drop below 5% — should revert
        uint256 remainingOwner = bucket.balanceOf(owner);
        uint256 newSupply = bucket.totalSupply();

        // Calculate amount that would push owner below 5%
        // Need: (remainingOwner - x) / (newSupply - x) < 0.05
        // Solve: x > (remainingOwner - 0.05*newSupply) / 0.95
        uint256 threshold = ((remainingOwner * 10000) - (newSupply * 500)) / 9500;
        uint256 tooMuch = threshold + 1e18; // safely over the limit

        if (tooMuch <= remainingOwner) {
            vm.expectRevert(PassiveBucket.OwnerNotAccountable.selector);
            bucket.redeem(tooMuch);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    BUCKET DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

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
        // User deposits so owner owns < 5%
        vm.prank(user1);
        bucket.deposit{value: 100 ether}(address(0), 0);

        // Owner has 0 shares, not accountable
        PassiveBucket.BucketDistribution[] memory newDists = new PassiveBucket.BucketDistribution[](1);
        newDists[0] = PassiveBucket.BucketDistribution(address(0), 100);

        vm.expectRevert(PassiveBucket.OwnerNotAccountable.selector);
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

    /*//////////////////////////////////////////////////////////////
                      ACCOUNTABILITY TESTS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                      RECOVER TOKENS TEST
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                      TOTAL VALUE CALCULATION
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                      DEX CONFIGURATION
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                    REBALANCE BY 1INCH TESTS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                    REBALANCE BY DEFI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertRebalanceByDefiSwapPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        bucket.deposit{value: 10 ether}(address(0), 0); // owner

        bucket.pauseSwap();

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.rebalanceByDefi();
    }

    /*//////////////////////////////////////////////////////////////
                          WETH MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_SetWETH() public {
        address wethAddr = makeAddr("weth");
        bucket.setWETH(wethAddr);
        assertEq(bucket.weth(), wethAddr);
    }

    function test_RevertSetWETHZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.setWETH(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

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
        // W2 (sc-vault-entry): this is a fresh bucket's FIRST deposit, so `DEAD_SHARES` (INV-6)
        // was carved out of `shares` (see BucketVaultBase.DEAD_SHARES). A full redeem of `shares`
        // (not `supply`) returns depositAmount*shares/supply, strictly less than `depositAmount`
        // by the DEAD_SHARES fraction — computed from live on-chain state below, not assumed.
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

        // Shares should be proportional to deposits
        // shares1 / shares2 ≈ amount1 / amount2
        // W2 (sc-vault-entry): user1 was the FIRST depositor, so `DEAD_SHARES` (INV-6) was
        // carved out of THEIR mint only — add it back before checking proportionality, or a
        // small-`amount1` fuzz run spuriously fails on a real, expected, one-time cost that has
        // nothing to do with proportionality (see BucketVaultBase.DEAD_SHARES).
        if (amount2 > 0 && shares2 > 0) {
            uint256 ratio1 = ((shares1 + bucket.DEAD_SHARES()) * 1e18) / shares2;
            uint256 ratio2 = (amount1 * 1e18) / amount2;
            assertApproxEqRel(ratio1, ratio2, 1e15); // 0.1% tolerance
        }
    }

    /*//////////////////////////////////////////////////////////////
                    RECEIVE ETH TEST
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH() public {
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        (bool success,) = address(bucket).call{value: 1 ether}("");
        assertTrue(success);
    }

    /*//////////////////////////////////////////////////////////////
                    UPDATE BUCKET INFO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateBucketInfo() public {
        // Deploy a new mock BucketInfo
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        // Owner of current bucketInfo is this contract (deployed in setUp)
        bucket.updateBucketInfo(address(newBucketInfo));

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_UpdateBucketInfoFromBucketInfoOwner() public {
        // Transfer BucketInfo ownership to user1
        bucketInfo.setOwner(user1);

        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        // user1 (the BucketInfo owner) can update
        vm.prank(user1);
        bucket.updateBucketInfo(address(newBucketInfo));

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoUnauthorized() public {
        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();

        // user1 is NOT the BucketInfo owner
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.UnauthorizedBucketInfoUpdate.selector);
        bucket.updateBucketInfo(address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.updateBucketInfo(address(0));
    }

    /*//////////////////////////////////////////////////////////////
            W2 (sc-vault-entry): LIVE-NAV DEPOSIT + INV-6 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-6/B2: the classic ERC-4626-style inflation/donation attack must not zero out
    /// a later depositor's shares, and the attacker's own claim on the pool must stay bounded to
    /// a small fraction of it (not grow to capture the donation) no matter how large the
    /// donation is. Mirrors ActiveBucket.t.sol's
    /// `test_InflationAttack_MitigatedByDeadShares` exactly, adjusted only for this file's
    /// TOKEN_A_PRICE ($2000, not $50) so the same 1.001e18-raw-share attacker deposit lands.
    function test_InflationAttack_MitigatedByDeadShares() public {
        address attacker = makeAddr("attacker");
        tokenA.mint(attacker, 10_000e18);

        // Attacker becomes the first depositor. 0.0005005 tokenA @ $2000/token = $1.001, which
        // mints 1.001e18 raw shares (sharesToMint = depositValue * 1e18 / INITIAL_TOKEN_PRICE =
        // 1.001e8 * 1e18 / 1e8). That clears the `FirstDepositTooSmall` floor (DEAD_SHARES =
        // 1e18) by only 0.001e18 -- the attacker's own stake is kept as close to the floor as
        // possible without reverting.
        vm.startPrank(attacker);
        tokenA.approve(address(bucket), 0.0005005e18);
        bucket.deposit(address(tokenA), 0.0005005e18);
        vm.stopPrank();

        uint256 attackerShares = bucket.balanceOf(attacker);
        assertEq(attackerShares, 0.001e18, "attacker's real (post-carve-out) stake must be exactly 0.001e18");

        // Donation: a RAW transfer, not deposit() -- inflates _calculateTotalValue() with zero
        // mint, the classic inflation-attack setup. 5,000 tokenA @ $2000/token = $10,000,000,
        // roughly 10,000,000x the attacker's own $1.001 contribution.
        vm.prank(attacker);
        tokenA.transfer(address(bucket), 5_000e18);

        // Victim deposits a modest, realistic amount.
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 2e18);
        bucket.deposit(address(tokenA), 2e18);
        vm.stopPrank();

        uint256 victimShares = bucket.balanceOf(user1);
        assertGt(victimShares, 0, "INV-6: DEAD_SHARES must keep the victim's mint nonzero even after a huge donation");

        // The attacker cannot sweep the donation: assert their claim as a FRACTION of the pool
        // (bounded regardless of donation size), not an absolute dollar figure -- see
        // ActiveBucket.t.sol's version of this test for the full reasoning.
        uint256 supply = bucket.totalSupply();
        uint256 totalValue = bucket.calculateTotalValue();
        uint256 attackerClaimValue = (totalValue * attackerShares) / supply;
        assertLt(
            attackerClaimValue * 100, totalValue, "attacker's claim must stay under 1% of the pool despite the donation"
        );
    }

    /// @notice `previewDeposit` must agree EXACTLY with what `deposit()` actually mints/values,
    /// across both the first-ever deposit (DEAD_SHARES carve-out branch) and a later deposit
    /// (no carve-out branch).
    function test_PreviewDepositAgreesWithActualDeposit() public {
        // First deposit: exercises the DEAD_SHARES carve-out branch.
        (uint256 previewedShares1, uint256 previewedValue1) = bucket.previewDeposit(address(0), 1 ether);

        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        uint256 actualShares1 = bucket.balanceOf(user1);

        assertEq(previewedShares1, actualShares1, "previewDeposit must match actual mint on first deposit");
        assertEq(previewedValue1, ETH_PRICE, "previewDeposit's USD value must match the oracle-priced deposit value");

        // Second deposit: no carve-out branch, live price unchanged since the first deposit.
        (uint256 previewedShares2,) = bucket.previewDeposit(address(0), 3 ether);

        vm.prank(user2);
        bucket.deposit{value: 3 ether}(address(0), 0);
        uint256 actualShares2 = bucket.balanceOf(user2);

        assertEq(previewedShares2, actualShares2, "previewDeposit must match actual mint on a later deposit");
    }

    /// @notice `previewRedeem` must agree EXACTLY with what `redeem()` actually pays out, across
    /// a multi-token holding and a partial redeem.
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

        // Match preview entries up by token address rather than assuming a fixed index, since
        // held-tokens registry order is an implementation detail this test should not depend on.
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

    /// @notice Proves `deposit()` mints against LIVE NAV, not the STALE stored `tokenPrice`
    /// state variable, when the oracle price moves between two deposits with NO rebalance in
    /// between (the pre-W2 bug this wave fixes).
    function test_LiveNavNotStale_PriceMovesBetweenDepositsWithoutRebalance() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        // What a stale-price bug would keep using for every subsequent deposit until the next
        // rebalance: `tokenPrice` after the first-ever deposit is INITIAL_TOKEN_PRICE ($1/share).
        uint256 stalePrice = bucket.tokenPrice();

        // Double the ETH oracle price with NO rebalance in between. `addToken` is idempotent for
        // an already-whitelisted token (MockBucketInfoForPassive.addToken above): it just
        // updates `prices[token]`.
        uint256 newEthPrice = ETH_PRICE * 2;
        bucketInfo.addToken(address(0), newEthPrice);

        vm.prank(user2);
        bucket.deposit{value: 1 ether}(address(0), 0);
        uint256 user2Shares = bucket.balanceOf(user2);

        // What user2's deposit would have minted under the pre-W2 bug: the new $4000 deposit
        // value divided by the OLD, stale $1/share basis.
        uint256 depositValueAtNewPrice = (1 ether * newEthPrice) / 1e18;
        uint256 staleFormulaShares = (depositValueAtNewPrice * 1e18) / stalePrice;

        // Live NAV: user1's 1 ETH is now worth 2x as much with nothing else in the vault, so the
        // live share price has also doubled (from $1/share to $2/share) even though no rebalance
        // happened. A correctly-priced $4000 deposit against a $2/share live basis mints half of
        // what the stale $1/share basis would have minted.
        assertLt(user2Shares, staleFormulaShares, "deposit() must not mint against the stale tokenPrice");
        assertApproxEqAbs(
            user2Shares * 2, staleFormulaShares, 2, "live price move must be reflected exactly, not partially"
        );
    }

    /// @notice `sharePrice()` defaults to `INITIAL_TOKEN_PRICE` ($1, workspace CLAUDE.md §6) on a
    /// totally fresh, empty vault (zero supply / zero value), and matches the live NAV formula
    /// once the vault holds a real deposit.
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

    // Allow test contract (owner) to receive ETH from redeem
    receive() external payable {}
}
