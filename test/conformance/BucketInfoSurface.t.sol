// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

// ============================================================
// W3.8 (N3) -- BucketInfo mutable-surface conformance test.
//
// Root CLAUDE.md §8 / `_deliverables/04-CONTRACTS-IMPLEMENTATION-PLAN.md` §5.6 (W3.8/W3.9,
// "what A2 created when it took upgradeability away"): A2 fixed `BucketInfo`'s mutable
// configuration surface at exactly five categories -- owner address, platform fee, token
// price, token whitelist, price feed -- because `BucketInfo` is permanently non-upgradeable
// (client decision A2, `09-DECISION-LOG.md` §3.1) and therefore has no way to patch a defect
// introduced by an undocumented sixth setter. This test is N3: the thing that actually
// enforces that promise, rather than a plan document asserting it.
//
// ⚠ Per the plan's own warning (§5.6, "N3's allow-list is NOT just A2's five items, and
// writing it literally makes the test fail on day one against correct code"): four more
// functions are correct, shipped, client-required exceptions, not defects --
// `pausePlatform`/`unpausePlatform` (the catastrophic-event kill switch, client 01:42, INV-1's
// one permitted redemption gate) and `withdrawAccumulatedFees`/`withdrawAccumulatedETHFees`
// (fee collection). They get their own explicit allow-list bucket, with this comment, so the
// next reader does not "tidy" them into a rejection.
//
// A fifth bucket -- blacklist management -- was declared EMPTY when this test was first written
// (2026-09-30, before W4.1 landed) specifically so W4.1 could extend this test's allow-list
// without needing to rediscover that this file exists. W4.1 has now landed
// (`blacklistAddress`/`removeBlacklist`/`batchBlacklistAddresses`/`batchRemoveBlacklist` on
// `BucketInfo.sol`, immediate/no-timelock -- see its own COMPLIANCE section) and the bucket
// below is populated accordingly. `isBlacklisted` is deliberately absent from every bucket: it
// is a `view` function (INV-7), so it is never enumerated by the mutability filter below.
//
// HOW THIS WORKS: Solidity has no runtime reflection over a contract's own function set, so
// this enumerates the ACTUAL compiled ABI from `out/BucketInfo.sol/BucketInfo.json` via
// `vm.readFile` + `vm.parseJsonString` (fs_permissions grants read-only access to `./out`,
// foundry.toml -- no `ffi`, which stays off everywhere in this repo). It walks `.abi[i]` for
// increasing `i`, using a `try/catch` on the cheatcode call itself to detect "index out of
// range" (forge reverts inside parseJsonString when the path does not resolve to exactly one
// value) rather than assuming any particular array length -- so this test does not need
// updating merely because the ABI grows unrelated events/errors/views. For every entry where
// `type == "function"` and `stateMutability` is neither `"view"` nor `"pure"` (i.e. every
// function capable of changing state), the function's `name` must appear in one of the
// allow-list buckets below, or the test fails and prints the offending name.
//
// PROVEN TO CATCH A REGRESSION (manual verification, not re-run automatically as part of CI --
// see W3-GATE-REPORT for the transcript): a throwaway
// `function setRandomThing(uint256) external onlyOwner {}` was added to `BucketInfo.sol`,
// `forge build` run to refresh `out/`, and this test was confirmed to FAIL, printing
// "Unrecognised mutable function on BucketInfo: setRandomThing". The throwaway setter was then
// removed and `forge build` re-run before this test was left in its passing state.
// ============================================================

contract BucketInfoSurfaceConformanceTest is Test {
    /// @dev A2's five configuration categories, exactly as root CLAUDE.md §8 states them.
    string[] private ownerAddressSurface;
    string[] private platformFeeSurface;
    string[] private tokenPriceSurface;
    string[] private tokenWhitelistSurface;
    string[] private priceFeedSurface;

    /// @dev W4.1 (blacklist storage) landed 2026-09-30 -- populated in {setUp} below. See this
    /// file's header comment.
    string[] private blacklistManagementSurface;

    /// @dev The four explicitly-permitted exceptions to A2's five categories (plan §5.6): the
    /// platform kill switch and fee withdrawal. Not part of A2's configuration surface, but
    /// correct, shipped, client-required code -- see this file's header comment.
    string[] private allowedExceptions;

    function setUp() public {
        // Owner address: Ownable2Step's own two-step handoff (`transferOwnership` /
        // `acceptOwnership`, W3.1) plus `renounceOwnership`, overridden to ALWAYS revert
        // (Q14.2, BucketInfo.sol's own GOVERNANCE section) -- it is listed here because it is
        // still an external, non-view function in the ABI, not because it ever succeeds.
        ownerAddressSurface.push("transferOwnership");
        ownerAddressSurface.push("acceptOwnership");
        ownerAddressSurface.push("renounceOwnership");

        // Platform fee: W3.4's propose/execute/cancel timelock via the shared TimelockedAdmin
        // module (W3.7).
        platformFeeSurface.push("proposePlatformFee");
        platformFeeSurface.push("executePlatformFee");
        platformFeeSurface.push("cancelPlatformFee");

        // Token price: deliberately untimelocked (W3.4 -- "No timelock on `setTokenPrice`",
        // the deviation cap/interval is a W1 concern instead).
        tokenPriceSurface.push("setTokenPrice");
        tokenPriceSurface.push("batchSetTokenPrices");

        // Token whitelist: additions are timelocked (W3.4), removal is immediate by design
        // (fail-closed -- delaying a removal would delay the platform's ability to cut off a
        // token discovered to be bad).
        tokenWhitelistSurface.push("proposeWhitelistAddition");
        tokenWhitelistSurface.push("executeWhitelistAddition");
        tokenWhitelistSurface.push("cancelWhitelistAddition");
        tokenWhitelistSurface.push("removeTokenWhitelist");
        tokenWhitelistSurface.push("batchProposeWhitelistAdditions");
        tokenWhitelistSurface.push("batchExecuteWhitelistAdditions");
        tokenWhitelistSurface.push("batchRemoveTokenWhitelist");

        // Price feed: propose/execute/cancel timelock (single + batch), plus
        // `setMaxPriceStaleness` -- documented in source (BucketInfo.sol's own doc comment on
        // that function) as "Same setter category as setPriceFeed -- an extension of 'price
        // feed' configuration, not a new one."
        priceFeedSurface.push("proposePriceFeed");
        priceFeedSurface.push("executePriceFeed");
        priceFeedSurface.push("cancelPriceFeed");
        priceFeedSurface.push("proposeBatchPriceFeeds");
        priceFeedSurface.push("executeBatchPriceFeeds");
        priceFeedSurface.push("setMaxPriceStaleness");

        // Allowed exceptions (plan §5.6): the kill switch and fee withdrawal. NOT in A2's five,
        // explicitly permitted anyway.
        allowedExceptions.push("pausePlatform");
        allowedExceptions.push("unpausePlatform");
        allowedExceptions.push("withdrawAccumulatedFees");
        allowedExceptions.push("withdrawAccumulatedETHFees");
        allowedExceptions.push("withdrawAccumulatedFeesToStable");

        // Blacklist management (W4.1, D2): immediate add/remove, single + batch, mirroring
        // token-whitelist REMOVAL's own "no timelock, fail-closed" rationale -- see
        // BucketInfo.sol's own COMPLIANCE section doc comments. `isBlacklisted` is a view
        // function and is therefore never enumerated by this test at all (see the mutability
        // filter in `test_BucketInfoMutableSurfaceIsExactlyTheAllowedSet` below).
        blacklistManagementSurface.push("blacklistAddress");
        blacklistManagementSurface.push("removeBlacklist");
        blacklistManagementSurface.push("batchBlacklistAddresses");
        blacklistManagementSurface.push("batchRemoveBlacklist");
    }

    /// @notice Every external/public non-view, non-pure function on the compiled `BucketInfo`
    /// ABI must be accounted for in one of this test's allow-list buckets. A function that is
    /// not is either an undocumented mutable-surface addition (A2 violation) or this test's own
    /// allow-list falling out of date -- either way, the test must fail loudly rather than
    /// silently pass.
    function test_BucketInfoMutableSurfaceIsExactlyTheAllowedSet() public {
        string memory json = vm.readFile("out/BucketInfo.sol/BucketInfo.json");

        uint256 checked = 0;
        for (uint256 i = 0; i < 1000; i++) {
            string memory typePath = string.concat(".abi[", vm.toString(i), "].type");
            string memory typ;
            // Detect "index out of range" via try/catch on the cheatcode call itself, rather
            // than assuming any fixed ABI length -- see this file's header comment.
            try vm.parseJsonString(json, typePath) returns (string memory t) {
                typ = t;
            } catch {
                break;
            }

            if (!_streq(typ, "function")) continue;

            string memory mutability =
                vm.parseJsonString(json, string.concat(".abi[", vm.toString(i), "].stateMutability"));
            if (_streq(mutability, "view") || _streq(mutability, "pure")) continue;

            string memory name = vm.parseJsonString(json, string.concat(".abi[", vm.toString(i), "].name"));
            checked++;

            assertTrue(_isInAnyBucket(name), string.concat("Unrecognised mutable function on BucketInfo: ", name));
        }

        // Sanity floor: if `out/BucketInfo.sol/BucketInfo.json` were stale, missing, or the
        // read/parse path silently no-opped, `checked` would be 0 and every assertion above
        // would have been vacuously skipped -- catch that failure mode explicitly rather than
        // reporting a false pass. 25 was the exact count when this test was first written
        // (before W4.1); W4.1 added 4 more mutable functions (`blacklistAddress`,
        // `removeBlacklist`, `batchBlacklistAddresses`, `batchRemoveBlacklist`), making 29 the
        // exact count today. The bound stays `>=` 25 rather than being bumped to 29, so this
        // line does not need editing every time a future wave adds another allowed function.
        assertGe(
            checked, 25, "Expected at least 25 mutable functions on BucketInfo -- ABI read may have failed silently"
        );
    }

    function _isInAnyBucket(string memory name) private view returns (bool) {
        return _contains(ownerAddressSurface, name) || _contains(platformFeeSurface, name)
            || _contains(tokenPriceSurface, name) || _contains(tokenWhitelistSurface, name)
            || _contains(priceFeedSurface, name) || _contains(blacklistManagementSurface, name)
            || _contains(allowedExceptions, name);
    }

    function _contains(string[] memory list, string memory needle) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (_streq(list[i], needle)) return true;
        }
        return false;
    }

    function _streq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
