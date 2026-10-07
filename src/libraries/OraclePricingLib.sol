// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title OraclePricingLib
 * @notice EIP-170 size-relief extraction (same pattern as {SeizureLib}/{DexSwapLib}) for W5's
 * returning oracle deliverable (`04-CONTRACTS-IMPLEMENTATION-PLAN.md` §5.1): per-held-token
 * outpriced / manual-price inventory views, and the aggregate-status transition event, built on
 * top of W1 (sc-oracle)'s per-token `IBucketInfo.isPotentiallyOutpriced(address)` and
 * `getPriceFeed(address)`. {BucketVaultBase.isAnyHeldTokenPotentiallyOutpriced} already OR's the
 * former across a vault's held-tokens set inline; this library exists so the REST of §5.1 (two
 * inventory views + a transition event) does not land as more inline bytecode in
 * {BucketVaultBase}, whose runtime size directly costs both ActiveBucket and PassiveBucket —
 * and PassiveBucket's margin is currently only +178 B (W4-SC-COMPLIANCE-REPORT.md).
 * @dev Functions are `public` (not `internal`) so this library is deployed ONCE and
 * DELEGATECALLed into by both ActiveBucket and PassiveBucket, exactly as {SeizureLib} and
 * {DexSwapLib} already are. Storage parameters (`EnumerableSet.AddressSet storage`,
 * `OutpricedTracker storage`) resolve against the CALLER's storage under delegatecall, identically
 * to an internal function reading the same storage directly would — see {SeizureLib}'s own
 * `mapping(...) storage` parameters for the precedent.
 * @dev "Outpriced" and "manually priced" are DELIBERATELY DIFFERENT inventories, not two names for
 * one concept. `BucketInfo.isPotentiallyOutpriced` (`BucketInfo.sol:490-493`) only ever evaluates
 * tokens that HAVE a Chainlink feed configured — it returns false for a manually-priced token
 * (there is no feed to go stale), per `BucketInfo.sol:499-513`'s `_tryGetPrice`. A manually-priced
 * token is identified instead by `getPriceFeed(token) == address(0)` (`BucketInfo.sol:567-569`).
 * Neither view is a subset of the other in general, so both are provided.
 */
library OraclePricingLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Holds exactly one `bool`, so {syncOutpricedStatus} can take a storage reference to a
    /// single tracked flag — mirroring the `TimelockedAdmin.AddressTimelock`/`SeizureTimelock`
    /// pattern {GovernanceLib}/{SeizureLib} already use to pass namespaced
    /// {BucketVaultBase} storage into a library by reference. A bare storage-reference `bool`
    /// parameter is unidiomatic in this codebase (every existing library-storage-param precedent
    /// wraps its tracked state in a struct or mapping), so this one-field struct is used instead.
    struct OutpricedTracker {
        bool lastKnownOutpriced;
    }

    /// @notice Emitted by {syncOutpricedStatus} exactly when the vault's aggregate outpriced
    /// status actually changes (never on a no-op re-check).
    event OutpricedStatusChanged(bool wasOutpriced, bool isOutpriced);

    /// @notice Whether any token in `heldTokens` is currently flagged by `bucketInfo` as
    /// potentially outpriced. Same semantics as
    /// {BucketVaultBase.isAnyHeldTokenPotentiallyOutpriced} — kept here too so
    /// {syncOutpricedStatus} and that external view share one implementation instead of two
    /// copies of the same loop existing in different places.
    /// @dev Bounded by `heldTokens.length()`, same cost shape as every other held-tokens scan in
    /// this codebase (`_syncAllHeldTokensFromWhitelist`, `isAnyHeldTokenPotentiallyOutpriced`).
    function isAnyOutpriced(IBucketInfo bucketInfo, EnumerableSet.AddressSet storage heldTokens)
        public
        view
        returns (bool)
    {
        uint256 n = heldTokens.length();
        for (uint256 i = 0; i < n; i++) {
            if (bucketInfo.isPotentiallyOutpriced(heldTokens.at(i))) {
                return true;
            }
        }
        return false;
    }

    /// @notice The subset of `heldTokens` currently flagged by `bucketInfo` as potentially
    /// outpriced (stale/invalid Chainlink data) — the plan's §5.1 "which tokens" inventory, as
    /// opposed to {isAnyOutpriced}'s plain boolean.
    function getOutpricedHeldTokens(IBucketInfo bucketInfo, EnumerableSet.AddressSet storage heldTokens)
        public
        view
        returns (address[] memory outpriced)
    {
        uint256 n = heldTokens.length();
        address[] memory buf = new address[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            address token = heldTokens.at(i);
            if (bucketInfo.isPotentiallyOutpriced(token)) {
                buf[count++] = token;
            }
        }
        outpriced = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            outpriced[i] = buf[i];
        }
    }

    /// @notice The subset of `heldTokens` with no Chainlink feed configured at all (manually
    /// priced, per `BucketInfo.getPriceFeed(token) == address(0)`) — the plan's §5.1
    /// manual-price inventory view. See this library's header for why this is NOT the same set
    /// as {getOutpricedHeldTokens}.
    function getManualPricedHeldTokens(IBucketInfo bucketInfo, EnumerableSet.AddressSet storage heldTokens)
        public
        view
        returns (address[] memory manuallyPriced)
    {
        uint256 n = heldTokens.length();
        address[] memory buf = new address[](n);
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            address token = heldTokens.at(i);
            if (bucketInfo.getPriceFeed(token) == address(0)) {
                buf[count++] = token;
            }
        }
        manuallyPriced = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            manuallyPriced[i] = buf[i];
        }
    }

    /// @notice Re-derives the vault's aggregate outpriced status and emits
    /// {OutpricedStatusChanged} only when it actually transitions.
    /// @dev Call exactly ONCE per state-changing function, after that function's own per-token
    /// loop/registry-sync work has completed — never from inside a per-token loop (e.g. inside
    /// `_syncHeldTokenByBalance`), or an O(n) caller becomes O(n^2). See
    /// `BucketVaultBase._syncOutpricedStatus`'s call sites for the four places this wave wires it:
    /// once after deposit's `_registerHeldToken`, once after each vault's redeem payout loop, and
    /// once after each vault's swap/rebalance held-token resync.
    function syncOutpricedStatus(
        OutpricedTracker storage tracker,
        IBucketInfo bucketInfo,
        EnumerableSet.AddressSet storage heldTokens
    ) public returns (bool isOutpriced) {
        bool wasOutpriced = tracker.lastKnownOutpriced;
        isOutpriced = isAnyOutpriced(bucketInfo, heldTokens);
        if (isOutpriced != wasOutpriced) {
            tracker.lastKnownOutpriced = isOutpriced;
            emit OutpricedStatusChanged(wasOutpriced, isOutpriced);
        }
    }
}
