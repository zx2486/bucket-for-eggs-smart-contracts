// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// W5-gate (task #66) — authoritative gate-level proof for the four-part W5 verification-plan
// row (`_deliverables/04-CONTRACTS-IMPLEMENTATION-PLAN.md:1277`):
//   G1. "Rugpull floor holds under both denominations of D1"
//   G2. "stable exit reverts on partial fill"
//   G3. "flashloan cannot be composed with deposit/redeem for profit"
//   G4. "and is callable by a holder who is not the owner (B6)"
//
// D1 is defined at `04-CONTRACTS-IMPLEMENTATION-PLAN.md:50`: PotentialRugpull's cash floor is
// denominated against whichever is HIGHER of the owner-asserted portfolio value and cumulative
// net investor deposits — chosen because flooring against the asserted value alone would let the
// owner lower the assertion to unlock the floor. "Both denominations" means G1 must prove the
// floor is governed by EACH side of that `max()` in turn, not just exercise the formula once.
//
// New, standalone gate file — same convention `test/W4Gate.t.sol` set (root CLAUDE.md hard rule
// 6): this file owns its own mocks rather than importing another test file's, and sits alongside
// (not instead of) the per-feature unit-test files this gate's proofs partially overlap with by
// design (`test/PotentialRugpull.t.sol`, `test/RedeemForStable.t.sol`, `test/ActiveBucket.t.sol`):
// those files prove each feature works in detail; this file is the four-line wave-level sign-off
// a verifier reads first (root CLAUDE.md hard rule 13 — an implementer's own build/test output is
// not certification, but it is the evidence a verifier needs handed to them already organised by
// gate item).

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PotentialRugpull} from "../src/PotentialRugpull.sol";
import {PotentialRugpullFactory} from "../src/PotentialRugpullFactory.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";

// ============================================================
//                      SHARED MOCKS
// ============================================================

/// @dev One IBucketInfo mock covering every method PotentialRugpull/ActiveBucket/PassiveBucket
/// call, same shape/precedent as `GateMockBucketInfo` (test/W4Gate.t.sol) and
/// `MockBucketInfoForRugpull` (test/PotentialRugpull.t.sol). `priceFeedSet` defaults every
/// `addToken`-ed token to Chainlink-priced, since none of this file's tests exercise the
/// manually-priced-token-rejection path.
contract GateMockBucketInfoW5 {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    mapping(address => bool) public priceFeedSet;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
    address public owner;
    mapping(address => bool) public blacklisted;

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

    function tryGetTokenPrice(address token) external view returns (bool, uint256) {
        if (!whitelisted[token]) return (false, 0);
        return (true, prices[token]);
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

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

    function setOperational(bool _operational) external {
        operational = _operational;
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    receive() external payable {}
}

/// @dev Plain mintable ERC20 mock, same shape as `GateMockERC20` (test/W4Gate.t.sol) /
/// `RugpullMockERC20` (test/PotentialRugpull.t.sol) / `MockERC20RFS` (test/RedeemForStable.t.sol).
contract GateMockERC20W5 {
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

/// @dev Zero-slippage, fair-value 1inch router mock — same mechanism as
/// `test/RedeemForStable.t.sol`'s `FairValueOneInchRouter` (duplicated here per hard rule 6, not
/// imported). Genuinely attempts the dstToken payout rather than hardcoding a failure, so an
/// unfunded router fails for the SAME reason a real one would (G2 relies on exactly this).
contract GateFairRouterW5 {
    mapping(address => uint256) public price; // 8-decimal USD price; address(0) = native ETH
    mapping(address => uint8) public tokenDecimals;

    function setPrice(address token, uint256 price_, uint8 decimals_) external {
        price[token] = price_;
        tokenDecimals[token] = decimals_;
    }

    function execute1inchSwap(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 amount,
        uint256 minReturn
    ) external payable returns (uint256 amountOut) {
        if (srcToken == address(0)) {
            require(msg.value == amount, "router: bad native value");
        } else {
            GateMockERC20W5(srcToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 srcPrice = price[srcToken];
        uint256 dstPrice = price[dstToken];
        require(srcPrice > 0 && dstPrice > 0, "router: no price set");
        uint8 srcDec = tokenDecimals[srcToken];
        uint8 dstDec = tokenDecimals[dstToken];

        amountOut = (amount * srcPrice * (10 ** dstDec)) / ((10 ** srcDec) * dstPrice);
        require(amountOut >= minReturn, "router: below minReturn");

        if (dstToken == address(0)) {
            (bool ok,) = dstReceiver.call{value: amountOut}("");
            require(ok, "router: ETH send failed");
        } else {
            require(GateMockERC20W5(dstToken).transfer(dstReceiver, amountOut), "router: transfer failed");
        }
    }

    receive() external payable {}
}

/// @dev G2 rewrite (2026-10-04) — router mock that computes a genuine fair-value swap amount but
/// DELIBERATELY pays out only a configurable fraction of it, ignoring the `minReturn` parameter
/// the vault handed it (no self-enforcing `require(amountOut >= minReturn)` the way
/// `GateFairRouterW5` above has). This models the verifier's own words exactly: "A router that
/// ignored the minimum short-paid 10% and the call still succeeded." The vault's own post-hoc
/// `received < legMinReturn` check (`BucketVaultBase.sol:1933`, `ReceivedBelowMinReturn`) is what
/// must catch this — the router itself does nothing to stop it, by design, so this contract is a
/// faithful stand-in for "a malicious or buggy router" rather than a shortcut.
contract GateShortPayRouterW5 {
    mapping(address => uint256) public price; // 8-decimal USD price; address(0) = native ETH
    mapping(address => uint8) public tokenDecimals;
    uint256 public immutable shortPayBps; // how much LESS than fair value this router pays out

    constructor(uint256 shortPayBps_) {
        shortPayBps = shortPayBps_;
    }

    function setPrice(address token, uint256 price_, uint8 decimals_) external {
        price[token] = price_;
        tokenDecimals[token] = decimals_;
    }

    function execute1inchSwap(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 amount,
        uint256 /* minReturn -- deliberately ignored, see this contract's doc comment */
    )
        external
        payable
        returns (uint256 amountOut)
    {
        if (srcToken == address(0)) {
            require(msg.value == amount, "router: bad native value");
        } else {
            GateMockERC20W5(srcToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 srcPrice = price[srcToken];
        uint256 dstPrice = price[dstToken];
        require(srcPrice > 0 && dstPrice > 0, "router: no price set");
        uint8 srcDec = tokenDecimals[srcToken];
        uint8 dstDec = tokenDecimals[dstToken];

        uint256 fairAmountOut = (amount * srcPrice * (10 ** dstDec)) / ((10 ** srcDec) * dstPrice);
        amountOut = (fairAmountOut * (10_000 - shortPayBps)) / 10_000;

        if (dstToken == address(0)) {
            (bool ok,) = dstReceiver.call{value: amountOut}("");
            require(ok, "router: ETH send failed");
        } else {
            require(GateMockERC20W5(dstToken).transfer(dstReceiver, amountOut), "router: transfer failed");
        }
    }

    receive() external payable {}
}

/// @dev G3 — attempts to compose a flashloan with `deposit`/`redeem` on the SAME bucket, mid-
/// callback, before repayment, to prove the shared `nonReentrant` lock (BucketVaultBase.sol)
/// blocks it. See `W5GateFlashLoanCompositionTest` below.
contract ComposerFlashLoanReceiverW5 is IFlashLoanReceiver {
    enum Mode {
        None,
        Deposit,
        Redeem
    }

    Mode public mode;
    ActiveBucket public bucket;

    constructor(ActiveBucket bucket_) {
        bucket = bucket_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata) external override {
        if (mode == Mode.Deposit) {
            // Attempt to mint shares "for free" using the just-borrowed ETH, mid-loan, before
            // repayment. Must revert: deposit()'s own `nonReentrant` collides with flashLoan's
            // already-held lock.
            bucket.deposit{value: amount}(address(0), 0);
        } else if (mode == Mode.Redeem) {
            // Symmetric attempt via redeem() instead of deposit(). Must revert for the identical
            // reason — proves the guard is not deposit-specific.
            bucket.redeem(1);
        }
    }

    receive() external payable {}
}

/// @dev G4 — a well-behaved flash loan receiver that actually repays principal + fee, used to
/// prove the POSITIVE holder-callable case (as opposed to `ComposerFlashLoanReceiverW5`, which is
/// deliberately malicious). Mirrors `MockFlashLoanReceiver` (test/ActiveBucket.t.sol).
contract MockFlashLoanReceiverW5 is IFlashLoanReceiver {
    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata) external override {
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount + fee}("");
            require(ok, "repay failed");
        } else {
            IERC20(token).transfer(msg.sender, amount + fee);
        }
    }

    receive() external payable {}
}

// ============================================================
// G1 — Rugpull floor holds under BOTH denominations of D1
// ============================================================

/// @notice D1 (`04-CONTRACTS-IMPLEMENTATION-PLAN.md:50`): the floor is
/// `cashRatio * max(assertedPortfolioValue, netInvestorDeposits) / 100`. These two tests each
/// drive one side of that `max()` to be the larger value and prove, BOTH by reading
/// `ownerWithdrawalFloorRequired()` directly AND by exercising `ownerWithdraw`'s exact
/// revert/success boundary, that the floor is actually computed against whichever side is
/// currently higher — not hardcoded to one side, and not silently falling back to the other.
contract W5GateRugpullFloorTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    GateMockERC20W5 public token;
    PotentialRugpullFactory public factory;
    PotentialRugpull public rugpull;

    address public ownerAddr;
    address public investor;

    uint256 constant TOKEN_PRICE = 1e8; // $1, 8-decimal USD
    uint256 constant CASH_RATIO = 50;

    function setUp() public {
        ownerAddr = address(this);
        investor = makeAddr("investor");

        bucketInfo = new GateMockBucketInfoW5();
        token = new GateMockERC20W5("Token", "TKN", 18);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        token.mint(investor, 10_000e18);

        factory = new PotentialRugpullFactory(address(bucketInfo));
        address instance = factory.createPotentialRugpull(CASH_RATIO, "Rugpull Share", "RUG");
        rugpull = PotentialRugpull(payable(instance));
    }

    /// @notice G1a: assertedPortfolioValue (1000e8) > netInvestorDeposits (600e8) — the floor
    /// must be governed by the HIGHER, asserted-value side of D1's `max()`, not by
    /// netInvestorDeposits alone.
    function test_G1a_FloorGovernedByAssertedValue_WhenHigherThanDeposits() public {
        rugpull.setAssertedPortfolioValue(1000e8);

        vm.startPrank(investor);
        token.approve(address(rugpull), 600e18);
        rugpull.deposit(address(token), 600e18); // netInvestorDeposits = 600e8
        vm.stopPrank();

        assertEq(rugpull.netInvestorDeposits(), 600e8);
        assertEq(rugpull.assertedPortfolioValue(), 1000e8);

        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertEq(required, 500e8, "required must be 50% of the HIGHER value (asserted: 1000e8)");
        assertTrue(
            required != (CASH_RATIO * rugpull.netInvestorDeposits()) / 100,
            "sanity: the netInvestorDeposits-only formula must give a DIFFERENT number here"
        );

        // Withdraw $150 -> remaining = 600e8 - 150e8 = 450e8 < 500e8 required -> reverts.
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 450e8, 500e8));
        rugpull.ownerWithdraw(address(token), 150e18);

        // Withdraw $90 instead -> cushion = 600e8 - 0 - 90e8 = 510e8 >= 500e8 required -> succeeds.
        // Verifier fix (2026-10-04), test rewrite: previously asserted
        // `netInvestorDeposits() == 510e8` here, i.e. the OLD ratcheting bug the verifier flagged
        // (floor "drops a bit after every owner withdrawal"). The fix in
        // {PotentialRugpull.ownerWithdraw} now leaves `netInvestorDeposits` untouched by an owner
        // withdrawal and tracks `ownerWithdrawnValueUsd8` instead — asserting that non-ratchet
        // property here is what makes this gate test actually prove the fix.
        rugpull.ownerWithdraw(address(token), 90e18);
        assertEq(rugpull.netInvestorDeposits(), 600e8, "non-ratchet: deposit ledger must be untouched");
        assertEq(rugpull.ownerWithdrawnValueUsd8(), 90e8);
        assertEq(token.balanceOf(ownerAddr), 90e18);
    }

    /// @notice G1b: netInvestorDeposits (1000e8) > assertedPortfolioValue (left at its default,
    /// 1e8) — the floor must now be governed by the HIGHER, deposits side instead. Same two-part
    /// proof as G1a, with the denominations' roles swapped.
    function test_G1b_FloorGovernedByNetInvestorDeposits_WhenHigherThanAssertedValue() public {
        // assertedPortfolioValue deliberately left at its default (1e8) — never raised, so this
        // test is the genuine mirror image of G1a, not a relabeling of the same scenario.
        assertEq(rugpull.assertedPortfolioValue(), 1e8);

        vm.startPrank(investor);
        token.approve(address(rugpull), 1000e18);
        rugpull.deposit(address(token), 1000e18); // netInvestorDeposits = 1000e8
        vm.stopPrank();

        assertEq(rugpull.netInvestorDeposits(), 1000e8);

        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertEq(required, 500e8, "required must be 50% of the HIGHER value (deposits: 1000e8)");
        assertTrue(
            required != (CASH_RATIO * rugpull.assertedPortfolioValue()) / 100,
            "sanity: the assertedPortfolioValue-only formula must give a DIFFERENT (much smaller) number here"
        );

        // Withdraw $600 -> remaining = 1000e8 - 600e8 = 400e8 < 500e8 required -> reverts.
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 400e8, 500e8));
        rugpull.ownerWithdraw(address(token), 600e18);

        // Withdraw $400 instead -> cushion = 1000e8 - 0 - 400e8 = 600e8 >= 500e8 required ->
        // succeeds. Verifier fix (2026-10-04), test rewrite: see G1a's sibling comment above for
        // why this no longer asserts `netInvestorDeposits()` decrementing.
        rugpull.ownerWithdraw(address(token), 400e18);
        assertEq(rugpull.netInvestorDeposits(), 1000e8, "non-ratchet: deposit ledger must be untouched");
        assertEq(rugpull.ownerWithdrawnValueUsd8(), 400e8);
        assertEq(token.balanceOf(ownerAddr), 400e18);
    }
}

// ============================================================
// G2 — stable exit reverts on partial fill (atomicity)
// ============================================================

/// @notice Verifier fix (2026-10-04), REWRITTEN. The original version of this test used a
/// single-asset (100% ETH) basket and a bare `vm.expectRevert()`, so it proved only that
/// `redeemForStable` can be made to revert SOMEHOW — the same assertion would pass even if the
/// function reverted unconditionally for an unrelated reason, which is exactly the verifier's
/// claim: "The W5 gate test for partial fills passes even when the function always reverts, so
/// it proves nothing" (and its sibling claim, "A bare 'expect any revert' check is also satisfied
/// by unrelated crashes"). This version fixes both:
///   1. A genuine TWO-leg basket (ETH + the stable token itself), so there is an actual "first leg
///      completes, second leg fails" scenario to prove atomicity over — the stable-token leg takes
///      the free `tokens[i] == dstToken` branch (`BucketVaultBase.sol:1902-1906`, no swap, direct
///      credit) and "completes" before the ETH leg's swap ever runs. The ETH leg is deliberately
///      sized to ~1% of total vault value (not 50/50) — see `BucketVaultBase.sol:1922-1925`'s own
///      doc comment: a leg worth ~5% of the vault short-paid 10% is RIGHT AT the whole-vault
///      `MAX_VALUE_LOSS_BPS` (0.5%) boundary and risks tripping `ValueLossTooHigh` instead of the
///      per-leg check this test exists to exercise; a ~1% leg clears that boundary with room to
///      spare (confirmed by running this test against a 50/50 split first: it failed with
///      `ValueLossTooHigh`, not `ReceivedBelowMinReturn` — exactly the masking this sizing avoids).
///   2. A precise revert assertion (`BucketVaultBase.ReceivedBelowMinReturn.selector` via
///      `vm.expectPartialRevert`, not a bare `vm.expectRevert()`) tied to the EXACT mechanism this
///      test is supposed to exercise: `GateShortPayRouterW5` genuinely executes the ETH->stable
///      swap and genuinely pays out stable tokens, but deliberately pays only 90% of fair value,
///      ignoring the `minReturn` it was handed — mirroring the owner's own example verbatim ("A
///      router that ignored the minimum short-paid 10% and the call still succeeded"). The
///      surviving guard is the vault's own post-hoc `received < legMinReturn` check
///      (`BucketVaultBase.sol:1933`), added by the task #80 fix — this test is also that fix's
///      hard-rule-13 proof, since no other test in `test/` exercised `ReceivedBelowMinReturn`
///      before this one (confirmed by grep).
/// Assertions then confirm the WHOLE call reverts, including the free leg's already-"completed"
/// effect: no shares burned, no ETH moved, and no stable token paid out to the user at all (not
/// even the free leg's portion) — genuine cross-leg atomicity, not merely "it reverted".
contract W5GateStableExitAtomicityTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    GateMockERC20W5 public stable; // 6 decimals — redemption target, ALSO a basket asset
    GateShortPayRouterW5 public router;
    ImplementationRegistry public registry;
    PassiveBucket public passiveImpl;
    PassiveBucket public passive;

    address public ownerAddr;
    address public user1;

    uint256 constant ETH_PRICE = 2000e8; // $2000
    uint256 constant STABLE_PRICE = 1e8; // $1
    uint256 constant SHORT_PAY_BPS = 1000; // router pays 10% less than fair value

    function setUp() public {
        ownerAddr = address(this);
        user1 = makeAddr("user1");
        vm.deal(user1, 100 ether);

        bucketInfo = new GateMockBucketInfoW5();
        stable = new GateMockERC20W5("Stable", "STB", 6);
        router = new GateShortPayRouterW5(SHORT_PAY_BPS);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(stable), STABLE_PRICE);

        router.setPrice(address(0), ETH_PRICE, 18);
        router.setPrice(address(stable), STABLE_PRICE, 6);

        // Router IS funded this time (unlike the old version) — the point is no longer "the
        // payout plumbing fails", it's "the router succeeds but pays short, and the vault's own
        // value check must catch it".
        stable.mint(address(router), 1_000_000e6);

        registry = new ImplementationRegistry(ownerAddr);
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);

        passiveImpl = new PassiveBucket(address(registry));
        // Two-asset basket: ETH (swapped leg) + stable itself (free, no-swap leg) — see this
        // contract's doc comment for why a single-asset basket cannot prove atomicity at all.
        // Weights deliberately lopsided (not 50/50) so the actual DEPOSITS below (which drive
        // held-token proportions, not these target weights — see `_registerHeldToken`) can mirror
        // them: the ETH leg must stay a small slice of total vault value. See this contract's doc
        // comment for why — a ~50% leg short-paid 10% blows the whole-vault MAX_VALUE_LOSS_BPS
        // (0.5%) guard before the per-leg ReceivedBelowMinReturn check is ever reached.
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 1);
        dists[1] = PassiveBucket.BucketDistribution(address(stable), 99);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(router), "Passive Share", "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(passiveImpl), initData);
        passive = PassiveBucket(payable(address(proxy)));

        // Fund the vault with BOTH basket assets so `redeemForStable` actually has two held-token
        // legs to iterate (held-tokens tracking is deposit-driven, not distribution-driven — see
        // `BucketVaultBase._registerHeldToken`). Amounts are deliberately lopsided: 1 ETH ($2,000)
        // against $198,000 stable makes the ETH leg ~1% of total vault value ($200,000), so a 10%
        // short-pay on it is only a ~0.1% WHOLE-VAULT loss — comfortably under the 0.5%
        // MAX_VALUE_LOSS_BPS guard — while still being a 100% violation of that leg's own
        // zero-tolerance `legMinReturn` floor (maxSlippageBps=0 below).
        vm.prank(user1);
        passive.deposit{value: 1 ether}(address(0), 0);

        stable.mint(user1, 198_000e6);
        vm.prank(user1);
        stable.approve(address(passive), 198_000e6);
        vm.prank(user1);
        passive.deposit(address(stable), 198_000e6);
    }

    /// @notice G2: a two-leg redemption where the free (`tokens[i] == dstToken`) leg "completes"
    /// first and the swapped (ETH) leg's router short-pays by 10% — `redeemForStable` must revert
    /// in its entirety via `ReceivedBelowMinReturn`, with NEITHER leg's effect surviving.
    function test_G2_StableExitRevertsEntirely_OnShortPaidLeg() public {
        uint256 sharesBefore = passive.balanceOf(user1);
        uint256 ethBefore = address(passive).balance;
        uint256 vaultStableBefore = stable.balanceOf(address(passive));
        uint256 userStableBefore = stable.balanceOf(user1);

        vm.prank(user1);
        // maxSlippageBps = 0 -> tightest possible per-leg floor (legMinReturn == fair value, no
        // tolerance), so the router's 10% short-pay is caught regardless of rounding. Precise
        // revert (hard rule 13 / verifier claim #6 — no bare `vm.expectRevert()`): `expectPartialRevert`
        // rather than an exact-args match, since replicating this library's internal rounding here
        // would just be re-deriving `SwapExecutionLib.minReturnForStableLeg` a second time (see
        // feedback memory on forge's exact-match `expectRevert` pitfall for parameterized errors).
        vm.expectPartialRevert(BucketVaultBase.ReceivedBelowMinReturn.selector);
        passive.redeemForStable(sharesBefore, address(stable), 0);

        assertEq(passive.balanceOf(user1), sharesBefore, "shares must survive a short-paid leg completely unburned");
        assertEq(address(passive).balance, ethBefore, "vault ETH balance must be untouched after a short-paid leg");
        assertEq(
            stable.balanceOf(address(passive)),
            vaultStableBefore,
            "vault stable balance must be untouched -- the free leg's payout must not survive the later leg's revert"
        );
        assertEq(
            stable.balanceOf(user1),
            userStableBefore,
            "user must receive NOTHING, not even the free leg's portion, when a later leg reverts"
        );
    }
}

// ============================================================
// G3 — flashloan cannot be composed with deposit/redeem for profit
// ============================================================

/// @notice `flashLoan`, `deposit`, `redeem` and `redeemForStable` all share ONE `nonReentrant`
/// lock (declared via `ReentrancyGuardTransient` on `BucketVaultBase`). A flash loan receiver
/// cannot therefore call back into `deposit`/`redeem` on the SAME bucket mid-loan to try to
/// extract value before repayment — the attempt itself reverts the whole transaction.
contract W5GateFlashLoanCompositionTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    ActiveBucket public activeImpl;
    ActiveBucket public active;
    ImplementationRegistry public registry;

    address public ownerAddr;
    address public user1;

    uint256 constant ETH_PRICE = 2000e8;

    function setUp() public {
        ownerAddr = address(this);
        user1 = makeAddr("user1");
        vm.deal(user1, 100 ether);

        bucketInfo = new GateMockBucketInfoW5();
        bucketInfo.addToken(address(0), ETH_PRICE);

        registry = new ImplementationRegistry(ownerAddr);
        activeImpl = new ActiveBucket(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), address(0xDEAD), "Active Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(activeImpl), initData);
        active = ActiveBucket(payable(address(proxy)));

        vm.prank(user1);
        active.deposit{value: 10 ether}(address(0), 0);
    }

    /// @notice G3a: receiver tries `deposit()` mid-callback, spending the just-borrowed (not yet
    /// repaid) ETH, to mint shares "for free". Must revert: `deposit`'s `nonReentrant` collides
    /// with the lock `flashLoan` already holds.
    function test_G3a_FlashLoanCannotComposeWithDeposit() public {
        ComposerFlashLoanReceiverW5 receiver = new ComposerFlashLoanReceiverW5(active);
        receiver.setMode(ComposerFlashLoanReceiverW5.Mode.Deposit);

        vm.prank(user1);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }

    /// @notice G3b: symmetric attempt via `redeem()` instead of `deposit()` — same shared lock,
    /// same guaranteed revert, proving the guard is not deposit-specific.
    function test_G3b_FlashLoanCannotComposeWithRedeem() public {
        ComposerFlashLoanReceiverW5 receiver = new ComposerFlashLoanReceiverW5(active);
        receiver.setMode(ComposerFlashLoanReceiverW5.Mode.Redeem);

        vm.prank(user1);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }
}

// ============================================================
// G4 — flashloan is callable by a holder who is not the owner (B6)
// ============================================================

/// @notice B6 (`09-DECISION-LOG.md` §8.1 item 6): `flashLoan` was `onlyOwner`, confirmed stale by
/// the client, and corrected (task #65) to be gated on holding a nonzero share balance instead.
/// This proves BOTH halves of that correction standalone: a genuine non-owner holder CAN call it,
/// and an address holding zero shares CANNOT — so the gate is actually share-based, not merely a
/// wider owner set in disguise.
contract W5GateFlashLoanHolderTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    ActiveBucket public activeImpl;
    ActiveBucket public active;
    ImplementationRegistry public registry;

    address public ownerAddr;
    address public holder; // deposits, becomes a shareholder -- NOT the owner
    address public nonHolder; // never deposits

    uint256 constant ETH_PRICE = 2000e8;

    function setUp() public {
        ownerAddr = address(this);
        holder = makeAddr("holder");
        nonHolder = makeAddr("nonHolder");
        vm.deal(holder, 100 ether);

        bucketInfo = new GateMockBucketInfoW5();
        bucketInfo.addToken(address(0), ETH_PRICE);

        registry = new ImplementationRegistry(ownerAddr);
        activeImpl = new ActiveBucket(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), address(0xDEAD), "Active Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(activeImpl), initData);
        active = ActiveBucket(payable(address(proxy)));

        vm.prank(holder);
        active.deposit{value: 10 ether}(address(0), 0);
    }

    /// @notice G4 positive case: `holder` genuinely holds shares but is explicitly NOT this
    /// bucket's `owner()` (that is `address(this)`, i.e. the deploying test contract, which never
    /// deposited and is a different address from `holder`).
    function test_G4_FlashLoanCallableByHolderWhoIsNotOwner() public {
        assertTrue(active.balanceOf(holder) > 0, "sanity: holder must actually hold shares");
        assertTrue(holder != active.owner(), "sanity: holder must NOT be the owner");

        MockFlashLoanReceiverW5 receiver = new MockFlashLoanReceiverW5();
        vm.deal(address(receiver), 1 ether); // covers the 2% fee on top of the repaid principal

        vm.prank(holder);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
        // No revert -- holder-callable, as B6 requires.
    }

    /// @notice G4 negative case: `nonHolder` is also not the owner, but holds ZERO shares (never
    /// deposited) and must be rejected — proving the check is genuinely share-based rather than a
    /// disguised, merely-wider owner-exclusivity check that happens to also accept `holder`.
    function test_G4_FlashLoanRejectsNonHolder() public {
        MockFlashLoanReceiverW5 receiver = new MockFlashLoanReceiverW5();

        vm.prank(nonHolder);
        vm.expectRevert(BucketVaultBase.InsufficientShares.selector);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }
}
