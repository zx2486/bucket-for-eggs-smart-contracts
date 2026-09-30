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
        address actor = _actor(actorSeed);
        uint256 actorBalance = bucket.balanceOf(actor);
        if (actorBalance == 0) return; // no-op, not a call the handler forces to revert

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

        implementation = new PassiveBucket();

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

    /// @dev forge-std calls this once after each invariant run completes. Not itself an
    /// assertion -- it exists so `ghost_redeemNothingToRedeemTolerated` is visible in run
    /// output (`-vv` or higher) without a separate script, so a verifier can confirm the
    /// tolerated-revert branch in the handler's `redeem` is actually being exercised and not
    /// silently dead code (same non-vacuity discipline as the revert-rate table forge already
    /// prints -- root CLAUDE.md §5.4).
    function afterInvariant() public view {
        console.log("ghost_redeemCalls:", handler.ghost_redeemCalls());
        console.log("ghost_redeemNothingToRedeemTolerated:", handler.ghost_redeemNothingToRedeemTolerated());
    }
}
