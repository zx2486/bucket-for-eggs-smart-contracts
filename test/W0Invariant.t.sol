// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// W0.5: the FIRST invariant suite in this programme (verified 2026-09-24: before this file,
// `grep -rnic "invariant" test/ src/ script/` matched no handler-based suite and no contract
// inherited StdInvariant -- root CLAUDE.md §5.4, _deliverables/04-CONTRACTS-IMPLEMENTATION-PLAN.md
// §3 INV-12's precondition note). `foundry.toml`'s `[profile.default.invariant]` table was
// flipped from `fail_on_revert = false` to `true` in the SAME W0 pass that adds this file, per
// that precondition note: flipping it before a suite exists is free; after, every call that
// reverts inside a run would otherwise still report PASS.
//
// Scope, deliberately narrow for a first suite: only PassiveBucket.deposit(ETH) and
// PassiveBucket.redeem are targeted. This keeps the accounting tractable (no rebalance fees, no
// ERC-20 transferFrom paths, no owner-accountability branch) while still exercising a real
// mint/burn invariant against a real (non-mocked) PassiveBucket behind its actual proxy.
// Extending target selectors to deposit(ERC20)/rebalanceBy1inch/rebalanceByDex is future work,
// not claimed here.

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {MockBucketInfoForPassive, MockERC20, MockOneInchRouter} from "./PassiveBucket.t.sol";

/// @dev Handler restricted to ETH-only deposit/redeem so the ghost accounting below is exact
/// share arithmetic, not an approximation. Extends Test only for cheatcode/bound() access; it
/// has no test_/invariant_ functions itself and forge will not run it as a suite on its own.
contract PassiveBucketDepositRedeemHandler is Test {
    PassiveBucket public bucket;
    address[] public actors;

    uint256 public ghost_sumSharesMinted;
    uint256 public ghost_sumSharesBurned;
    uint256 public ghost_depositCalls;
    uint256 public ghost_redeemCalls;
    /// @dev Counts `BucketVaultBase.NothingToRedeem()` reverts tolerated by `redeem` below.
    /// A verifier should check this is nonzero over a real run -- zero here would mean the
    /// tolerated branch is dead code and the try/catch below is unexercised, not proof that
    /// zero-payout redemptions never happen.
    uint256 public ghost_redeemNothingToRedeemTolerated;
    /// @dev Verifier finding (2026-10-04, claim #8): the original version of `redeem` picked ONE
    /// actor by seed and silently `return`-ed, uncounted, whenever THAT actor happened to hold
    /// zero shares -- with only 3 actors and deposits/redeems interleaved by the fuzzer in random
    /// order, the verifier measured this happening on ~54% of dispatched `redeem` calls. Forge's
    /// own per-selector table counts every dispatch as a "call" regardless of whether the handler
    /// body does anything, so a run full of these silent no-ops still prints a healthy-looking
    /// "1928 calls, 0 reverts" with no signal that barely half of them touched the contract at
    /// all -- exactly the owner's complaint ("if a test does nothing, it should be rewritten").
    /// The fix below (see `redeem`) falls back to ANY actor presently holding shares before
    /// giving up, and these two ghosts make the TRUE no-op rate visible instead of hidden inside
    /// forge's calls/reverts table: `ghost_redeemAttempts` is every dispatch (matches forge's own
    /// "Calls" column), `ghost_redeemNoHolderYet` is the genuine no-op (no actor anywhere holds
    /// any shares) -- a verifier divides the two to get the real no-op rate.
    uint256 public ghost_redeemAttempts;
    uint256 public ghost_redeemNoHolderYet;

    constructor(PassiveBucket _bucket, address[] memory _actors) {
        bucket = _bucket;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 0.001 ether, 5 ether);

        // W2 (sc-vault-entry) added a subtractive DEAD_SHARES inflation-attack mitigation
        // (BucketVaultBase._processDeposit, INV-6/B2): on the very first-ever deposit, a fixed
        // DEAD_SHARES amount is minted to a separate DEAD_SHARES_RECIPIENT address, carved out of
        // (not added on top of) the depositor's own mint. That mint is a real, permanent addition
        // to totalSupply() that this handler's actor-balance-delta accounting below cannot see,
        // because it never lands in `actor`'s own balance. Detect the 0 -> nonzero totalSupply()
        // transition this call causes and account for it once, alongside (not instead of) the
        // existing actor-delta line -- see W2-SC-ENTRY-REPORT.md's suggested fix and
        // W2-ORCHESTRATOR-NOTE-INVARIANT-FIX.md for why this is an orchestrator-level fix, not
        // sc-vault-entry's own (hard rule 6 -- this file is outside that agent's ownership scope).
        bool isFirstEverDeposit = bucket.totalSupply() == 0;

        uint256 sharesBefore = bucket.balanceOf(actor);
        vm.prank(actor);
        bucket.deposit{value: amount}(address(0), 0);
        uint256 sharesAfter = bucket.balanceOf(actor);

        ghost_sumSharesMinted += (sharesAfter - sharesBefore);
        if (isFirstEverDeposit) {
            ghost_sumSharesMinted += bucket.DEAD_SHARES();
        }
        ghost_depositCalls += 1;
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_redeemAttempts += 1;
        address actor = _actor(actorSeed);
        uint256 actorBalance = bucket.balanceOf(actor);
        if (actorBalance == 0) {
            // Verifier fix (claim #8): don't give up on the first seed-picked actor holding zero
            // shares -- fall back to scanning every actor for one who actually holds a balance,
            // so a redeem dispatch only becomes a genuine no-op when NOBODY has anything to
            // redeem, not merely when this one random pick came up empty. This is what turns the
            // measured ~54% silent-no-op rate into a real exercise of the redeem path.
            for (uint256 i = 0; i < actors.length; i++) {
                uint256 bal = bucket.balanceOf(actors[i]);
                if (bal > 0) {
                    actor = actors[i];
                    actorBalance = bal;
                    break;
                }
            }
            if (actorBalance == 0) {
                ghost_redeemNoHolderYet += 1;
                return; // genuine no-op: not one actor empty, EVERY actor empty
            }
        }

        uint256 shares = bound(sharesSeed, 1, actorBalance);
        vm.prank(actor);
        // W2 (sc-vault-exit) added BucketVaultBase.NothingToRedeem() when a proportional
        // payout would floor to zero on every held token for a `shares` count that is small
        // relative to large held-token balances -- an intentional, correct revert (see
        // W2-SC-EXIT-REPORT.md "Blocked" item 1), not a bug in share-price accounting.
        // Tolerate ONLY this selector; any other revert reason is bubbled up unchanged so it
        // still fails the run -- swallowing all reverts here would make this invariant suite
        // vacuous again, exactly what root CLAUDE.md §5.4 / INV-vacuity warns against.
        try bucket.redeem(shares) {
            ghost_sumSharesBurned += shares;
            ghost_redeemCalls += 1;
        } catch (bytes memory lowLevelData) {
            if (bytes4(lowLevelData) != BucketVaultBase.NothingToRedeem.selector) {
                assembly {
                    revert(add(lowLevelData, 0x20), mload(lowLevelData))
                }
            }
            // else: no-op, matches the actorBalance == 0 no-op above in spirit -- a
            // zero-payout redeem attempt correctly rejected, not a state change to account for.
            ghost_redeemNothingToRedeemTolerated += 1;
        }
    }
}

contract W0InvariantPassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockOneInchRouter public oneInchRouter;
    PassiveBucketDepositRedeemHandler public handler;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 2000e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    function setUp() public {
        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        oneInchRouter = new MockOneInchRouter();

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new PassiveBucket(address(registry));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

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

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("invariantActor0");
        actors[1] = makeAddr("invariantActor1");
        actors[2] = makeAddr("invariantActor2");
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 1000 ether);
        }

        handler = new PassiveBucketDepositRedeemHandler(bucket, actors);

        // Narrow the fuzz surface to the handler's two bounded entrypoints -- this is what
        // keeps runs meaningful rather than hammering PassiveBucket's owner-only or ERC20 paths
        // with unbounded random calldata that would mostly just revert on access control.
        targetContract(address(handler));
    }

    /// @dev Ghost-accounting invariant: every share ever in existence came from a `deposit` the
    /// handler recorded, and every share no longer in existence went through a `redeem` the
    /// handler recorded. A break here means minting or burning happened somewhere the handler's
    /// bookkeeping did not see -- e.g. a rounding path or a fee-on-mint that was added without
    /// updating this accounting.
    function invariant_TotalSupplyMatchesGhostMintBurn() public view {
        assertEq(bucket.totalSupply(), handler.ghost_sumSharesMinted() - handler.ghost_sumSharesBurned());
    }

    /// @dev Once any shares have ever been minted, tokenPrice must never be (or return to) zero
    /// -- a zero share price makes every subsequent deposit's `sharesToMint` computation
    /// (PassiveBucket.sol:332, dividing by `tokenPrice`) revert on division by zero, freezing the
    /// vault for every future depositor.
    function invariant_TokenPriceNeverZeroOnceSharesExist() public view {
        if (bucket.totalSupply() > 0) {
            assertGt(bucket.tokenPrice(), 0);
        }
    }

    /// @dev forge-std calls `afterInvariant` once PER RUN, from a state that was reset to
    /// post-`setUp()` at the start of that run (verified empirically 2026-10-04: a handler ghost
    /// counter that only ever increments still read single digits here across five fixed-seed
    /// runs, while forge's own cumulative per-selector table summed to ~1900+ redeem calls across
    /// the full 256-run campaign) -- so any one run's sample here is bounded by `depth` (15) and
    /// is too small for a no-op-RATE threshold to mean anything (a shrunk 1-call repro of "redeem
    /// before any deposit" is a genuine, correct no-op that would trip a naive threshold at n=1).
    /// This function therefore only LOGS, as a diagnostic a verifier can read per-run; the actual
    /// claim #8 proof -- that the actor-fallback fix below measurably collapses the no-op rate
    /// over a realistic-length sequence -- lives in the dedicated, non-fuzzed
    /// `test_RedeemNoOpRateCollapsesWithActorFallback` below, which runs one long deterministic
    /// sequence with no inter-call state reset and asserts the rate directly.
    function afterInvariant() public view {
        console.log("ghost_redeemAttempts (this run):", handler.ghost_redeemAttempts());
        console.log("ghost_redeemCalls (this run):", handler.ghost_redeemCalls());
        console.log("ghost_redeemNothingToRedeemTolerated (this run):", handler.ghost_redeemNothingToRedeemTolerated());
        console.log("ghost_redeemNoHolderYet (this run, genuine no-op):", handler.ghost_redeemNoHolderYet());
    }

    /// @notice Verifier claim #8 (2026-10-04), direct reproduction and fix proof. The original
    /// `redeem` handler picked exactly one actor by seed and silently `return`-ed, UNCOUNTED,
    /// whenever that one actor held zero shares. With only 3 actors and seeds that cycle through
    /// them, any sequence where two of the three never (or no longer) hold shares makes a large
    /// share of dispatched calls do nothing while forge's own table still reports them as
    /// ordinary, non-reverting "calls" -- the verifier measured this at ~54% over a real
    /// invariant campaign. This test reproduces the same shape directly and deterministically:
    /// only ONE of three actors ever deposits, then redeem is dispatched cycling through all
    /// three actors' seeds, so 2 of every 3 calls target an actor who has never held a share.
    function test_RedeemNoOpRateCollapsesWithActorFallback() public {
        address actor0 = handler.actors(0);
        vm.deal(actor0, 1000 ether);
        // Fund actor0 generously; redeeming only 1 wei of share (out of the ~2e22 minted here)
        // would entitle the redeemer to a proportional payout that floors to zero on the only
        // token the vault holds (ETH) and legitimately reverts `NothingToRedeem` -- a REAL,
        // tolerated no-op unrelated to the actor-fallback bug this test targets. So each
        // iteration below redeems 5% of actor0's CURRENT balance instead of a fixed tiny amount,
        // which is always large enough to pay out something real, and (0.95)^30 ~= 21% remains
        // at the end -- actor0 never runs dry over the loop.
        handler.deposit(0, 10 ether); // actorSeed 0 -> actor0 (see `_actor`, seed % 3 == 0)

        uint256 iterations = 30;
        for (uint256 i = 0; i < iterations; i++) {
            // actorSeed cycles 0,1,2,0,1,2,... so 2 of every 3 calls target actor1/actor2, who
            // never deposited -- exactly the shape that produced the verifier's ~54% figure.
            uint256 fivePercent = bucket.balanceOf(actor0) / 20;
            handler.redeem(i, fivePercent);
        }

        uint256 attempts = handler.ghost_redeemAttempts();
        uint256 noHolderYet = handler.ghost_redeemNoHolderYet();
        console.log("test_RedeemNoOpRateCollapsesWithActorFallback: attempts =", attempts);
        console.log("test_RedeemNoOpRateCollapsesWithActorFallback: noHolderYet =", noHolderYet);
        assertEq(attempts, iterations, "every loop iteration must count as a dispatched attempt");

        // Pre-fix, actor1/actor2's seeds (2 of every 3 calls, i.e. ~67% here -- the same order of
        // magnitude as the verifier's measured ~54% over a real fuzz campaign) would each hit the
        // `actorBalance == 0 -> return` branch and do nothing. Post-fix, every one of those falls
        // back to actor0, who holds a real balance throughout, so the TRUE no-op rate should be
        // zero (nobody has ever had a reason to hit `ghost_redeemNoHolderYet` in this sequence,
        // since actor0 deposited before any redeem was ever attempted).
        assertEq(noHolderYet, 0, "actor-fallback should eliminate every no-op in this sequence");
        assertEq(handler.ghost_redeemCalls(), iterations, "every attempt should have reached a real redeem() call");
    }
}
