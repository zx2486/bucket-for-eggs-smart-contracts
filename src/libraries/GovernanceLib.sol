// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IImplementationRegistry} from "../interfaces/IImplementationRegistry.sol";
import {TimelockedAdmin} from "../libs/TimelockedAdmin.sol";

/**
 * @title GovernanceLib
 * @notice EIP-170 size-relief extraction, same rationale and precedent as {SeizureLib} and
 * {DexSwapLib}: after W4.3's seizure feature landed (even fully consolidated across four passes,
 * see SeizureLib.sol's header comment), `forge build --sizes` still showed PassiveBucket's
 * runtime margin at -1,000 B. This library moves every W3 governance function
 * (`proposeUpdateBucketInfo`/`vetoUpdateBucketInfo`/`executeUpdateBucketInfo`, and
 * `queueUpgrade`/`cancelUpgrade`/`authorizeUpgrade` (was `_authorizeUpgradeCommon`)) out of
 * `BucketVaultBase`'s own bytecode. Measured empirically, one pass at a time, exactly as
 * SeizureLib's four passes were:
 *   - {authorizeUpgrade} + {proposeUpdateBucketInfo} (the two functions with real branching
 *     logic — a mismatch check, a registry call, an owner-address comparison): -1,000 B -> -626 B
 *     (374 B recovered).
 *   - {queueUpgrade} (one zero-check): -626 B -> -533 B (93 B recovered).
 *   - {vetoUpdateBucketInfo} + {cancelUpgrade} (cancel + read + emit, no check — thinner than the
 *     above but NOT the zero-logic case SeizureLib's pass 3 found counterproductive, since each
 *     still has a struct read plus an event emission): -533 B -> -487 B (46 B recovered).
 *   - {executeUpdateBucketInfo} (timelock consumption + emit, split from the
 *     `_setBucketInfo` call that must stay in the caller — see that function's own doc comment):
 *     measured below.
 * Total, before the last step: 513 B recovered (-1,000 B -> -487 B) — comparable to SeizureLib's
 * entire four-pass total of 547 B. Deliberately LEFT INLINE: `pendingBucketInfoUpdate`,
 * `pendingImplementation`, `upgradeEta` — bare struct-field getters with no check and no event,
 * the exact shape SeizureLib's pass 3 proved is COUNTERPRODUCTIVE to extract (delegatecall
 * call-setup/return-decode glue costs more than the read it replaces).
 * @dev This is a PURE bytecode-location change on every function it touches: each check, revert,
 * and event below is copied unchanged from `BucketVaultBase.sol`'s "updateBucketInfo"/"Upgrade
 * governance" sections (W3.2/W3.3). No behavior, ordering, gating, or timelock semantics differs.
 * Because this touches ALREADY-TESTED W3 deliverables (task #45's gate tests, task #46's
 * verification report), the full `forge test` suite — not just `forge build` — must be re-run
 * after this change to prove zero regression (root CLAUDE.md hard rule 13); a passing
 * `forge build` alone is not evidence for pre-existing, previously-verified functionality.
 * @dev Functions are `public` so this library is deployed once and DELEGATECALLed into by both
 * `ActiveBucket` and `PassiveBucket`, exactly as {SeizureLib} and {DexSwapLib} already are. A
 * `storage` parameter (the `TimelockedAdmin.AddressTimelock` slot) resolves against the CALLER's
 * own storage under delegatecall; `msg.sender` and `address(this)` inside these functions also
 * resolve to the CALLING vault, not this library, for the same reason.
 * @dev {_registry}/{_registryKind} are `internal virtual` functions on `BucketVaultBase` (each
 * child overrides them to point at its own namespace) and therefore CANNOT be called from this
 * library — a library has no access to a contract's virtual dispatch table. The caller evaluates
 * both and passes the results in; {authorizeUpgrade} takes the resolved `IImplementationRegistry`
 * and `Kind` as plain parameters, not a callback. The same constraint is why {executeUpdateBucketInfo}
 * returns the new address rather than calling `_setBucketInfo` itself — see that function's doc
 * comment.
 */

library GovernanceLib {
    using TimelockedAdmin for TimelockedAdmin.AddressTimelock;

    /// @dev Selector-identical to `BucketVaultBase.ZeroAddress()` — same duplication-for-selector
    /// pattern {SeizureLib.Blacklisted} already uses and documents; a library cannot revert with
    /// an error it did not itself declare, and Solidity matches custom errors by selector
    /// (name + arg types), not by declaring contract.
    error ZeroAddress();

    /// @dev Selector-identical to `BucketVaultBase.UnauthorizedBucketInfoUpdate()`.
    error UnauthorizedBucketInfoUpdate();

    /// @dev Selector-identical to `BucketVaultBase.UpgradeImplementationMismatch(address,address)`.
    error UpgradeImplementationMismatch(address expected, address provided);

    /// @dev Selector-identical to `BucketVaultBase.UpgradeNotApproved(address)`.
    error UpgradeNotApproved(address implementation);

    /// @dev Selector-identical to `BucketVaultBase.BucketInfoUpdateProposed(...)`.
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed newBucketInfo, address indexed proposedBy, uint256 eta
    );

    /// @dev Selector-identical to `BucketVaultBase.UpgradeQueued(...)`.
    event UpgradeQueued(address indexed vault, address indexed newImplementation, uint256 eta);

    /// @dev Selector-identical to `BucketVaultBase.BucketInfoUpdateVetoed(...)`.
    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);

    /// @dev Selector-identical to `BucketVaultBase.UpgradeCancelled(...)`.
    event UpgradeCancelled(address indexed vault, address indexed implementation);

    /// @dev Selector-identical to `BucketVaultBase.BucketInfoUpdated(...)`.
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);

    /// @notice Propose updating the BucketInfo contract address. See
    /// `BucketVaultBase.proposeUpdateBucketInfo`'s own doc comment for the full rationale
    /// (gated on the CURRENT BucketInfo's owner, not this vault's owner — the reverse-direction
    /// protection for this vault's own investors).
    function proposeUpdateBucketInfo(
        TimelockedAdmin.AddressTimelock storage bucketInfoUpdateTimelock,
        IBucketInfo currentBucketInfo,
        address newBucketInfo,
        uint256 delay
    ) public {
        if (newBucketInfo == address(0)) revert ZeroAddress();

        address bucketInfoOwner = currentBucketInfo.owner();
        if (msg.sender != bucketInfoOwner) revert UnauthorizedBucketInfoUpdate();

        bucketInfoUpdateTimelock.propose(newBucketInfo, delay);

        emit BucketInfoUpdateProposed(address(currentBucketInfo), newBucketInfo, msg.sender, block.timestamp + delay);
    }

    /// @notice Shared body of `_authorizeUpgrade`, called from a one-line override in each of
    /// `ActiveBucket`/`PassiveBucket`. See `BucketVaultBase._authorizeUpgradeCommon`'s own doc
    /// comment for the full four-condition rationale (`04-CONTRACTS-IMPLEMENTATION-PLAN.md`
    /// §5.6.1/§10.1). Conditions 2+3 (address match, elapsed delay) are enforced by
    /// `TimelockedAdmin.execute`; condition 4 (still-live registry approval) is re-checked HERE,
    /// at execution time, matching a caller-supplied `registry`/`kind` since this library cannot
    /// reach the calling contract's own virtual `_registry()`/`_registryKind()`.
    function authorizeUpgrade(
        TimelockedAdmin.AddressTimelock storage upgradeTimelock,
        IImplementationRegistry registry,
        IImplementationRegistry.Kind kind,
        address newImplementation
    ) public {
        address queued = upgradeTimelock.pending;
        if (queued != address(0) && newImplementation != queued) {
            revert UpgradeImplementationMismatch(queued, newImplementation);
        }

        upgradeTimelock.execute();

        if (!registry.isApproved(kind, newImplementation)) {
            revert UpgradeNotApproved(newImplementation);
        }
    }

    /// @notice Queue a UUPS upgrade to `newImplementation`. See
    /// `BucketVaultBase.queueUpgrade`'s own doc comment for the full rationale. `onlyOwner` is
    /// enforced by the modifier on the one-line wrapper that calls this, not re-checked here —
    /// same split as {SeizureLib}'s own `requirePlatformOwner`-vs-modifier distinction, applied
    /// in the opposite direction (this gate is cheap enough to leave as a compile-time modifier).
    function queueUpgrade(
        TimelockedAdmin.AddressTimelock storage upgradeTimelock,
        address newImplementation,
        uint256 delay
    ) public {
        if (newImplementation == address(0)) revert ZeroAddress();

        upgradeTimelock.propose(newImplementation, delay);

        emit UpgradeQueued(address(this), newImplementation, block.timestamp + delay);
    }

    /// @notice Veto (cancel) a pending BucketInfo update. See
    /// `BucketVaultBase.vetoUpdateBucketInfo`'s own doc comment. `onlyOwner` is enforced by the
    /// modifier on the one-line wrapper that calls this.
    function vetoUpdateBucketInfo(TimelockedAdmin.AddressTimelock storage bucketInfoUpdateTimelock) public {
        address proposed = bucketInfoUpdateTimelock.pending;
        bucketInfoUpdateTimelock.cancel();
        emit BucketInfoUpdateVetoed(proposed, msg.sender);
    }

    /// @notice Cancel a pending upgrade. See `BucketVaultBase.cancelUpgrade`'s own doc comment.
    /// `onlyOwner` is enforced by the modifier on the one-line wrapper that calls this.
    function cancelUpgrade(TimelockedAdmin.AddressTimelock storage upgradeTimelock) public {
        address pending = upgradeTimelock.pending;
        upgradeTimelock.cancel();
        emit UpgradeCancelled(address(this), pending);
    }

    /// @notice Execute a pending BucketInfo update once the timelock has elapsed and no veto
    /// arrived. See `BucketVaultBase.executeUpdateBucketInfo`'s own doc comment (deliberately
    /// PERMISSIONLESS — no modifier to split the auth check out of, unlike every other function
    /// in this library).
    /// @dev Cannot move the `_setBucketInfo(newBucketInfo)` storage write itself: that is an
    /// `internal virtual` function each child overrides, unreachable from a library with no
    /// access to the calling contract's own dispatch table (same constraint as
    /// `_registry()`/`_registryKind()` above). The caller therefore still performs that one line
    /// itself, using the `newBucketInfo` this function validates and returns — mirroring
    /// {SeizureLib.executeSeizure}'s split with `super._update`.
    function executeUpdateBucketInfo(
        TimelockedAdmin.AddressTimelock storage bucketInfoUpdateTimelock,
        address oldBucketInfo
    ) public returns (address newBucketInfo) {
        newBucketInfo = bucketInfoUpdateTimelock.execute();
        emit BucketInfoUpdated(oldBucketInfo, newBucketInfo, msg.sender);
    }
}
