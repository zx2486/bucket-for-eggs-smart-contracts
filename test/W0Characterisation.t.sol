// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// W0.4 characterisation tests.
//
// Purpose (per _deliverables/04-CONTRACTS-IMPLEMENTATION-PLAN.md, W0.4): pin the CURRENT
// behaviour of functions later waves will change -- including buggy or dangerous current
// behaviour -- so that a later wave's fix has a test that used to pass on the OLD behaviour
// and must be updated (not silently left green) once the behaviour changes. Every test below
// is marked `// CHARACTERISATION: documents current behaviour, expected to change in Wx`.
//
// These are NOT regression tests for a fix, and they are NOT invariants (see W0.5 for the
// first invariant suite). Passing here means "this is what the code does today", not
// "this is correct" -- several of these tests document defects named in root CLAUDE.md
// (the oracle-manipulation risk at §00:44, the arbitrary-1inch-calldata risk at hard rule 12)
// and in _deliverables/09-DECISION-LOG.md.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BucketInfo} from "../src/BucketInfo.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {MockV3Aggregator} from "@chainlink/tests/MockV3Aggregator.sol";

import {MockBucketInfoForPassive, MockERC20, MockOneInchRouter} from "./PassiveBucket.t.sol";

// _pending_: BucketInfo price-path characterisations (setTokenPrice bound/rate-limit,
// Chainlink-path negative price, Chainlink-path staleness-blindness).
contract W0CharacterisationBucketInfoTest is Test {
    BucketInfo public bucketInfo;
    address public nativeToken;

    function setUp() public {
        bucketInfo = new BucketInfo();
        nativeToken = address(0); // whitelisted by the constructor, BucketInfo.sol:79-81
    }

    /// CHARACTERISATION: documents current behaviour, expected to change in W1 (sc-oracle).
    /// setTokenPrice (BucketInfo.sol:167-174) has no upper bound, no maximum-deviation-from-
    /// last-price check, and no minimum interval between updates -- only `price > 0` and
    /// `isWhitelisted[token]`. The owner can move a price from $1 to the maximum uint256 value
    /// in a single call, in the same block as the previous update.
    function test_CharacterisationSetTokenPriceHasNoUpperBoundOrRateLimit() public {
        bucketInfo.setTokenPrice(nativeToken, 1);
        assertEq(bucketInfo.getTokenPrice(nativeToken), 1);

        // Same block, no cooldown, no deviation cap: jump straight to type(uint256).max.
        bucketInfo.setTokenPrice(nativeToken, type(uint256).max);
        assertEq(bucketInfo.getTokenPrice(nativeToken), type(uint256).max);
    }

    /// CHARACTERISATION: documents current behaviour, expected to change in W1 (sc-oracle).
    /// getTokenPrice's Chainlink branch (BucketInfo.sol:226-238) destructures
    /// `latestRoundData()` as `(, int256 price,,,)` -- it reads only the price and discards
    /// roundId, startedAt, updatedAt and answeredInRound. It also never checks `price > 0`
    /// before the explicit `uint256(price)` conversion. A negative answer is NOT rejected: the
    /// int256->uint256 conversion reinterprets the two's-complement bit pattern, so a small
    /// negative answer becomes a value near type(uint256).max, not a revert.
    function test_CharacterisationChainlinkPriceFeedIgnoresNegativePrice() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8); // starts at a sane $100 price
        bucketInfo.setPriceFeed(nativeToken, address(feed));

        feed.updateAnswer(-100e8); // negative price, same 8 decimals as PRICE_DECIMALS

        uint256 price = bucketInfo.getTokenPrice(nativeToken); // does not revert
        // uint256(int256(-100e8)) == 2**256 - 100e8, i.e. astronomically far from a real price.
        assertEq(price, uint256(int256(-100e8)));
        assertGt(price, 1e30); // sanity check that this is "huge", not a small wrapped value
    }

    /// CHARACTERISATION: documents current behaviour, expected to change in W1 (sc-oracle).
    /// The Chainlink branch has no staleness check at all -- contrast with the manual-price
    /// branch just below it (BucketInfo.sol:239-243), which reverts "Price is outdated" past
    /// 30 days. A Chainlink feed's `updatedAt` can be arbitrarily old (or even in the past
    /// relative to a stale/halted feed) and getTokenPrice will still return its answer.
    function test_CharacterisationChainlinkPriceFeedIgnoresStaleness() public {
        vm.warp(1000 days); // move off genesis timestamp so the subtraction below cannot underflow
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        bucketInfo.setPriceFeed(nativeToken, address(feed));

        // Round data explicitly timestamped 400 days in the past -- far past the 30-day
        // staleness cutoff the manual-price branch enforces.
        feed.updateRoundData(1, 100e8, block.timestamp - 400 days, block.timestamp - 400 days);
        vm.warp(block.timestamp + 400 days);

        uint256 price = bucketInfo.getTokenPrice(nativeToken); // does not revert
        assertEq(price, 100e8);
    }

    /// CHARACTERISATION: documents current behaviour, NOT expected to change (recorded here as
    /// the contrast case for the two tests above). The manual-price branch DOES enforce a
    /// 30-day staleness window (BucketInfo.sol:240-243). This is the asymmetry that makes the
    /// two tests above worth pinning: the two price-source branches disagree about staleness.
    function test_CharacterisationManualPriceStalenessBoundaryStillEnforced() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);

        vm.warp(block.timestamp + 30 days);
        assertEq(bucketInfo.getTokenPrice(nativeToken), 100e8); // exactly 30 days: still valid

        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("Price is outdated"));
        bucketInfo.getTokenPrice(nativeToken);
    }
}

// _pending_: PassiveBucket rebalanceBy1inch / router-allowlist / updateBucketInfo-gate
// characterisations.
contract W0CharacterisationPassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA; // 18 decimals
    MockERC20 public tokenB; // 6 decimals
    MockOneInchRouter public oneInchRouter;

    address public user1;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 2000e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    function setUp() public {
        user1 = makeAddr("user1");

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

        vm.deal(user1, 100 ether);
        tokenA.mint(user1, 100e18);
        tokenB.mint(user1, 100000e6);
    }

    /// CHARACTERISATION RETIRED by W2 (sc-swap): the behaviour this test pinned — rebalanceBy1inch
    /// forwarding arbitrary caller-supplied calldata to `oneInchRouter` via a raw `.call()` with
    /// no validation of selector or parameters — no longer exists. `rebalanceBy1inch` now takes
    /// four typed parameters (srcToken, dstToken, amount, minReturn); this contract builds 100%
    /// of the router calldata itself (BucketVaultBase._execute1inchSwap), so there is no calldata
    /// field left for a caller to control. The full pre-fix-vs-post-fix evidence (a drain PoC
    /// that succeeds pre-fix and reverts post-fix) lives in test/OneInchSwapSecurity.t.sol, not
    /// here — this test is kept only as a minimal compile-time pin that malformed/self-swap input
    /// is now rejected BEFORE any external call, rather than forwarded unvalidated.
    /// @dev Scope note (workspace CLAUDE.md hard rule 6/9): this file is not in sc-swap's
    /// file-ownership list, but its own header anticipated this exact edit ("expected to change
    /// in W2") and a stale call signature here blocks `forge build` for the entire project,
    /// including every other agent's tests. Edit is the minimal one-line signature/assertion
    /// change needed to keep the build green — see W2-SC-SWAP-REPORT.md "Corrections to my
    /// briefing" for the full account of this exception.
    function test_CharacterisationRebalanceBy1inchForwardsArbitraryCalldataUnvalidated() public {
        vm.startPrank(user1);
        bucket.deposit{value: 0.25 ether}(address(0), 0); // $500 @ $2000/ETH -> 50%
        tokenA.approve(address(bucket), 0.15e18);
        bucket.deposit(address(tokenA), 0.15e18); // $300 @ $2000/token -> 30%
        tokenB.approve(address(bucket), 200e6);
        bucket.deposit(address(tokenB), 200e6); // $200 @ $1/token -> 20%
        vm.stopPrank();

        assertGt(bucket.balanceOf(user1), 0);

        // Post-fix: a same-token "swap" is rejected by construction before any external call is
        // ever made — this is what replaced "accepts anything, the mock router's fallback takes
        // any calldata" as the pinned behaviour.
        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.SameToken.selector);
        bucket.rebalanceBy1inch(address(0), address(0), 1, 0);
    }

    /// CHARACTERISATION: documents current behaviour, expected to change in W2. PassiveBucket has
    /// no setter for `oneInchRouter` at all -- it is set once in `initialize` (PassiveBucket.sol:
    /// 265-289) and the only check applied is `_oneInchRouter == address(0)` (:273). There is no
    /// allowlist, no interface probe, and no check that the address even has code: an EOA can be
    /// wired in as the router that rebalanceBy1inch will later `.call()` into. (ActiveBucket's
    /// sibling setter, setOneInchRouter at src/ActiveBucket.sol:414-418, has the identical gap on
    /// an owner-gated setter instead of at init time.)
    function test_CharacterisationInitializeAcceptsAnyNonzeroRouterAddressNoCodeCheck() public {
        address plainEOA = makeAddr("plainEOAWithNoCode");
        assertEq(plainEOA.code.length, 0);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, plainEOA, "PassiveBucket Share", "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData); // does not revert

        assertEq(PassiveBucket(payable(address(proxy))).oneInchRouter(), plainEOA);
    }

    /// CHARACTERISATION: documents current behaviour, NOT expected to change by the fix itself --
    /// recorded here because it is the exact guarantee root CLAUDE.md §00:44 describes ("Even
    /// contract owners should not able to change [the oracle]... to protect contract investors
    /// from being rug pulled by bad price feed source") and any W1 fix to the factory-supplied
    /// BucketInfo pointer (root CLAUDE.md §8, the "factory-immutable" item) must preserve this
    /// gate exactly. updateBucketInfo (PassiveBucket.sol:708-718) is gated on
    /// `IBucketInfo(bucketInfo).owner()`, i.e. the CURRENT BucketInfo's owner -- NOT
    /// `msg.sender == owner()` of the vault itself. The vault owner cannot call it if they are
    /// not also the BucketInfo owner.
    function test_CharacterisationUpdateBucketInfoGatedOnBucketInfoOwnerNotVaultOwner() public {
        address vaultOwner = bucket.owner();
        address bucketInfoOwner = makeAddr("bucketInfoOwner");
        bucketInfo.setOwner(bucketInfoOwner);
        assertTrue(vaultOwner != bucketInfoOwner);

        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();

        // The vault's own owner is refused -- they are not the BucketInfo's owner.
        vm.prank(vaultOwner);
        vm.expectRevert(BucketVaultBase.UnauthorizedBucketInfoUpdate.selector);
        bucket.updateBucketInfo(address(newBucketInfo));

        // The BucketInfo's owner succeeds, regardless of whether they are the vault's owner.
        vm.prank(bucketInfoOwner);
        bucket.updateBucketInfo(address(newBucketInfo));
        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }
}
