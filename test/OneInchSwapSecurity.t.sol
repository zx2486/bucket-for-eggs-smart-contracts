// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// W2 (sc-swap) — 1inch/arbitrary-calldata swap security suite.
//
// Built skeleton-first (workspace CLAUDE.md hard rule 7): this file is written in stages —
// (1) the pre-fix drain exploit, run against the ORIGINAL `bytes calldata swapCalldata` shape of
//     PassiveBucket.rebalanceBy1inch to prove the vulnerability exists, evidence captured in
//     W2-SC-SWAP-REPORT.md BEFORE the fix landed;
// (2) a post-fix companion test showing the same attacker intent is now impossible against the
//     typed-parameter signature;
// (3) a test reproducing why the CURRENT (pre-fix) shape's real-router calls fail on Sepolia
//     (missing-allowance hypothesis, A4).
// Sections below are filled in that order; see W2-SC-SWAP-REPORT.md for the full narrative.
// ============================================================

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

/// @dev Minimal single-token BucketInfo mock, deliberately separate from
/// test/PassiveBucket.t.sol's `MockBucketInfoForPassive` so this file has no cross-file
/// dependency on another test file's private fixtures. Implements the same surface PassiveBucket
/// actually calls.
contract SecurityMockBucketInfo {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 0;
    address public owner;

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

    receive() external payable {}
}

contract SecurityMockERC20 {
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

/// @dev A "router" that behaves exactly the way a real aggregation router does once it has been
/// granted an allowance and receives calldata whose destination field an attacker controls: it
/// pulls `amount` of `token` FROM WHOEVER CALLS IT (the vault, since the vault itself performs
/// `oneInchRouter.call(swapCalldata)`, making the vault `msg.sender` from this router's point of
/// view) and sends it to an attacker-chosen `to`. This is the mechanism `_review`/A4 describes as
/// "latent, not live" — it requires an allowance to exist first (see the test below for where
/// that allowance is granted and why that is permitted here).
contract MaliciousOneInchRouter {
    function steal(address token, uint256 amount, address to) external {
        IERC20(token).transferFrom(msg.sender, to, amount);
    }
}

// ============================================================
//              PRE-FIX DRAIN EXPLOIT — HISTORICAL EVIDENCE
// ============================================================
//
// The contract that lived in this section (`PreFixRebalanceBy1inchDrainTest`) was written and
// run against the ORIGINAL `PassiveBucket.rebalanceBy1inch(bytes calldata swapCalldata)` shape,
// BEFORE any src/ edit in this wave landed — i.e. against the actual pre-fix commit's behaviour,
// not a re-derivation of it. It is preserved here only as a comment (it can no longer compile:
// its one call site, `bucket.rebalanceBy1inch(maliciousCalldata)`, targets a single-`bytes`
// parameter list that no longer exists on the fixed interface — see
// PassiveBucket.rebalanceBy1inch's current four-typed-parameter signature). Captured, verbatim,
// BEFORE the fix landed (hard rule 13's "proven to fail on the pre-fix commit" evidence):
//
//   Ran 1 test for test/OneInchSwapSecurity.t.sol:PreFixRebalanceBy1inchDrainTest
//   [PASS] test_PreFix_RebalanceBy1inch_DrainsVaultToAttacker() (gas: 33766947)
//   Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 21.73ms (21.15ms CPU time)
//
// What that run proved: with a single-token (100%-weight) PassiveBucket, an attacker holding only
// a dust deposit (1,000 of 1,001,000 total units — 0.0999%) — enough to pass the
// `balanceOf(msg.sender) > 0` gate and nothing else — could repeatedly call
// `rebalanceBy1inch(maliciousCalldata)` with calldata built for a `MaliciousOneInchRouter.steal`
// call naming themselves as recipient, and, purely because the pre-fix helper forwarded that
// calldata to `oneInchRouter` unvalidated, extract more than half the vault's real token holdings
// to their own address within 200 loop iterations — each individual call staying under the
// existing 0.5% `MAX_VALUE_LOSS_BPS` per-call cap, the loop structure defeating that cap
// cumulatively, exactly as bucket-for-eggs-smart-contracts/CLAUDE.md §8 rule 2 predicted.
//
// The `PostFixRebalanceBy1inchAttackBlockedTest` contract directly below reproduces the IDENTICAL
// setup (same single-token distribution, same depositor/attacker split, same malicious router
// wired in as `oneInchRouter`) against the FIXED interface, and proves the same attacker intent
// (attempting to name themselves, or any address other than this vault, as swap recipient) is now
// rejected before any external call is ever made.
// ============================================================

contract PostFixRebalanceBy1inchAttackBlockedTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    SecurityMockBucketInfo public bucketInfo;
    SecurityMockERC20 public tokenB;
    MaliciousOneInchRouter public maliciousRouter;

    address public depositor;
    address public attacker;

    uint256 constant TOKEN_B_PRICE = 1e8;
    uint256 constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 constant ATTACKER_DEPOSIT = 1_000e6;

    function setUp() public {
        depositor = address(this);
        attacker = makeAddr("attacker");

        bucketInfo = new SecurityMockBucketInfo();
        tokenB = new SecurityMockERC20("Token B", "TKB", 6);
        maliciousRouter = new MaliciousOneInchRouter();

        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        implementation = new PassiveBucket();

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(tokenB), 100);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(maliciousRouter), // same attacker-controlled mock as the pre-fix run
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        tokenB.mint(depositor, INITIAL_DEPOSIT);
        tokenB.mint(attacker, ATTACKER_DEPOSIT);

        tokenB.approve(address(bucket), INITIAL_DEPOSIT);
        bucket.deposit(address(tokenB), INITIAL_DEPOSIT);

        vm.startPrank(attacker);
        tokenB.approve(address(bucket), ATTACKER_DEPOSIT);
        bucket.deposit(address(tokenB), ATTACKER_DEPOSIT);
        vm.stopPrank();

        // Same R-V1-permitted allowance grant as the pre-fix run — irrelevant to the outcome
        // below (the call never reaches a point where this allowance would be exercised via an
        // attacker-chosen path), kept identical to the pre-fix setup so this is a true
        // apples-to-apples comparison, not a weakened reproduction.
        vm.prank(address(bucket));
        tokenB.approve(address(maliciousRouter), type(uint256).max);
    }

    /// @notice The single-token distribution means there is no OTHER whitelisted token the
    /// attacker can legally name as `dstToken` — every attempt reverts with `InvalidToken`
    /// before `_execute1inchSwap` ever reaches the router call. This mirrors the pre-fix test's
    /// setup exactly (same tokens, same router, same attacker) and shows the identical attacker
    /// intent is now unreachable, not merely rate-limited.
    function test_PostFix_RebalanceBy1inch_RejectsUnwhitelistedDestination() public {
        uint256 initialVaultBalance = tokenB.balanceOf(address(bucket));
        address fakeDst = makeAddr("fakeDstToken");

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, fakeDst));
            bucket.rebalanceBy1inch(address(tokenB), fakeDst, 1_000e6, 0);
        }

        assertEq(tokenB.balanceOf(address(bucket)), initialVaultBalance);
        assertEq(tokenB.balanceOf(attacker), 0);
    }

    /// @notice Even granting the attacker a same-token "swap" (the one case that does not fail
    /// the whitelist check on the destination leg, since src==dst) is rejected by the
    /// same-token guard before any call — there is no way to reach the router at all with a
    /// destination the attacker controls, because this contract never accepts a destination
    /// parameter in the first place; the receiver is always `address(this)` by construction.
    function test_PostFix_RebalanceBy1inch_RejectsSameTokenSwap() public {
        vm.prank(attacker);
        vm.expectRevert(BucketVaultBase.SameToken.selector);
        bucket.rebalanceBy1inch(address(tokenB), address(tokenB), 1_000e6, 0);
    }
}

// ============================================================
//      SEPOLIA "MISSING ALLOWANCE" LATENCY MECHANISM (A4)
// ============================================================

/// @notice A4 (`09-DECISION-LOG.md` §4): `rebalanceBy1inch`/`swapBy1inch` have never once
/// succeeded on Sepolia, and the client's own leading hypothesis is "we really need to do the
/// approval first". This test isolates that exact mechanism — independent of the calldata-shape
/// fix above — using a router that behaves like a real aggregation router: it PULLS `amount` of
/// `srcToken` from whoever calls it via `transferFrom`, which requires a pre-existing allowance.
/// Confirmed latent — armed by the allowance, not by a code change: the SAME router, the SAME
/// call, reverts with no allowance and succeeds once one exists, with no other input changed.
/// This is exactly why hard rule 12 treats "grant the allowance" as the exploit's missing
/// precondition, and why this wave's fix grants that allowance itself — but ONLY scoped
/// (forceApprove(router, amount) -> call -> forceApprove(router, 0), INV-3) — inside
/// `_execute1inchSwap`, never as a standing grant, and never in src/ outside that one scoped
/// bracket.
contract AllowanceGatedRouter {
    function pull(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract SepoliaLatentAllowanceTest is Test {
    SecurityMockERC20 public token;
    AllowanceGatedRouter public router;
    address public vaultStandIn;

    function setUp() public {
        token = new SecurityMockERC20("Token", "TKN", 18);
        router = new AllowanceGatedRouter();
        vaultStandIn = address(this);
        token.mint(vaultStandIn, 1_000e18);
    }

    function test_RouterCallRevertsWithNoAllowance_MissingPrecondition() public {
        // No allowance granted — this is the CURRENT Sepolia state per A4: every real call
        // reverts, and the arbitrary-calldata path is therefore latent, not live.
        vm.expectRevert();
        router.pull(address(token), 100e18);
    }

    function test_RouterCallSucceedsOnceAllowanceExists_ArmedByTheAllowance() public {
        // R-V1-permitted, test/-only allowance grant against local ephemeral EVM state (mock
        // router) — simulates the ONE precondition A4 says is currently missing. See hard rule
        // 12 / R-V1 in workspace CLAUDE.md: this is what proves the calldata fix must ship
        // BEFORE this precondition is ever satisfied in src/, which is exactly the order this
        // wave delivered it in (this test file's own PassiveBucket contracts already run the
        // fixed executor, and its OWN internal grant is scoped per-call, never standing).
        token.approve(address(router), 100e18);

        router.pull(address(token), 100e18);

        assertEq(token.balanceOf(address(router)), 100e18);
        // Confirmed latent — armed by the allowance, not by a code change: identical call,
        // identical router, identical vault-standin; the only variable that changed between the
        // revert above and the success here is the allowance's existence.
    }
}
