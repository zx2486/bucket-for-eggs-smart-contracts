// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// W4-gate (task #59) — standalone gate tests for the Compliance wave (blacklist, soulbound,
// seizure). Per plan §10.1's W4 gate row (cited via 04-CONTRACTS-IMPLEMENTATION-PLAN.md:1007-1011)
// and root CLAUDE.md hard rule 13, every one of the five checks below must be proven to FAIL on
// the pre-fix state, not merely proven to pass today. See W4-SC-COMPLIANCE-REPORT.md §6 for the
// actual red/green evidence (this file only contains the tests; the report records what running
// them printed, before and after temporarily neutralizing each guard).
//
// New standalone file, not additions to ActiveBucket.t.sol/PassiveBucket.t.sol/PureMembership.t.sol
// -- deliberate choice: no test/W3*.t.sol file exists either (confirmed via Glob, zero matches),
// implying prior wave gate tests were added inline into large existing files, but W4's five gates
// span three different contracts and several multi-step scenarios (propose/warp/execute for
// seizure); a standalone file keeps this wave's evidence in one place without risking an edit to
// an already-green, unrelated 1000+-line test file (hard rule 6's file-ownership-scope spirit).
//
// Five gate categories (plan §10.1, task #59 description) -- each test function is tagged with
// which one it proves:
//   G1 - blacklisted address blocked on deposit/redeem/transfer (both vault families + membership)
//   G2 - blacklisted owner/caller blocked on rebalanceBy1inch/rebalanceByDefi/swapBy1inch
//   G3 - membership soulbound: holder-to-holder transfer reverts regardless of blacklist status
//   G4 - fail-closed: a BucketInfo that reverts on isBlacklisted() blocks the action (D2/INV-7)
//   G5 - seizure: moves balance to nominated wallet, emits documentHash + before/after balances,
//        reverts if `from` is not confirmed blacklisted at execution, respects the 48h timelock,
//        and ABORTS (does not proceed) if BucketInfo is unreachable at execution -- the ONE place
//        in this codebase where fail-closed is reversed (BucketVaultBase.sol's COMPLIANCE --
//        SEIZURE header comment, SeizureLib.requireConfirmedBlacklisted).
//
// INV-1 tension note (recorded here per the plan's explicit instruction, 04-...md:1011): G1's
// redeem test demonstrates exactly the tension the plan calls out -- redemption, previously
// documented to depend on nothing but share arithmetic plus `whenPlatformOperational`, now ALSO
// depends on BucketInfo answering `isBlacklisted` (G4 shows what happens when it cannot: fail-
// closed blocks the redemption). D2 accepts this consciously; INV-7 is the mitigation (the check
// must stay an O(1) storage read on BucketInfo's side, never a loop or further external call, so
// the only way it can revert is BucketInfo being genuinely unreachable, not gas exhaustion).
// ============================================================

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {SeizureLib} from "../src/libraries/SeizureLib.sol";
import {TimelockedAdmin} from "../src/libs/TimelockedAdmin.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

/// @dev One comprehensive IBucketInfo mock shared across all three test contracts below (all
/// three token contracts consume the same `IBucketInfo` interface -- verified at
/// src/interfaces/IBucketInfo.sol). Adds two things beyond the isolated per-contract mocks each
/// existing *.t.sol file already carries: `owner` defaults to the deployer (so the deploying test
/// contract can call proposeSeizure/cancelSeizure directly, mirroring
/// MockBucketInfoForMembership's `owner = msg.sender` pattern), and `blacklistCheckReverts`, a
/// single toggle that makes `isBlacklisted` revert unconditionally -- this is what G4's
/// fail-closed tests and G5's reversed-fail-closed seizure-abort test both need, and reusing one
/// flag for both directions is deliberate: the DIFFERENCE between D2's two directions is entirely
/// in which caller-side function (`_isBlacklistedFailClosed` vs `SeizureLib.requireConfirmedBlacklisted`)
/// interprets the same revert, not in how the mock produces it.
contract GateMockBucketInfo {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 0;
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

    // --- W5-oracle regression fix (same class as task #61's isBlacklisted gap): see
    // PassiveBucket.t.sol's MockBucketInfoForPassive for the full explanation.
    function getPriceFeed(address) external pure returns (address) {
        return address(0);
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

    /// @dev W4.1 surface. Reverts unconditionally when `blacklistCheckReverts` is set -- the ONE
    /// knob both G4 (user-facing fail-closed) and G5's abort case (platform-action reversed
    /// fail-closed) drive.
    function isBlacklisted(address account) external view returns (bool) {
        if (blacklistCheckReverts) revert("GateMockBucketInfo: isBlacklisted unreachable");
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function setBlacklistCheckReverts(bool status) external {
        blacklistCheckReverts = status;
    }

    receive() external payable {}
}

contract GateMockERC20 {
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
//              G1 / G2 / G4 / G5 — ActiveBucket
// ============================================================

contract W4GateActiveBucketTest is Test {
    ActiveBucket public implementation;
    ActiveBucket public bucket;
    GateMockBucketInfo public bucketInfo;
    GateMockERC20 public token;

    address public depositor;
    address public user1;
    address public custody;

    uint256 constant TOKEN_PRICE = 1e8;
    uint256 constant SEED_DEPOSIT = 1_000_000e6;
    uint256 constant USER_DEPOSIT = 10_000e6;

    function setUp() public {
        depositor = address(this);
        user1 = makeAddr("user1");
        custody = makeAddr("custody");

        bucketInfo = new GateMockBucketInfo();
        token = new GateMockERC20("Token", "TKN", 6);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new ActiveBucket(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);

        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector,
            address(bucketInfo),
            address(0xBEEF), // dummy 1inch router -- never reached by any test in this file
            "ActiveBucket Share",
            "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = ActiveBucket(payable(address(proxy)));

        token.mint(depositor, SEED_DEPOSIT);
        token.mint(user1, USER_DEPOSIT);

        // Seed deposit from a never-blacklisted address so DEAD_SHARES/first-deposit bookkeeping
        // (BucketVaultBase._processDeposit) is out of the way before any blacklist scenario runs.
        token.approve(address(bucket), SEED_DEPOSIT);
        bucket.deposit(address(token), SEED_DEPOSIT);
    }

    /// @notice G1: a blacklisted address cannot deposit. Covered by BucketVaultBase._update's
    /// mint-path hook (`_mint` -> `_update(address(0), user1, shares)`), not an explicit check --
    /// deposit unconditionally mints on every call, so the hook alone is sufficient coverage
    /// (BucketVaultBase.sol:483-490's own doc comment).
    function test_G1_Blacklisted_CannotDeposit() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    /// @notice G1: a blacklisted address cannot redeem. Deposits while clean, THEN gets
    /// blacklisted, so this isolates the redeem-time check from the deposit-time one -- covered by
    /// the same `_update` hook via `_burn` -> `_update(user1, address(0), shares)`.
    function test_G1_Blacklisted_CannotRedeem() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.redeem(shares);
    }

    /// @notice G1: "even transferring the contract tokens" (client requirement, quoted in
    /// BucketVaultBase.sol's COMPLIANCE header) -- a plain ERC-20 `transfer` of vault shares
    /// between two ordinary holders is blocked the moment EITHER side is blacklisted, proven both
    /// ways (blacklisted sender, then blacklisted recipient).
    function test_G1_Blacklisted_CannotTransferShares() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        vm.stopPrank();

        address user2 = makeAddr("user2");

        // Blacklisted sender.
        bucketInfo.setBlacklisted(user1, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.transfer(user2, shares / 2);
        bucketInfo.setBlacklisted(user1, false);

        // Blacklisted recipient.
        bucketInfo.setBlacklisted(user2, true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user2));
        bucket.transfer(user2, shares / 2);
    }

    /// @notice G2: `swapBy1inch` mints/burns no shares, so the `_update` hook never fires for it
    /// (ActiveBucket.sol:283-287's own W4.2c comment) -- an explicit `_assertNotBlacklisted`
    /// guards it. `depositor` is both `owner()` (via `onlyOwner`) and, once blacklisted, blocked
    /// before the router is ever called -- proves the check runs BEFORE `_execute1inchSwap`,
    /// against the dummy `address(0xBEEF)` router that would otherwise revert for an unrelated
    /// reason and give a false pass.
    function test_G2_Blacklisted_CannotSwapBy1inch() public {
        bucketInfo.setBlacklisted(depositor, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, depositor));
        bucket.swapBy1inch(address(token), address(token), 1, 0);
    }

    /// @notice G4: fail-closed. `bucketInfo.isBlacklisted` reverting unconditionally (BucketInfo
    /// unreachable, per D2) must block the action exactly as an actual blacklist entry would --
    /// this is INV-7's whole point: "in doubt" resolves to blocked for a user-facing action.
    function test_G4_FailClosed_RevertingBucketInfo_BlocksDeposit() public {
        bucketInfo.setBlacklistCheckReverts(true);

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    /// @notice G6 (verifier fix, 2026-10-04): a blacklisted address cannot `approve` -- the
    /// verifier's exact named gap ("Ten calls still succeed for a blacklisted address... approve").
    /// Covered by {BucketVaultBase.approve}'s `whenCallerNotBlacklisted` override, which this test
    /// proves runs BEFORE the allowance is actually set (not merely that the call eventually fails
    /// for some other reason) by asserting the allowance is still zero afterward (belt-and-braces;
    /// `vm.expectRevert` already proves the call reverted, but a revert from the wrong cause could
    /// still leave state unchanged by coincidence).
    function test_G6_Blacklisted_CannotApprove() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.approve(custody, USER_DEPOSIT);

        assertEq(bucket.allowance(user1, custody), 0);
    }

    /// @notice G6 (verifier fix, 2026-10-04): `transferFrom` called by a blacklisted SPENDER must
    /// revert even though neither the share holder (`user1`) nor the recipient is blacklisted --
    /// the verifier's exact named gap ("transferFrom by a blacklisted spender"). Before this wave's
    /// {BucketVaultBase._spendAllowance} override, the only blacklist check ran in
    /// `_update(from, to, ...)`, which never sees the third-party `msg.sender` spender, so this
    /// scenario is the one {_update} alone structurally cannot catch -- it isolates the NEW check
    /// from the pre-existing G1 transfer check above. Uses a THIRD address (`recipient`, distinct
    /// from both `user1` and the blacklisted `custody` spender) so `_update`'s own `to`-side check
    /// cannot coincidentally mask a missing spender-side check -- an earlier draft of this test
    /// used `custody` as both spender and recipient, which passed for the WRONG reason (confirmed
    /// by temporarily removing {_spendAllowance}'s check: that draft still failed to catch the
    /// regression because `_update`'s `to == custody` check fired first).
    function test_G6_Blacklisted_SpenderCannotTransferFrom() public {
        address recipient = makeAddr("recipient");

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(custody, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(custody, true);

        vm.prank(custody);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, custody));
        bucket.transferFrom(user1, recipient, shares);

        // Neither the holder's balance nor the allowance moved.
        assertEq(bucket.balanceOf(user1), shares);
        assertEq(bucket.allowance(user1, custody), shares);
    }

    /// @notice G6 (verifier fix, 2026-10-04): `burnFrom` called by a blacklisted SPENDER must
    /// revert for the identical reason as {test_G6_Blacklisted_SpenderCannotTransferFrom} above --
    /// `ERC20BurnableUpgradeable.burnFrom` routes through the same `_spendAllowance` hook this wave
    /// now overrides, so this proves the override's coverage is NOT limited to the `transferFrom`
    /// call path. `burnFrom` has no `to` parameter at all (it burns outright), so this scenario was
    /// never at risk of the same recipient-masking trap as the transferFrom test above.
    function test_G6_Blacklisted_SpenderCannotBurnFrom() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(custody, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(custody, true);

        vm.prank(custody);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, custody));
        bucket.burnFrom(user1, shares);

        assertEq(bucket.balanceOf(user1), shares);
    }

    /// @notice G6 (verifier fix, 2026-10-04): an admin (`onlyOwner`) call made by a blacklisted
    /// OWNER must revert -- the verifier's exact named gap ("admin calls by a blacklisted owner").
    /// `pause()` is `onlyOwner whenCallerNotBlacklisted` (ActiveBucket.sol:411); `depositor` is
    /// `owner()` here (see {test_G2_Blacklisted_CannotSwapBy1inch}'s comment above for why).
    function test_G6_Blacklisted_OwnerCannotCallAdminFunction() public {
        bucketInfo.setBlacklisted(depositor, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, depositor));
        bucket.pause();

        assertFalse(bucket.paused());
    }
}

// ============================================================
//         G1 / G2 / G4 / G5 — PassiveBucket (+ full seizure suite)
// ============================================================

contract W4GatePassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    GateMockBucketInfo public bucketInfo;
    GateMockERC20 public token;

    address public depositor;
    address public user1;
    address public user2;
    address public custody;

    uint256 constant TOKEN_PRICE = 1e8;
    uint256 constant SEED_DEPOSIT = 1_000_000e6;
    uint256 constant USER_DEPOSIT = 10_000e6;
    bytes32 constant COURT_ORDER_HASH = keccak256("case-2026-W4-001");

    function setUp() public {
        depositor = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        custody = makeAddr("custody");

        bucketInfo = new GateMockBucketInfo();
        token = new GateMockERC20("Token", "TKN", 6);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new PassiveBucket(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(token), 100);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(0xBEEF), // dummy 1inch router -- never reached by any test in this file
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        token.mint(depositor, SEED_DEPOSIT);
        token.mint(user1, USER_DEPOSIT);
        token.mint(user2, USER_DEPOSIT);

        token.approve(address(bucket), SEED_DEPOSIT);
        bucket.deposit(address(token), SEED_DEPOSIT);
    }

    /// @notice G1 (PassiveBucket side of the deposit check -- see the ActiveBucket contract above
    /// for the identical BucketVaultBase._update hook proof; repeated here because PassiveBucket
    /// is the OTHER vault family the plan's G1 row names explicitly).
    function test_G1_Blacklisted_CannotDeposit() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();
    }

    /// @notice G1 (PassiveBucket redeem).
    function test_G1_Blacklisted_CannotRedeem() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.redeem(shares);
    }

    /// @notice G2: `rebalanceByDefi` is permissionless/share-gated (`_requireHasShares()`, not
    /// `onlyOwner`) and executes no mint/burn on this path -- PassiveBucket.sol:368-371's own
    /// W4.2c comment. `user1` deposits (clean), then gets blacklisted, then tries to call it.
    function test_G2_Blacklisted_CannotRebalanceByDefi() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.rebalanceByDefi();
    }

    /// @notice G2: `rebalanceBy1inch` is likewise permissionless/share-gated and mints/burns
    /// nothing -- PassiveBucket.sol:497-501. Blocked before the (dummy) router is ever called.
    function test_G2_Blacklisted_CannotRebalanceBy1inch() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.rebalanceBy1inch(address(token), address(token), 1, 0);
    }

    /// @notice G4 (PassiveBucket redeem side): fail-closed blocks redemption when BucketInfo is
    /// unreachable -- this is the INV-1 tension note made concrete (see this file's header
    /// comment): redemption now depends on BucketInfo answering `isBlacklisted`, and D2 says an
    /// unreachable answer must be treated as "blocked", not "allowed through".
    function test_G4_FailClosed_RevertingBucketInfo_BlocksRedeem() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        vm.stopPrank();

        bucketInfo.setBlacklistCheckReverts(true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.redeem(shares);
    }

    // --------------------------------------------------------------
    // G5 -- seizure (shared BucketVaultBase/SeizureLib code; exercised once here rather than
    // duplicated on ActiveBucket, since ActiveBucket inherits the identical implementation from
    // the same base contract -- INV-9, "written once").
    // --------------------------------------------------------------

    function _blacklistAndDeposit(address user) internal returns (uint256 shares) {
        vm.startPrank(user);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        shares = bucket.balanceOf(user);
        vm.stopPrank();
        bucketInfo.setBlacklisted(user, true);
    }

    /// @notice G5: seizure moves the ENTIRE blacklisted balance to the nominated wallet, and
    /// {SeizureLib.SeizureExecuted} carries the document hash plus the before/after balances
    /// (before = full seized amount, after = deterministic 0 -- SeizureLib.sol:150-153's doc
    /// comment on why `afterBalance` is hardcoded rather than re-read).
    function test_G5_Seizure_MovesBalanceAndEmitsDocumentHashAndBalances() public {
        uint256 shares = _blacklistAndDeposit(user1);

        // Platform owner (this test contract, per GateMockBucketInfo's `owner = msg.sender`
        // constructor convention) proposes.
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (address pendingTo, bytes32 pendingHash, uint256 eta) = bucket.pendingSeizure(user1);
        assertEq(pendingTo, custody);
        assertEq(pendingHash, COURT_ORDER_HASH);
        assertGt(eta, block.timestamp);

        vm.warp(eta);

        vm.expectEmit(true, true, false, true, address(bucket));
        emit SeizureLib.SeizureExecuted(user1, custody, COURT_ORDER_HASH, shares, 0);
        bucket.executeSeizure(user1);

        assertEq(bucket.balanceOf(user1), 0);
        assertEq(bucket.balanceOf(custody), shares);
    }

    /// @notice G5: the timelock is enforced, not merely recorded -- executing before `eta` reverts
    /// with {TimelockedAdmin.TimelockNotElapsed}, and the seizure has moved nothing.
    function test_G5_Seizure_RespectsTimelock() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAdmin.TimelockNotElapsed.selector, eta, block.timestamp));
        bucket.executeSeizure(user1);
    }

    /// @notice G5: "reverts if `from` is not blacklisted at execution time" (task #59's own
    /// wording) -- a revocation BETWEEN propose and execute must cancel the seizure's effect, not
    /// merely delay it. This is the NORMAL fail-closed direction re-checked at execution
    /// (SeizureLib.requireConfirmedBlacklisted), distinct from the reversed-direction abort case
    /// tested immediately below.
    function test_G5_Seizure_RevertsIfNotConfirmedBlacklistedAtExecution() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        // Revoked before execution.
        bucketInfo.setBlacklisted(user1, false);
        vm.warp(eta);

        vm.expectRevert(abi.encodeWithSelector(SeizureLib.NotBlacklisted.selector, user1));
        bucket.executeSeizure(user1);

        // Nothing moved.
        assertEq(bucket.balanceOf(custody), 0);
    }

    /// @notice G5, the reversed-polarity case (the one place in this codebase where fail-closed
    /// runs the OPPOSITE direction, per BucketVaultBase.sol:521-530 / SeizureLib.sol:46-49): if
    /// BucketInfo is unreachable AT EXECUTION TIME, the seizure must ABORT, not proceed. A
    /// platform action that irreversibly moves a third party's funds cannot be waved through on an
    /// unverified compliance state -- the opposite of G4's user-facing direction, where "in doubt"
    /// blocks the USER. Here "in doubt" blocks the PLATFORM's own irreversible action instead.
    function test_G5_Seizure_AbortsIfBucketInfoUnreachableAtExecution_ReversedFailClosed() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        bucketInfo.setBlacklistCheckReverts(true);
        vm.warp(eta);

        vm.expectRevert(abi.encodeWithSelector(SeizureLib.BucketInfoUnreachableForSeizure.selector, user1));
        bucket.executeSeizure(user1);

        // Aborted, not proceeded: nothing moved, and -- since `TimelockedAdmin.execute` deletes
        // the pending slot only on a path that returns normally, and this call reverted -- the
        // whole transaction (including that deletion) unwound, so the proposal is still pending
        // once BucketInfo is reachable again.
        assertEq(bucket.balanceOf(custody), 0);
        bucketInfo.setBlacklistCheckReverts(false);
        (,, uint256 stillPendingEta) = bucket.pendingSeizure(user1);
        assertEq(stillPendingEta, eta);
    }

    /// @notice G5 destination-side fail-closed: a seizure cannot land funds INTO an address that
    /// is itself (fail-closed) blacklisted at execution time -- SeizureLib.requireNotBlacklistedFailClosed,
    /// the ordinary D2 direction applied to `to` rather than `account`. Included alongside the
    /// five named gates as directly adjacent coverage of the same seizure code path.
    function test_G5_Seizure_RevertsIfDestinationBlacklistedAtExecution() public {
        _blacklistAndDeposit(user1);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);
        (,, uint256 eta) = bucket.pendingSeizure(user1);

        bucketInfo.setBlacklisted(custody, true);
        vm.warp(eta);

        vm.expectRevert(abi.encodeWithSelector(SeizureLib.Blacklisted.selector, custody));
        bucket.executeSeizure(user1);
    }

    /// @notice Sanity check on the platform-owner gate that both `proposeSeizure` and
    /// `cancelSeizure` share: a non-platform-owner (here, the blacklisted user1 themselves)
    /// cannot self-serve a proposal or a cancellation of their own seizure.
    function test_G5_Seizure_ProposeAndCancel_ArePlatformOwnerGated() public {
        _blacklistAndDeposit(user1);

        vm.prank(user1);
        vm.expectRevert(SeizureLib.UnauthorizedSeizure.selector);
        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);

        bucket.proposeSeizure(user1, custody, COURT_ORDER_HASH);

        vm.prank(user1);
        vm.expectRevert(SeizureLib.UnauthorizedSeizure.selector);
        bucket.cancelSeizure(user1);
    }

    /// @notice G6 (verifier fix, 2026-10-04): PassiveBucket side of
    /// {W4GateActiveBucketTest.test_G6_Blacklisted_CannotApprove} -- same
    /// `BucketVaultBase.approve` override, repeated here because it is shared base code and this
    /// file tests both vault families against it independently (same convention as G1's repeats).
    function test_G6_Blacklisted_CannotApprove() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user1));
        bucket.approve(custody, USER_DEPOSIT);

        assertEq(bucket.allowance(user1, custody), 0);
    }

    /// @notice G6 (verifier fix, 2026-10-04): PassiveBucket side of
    /// {W4GateActiveBucketTest.test_G6_Blacklisted_SpenderCannotTransferFrom} -- a blacklisted
    /// third-party SPENDER (not the share holder or recipient) must be blocked by the
    /// `_spendAllowance` override, isolating it from the `_update`-hook-covered G1 case. Uses
    /// `custody` as the recipient (distinct from both `user1` and the blacklisted `user2` spender)
    /// for the same reason noted on the ActiveBucket sibling test: reusing the spender as the
    /// recipient would let `_update`'s `to`-side check mask a missing spender-side check.
    function test_G6_Blacklisted_SpenderCannotTransferFrom() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(user2, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user2, true);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user2));
        bucket.transferFrom(user1, custody, shares);

        assertEq(bucket.balanceOf(user1), shares);
        assertEq(bucket.allowance(user1, user2), shares);
    }

    /// @notice G6 (verifier fix, 2026-10-04): PassiveBucket side of
    /// {W4GateActiveBucketTest.test_G6_Blacklisted_SpenderCannotBurnFrom}.
    function test_G6_Blacklisted_SpenderCannotBurnFrom() public {
        vm.startPrank(user1);
        token.approve(address(bucket), USER_DEPOSIT);
        bucket.deposit(address(token), USER_DEPOSIT);
        uint256 shares = bucket.balanceOf(user1);
        assertGt(shares, 0);
        bucket.approve(user2, shares);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user2, true);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, user2));
        bucket.burnFrom(user1, shares);

        assertEq(bucket.balanceOf(user1), shares);
    }

    /// @notice G6 (verifier fix, 2026-10-04): an admin call by a blacklisted owner must revert on
    /// PassiveBucket too. `unpause()` is `onlyOwnerNotBlacklisted` (PassiveBucket.sol:548) --
    /// deliberately NOT `pause()`/`pauseSwap()`/`unpauseSwap()`, which are `onlyAccountableOwner`
    /// and would conflate this check with the separate `OwnerNotAccountable` guard. Platform must
    /// first pause while still clean, THEN get blacklisted, to isolate the unpause-time check.
    function test_G6_Blacklisted_OwnerCannotCallAdminFunction() public {
        bucket.pause();
        bucketInfo.setBlacklisted(depositor, true);

        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.Blacklisted.selector, depositor));
        bucket.unpause();

        assertTrue(bucket.paused());
    }
}

// ============================================================
//              G1 / G3 / G4 — PureMembership
// ============================================================

contract W4GatePureMembershipTest is Test {
    PureMembership public implementation;
    PureMembership public membership;
    GateMockBucketInfo public bucketInfo;
    GateMockERC20 public payToken;
    ImplementationRegistry public registry;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant PAY_TOKEN_PRICE = 1e8; // $1 USD

    uint256 constant BASIC_ID = 1;
    uint256 constant BASIC_LEVEL = 1;
    uint256 constant BASIC_PRICE = 10e8; // $10 USD
    uint256 constant BASIC_DURATION = 30 days;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        bucketInfo = new GateMockBucketInfo();
        payToken = new GateMockERC20("USD Coin", "USDC", 6);
        bucketInfo.addToken(address(payToken), PAY_TOKEN_PRICE);

        registry = new ImplementationRegistry(owner);
        implementation = new PureMembership(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);

        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](1);
        configs[0] = PureMembership.MembershipConfig(BASIC_ID, BASIC_LEVEL, "Basic", BASIC_PRICE, BASIC_DURATION);

        bytes memory initData =
            abi.encodeWithSelector(PureMembership.initialize.selector, configs, address(bucketInfo), "");
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        membership = PureMembership(payable(address(proxy)));

        payToken.mint(user1, 100_000e6);
        payToken.mint(user2, 100_000e6);
    }

    /// @notice G1: a blacklisted address cannot buy a NEW membership. `buyMembership` checks
    /// `_assertNotBlacklisted(msg.sender)` unconditionally before either branch (new-purchase or
    /// renewal) — PureMembership.sol:392.
    function test_G1_Blacklisted_CannotBuyNewMembership() public {
        bucketInfo.setBlacklisted(user1, true);

        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, user1));
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();
    }

    /// @notice G1: a blacklisted holder cannot RENEW an existing membership either. This is the
    /// genuine coverage gap PureMembership.sol:385-391 documents: the renewal branch never calls
    /// `_mint`, so the ERC-1155 `_update` hook alone would NOT have caught it -- only the explicit
    /// check at the top of `buyMembership` does. Buys clean, then gets blacklisted, then tries to
    /// renew, isolating this from the new-purchase check above.
    function test_G1_Blacklisted_CannotRenewMembership() public {
        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, user1));
        membership.buyMembership(BASIC_ID, address(payToken), 0);
    }

    /// @notice G3: soulbound blocks ANY holder-to-holder transfer, regardless of blacklist status
    /// on either side -- proven here with NEITHER party blacklisted, so the only possible reason
    /// for the revert is the soulbound gate itself (PureMembership.sol:309), not the blacklist
    /// check that runs after it. This is the test that would have caught the pre-W4 defect root
    /// CLAUDE.md §8 records: "before this override, `safeTransferFrom` worked... despite
    /// membership being a client requirement to be non-transferable."
    function test_G3_Soulbound_BlocksHolderToHolderTransfer_RegardlessOfBlacklist() public {
        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        assertFalse(bucketInfo.blacklisted(user1));
        assertFalse(bucketInfo.blacklisted(user2));

        vm.prank(user1);
        vm.expectRevert(PureMembership.MembershipNotTransferable.selector);
        membership.safeTransferFrom(user1, user2, BASIC_ID, 1, "");
    }

    /// @notice G3, negative-control companion: blacklisting one side does NOT change the revert
    /// reason -- it is still soulbound-first, not blacklist-first (PureMembership.sol:309-311's
    /// ordering: the soulbound check runs BEFORE either blacklist check, unconditionally).
    function test_G3_Soulbound_StillGovernsEvenWhenAlsoBlacklisted() public {
        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();

        bucketInfo.setBlacklisted(user2, true);

        vm.prank(user1);
        vm.expectRevert(PureMembership.MembershipNotTransferable.selector);
        membership.safeTransferFrom(user1, user2, BASIC_ID, 1, "");
    }

    /// @notice G4: fail-closed on PureMembership's own (necessarily duplicated -- it has no shared
    /// base to inherit BucketVaultBase's copy from; see PureMembership.sol:264-268's doc comment)
    /// `_isBlacklistedFailClosed`. An unreachable BucketInfo blocks a brand-new purchase exactly as
    /// an actual blacklist entry would.
    function test_G4_FailClosed_RevertingBucketInfo_BlocksBuyMembership() public {
        bucketInfo.setBlacklistCheckReverts(true);

        vm.startPrank(user1);
        payToken.approve(address(membership), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, user1));
        membership.buyMembership(BASIC_ID, address(payToken), 0);
        vm.stopPrank();
    }

    /// @notice G6 (verifier fix, 2026-10-04): PureMembership has no ERC-20 approve/transferFrom
    /// surface (it is ERC-1155 and soulbound -- G3 above already proves holder-to-holder transfer
    /// is blocked unconditionally), so its share of the verifier's "admin calls by a blacklisted
    /// owner" gap is proven here instead: `pause()` is `onlyOwner whenCallerNotBlacklisted`
    /// (PureMembership.sol:684). `owner` is `address(this)`, the direct proxy deployer, since this
    /// test (like the others in this file) deploys the proxy itself rather than going through
    /// `PureMembershipFactory` (whose `transferOwnership(msg.sender)` is exercised by its own
    /// dedicated factory tests, not here).
    function test_G6_Blacklisted_OwnerCannotCallAdminFunction() public {
        bucketInfo.setBlacklisted(owner, true);

        vm.expectRevert(abi.encodeWithSelector(PureMembership.Blacklisted.selector, owner));
        membership.pause();

        assertFalse(membership.paused());
    }
}
