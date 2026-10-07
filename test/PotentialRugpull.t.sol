// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// PotentialRugpull.t.sol — task #63 (W5.1, SC-8) unit test coverage.
//
// Covers: deposit/ownerDeposit/redeem/ownerWithdraw/setAssertedPortfolioValue, the cashRatio floor
// mechanism (including the R1-no-lockout proof per PotentialRugpull.sol's DECISION 2 header, and
// the separate owner-reclaims-own-deposit-with-zero-investors edge case flagged in that same
// header), blacklist/_update, seizure (thin wrapper over SeizureLib — one round-trip test, not the
// full G1-G5 matrix which already lives in W4Gate.t.sol against the shared BucketVaultBase/
// SeizureLib code), renounceOwnership-always-reverts, factory wiring, and the one-shot
// initialize/onlyFactory guard.
//
// New standalone file (same reasoning W4Gate.t.sol's header gives for not being added inline into
// an existing *.t.sol): PotentialRugpull is a new, independent contract, not a change to an
// existing one, so there is no existing file whose ownership this would straddle.
// ============================================================

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PotentialRugpull} from "../src/PotentialRugpull.sol";
import {PotentialRugpullFactory} from "../src/PotentialRugpullFactory.sol";
import {SeizureLib} from "../src/libraries/SeizureLib.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

/// @dev One shared IBucketInfo mock, same shape/precedent as GateMockBucketInfo
/// (test/W4Gate.t.sol) and MockBucketInfoForPassive (test/PassiveBucket.t.sol), implementing every
/// IBucketInfo method PotentialRugpull calls. `priceFeedSet` tracks which tokens have a
/// (mock) Chainlink feed configured — PotentialRugpull's _requireChainlinkPriced rejects any
/// token where getPriceFeed returns address(0), unlike the two existing vaults which accept
/// manually-priced tokens too (g).2.
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

    /// @dev address(0) ("manually priced") unless the test opted a token in via
    /// `setHasPriceFeed`. Drives PotentialRugpull's Chainlink-only enforcement (g).2.
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

    // --- test helpers ---
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

/// @dev Plain mintable ERC20 mock, same shape as GateMockERC20 (test/W4Gate.t.sol) /
/// MockERC20 (test/PassiveBucket.t.sol).
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

// ============================================================
//                      TEST CONTRACT
// ============================================================

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

    // ============================================================
    // initialize / factory wiring
    // ============================================================

    /// @notice The factory's own immutable BucketInfo pointer is wired into the instance, the
    /// caller (this test contract) becomes the owner within the SAME transaction the factory
    /// call makes, and the default 1 share / $1 portfolio value are set exactly as 00:15
    /// specifies.
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

    /// @notice One-shot latch: a second initialize call, even from the real factory, reverts.
    function test_Initialize_RevertsIfCalledTwice() public {
        vm.prank(address(factory));
        vm.expectRevert(PotentialRugpull.AlreadyInitialized.selector);
        rugpull.initialize(address(bucketInfo), ownerAddr, "x", "y");
    }

    /// @notice onlyFactory: nobody but the deploying factory may call initialize — not even the
    /// instance's own owner.
    function test_Initialize_OnlyFactoryCanCall() public {
        PotentialRugpull fresh = new PotentialRugpull(CASH_RATIO);
        vm.prank(user1);
        vm.expectRevert(PotentialRugpull.OnlyFactory.selector);
        fresh.initialize(address(bucketInfo), user1, "x", "y");
    }

    /// @notice Self-caught design bug from the header comment, proven: minting happens in
    /// {initialize} to the explicit `owner_` parameter, NOT to `msg.sender` (which inside a
    /// constructor-chain deployed by the factory would resolve to the factory itself). The
    /// factory never holds a balance at any point.
    function test_Initialize_MintsToRealOwnerNeverToFactory() public view {
        assertEq(rugpull.balanceOf(address(factory)), 0);
        assertEq(rugpull.balanceOf(ownerAddr), 1e18);
    }

    // ============================================================
    // constructor bounds
    // ============================================================

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

    // ============================================================
    // deposit
    // ============================================================

    /// @notice A non-owner deposit mints shares at current sharePrice and increments the LIVE
    /// netInvestorDeposits ledger by the USD value deposited (DECISION 2's increment side, A3).
    function test_Deposit_MintsSharesAndIncrementsLedger() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        // USER_DEPOSIT (1000e18 @ 18 decimals) * TOKEN_PRICE (1e8) / 1e18 = 1000e8 USD8
        uint256 expectedValueUsd8 = 1_000e8;
        assertEq(rugpull.netInvestorDeposits(), expectedValueUsd8);
        assertGt(rugpull.balanceOf(user1), 0);
    }

    /// @notice (g).2: a token with no Chainlink feed (getPriceFeed returns address(0)) is
    /// rejected even if whitelisted/valid — PotentialRugpull, unlike the two existing vaults,
    /// never accepts manually-priced tokens.
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

    /// @notice Platform kill switch (root CLAUDE.md §8): no local Pausable bit, gated solely on
    /// IBucketInfo.isPlatformOperational().
    function test_Deposit_RevertsWhenPlatformNotOperational() public {
        bucketInfo.setOperational(false);
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(PotentialRugpull.PlatformNotOperational.selector);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    // ============================================================
    // ownerDeposit
    // ============================================================

    /// @notice "Contract owner can also deposit Chainlink pricefeed tokens without issuing new
    /// contract tokens" (00:15) — total supply is unchanged, and netInvestorDeposits (A3: non-
    /// owner deposits only) is deliberately untouched.
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

    // ============================================================
    // redeem
    // ============================================================

    /// @notice A full investor exit burns their shares, pays out their pro-rata share of held
    /// tokens, and drains netInvestorDeposits back toward zero — DECISION 2's decrement side,
    /// and the actual mechanism that prevents R1's lockout (the ledger shrinks as investors
    /// leave, so it can never permanently pin the floor high).
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
        assertGt(token.balanceOf(user1), 1_000_000e18 - USER_DEPOSIT); // got a payout back
    }

    /// @notice A partial redeem drains the ledger proportionally, not fully — proves the
    /// proportional-to-shares-burned formula, not an all-or-nothing reset.
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
        assertApproxEqAbs(ledgerAfter, ledgerBefore / 2, 1); // rounding tolerance
        assertGt(ledgerAfter, 0);
    }

    /// @notice The owner redeeming their own initial (never-ledgered) shares must not touch
    /// netInvestorDeposits at all — owner deposits never minted shares in the first place, so
    /// there is nothing investor-attributable about the owner's own balance (contract's own
    /// `redeem` doc comment).
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

    // ============================================================
    // ownerWithdraw floor mechanism — D1, DECISION 2
    // ============================================================

    /// @notice Core protection: once investor funds give the ledger real weight, the owner
    /// cannot withdraw below `cashRatio * max(assertedPortfolioValue, netInvestorDeposits) / 100`
    /// — the contract's one stated purpose ("some kind of unsuccessful protection (cashRatio)...
    /// This is why it is called PotentialRugpull", 00:15).
    function test_OwnerWithdraw_RevertsWhenBreachingFloor() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        // netInvestorDeposits = 1000e8 USD8, cashRatio = 50 -> required = 500e8 USD8.
        // Withdrawing enough to push remaining below 500e8 must revert.
        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertEq(required, 500e8);

        // Withdraw 600 tokens (= $600 = 600e8 USD8) -> remaining = 400e8 < 500e8 required.
        uint256 tooMuch = 600e18;
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 400e8, 500e8));
        rugpull.ownerWithdraw(address(token), tooMuch);
    }

    /// @notice A withdrawal that leaves the CUSHION (`netInvestorDeposits - ownerWithdrawnValueUsd8`)
    /// exactly AT the floor succeeds (>= per 00:15's own wording: "should be larger or equal to").
    /// @dev Verifier fix (2026-10-04), test rewrite: this test previously asserted
    /// `netInvestorDeposits() == 500e8` after the withdrawal — i.e. it asserted the OLD, buggy
    /// ratcheting behavior the verifier flagged ("the withdrawal floor drops a bit after every
    /// owner withdrawal, so repeated withdrawals can drain investors almost to zero"), which this
    /// wave fixed in {PotentialRugpull.ownerWithdraw} (see DECISION 2 in that file). Under the fix,
    /// `netInvestorDeposits` moves ONLY on investor deposit/redeem and must stay UNCHANGED by an
    /// owner withdrawal — that is the whole point of the fix, so asserting it unchanged here is
    /// what makes this test prove the fix rather than contradict it. `ownerWithdrawnValueUsd8` is
    /// the ledger that now actually moves.
    function test_OwnerWithdraw_SucceedsAtExactFloor() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 ledgerBefore = rugpull.netInvestorDeposits();

        // required = 500e8. Withdraw exactly 500 tokens -> cushion = 1000e8 - 0 - 500e8 = 500e8
        // == required.
        rugpull.ownerWithdraw(address(token), 500e18);

        // Non-ratchet guarantee: the DEPOSIT ledger itself is untouched by an owner withdrawal.
        assertEq(rugpull.netInvestorDeposits(), ledgerBefore);
        // The ledger that DOES move is the owner's own cumulative withdrawn-value tracker.
        assertEq(rugpull.ownerWithdrawnValueUsd8(), 500e8);
    }

    /// @notice A withdrawal just inside the floor succeeds and increments the owner's own
    /// withdrawn-value ledger by the exact USD value withdrawn, while leaving the investor
    /// deposit ledger untouched — DECISION 2's non-ratcheting fix.
    /// @dev Verifier fix (2026-10-04), test rewrite: see the sibling test's doc comment above for
    /// why this no longer asserts `netInvestorDeposits()` decrementing — that was the pre-fix,
    /// buggy, ratcheting behavior. Renamed from "...AndDecrementsLedger" to reflect what the
    /// now-correct code actually does: it decrements nothing, it accumulates a separate ledger.
    function test_OwnerWithdraw_SucceedsWithinFloorAndTracksOwnerWithdrawnLedger() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        uint256 depositLedgerBefore = rugpull.netInvestorDeposits();
        uint256 withdrawnLedgerBefore = rugpull.ownerWithdrawnValueUsd8();
        rugpull.ownerWithdraw(address(token), 100e18); // $100 well within floor
        assertEq(rugpull.netInvestorDeposits(), depositLedgerBefore); // unchanged — non-ratcheting
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

    // ============================================================
    // R1 no-lockout proof (DECISION 2) — the floor must NEVER permanently lock the owner out:
    // as investors exit, both the ledger AND the floor it feeds shrink together.
    // ============================================================

    /// @notice Direct proof against R1 (`09-DECISION-LOG.md:428-458`): deposit, have the owner
    /// get blocked by the floor, then have the investor FULLY exit — `required` must collapse from
    /// its historical peak, because a lifetime-monotonic ledger (R1's hazard) would instead keep it
    /// pinned at 500e8 forever.
    /// @dev CORRECTION, recorded live rather than silently patched over (root CLAUDE.md hard rule
    /// 5): this test originally also asserted that `ownerWithdraw(token, 600e18)` SUCCEEDS once the
    /// investor is gone. That assertion was wrong on two independent, already-documented grounds,
    /// both discovered by actually running this test rather than by inspection:
    ///   (1) `redeem`'s payout is `(bal * shares18) / supplyBefore`, and `supplyBefore` INCLUDES the
    ///       owner's permanent `DEFAULT_SHARE_AMOUNT` (1e18) — so a "full" investor exit can never
    ///       recover 100% of the pool pro-rata; a sliver proportional to
    ///       ownerShares/totalSupply is permanently left behind (here: ~0.999e18 of the 1000e18
    ///       token balance, NOT ~1000e18). `ownerWithdraw(token, 600e18)` therefore reverts with
    ///       `InsufficientShares()` at the balance check (`PotentialRugpull.sol:515`) before the
    ///       floor is even evaluated — a NEW finding, distinct from DECISION 2's two flagged edge
    ///       cases, worth its own line in the W5 report's corrections section.
    ///   (2) Separately, and this IS the already-flagged zero-investor-cushion edge case
    ///       (`PotentialRugpull.sol:125-143`): once `netInvestorDeposits == 0`, `remaining` floors
    ///       at 0 for ANY withdrawal amount (even the smallest nonzero one), while `required` can
    ///       never be zero — so `ownerWithdraw` reverts unconditionally, not just for 600e18.
    /// The corrected proof below keeps the part that is actually true and load-bearing for R1 —
    /// `required` recomputes from the LIVE ledger instead of staying pinned at the historical peak —
    /// and separately shows that the revert reason that follows is edge case (2), not a stale
    /// 500e8 floor, which is the real signature that distinguishes "no lockout" from "R1 lockout."
    function test_W5R1_NoLockout_FloorRelaxesAfterInvestorExit() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        // Owner blocked from withdrawing the bulk of the pool while the investor is still in.
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 400e8, 500e8));
        rugpull.ownerWithdraw(address(token), 600e18);

        // Investor fully exits.
        vm.prank(user1);
        rugpull.redeem(shares);

        // R1 lockout, if present, would still show required == 500e8 (the historical peak) here.
        // The LIVE ledger instead reads 0, so required collapses to cashRatio * assertedPortfolioValue
        // / 100 = 50 * 1e8 / 100 = 0.5e8 — proving the floor recomputed rather than staying pinned.
        assertEq(rugpull.netInvestorDeposits(), 0);
        assertEq(rugpull.ownerWithdrawalFloorRequired(), 0.5e8);

        // A tiny withdrawal, well within the ~0.999e18 tokens actually left in the contract (see
        // finding (1) above), isolates the floor check from the balance check. It still reverts —
        // but via edge case (2)'s signature (remaining=0, required=0.5e8), NOT via the ORIGINAL
        // pinned-peak signature (remaining=something, required=500e8) that R1 lockout would produce.
        // That difference in the revert's own arguments is the proof the ledger is live.
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 0, 0.5e8));
        rugpull.ownerWithdraw(address(token), 1e14);
    }

    /// @notice Same proof, partial-exit variant: the floor relaxes proportionally as a FRACTION
    /// of investors leave, not only on a full exit — confirming the ledger is live at every
    /// step, not merely reset-on-zero.
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

    // ============================================================
    // Zero-investor-cushion edge case — flagged in PotentialRugpull.sol's DECISION 2 header,
    // shipped per reading (a) (the literal text), not silently "fixed" toward reading (b).
    // ============================================================

    /// @notice Proves the shipped (flagged, not silently decided) behavior: with zero investors
    /// ever having deposited, `required` is never zero (assertedPortfolioValue defaults nonzero
    /// and can never be set back to zero) while `remaining` IS zero, so ANY ownerWithdraw —
    /// including reclaiming the owner's OWN {ownerDeposit}'d tokens — reverts.
    function test_OwnerWithdraw_RevertsWhenNoInvestorCushionYet_EdgeCase() public {
        // No investor has ever deposited. Owner deposits their own tokens via ownerDeposit.
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.ownerDeposit(address(token), USER_DEPOSIT);

        assertEq(rugpull.netInvestorDeposits(), 0);
        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertGt(required, 0); // never zero: max(assertedPortfolioValue, 0) = assertedPortfolioValue = 1e8

        // Even withdrawing back the owner's own just-deposited tokens reverts, per the flagged
        // edge case: remaining (0) < required (cashRatio * 1e8 / 100).
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 0, required));
        rugpull.ownerWithdraw(address(token), 1e18);
    }

    // ============================================================
    // setAssertedPortfolioValue
    // ============================================================

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

    // ============================================================
    // blacklist / _update — W4 compliance, mirrors BucketVaultBase.sol:468-498
    // ============================================================

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

    /// @notice "even transferring the contract tokens" (client requirement) — a plain ERC-20
    /// transfer of shares between two ordinary holders is blocked the moment EITHER side is
    /// blacklisted.
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

    /// @notice Fail-closed (D2/INV-7): an unreachable/reverting BucketInfo.isBlacklisted call is
    /// treated as blacklisted, blocking the action rather than allowing it through.
    function test_FailClosed_RevertingBucketInfo_BlocksDeposit() public {
        bucketInfo.setBlacklistCheckReverts(true);
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.Blacklisted.selector, user1));
        rugpull.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    // ============================================================
    // seizure — thin wrapper over SeizureLib (shared code already fully exercised by W4Gate.t.sol
    // against ActiveBucket/PassiveBucket); one round-trip test here confirms PotentialRugpull's
    // own wrapper wiring (its locally-declared seizureTimelocks mapping, its own
    // SEIZURE_TIMELOCK_DELAY constant, and the beforeBalance parameter this contract reads and
    // passes to SeizureLib.executeSeizure) is correct, not a re-derivation of SeizureLib itself.
    // ============================================================

    function test_Seizure_MovesBalanceAndEmitsDocumentHashAndBalances() public {
        vm.startPrank(user1);
        token.approve(address(rugpull), USER_DEPOSIT);
        rugpull.deposit(address(token), USER_DEPOSIT);
        uint256 shares = rugpull.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        // Platform owner (this test contract, per MockBucketInfoForRugpull's `owner = msg.sender`
        // constructor convention) proposes.
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

    // ============================================================
    // renounceOwnership — Q14.2, universal
    // ============================================================

    function test_RenounceOwnership_AlwaysReverts() public {
        vm.expectRevert(PotentialRugpull.RenounceOwnershipDisabled.selector);
        rugpull.renounceOwnership();
    }

    // ============================================================
    // name()/symbol() overrides (DECISION 1) — distinct instances have distinct, wallet-visible
    // names despite the single-variable constructor constraint.
    // ============================================================

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

// ============================================================
//                 FACTORY — PotentialRugpullFactory
// ============================================================

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

    /// @notice The caller becomes the owner within the SAME transaction — no indexer-visible
    /// window where the factory appears to be the owner (unlike an Ownable2Step handoff).
    function test_CreatePotentialRugpull_CallerBecomesOwnerSameTransaction() public {
        address user = makeAddr("creator");
        vm.prank(user);
        address instance = factory.createPotentialRugpull(50, "X", "Y");

        PotentialRugpull rp = PotentialRugpull(payable(instance));
        assertEq(rp.owner(), user);
        assertEq(rp.balanceOf(user), 1e18);
        assertEq(rp.balanceOf(address(factory)), 0);
    }

    /// @notice Every instance created through this factory shares the SAME factory-immutable
    /// BucketInfo pointer, never a value the `createPotentialRugpull` caller supplies — root
    /// CLAUDE.md §1.1's factory-immutable-pointer precondition, mirrored from W1.7's fix on the
    /// other three factories.
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
