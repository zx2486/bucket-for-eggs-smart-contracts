// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

contract MockBucketInfoForActive {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100;
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

    // --- W4.2a regression fix (task #61): see PassiveBucket.t.sol's MockBucketInfoForPassive
    // for the full explanation -- this mock predates the blacklist hook and lacked
    // `isBlacklisted`, so the fail-closed try/catch in _isBlacklistedFailClosed blocked every
    // mint/burn/transfer. Defaults to false.
    mapping(address => bool) public blacklisted;

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    // --- W5-oracle regression fix (same class as task #61's isBlacklisted gap): see
    // PassiveBucket.t.sol's MockBucketInfoForPassive for the full explanation -- this mock
    // predates {OraclePricingLib}'s wiring and lacked `isPotentiallyOutpriced`/`getPriceFeed`.
    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
    }

    receive() external payable {}
}

contract MockERC20ForActive {
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

/// @dev Flash loan receiver that properly repays with interest
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bool public shouldRepay = true;

    function setShouldRepay(bool _shouldRepay) external {
        shouldRepay = _shouldRepay;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata) external override {
        if (!shouldRepay) return;

        uint256 totalOwed = amount + fee;
        if (token == address(0)) {
            // Repay ETH
            (bool success,) = msg.sender.call{value: totalOwed}("");
            require(success, "ETH repay failed");
        } else {
            // Repay ERC-20
            MockERC20ForActive(token).transfer(msg.sender, totalOwed);
        }
    }

    receive() external payable {}
}

/// @dev Flash loan receiver that does NOT repay
contract BadFlashLoanReceiver is IFlashLoanReceiver {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external override {
        // Do nothing - don't repay
    }

    receive() external payable {}
}

// ============================================================
//                      TEST CONTRACT
// ============================================================

contract ActiveBucketTest is Test {
    ActiveBucket public implementation;
    ActiveBucket public bucket;
    MockBucketInfoForActive public bucketInfo;
    MockERC20ForActive public tokenA;
    MockERC20ForActive public tokenB;
    address public oneInchRouter;
    // W3.3: platform-owned registry ActiveBucket's immutable constructor parameter now
    // requires. Not exercised by most tests here -- deployed purely so
    // `new ActiveBucket(address)` compiles; queue/cancel/authorize tests approve into it directly.
    ImplementationRegistry public registry;

    address public owner;
    address public user1;
    address public user2;

    string constant NAME = "Active Bucket Share";
    string constant SYMBOL = "ABS";

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 50e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        bucketInfo = new MockBucketInfoForActive();
        tokenA = new MockERC20ForActive("Token A", "TKA", 18);
        tokenB = new MockERC20ForActive("Token B", "TKB", 6);
        oneInchRouter = makeAddr("oneInchRouter");

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        registry = new ImplementationRegistry(owner);
        implementation = new ActiveBucket(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test suite deploys proxies directly
        // (not through `ActiveBucketFactory`), so the test contract itself must be an
        // authorized "factory" from the registry's point of view, or every `initialize()` call
        // below reverts with `UnauthorizedInitializer()`.
        registry.setAuthorizedFactory(address(this), true);

        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, NAME, SYMBOL);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = ActiveBucket(payable(address(proxy)));

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        tokenA.mint(user1, 1000e18);
        tokenA.mint(user2, 1000e18);
        tokenB.mint(user1, 100000e6);
        tokenB.mint(user2, 100000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialization() public view {
        assertEq(bucket.name(), NAME);
        assertEq(bucket.symbol(), SYMBOL);
        assertEq(bucket.owner(), owner);
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), oneInchRouter);
        assertEq(bucket.performanceFeeBps(), 1400); // 5% default
        assertEq(bucket.tokenPrice(), 0); // not set until first deposit
    }

    function test_RevertInitializeZeroBucketInfo() public {
        ActiveBucket impl = new ActiveBucket(address(registry));

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(0), oneInchRouter, NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeZeroOneInch() public {
        ActiveBucket impl = new ActiveBucket(address(registry));

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), address(0), NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertDoubleInitialize() public {
        vm.expectRevert();
        bucket.initialize(address(bucketInfo), oneInchRouter, NAME, SYMBOL);
    }

    function test_InitializeCustomNameAndSymbol() public {
        ActiveBucket impl = new ActiveBucket(address(registry));
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, "My Active Bucket", "MAB"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        ActiveBucket customBucket = ActiveBucket(payable(address(proxy)));

        assertEq(customBucket.name(), "My Active Bucket");
        assertEq(customBucket.symbol(), "MAB");
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositETH() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.tokenPrice(), 1e8);
        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(address(bucket).balance, 1 ether);
        assertEq(bucket.totalDepositValue(), 2000e8);
    }

    function test_DepositERC20() public {
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(bucket.totalDepositValue(), 500e8); // 10 * $50
    }

    function test_DepositMultipleTokens() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        assertTrue(bucket.balanceOf(user1) > 0);
        assertEq(bucket.totalDepositValue(), 2500e8); // 2000 + 500
    }

    function test_DepositSetsTokenPriceOnFirstDeposit() public {
        assertEq(bucket.tokenPrice(), 0);

        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.tokenPrice(), 1e8); // INITIAL_TOKEN_PRICE
    }

    function test_RevertDepositZero() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.ZeroAmount.selector);
        bucket.deposit{value: 0}(address(0), 0);
    }

    function test_RevertDepositInvalidToken() public {
        address fake = makeAddr("fake");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, fake));
        bucket.deposit(fake, 100);
    }

    function test_RevertDepositPlatformDown() public {
        bucketInfo.setOperational(false);
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_RevertDepositWhenPaused() public {
        bucket.pause();
        vm.prank(user1);
        vm.expectRevert();
        bucket.deposit{value: 1 ether}(address(0), 0);
    }

    function test_DepositMultipleUsers() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares1 = bucket.balanceOf(user1);

        vm.prank(user2);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares2 = bucket.balanceOf(user2);

        // W2 (sc-vault-entry): user1 was the FIRST depositor, so `DEAD_SHARES` (INV-6) was
        // carved OUT of their own mint (see BucketVaultBase.DEAD_SHARES / _processDeposit).
        // user2's deposit is not a first deposit, so it is unaffected. Both users deposited
        // equal value at an unchanged live price, so user1's shares plus the one-time dead-share
        // floor should equal user2's shares exactly (up to 1 wei of integer-division rounding).
        assertApproxEqAbs(shares1 + bucket.DEAD_SHARES(), shares2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RedeemShares() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 supply = bucket.totalSupply();
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        assertEq(bucket.balanceOf(user1), 0);
        // W2 (sc-vault-entry): user1 is the FIRST depositor, so `DEAD_SHARES` (INV-6) was
        // carved out of their mint and permanently locked in `totalSupply()`. A full redeem of
        // user1's own (net) shares therefore returns balance*shares/supply, strictly less than
        // the full 2 ether by the DEAD_SHARES fraction — not "approximately 2 ETH" as before this
        // wave. See BucketVaultBase.DEAD_SHARES's doc comment.
        uint256 expected = (2 ether * shares) / supply;
        assertApproxEqAbs(user1.balance - ethBefore, expected, 1);
    }

    function test_RedeemPartial() public {
        vm.prank(user1);
        bucket.deposit{value: 4 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares / 2);

        assertEq(bucket.balanceOf(user1), shares / 2);
    }

    // CHARACTERISATION: changed in W2 (sc-vault-exit). `redeem()` no longer computes a USD
    // value on-chain at all (that required an oracle call, forbidden by INV-1), so
    // `totalWithdrawValue` is no longer incremented and stays frozen at 0 across this vault's
    // lifetime from this wave onward — see ActiveBucket.sol's doc comment on the state
    // variable. The statistic itself is preserved off-chain via the redesigned `Redeemed`
    // event, asserted below instead of the old on-chain accumulator.
    function test_RedeemTracksWithdrawValue() public {
        vm.prank(user1);
        bucket.deposit{value: 2 ether}(address(0), 0);

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

    function test_RedeemMultipleTokens() public {
        // Deposit ETH and ERC20
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        uint256 shares = bucket.balanceOf(user1);
        uint256 ethBefore = user1.balance;
        uint256 tokenABefore = tokenA.balanceOf(user1);

        vm.prank(user1);
        bucket.redeem(shares);

        // Should receive both ETH and Token A back
        assertTrue(user1.balance > ethBefore);
        assertTrue(tokenA.balanceOf(user1) > tokenABefore);
    }

    function test_RevertRedeemZero() public {
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InvalidRedeemAmount.selector);
        bucket.redeem(0);
    }

    function test_RevertRedeemTooMuch() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.InvalidRedeemAmount.selector);
        bucket.redeem(shares + 1);
    }

    function test_RevertRedeemWhenPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        bucket.pause();

        uint256 shares = bucket.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert();
        bucket.redeem(shares);
    }

    function test_RevertRedeemPlatformDown() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        bucketInfo.setOperational(false);

        uint256 shares = bucket.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.redeem(shares);
    }

    /*//////////////////////////////////////////////////////////////
                        FLASH LOAN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FlashLoanERC20() public {
        // Setup: deposit tokens into bucket
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 100e18);
        bucket.deposit(address(tokenA), 100e18);
        vm.stopPrank();

        // Create flash loan receiver and fund it with enough to cover interest
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        tokenA.mint(address(receiver), 10e18); // Extra for interest

        uint256 loanAmount = 50e18;
        uint256 expectedFee = (loanAmount * 200) / 10000; // 2% = 1e18

        uint256 bucketBalBefore = tokenA.balanceOf(address(bucket));

        // W5.3 (SC-10, B6): flashLoan is holder-gated (`_requireHasShares()`), not
        // owner-gated. user1 is the depositor and therefore the shareholder entitled to call
        // -- without this prank the call would be made by `owner`/address(this), who holds
        // zero shares here, and would revert InsufficientShares() before ever reaching the
        // logic this test means to exercise.
        vm.prank(user1);
        bucket.flashLoan(address(tokenA), loanAmount, address(receiver), bytes(""));

        uint256 bucketBalAfter = tokenA.balanceOf(address(bucket));
        assertGe(bucketBalAfter, bucketBalBefore + expectedFee);
    }

    function test_FlashLoanETH() public {
        // Deposit ETH
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether); // Extra for interest

        uint256 loanAmount = 5 ether;
        uint256 expectedFee = (loanAmount * 200) / 10000; // 2% = 0.1 ether

        uint256 bucketBalBefore = address(bucket).balance;

        // W5.3 (SC-10, B6): caller must be the shareholder (user1), see comment in
        // test_FlashLoanERC20 above.
        vm.prank(user1);
        bucket.flashLoan(address(0), loanAmount, address(receiver), bytes(""));

        uint256 bucketBalAfter = address(bucket).balance;
        assertGe(bucketBalAfter, bucketBalBefore + expectedFee);
    }

    function test_FlashLoanEmitsEvent() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether);

        uint256 loanAmount = 5 ether;
        uint256 expectedFee = (loanAmount * 200) / 10000;

        // W5.3 (SC-10, B6): the caller (and therefore the event's `initiator`) is now user1,
        // the shareholder, not `address(this)`.
        vm.expectEmit(true, true, true, true);
        emit ActiveBucket.FlashLoan(user1, address(receiver), address(0), loanAmount, expectedFee);
        vm.prank(user1);
        bucket.flashLoan(address(0), loanAmount, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanInsufficientRepayment() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        BadFlashLoanReceiver badReceiver = new BadFlashLoanReceiver();
        vm.deal(address(badReceiver), 1 ether);

        // W5.3 (SC-10, B6): caller must be the shareholder (user1) so the revert below is
        // actually InsufficientRepayment, not a false-positive InsufficientShares from a
        // zero-share default caller.
        vm.prank(user1);
        vm.expectRevert();
        bucket.flashLoan(address(0), 5 ether, address(badReceiver), bytes(""));
    }

    function test_RevertFlashLoanNonHolderRejected() public {
        // W5.3 (SC-10, B6): this test used to be `test_RevertFlashLoanNotOwner`, asserting a
        // non-owner DEPOSITOR (user1) was rejected -- that is exactly backwards now that
        // flashLoan is holder-gated rather than owner-gated: a depositing shareholder is
        // precisely who should be allowed to call. Repurposed to assert a genuine NON-HOLDER
        // (user2, who never deposited and holds zero shares) is rejected with
        // InsufficientShares(), which is the actual guarantee B6 requires.
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.prank(user2);
        vm.expectRevert(BucketVaultBase.InsufficientShares.selector);
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroAmount() public {
        // W5.3 (SC-10, B6): `_requireHasShares()` now runs first in the function body, so the
        // caller must hold shares before the ZeroAmount check (which runs after it) can ever
        // be reached. `owner` deposits here and calls with the default (unpranked) sender, who
        // is `owner`/address(this).
        bucket.deposit{value: 1 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(BucketVaultBase.ZeroAmount.selector);
        bucket.flashLoan(address(0), 0, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroReceiver() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        // W5.3 (SC-10, B6): caller must be the shareholder (user1).
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.flashLoan(address(0), 1 ether, address(0), bytes(""));
    }

    function test_RevertFlashLoanInsufficientBalance() public {
        // W5.3 (SC-10, B6): caller must hold shares to clear `_requireHasShares()` before
        // reaching the InsufficientBalance check. `owner` deposits a small amount, then
        // requests a loan larger than the bucket's actual balance.
        bucket.deposit{value: 1 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(ActiveBucket.InsufficientBalance.selector);
        bucket.flashLoan(address(0), 2 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanPlatformDown() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucketInfo.setOperational(false);
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanWhenPaused() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        bucket.pause();

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.expectRevert();
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PauseUnpause() public {
        bucket.pause();
        assertTrue(bucket.paused());

        bucket.unpause();
        assertFalse(bucket.paused());
    }

    function test_PauseSwap() public {
        bucket.pauseSwap();
        assertTrue(bucket.swapPaused());

        bucket.unpauseSwap();
        assertFalse(bucket.swapPaused());
    }

    function test_RevertPauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.pause();
    }

    function test_RevertUnpauseNotOwner() public {
        bucket.pause();
        vm.prank(user1);
        vm.expectRevert();
        bucket.unpause();
    }

    /// @dev W3.5 design rationale (`04-CONTRACTS-IMPLEMENTATION-PLAN.md`, review reply §4.5(4)):
    /// `unpause()` is deliberately plain `onlyOwner`, NOT `onlyAccountableOwner`. This proves the
    /// failure mode the design guards against: an owner who WAS accountable at pause time can
    /// fall below `MIN_OWNER_BPS` while the vault sits paused -- here via plain ERC20 `transfer`,
    /// which is not `whenNotPaused`-gated (only deposit/redeem/rebalance are) -- and `unpause()`
    /// must still succeed. If it required accountability too, the vault would be PERMANENTLY
    /// stuck paused: deposit/redeem are `whenNotPaused`, so there is no path back to
    /// accountability once paused and diluted.
    function test_UnpauseSucceedsWhenOwnerNotAccountable() public {
        bucket.deposit{value: 1 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());

        bucket.pause();
        assertTrue(bucket.paused());

        // Dilute the owner below MIN_OWNER_BPS while paused, via plain ERC20 transfer -- leave
        // the owner ~0.1% of supply, well under the 1% floor (`MIN_OWNER_BPS() == 100`).
        uint256 ownerShares = bucket.balanceOf(address(this));
        bucket.transfer(user1, ownerShares - (ownerShares / 1000));
        assertFalse(bucket.isBucketAccountable());

        bucket.unpause();
        assertFalse(bucket.paused());
    }

    function test_RevertPauseSwapNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.pauseSwap();
    }

    function test_RevertPauseSwapAlreadyPaused() public {
        bucket.pauseSwap();
        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.pauseSwap();
    }

    function test_RevertUnpauseSwapNotPaused() public {
        vm.expectRevert(BucketVaultBase.SwapNotPaused.selector);
        bucket.unpauseSwap();
    }

    function test_RevertUnpauseSwapNotOwner() public {
        bucket.pauseSwap();
        vm.prank(user1);
        vm.expectRevert();
        bucket.unpauseSwap();
    }

    /*//////////////////////////////////////////////////////////////
                      RECOVER TOKENS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RecoverTokens() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        bucket.recoverTokens(address(rogue), 1000e18, user1);
        assertEq(rogue.balanceOf(user1), 1000e18);
    }

    function test_RecoverETH() public {
        // ETH is whitelisted in our setup, so this should revert
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.CannotRecoverWhitelistedToken.selector, address(0)));
        bucket.recoverTokens(address(0), 1 ether, user1);
    }

    function test_RevertRecoverWhitelistedToken() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.CannotRecoverWhitelistedToken.selector, address(tokenA)));
        bucket.recoverTokens(address(tokenA), 100e18, user1);
    }

    function test_RevertRecoverZeroAddress() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.recoverTokens(address(rogue), 1000e18, address(0));
    }

    function test_RevertRecoverNotOwner() public {
        MockERC20ForActive rogue = new MockERC20ForActive("Rogue", "RGT", 18);
        rogue.mint(address(bucket), 1000e18);

        vm.prank(user1);
        vm.expectRevert();
        bucket.recoverTokens(address(rogue), 1000e18, user1);
    }

    /*//////////////////////////////////////////////////////////////
                    SWAP BY 1INCH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertSwapBy1inchNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertSwapBy1inchSwapPaused() public {
        bucket.pauseSwap();

        vm.expectRevert(BucketVaultBase.SwapIsPaused.selector);
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertSwapBy1inchPlatformDown() public {
        bucketInfo.setOperational(false);

        vm.expectRevert(BucketVaultBase.PlatformNotOperational.selector);
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    function test_RevertSwapBy1inchWhenContractPaused() public {
        bucket.pause();

        vm.expectRevert();
        bucket.swapBy1inch(address(0), address(0), 1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SET ONEINCH ROUTER
    //////////////////////////////////////////////////////////////*/

    function test_SetOneInchRouter() public {
        address newRouter = makeAddr("newRouter");
        bucket.setOneInchRouter(newRouter);
        assertEq(bucket.oneInchRouter(), newRouter);
    }

    function test_SetOneInchRouterEmitsEvent() public {
        address newRouter = makeAddr("newRouter");
        vm.expectEmit(true, false, false, false);
        emit ActiveBucket.OneInchRouterUpdated(newRouter);
        bucket.setOneInchRouter(newRouter);
    }

    function test_RevertSetOneInchRouterZero() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.setOneInchRouter(address(0));
    }

    function test_RevertSetOneInchRouterNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setOneInchRouter(makeAddr("newRouter"));
    }

    /*//////////////////////////////////////////////////////////////
                    PERFORMANCE FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetPerformanceFee() public {
        bucket.setPerformanceFee(1000); // 10%
        assertEq(bucket.performanceFeeBps(), 1000);
    }

    function test_SetPerformanceFeeEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ActiveBucket.PerformanceFeeUpdated(1000);
        bucket.setPerformanceFee(1000);
    }

    function test_RevertSetPerformanceFeeExceeds100() public {
        vm.expectRevert("Fee exceeds 100%");
        bucket.setPerformanceFee(10001);
    }

    function test_RevertSetPerformanceFeeNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setPerformanceFee(1000);
    }

    function test_SetPerformanceFeeBoundary() public {
        // 0% is valid
        bucket.setPerformanceFee(0);
        assertEq(bucket.performanceFeeBps(), 0);

        // 100% is valid
        bucket.setPerformanceFee(10000);
        assertEq(bucket.performanceFeeBps(), 10000);
    }

    /*//////////////////////////////////////////////////////////////
                MAX VALUE-LOSS BPS TESTS (task #97, extended task #98)
    //////////////////////////////////////////////////////////////*/

    function test_MaxValueLossBpsDefaultsToFiftyBpsWhenUnset() public view {
        // Zero means "use the hardcoded 0.5% default" — never zero itself.
        assertEq(bucket.maxValueLossBps(), 50);
    }

    function test_EpochValueLossBudgetBpsDefaultsToOneFiftyBpsWhenUnset() public view {
        // Zero means "use the hardcoded 1.5%/day default" — never zero itself.
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_SetMaxValueLossBpsUpdatesGetter() public {
        bucket.setMaxValueLossBps(300, 0); // 3% per-call, leave epoch budget at default
        assertEq(bucket.maxValueLossBps(), 300);
    }

    function test_SetMaxValueLossBpsUpdatesEpochBudgetGetter() public {
        bucket.setMaxValueLossBps(0, 700); // leave per-call at default, 7%/day epoch budget
        assertEq(bucket.epochValueLossBudgetBps(), 700);
    }

    function test_SetMaxValueLossBpsSetsBothIndependentlyInOneCall() public {
        bucket.setMaxValueLossBps(500, 700);
        assertEq(bucket.maxValueLossBps(), 500);
        assertEq(bucket.epochValueLossBudgetBps(), 700);
    }

    function test_SetMaxValueLossBpsEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BucketVaultBase.MaxValueLossBpsUpdated(300, 700);
        bucket.setMaxValueLossBps(300, 700);
    }

    function test_SetMaxValueLossBpsAtCeilingSucceeds() public {
        // Exactly 1000 bps (10%) is the ceiling, not an off-by-one boundary that reverts.
        bucket.setMaxValueLossBps(1000, 1000);
        assertEq(bucket.maxValueLossBps(), 1000);
        assertEq(bucket.epochValueLossBudgetBps(), 1000);
    }

    function test_RevertSetMaxValueLossBpsAboveCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.MaxValueLossBpsExceedsCeiling.selector, 1001));
        bucket.setMaxValueLossBps(1001, 0);
    }

    function test_RevertSetEpochValueLossBudgetBpsAboveCeiling() public {
        // The epoch budget field is checked against the same ceiling, independently of the
        // per-call field — a valid per-call value does not excuse an over-ceiling epoch budget.
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.MaxValueLossBpsExceedsCeiling.selector, 1001));
        bucket.setMaxValueLossBps(300, 1001);
    }

    function test_SetMaxValueLossBpsBackToZeroRestoresDefault() public {
        bucket.setMaxValueLossBps(1000, 1000);
        assertEq(bucket.maxValueLossBps(), 1000);
        assertEq(bucket.epochValueLossBudgetBps(), 1000);

        // Owner can lower it again, including back down to 0 (which re-resolves to each field's
        // own default rather than permanently sticking at whatever ceiling was last set) — and
        // the two fields restore independently, not jointly.
        bucket.setMaxValueLossBps(0, 0);
        assertEq(bucket.maxValueLossBps(), 50);
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_SetMaxValueLossBpsZeroRestoresOnlyThatFieldIndependently() public {
        bucket.setMaxValueLossBps(500, 700);

        // Restoring only the per-call bound to default must not disturb the epoch budget.
        bucket.setMaxValueLossBps(0, 700);
        assertEq(bucket.maxValueLossBps(), 50);
        assertEq(bucket.epochValueLossBudgetBps(), 700);

        // And vice versa: restoring only the epoch budget must not disturb the per-call bound.
        bucket.setMaxValueLossBps(0, 0);
        bucket.setMaxValueLossBps(500, 700);
        bucket.setMaxValueLossBps(500, 0);
        assertEq(bucket.maxValueLossBps(), 500);
        assertEq(bucket.epochValueLossBudgetBps(), 150);
    }

    function test_RevertSetMaxValueLossBpsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bucket.setMaxValueLossBps(300, 0);
    }

    function test_RevertSetMaxValueLossBpsBlacklistedOwner() public {
        // onlyOwnerNotBlacklisted: the owner itself, if blacklisted, is locked out of its own
        // risk-tolerance control just like every other admin function on this base.
        bucketInfo.setBlacklisted(owner, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, owner));
        bucket.setMaxValueLossBps(300, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    ACCOUNTABILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_IsBucketAccountableNoSupply() public view {
        // With no supply, accountability is trivially true
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHolds100Pct() public {
        // Owner deposits — holds 100% of supply
        bucket.deposit{value: 1 ether}(address(0), 0);
        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerHoldsMinimum() public {
        // Owner deposits first
        bucket.deposit{value: 1 ether}(address(0), 0);

        // W2 (sc-vault-entry): owner is the FIRST depositor, so `DEAD_SHARES` (INV-6) is carved
        // out of the owner's own mint (see BucketVaultBase.DEAD_SHARES). This test used to size
        // user1's deposit at exactly the 5% boundary back when `MIN_OWNER_BPS` was 500 (19x
        // owner's stake gives owner precisely 2000/40000 = 5.00% pre-mitigation, 1999e18 /
        // 4.9975% post-mitigation). ⚠ `MIN_OWNER_BPS` was reversed to 100 (1%) by direct
        // instruction 2026-09-30 (see BucketVaultBase.sol:194's doc comment) -- this test's
        // ~5.26% owner share is now comfortably above the LIVE 1% boundary, not a near-boundary
        // case for it. Left at this sizing (still a valid, passing "holds well above minimum"
        // case) rather than re-tuned to the new boundary, since re-tuning was out of the scope of
        // the instruction that triggered this comment update; a tighter near-1%-boundary test
        // would need its own deposit-sizing math redone from scratch.
        vm.prank(user1);
        bucket.deposit{value: 18 ether}(address(0), 0);

        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerBelowMinimum() public {
        // Owner deposits
        bucket.deposit{value: 0.04 ether}(address(0), 0);

        // User deposits way more (owner will hold < 1%, well under either the old 5% or the
        // current 1% MIN_OWNER_BPS boundary -- ~0.4%)
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        assertFalse(bucket.isBucketAccountable());
    }

    /*//////////////////////////////////////////////////////////////
                      TOTAL VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TotalValueEmpty() public view {
        assertEq(bucket.calculateTotalValue(), 0);
    }

    function test_TotalValueAfterDeposit() public {
        vm.prank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);

        assertEq(bucket.calculateTotalValue(), 2000e8);
    }

    function test_TotalValueMultipleTokens() public {
        vm.startPrank(user1);
        bucket.deposit{value: 1 ether}(address(0), 0);
        tokenA.approve(address(bucket), 10e18);
        bucket.deposit(address(tokenA), 10e18);
        vm.stopPrank();

        // 1 ETH = $2000, 10 TKA = $500
        assertEq(bucket.calculateTotalValue(), 2500e8);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTANTS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constants() public view {
        assertEq(bucket.PRECISION(), 1e18);
        assertEq(bucket.INITIAL_TOKEN_PRICE(), 1e8);
        assertEq(bucket.BPS_DENOMINATOR(), 10000);
        assertEq(bucket.MAX_VALUE_LOSS_BPS(), 50);
        assertEq(bucket.FLASH_LOAN_FEE_BPS(), 200);
        assertEq(bucket.MIN_OWNER_BPS(), 100);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositETH(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 50 ether);

        vm.prank(user1);
        bucket.deposit{value: amount}(address(0), 0);

        assertTrue(bucket.balanceOf(user1) > 0);
    }

    function testFuzz_DepositAndRedeem(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 50 ether);

        vm.prank(user1);
        bucket.deposit{value: amount}(address(0), 0);

        uint256 shares = bucket.balanceOf(user1);
        uint256 supply = bucket.totalSupply();
        uint256 ethBefore = user1.balance;

        vm.prank(user1);
        bucket.redeem(shares);

        uint256 ethReceived = user1.balance - ethBefore;
        // W2 (sc-vault-entry): this is a fresh bucket's FIRST deposit, so `DEAD_SHARES` (INV-6)
        // was carved out of `shares`. A full redeem of `shares` (not `supply`) returns
        // amount*shares/supply, strictly less than `amount` by the DEAD_SHARES fraction — the
        // expected value below is computed from live on-chain state, not assumed to be `amount`.
        uint256 expected = (amount * shares) / supply;
        assertApproxEqAbs(ethReceived, expected, 1);
    }

    function testFuzz_FlashLoanFee(uint256 amount) public {
        amount = bound(amount, 0.1 ether, 10 ether);
        vm.deal(address(this), amount + 10 ether);

        bucket.deposit{value: amount + 1 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.deal(address(receiver), 5 ether);

        uint256 balBefore = address(bucket).balance;

        bucket.flashLoan(address(0), amount, address(receiver), bytes(""));

        uint256 balAfter = address(bucket).balance;
        uint256 expectedFee = (amount * 200) / 10000;
        assertGe(balAfter, balBefore + expectedFee);
    }

    function testFuzz_PerformanceFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, 10000);
        bucket.setPerformanceFee(feeBps);
        assertEq(bucket.performanceFeeBps(), feeBps);
    }

    function testFuzz_MultipleDepositsAndRedeemPartial(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 0.01 ether, 25 ether);
        amount2 = bound(amount2, 0.01 ether, 25 ether);

        vm.prank(user1);
        bucket.deposit{value: amount1}(address(0), 0);

        vm.prank(user2);
        bucket.deposit{value: amount2}(address(0), 0);

        uint256 shares1 = bucket.balanceOf(user1);
        uint256 shares2 = bucket.balanceOf(user2);

        // Each user redeems half
        vm.prank(user1);
        bucket.redeem(shares1 / 2);

        vm.prank(user2);
        bucket.redeem(shares2 / 2);

        // Remaining shares should be approximately half
        assertApproxEqAbs(bucket.balanceOf(user1), shares1 / 2, 1);
        assertApproxEqAbs(bucket.balanceOf(user2), shares2 / 2, 1);
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
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        // Owner of current bucketInfo is this contract (deployed in setUp)
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        bucket.executeUpdateBucketInfo();

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_UpdateBucketInfoFromBucketInfoOwner() public {
        // Transfer BucketInfo ownership to user1
        bucketInfo.setOwner(user1);

        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        // user1 (the BucketInfo owner) can propose
        vm.prank(user1);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());

        // execute is permissionless -- anyone, not just user1 or the vault owner, may apply it
        bucket.executeUpdateBucketInfo();

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoUnauthorized() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();

        // user1 is NOT the BucketInfo owner
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.UnauthorizedBucketInfoUpdate.selector);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.proposeUpdateBucketInfo(address(0));
    }

    function test_RevertExecuteUpdateBucketInfoBeforeTimelockElapsed() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        (, uint256 eta) = bucket.pendingBucketInfoUpdate();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.executeUpdateBucketInfo();
    }

    function test_RevertExecuteUpdateBucketInfoWithNothingPending() public {
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.executeUpdateBucketInfo();
    }

    /// @notice D3's veto window: the vault's OWN owner (not the BucketInfo owner, not a
    /// third party) may cancel a proposed repoint before it executes.
    function test_VetoUpdateBucketInfoByVaultOwner() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        bucket.proposeUpdateBucketInfo(address(newBucketInfo));
        // bucket.owner() is this test contract (deployed in setUp), matching how propose was
        // called above with no vm.prank.
        bucket.vetoUpdateBucketInfo();

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.executeUpdateBucketInfo();

        // The old BucketInfo is still in place -- the veto stopped the repoint.
        assertTrue(address(bucket.bucketInfo()) != address(newBucketInfo));
    }

    function test_RevertVetoUpdateBucketInfoByNonVaultOwner() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.prank(user1); // user1 is not bucket.owner()
        vm.expectRevert(); // OwnableUpgradeable.OwnableUnauthorizedAccount
        bucket.vetoUpdateBucketInfo();
    }

    /*//////////////////////////////////////////////////////////////
            W2 (sc-vault-entry): LIVE-NAV DEPOSIT + INV-6 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV-6/B2: the classic ERC-4626-style inflation/donation attack must not zero out
    /// a later depositor's shares, and the attacker's own claim on the pool must stay bounded to
    /// a small fraction of it (not grow to capture the donation) no matter how large the
    /// donation is. The attacker keeps their own real (post-carve-out) shares just barely above
    /// zero, which is the worst case for a victim: it maximises the fraction of `totalSupply()`
    /// that is the fixed, unclaimable `DEAD_SHARES` floor, and minimises the attacker's own
    /// stake -- and the test shows the mitigation holds even so.
    function test_InflationAttack_MitigatedByDeadShares() public {
        address attacker = makeAddr("attacker");
        tokenA.mint(attacker, 1_000_000e18);

        // Attacker becomes the first depositor. 0.02002 tokenA @ $50/token = $1.001, which
        // mints 1.001e18 raw shares (see BucketVaultBase._processDeposit: sharesToMint =
        // depositValue * 1e18 / INITIAL_TOKEN_PRICE = 1.001e8 * 1e18 / 1e8). That clears the
        // `FirstDepositTooSmall` floor (DEAD_SHARES = 1e18) by only 0.001e18 -- the attacker's
        // own stake is kept as close to the floor as possible without reverting.
        vm.startPrank(attacker);
        tokenA.approve(address(bucket), 0.02002e18);
        bucket.deposit(address(tokenA), 0.02002e18);
        vm.stopPrank();

        uint256 attackerShares = bucket.balanceOf(attacker);
        assertEq(attackerShares, 0.001e18, "attacker's real (post-carve-out) stake must be exactly 0.001e18");

        // Donation: a RAW transfer, not deposit() -- inflates _calculateTotalValue() with zero
        // mint, the classic inflation-attack setup. 200,000 tokenA @ $50/token = $10,000,000,
        // roughly 10,000,000x the attacker's own $1.001 contribution.
        vm.prank(attacker);
        tokenA.transfer(address(bucket), 200_000e18);

        // Victim deposits a modest, realistic amount.
        vm.startPrank(user1);
        tokenA.approve(address(bucket), 2e18);
        bucket.deposit(address(tokenA), 2e18);
        vm.stopPrank();

        uint256 victimShares = bucket.balanceOf(user1);
        assertGt(victimShares, 0, "INV-6: DEAD_SHARES must keep the victim's mint nonzero even after a huge donation");

        // The attacker cannot sweep the donation: their redeemable claim is bounded by their own
        // tiny real share count relative to total supply (which is floored at DEAD_SHARES), not
        // by the size of the donation they made outside deposit() accounting. Assert this as a
        // FRACTION of the pool, not an absolute dollar figure -- an absolute cap would not scale
        // to an arbitrarily larger donation, but the attacker's fraction of the pool is bounded
        // regardless of donation size, because the donation inflates the pool for every
        // shareholder, including the permanently-unclaimable dead-shares recipient.
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
        // an already-whitelisted token (MockBucketInfoForActive.addToken, this file's mock
        // contracts section): it just updates `prices[token]`.
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

    /*//////////////////////////////////////////////////////////////
                UPGRADE GOVERNANCE TESTS — W3.3 (basic)
    //////////////////////////////////////////////////////////////*/
    // Basic happy-path/revert-path coverage for {queueUpgrade}/{cancelUpgrade}/{_authorizeUpgrade}
    // per `09-DECISION-LOG.md` §10.1. The exhaustive adversarial suite (namespace isolation,
    // factory-handover regression, renounceOwnership/Ownable2Step semantics, pause-during-queue)
    // is task #45's own gate suite, not duplicated here.

    function _deployApprovedActiveBucketImplementation() internal returns (address newImpl) {
        newImpl = address(new ActiveBucket(address(registry)));
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, newImpl);
    }

    function test_QueueUpgrade_SetsPendingAndEta() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(newImpl);

        assertEq(bucket.pendingImplementation(), newImpl);
        assertEq(bucket.upgradeEta(), block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());
    }

    function test_RevertQueueUpgradeNotOwner() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        vm.prank(user1);
        vm.expectRevert();
        bucket.queueUpgrade(newImpl);
    }

    function test_RevertQueueUpgradeZeroAddress() public {
        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.queueUpgrade(address(0));
    }

    function test_UpgradeSucceeds_AfterQueueApprovalAndElapsedDelay() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        bucket.upgradeToAndCall(newImpl, "");

        // Successful execution clears the pending slot (TimelockedAdmin.execute deletes it).
        assertEq(bucket.pendingImplementation(), address(0));
        assertEq(bucket.upgradeEta(), 0);
    }

    function test_RevertUpgrade_BeforeTimelockElapsed() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        uint256 eta = bucket.upgradeEta();
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NothingQueued() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_ImplementationMismatch() public {
        address queuedImpl = _deployApprovedActiveBucketImplementation();
        address otherImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(queuedImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(BucketVaultBase.UpgradeImplementationMismatch.selector, queuedImpl, otherImpl)
        );
        bucket.upgradeToAndCall(otherImpl, "");
    }

    /// @notice Registry approval is re-checked at EXECUTION time, not just at queue time — a
    /// mid-window platform revocation actually blocks the upgrade (the plan's own "test 3",
    /// 04 §5.6.1/§10.1). This is the scenario most likely to be omitted.
    function test_RevertUpgrade_RegistryApprovalRevokedMidWindow() public {
        address newImpl = _deployApprovedActiveBucketImplementation();

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, newImpl);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_RevertUpgrade_NeverApproved() public {
        // Deployed but never approved in the registry -- distinct from the revoked-mid-window
        // case above (never-approved vs. approved-then-revoked), same revert reason.
        address newImpl = address(new ActiveBucket(address(registry)));

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_ClearsPendingState() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        bucket.cancelUpgrade();

        assertEq(bucket.pendingImplementation(), address(0));
        assertEq(bucket.upgradeEta(), 0);

        // A cancelled entry cannot later be executed, even after what would have been the delay.
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());
        vm.expectRevert(TimelockedAdmin.NoProposalPending.selector);
        bucket.upgradeToAndCall(newImpl, "");
    }

    function test_CancelUpgrade_NoOpWhenNothingPending() public {
        // Matches TimelockedAdmin.cancel's own semantics: does not revert.
        bucket.cancelUpgrade();
        assertEq(bucket.pendingImplementation(), address(0));
    }

    function test_RevertCancelUpgradeNotOwner() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        vm.prank(user1);
        vm.expectRevert();
        bucket.cancelUpgrade();
    }

    function test_RevertUpgrade_NotOwner() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.prank(user1);
        vm.expectRevert();
        bucket.upgradeToAndCall(newImpl, "");
    }

    /*//////////////////////////////////////////////////////////////
                UPGRADE GOVERNANCE TESTS — W3 GATE (task #45)
    //////////////////////////////////////////////////////////////*/
    // The exhaustive adversarial suite promised by the comment above the basic-coverage section:
    // namespace isolation, platform-cannot-trigger, renounceOwnership/single-step-Ownable
    // semantics, and pause-during-queue independence. Factory-handover regression (owner() ==
    // msg.sender inside the creation transaction) is already covered by
    // `ActiveBucketFactory.t.sol`'s `test_Create_OwnerIsCallerNotFactory` /
    // `test_Create_OwnerIsNotFactory` — not duplicated here.

    /// @dev Task #45 discovery: `renounceOwnership()` had NO override anywhere in this vault's
    /// inheritance chain before this fix (`grep -rni "renounce" src/ActiveBucket.sol
    /// src/base/BucketVaultBase.sol` returned zero hits) -- unlike `BucketInfo.sol:716` and
    /// `ImplementationRegistry.sol:94`, which both correctly disable it. `OwnableUpgradeable`'s
    /// default `renounceOwnership()` SUCCEEDS, so this vault could have been permanently bricked
    /// (no owner, therefore no `pause`/`queueUpgrade`/`updateBucketInfo`/... ever again, and no
    /// DAO to hand it to per Q14.2). PROVEN TO CATCH THIS REGRESSION (manual verification, see
    /// W3-GATE-REPORT for the transcript): this test was run against `BucketVaultBase.sol` with
    /// its new `renounceOwnership` override temporarily commented back out, confirmed to FAIL
    /// with "call did not revert as expected", then the override was restored and this test
    /// confirmed passing again.
    function test_RevertRenounceOwnership() public {
        vm.expectRevert(BucketVaultBase.RenounceOwnershipDisabled.selector);
        bucket.renounceOwnership();
    }

    /// @dev D-3 (root CLAUDE.md §8): vaults stay single-step `Ownable`, NEVER `Ownable2Step` —
    /// unlike `BucketInfo`/`ImplementationRegistry` (the only two two-step contracts in this
    /// system). Proves ownership transfers immediately on `transferOwnership`, with no
    /// intervening `acceptOwnership()` call and no `pendingOwner()` step to satisfy first — the
    /// exact property that would break if `Ownable2Step` were ever (wrongly) applied here.
    function test_TransferOwnershipIsSingleStepNotTwoStep() public {
        bucket.transferOwnership(user1);
        assertEq(
            bucket.owner(),
            user1,
            "single-step Ownable must hand over ownership immediately, with no acceptOwnership() call"
        );
    }

    /// @dev Sharpens sub-item (4) of task #45's five authorisation tests ("non-owner (incl.
    /// platform) cannot trigger"). A generic `user1` (`test_RevertUpgrade_NotOwner` above) proves
    /// nothing about the platform specifically, because throughout this file the platform
    /// (`registry`'s owner) and the vault owner are the SAME address (`address(this)`). This test
    /// gives the platform a genuinely distinct identity: it approves an implementation via the
    /// registry it owns, then tries to queue/execute the upgrade on a DIFFERENT vault it does not
    /// own — proving registry-approval power grants no trigger power (root CLAUDE.md §8: "the
    /// platform cannot push a fix into a vault").
    function test_RevertUpgrade_PlatformCannotTrigger() public {
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), oneInchRouter, NAME, SYMBOL);
        // Task #33: this test deliberately simulates a customer deploying their own proxy
        // directly (not through the factory) to get a vault the platform does not own. That is
        // now exactly the shape the bypass fix blocks by default, so `user2` must be explicitly
        // authorized here -- the point of this test is upgrade-authority, not the bypass itself.
        registry.setAuthorizedFactory(user2, true);
        vm.prank(user2);
        ERC1967Proxy customerProxy = new ERC1967Proxy(address(implementation), initData);
        ActiveBucket customerBucket = ActiveBucket(payable(address(customerProxy)));
        assertEq(customerBucket.owner(), user2, "customerBucket must be owned by the customer, not the platform");

        address newImpl = address(new ActiveBucket(address(registry)));
        // Platform (`address(this)`, owner of `registry`) approves the implementation -- this
        // succeeds, since approving is exactly the platform's job.
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, newImpl);

        // The platform is NOT customerBucket's owner, so it cannot even queue the upgrade it just
        // approved:
        vm.expectRevert();
        customerBucket.queueUpgrade(newImpl);

        // Nor can it execute one queued by the actual owner:
        vm.prank(user2);
        customerBucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + customerBucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert();
        customerBucket.upgradeToAndCall(newImpl, "");
    }

    /// @dev Confirmed gap (task #45 inventory): no existing test approves an implementation for
    /// the WRONG `Kind` and then attempts to install it on a vault of the RIGHT kind -- the
    /// vault-level instance of `ImplementationRegistry`'s namespace isolation
    /// (`IImplementationRegistry.sol`'s own doc comment: "an implementation approved for one kind
    /// must never read as approved for another"). PROVEN TO CATCH A REGRESSION (manual
    /// verification, see W3-GATE-REPORT): `_authorizeUpgradeCommon`'s
    /// `_registry().isApproved(_registryKind(), newImplementation)` check was temporarily changed
    /// to query `Kind.PassiveBucket` unconditionally; this test was confirmed to FAIL (the
    /// wrongly-approved upgrade succeeded); the change was reverted and this test reconfirmed
    /// passing.
    function test_RevertUpgrade_ApprovedForWrongKind() public {
        address newImpl = address(new ActiveBucket(address(registry)));
        // Approved for PassiveBucket's namespace, NOT ActiveBucket's -- `bucket` is an
        // ActiveBucket.
        registry.approve(IImplementationRegistry.Kind.PassiveBucket, newImpl);

        bucket.queueUpgrade(newImpl);
        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.UpgradeNotApproved.selector, newImpl));
        bucket.upgradeToAndCall(newImpl, "");
    }

    /// @dev Confirmed gap: no test proves the platform's kill switch (`BucketInfo.pausePlatform`,
    /// modelled here via the mock's `setOperational(false)`) is independent of a vault's upgrade
    /// timelock -- neither blocks the other. `queueUpgrade`/`cancelUpgrade`/
    /// `_authorizeUpgradeCommon` carry no `whenPlatformOperational` modifier (confirmed absent
    /// from all three in `BucketVaultBase.sol`), so a customer's already-queued upgrade must
    /// remain executable even while the platform is paused -- pausing is a deposit/redeem/swap
    /// guard (root CLAUDE.md's kill-switch description, 01:42), never an upgrade gate.
    function test_UpgradeQueued_PlatformPauseDoesNotBlockIt() public {
        address newImpl = _deployApprovedActiveBucketImplementation();
        bucket.queueUpgrade(newImpl);

        // Platform pause succeeds regardless of the pending upgrade.
        bucketInfo.setOperational(false);
        assertFalse(bucketInfo.isPlatformOperational());

        vm.warp(block.timestamp + bucket.UPGRADE_TIMELOCK_DELAY());

        // The queued upgrade still executes even though the platform is paused.
        bucket.upgradeToAndCall(newImpl, "");
        assertEq(bucket.pendingImplementation(), address(0));
    }
}
