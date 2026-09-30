// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";

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

        implementation = new ActiveBucket();

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
        ActiveBucket impl = new ActiveBucket();

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bytes memory initData =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(0), oneInchRouter, NAME, SYMBOL);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertInitializeZeroOneInch() public {
        ActiveBucket impl = new ActiveBucket();

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
        ActiveBucket impl = new ActiveBucket();
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
              N5 / A3 OWNER-WITHDRAWAL-FLOOR TESTS (BUILT, UNWIRED)
       These exercise BucketVaultBase.isOwnerWithdrawalFloorMet /
       wouldOwnerMeetWithdrawalFloorAfterRedeem directly. Neither function is called from
       redeem() as of W2 (sc-vault-exit) — see the doc comment on that section in
       BucketVaultBase.sol for why (deliberate LIVE-quantity substitution for A3's literal
       "20% of total deposited value or portfolio" wording, pending client/verification-stream
       confirmation before ever being wired live).
    //////////////////////////////////////////////////////////////*/

    /// @notice Case 1/3: below the 20% floor, both the current-state check and the
    /// hypothetical-after-redeem check must report "not met".
    function test_OwnerWithdrawalFloor_BlockedBelowFloor() public {
        // Owner (address(this)) deposits a small stake; user1 deposits far more, diluting the
        // owner to ~10% of supply — below the 20% floor.
        bucket.deposit{value: 1 ether}(address(0), 0);
        vm.prank(user1);
        bucket.deposit{value: 9 ether}(address(0), 0);

        assertFalse(bucket.isOwnerWithdrawalFloorMet(), "owner at ~10% must be below the 20% floor");

        uint256 ownerShares = bucket.balanceOf(owner);
        // Already below floor: redeeming everything (or anything) cannot make it "met".
        assertFalse(
            bucket.wouldOwnerMeetWithdrawalFloorAfterRedeem(ownerShares),
            "already-below-floor owner cannot meet the floor after redeeming more"
        );
    }

    /// @notice Case 2/3: at/above the 20% floor, both checks must report "met", including for a
    /// hypothetical partial redeem that keeps the owner at/above the floor afterwards.
    function test_OwnerWithdrawalFloor_PermittedAtOrAboveFloor() public {
        // Owner deposits 3 ETH, user1 deposits 7 ETH -> owner holds exactly 30% of supply.
        bucket.deposit{value: 3 ether}(address(0), 0);
        vm.prank(user1);
        bucket.deposit{value: 7 ether}(address(0), 0);

        assertTrue(bucket.isOwnerWithdrawalFloorMet(), "owner at 30% must meet the 20% floor");

        uint256 ownerShares = bucket.balanceOf(owner);
        // Redeem a third of the owner's shares: 2/9 ~= 22.2% remains -> still >= 20%.
        assertTrue(
            bucket.wouldOwnerMeetWithdrawalFloorAfterRedeem(ownerShares / 3),
            "owner redeeming down to ~22.2% must still meet the 20% floor"
        );
        // Redeem two-thirds instead: 1/8 = 12.5% remains -> below 20%, must report false.
        assertFalse(
            bucket.wouldOwnerMeetWithdrawalFloorAfterRedeem((ownerShares * 2) / 3),
            "owner redeeming down to 12.5% must fail the 20% floor"
        );
    }

    /// @notice Case 3/3: the R1-lockout-absence proof. The contracts plan's own §5.5 "R1"
    /// analysis shows that a LITERAL lifetime-accumulator reading of A3 ("20% of total deposited
    /// value") permanently locks the owner out after a single full investor deposit/exit cycle,
    /// because a lifetime accumulator never forgets that dilution happened. This test proves the
    /// LIVE-quantity interpretation built here does NOT have that defect: once the diluting
    /// investor fully exits, the owner's LIVE ratio recovers on its own, with no unlock action
    /// needed from anyone.
    function test_OwnerWithdrawalFloor_R1LockoutAbsenceProof() public {
        // Owner deposits first and alone: 100% of supply, floor trivially met.
        bucket.deposit{value: 5 ether}(address(0), 0);
        assertTrue(bucket.isOwnerWithdrawalFloorMet(), "sole owner depositor starts at 100%");

        // A large investor deposit dilutes the owner to 5/50 = 10% -- now BELOW the floor.
        vm.prank(user1);
        bucket.deposit{value: 45 ether}(address(0), 0);
        assertFalse(bucket.isOwnerWithdrawalFloorMet(), "owner must be diluted below the 20% floor mid-cycle");

        // The investor fully exits (a complete deposit/redeem cycle on their side).
        uint256 investorShares = bucket.balanceOf(user1);
        vm.prank(user1);
        bucket.redeem(investorShares);

        // LIVE quantity: with the diluting investor gone, the owner is back to 100% of the
        // (now smaller) supply. A lifetime-accumulator design would have no such recovery path --
        // this is the R1 lockout this substitution avoids.
        assertTrue(
            bucket.isOwnerWithdrawalFloorMet(),
            "LIVE ratio must recover once the diluting investor fully exits (R1 lockout absence proof)"
        );
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

        vm.expectEmit(true, true, true, true);
        emit ActiveBucket.FlashLoan(address(this), address(receiver), address(0), loanAmount, expectedFee);
        bucket.flashLoan(address(0), loanAmount, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanInsufficientRepayment() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        BadFlashLoanReceiver badReceiver = new BadFlashLoanReceiver();
        vm.deal(address(badReceiver), 1 ether);

        vm.expectRevert();
        bucket.flashLoan(address(0), 5 ether, address(badReceiver), bytes(""));
    }

    function test_RevertFlashLoanNotOwner() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.prank(user1);
        vm.expectRevert();
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroAmount() public {
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(BucketVaultBase.ZeroAmount.selector);
        bucket.flashLoan(address(0), 0, address(receiver), bytes(""));
    }

    function test_RevertFlashLoanZeroReceiver() public {
        vm.prank(user1);
        bucket.deposit{value: 10 ether}(address(0), 0);

        vm.expectRevert(BucketVaultBase.ZeroAddress.selector);
        bucket.flashLoan(address(0), 1 ether, address(0), bytes(""));
    }

    function test_RevertFlashLoanInsufficientBalance() public {
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        vm.expectRevert(ActiveBucket.InsufficientBalance.selector);
        bucket.flashLoan(address(0), 1 ether, address(receiver), bytes(""));
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
        // user1's deposit at exactly the 5% boundary (19x owner's stake gives owner precisely
        // 2000/40000 = 5.00% pre-mitigation); post-mitigation the owner's net shares are
        // 1999e18, not 2000e18, which would put the owner just BELOW 5% at that exact ratio.
        // Sized down to 18x here so the owner clears MIN_OWNER_BPS with comfortable margin
        // (~5.26%) rather than sitting exactly on the boundary the mitigation now shifts.
        vm.prank(user1);
        bucket.deposit{value: 18 ether}(address(0), 0);

        assertTrue(bucket.isBucketAccountable());
    }

    function test_IsBucketAccountableOwnerBelowMinimum() public {
        // Owner deposits
        bucket.deposit{value: 0.04 ether}(address(0), 0);

        // User deposits way more (owner will hold < 5%)
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
        assertEq(bucket.MIN_OWNER_BPS(), 500);
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
        bucket.updateBucketInfo(address(newBucketInfo));

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_UpdateBucketInfoFromBucketInfoOwner() public {
        // Transfer BucketInfo ownership to user1
        bucketInfo.setOwner(user1);

        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();
        newBucketInfo.addToken(address(0), ETH_PRICE);

        // user1 (the BucketInfo owner) can update
        vm.prank(user1);
        bucket.updateBucketInfo(address(newBucketInfo));

        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }

    function test_RevertUpdateBucketInfoUnauthorized() public {
        MockBucketInfoForActive newBucketInfo = new MockBucketInfoForActive();

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
}
