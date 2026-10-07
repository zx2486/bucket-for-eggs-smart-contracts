// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {TimelockedAdmin} from "../libs/TimelockedAdmin.sol";

/**
 * @title SeizureLib
 * @notice EIP-170 size-relief extraction for W4.3 (compliance seizure), precedented by
 * {DexSwapLib}: `forge build --sizes` showed the seizure section landing inline in
 * {BucketVaultBase} pushed PassiveBucket's runtime margin negative (-1,547 B) — the same failure
 * mode {DexSwapLib} was created to fix for the swap logic (tasks #31/#48/#50). This is a PURE
 * bytecode-location change: every check, revert, and event below is copied unchanged from the
 * `proposeSeizure`/`cancelSeizure`/`executeSeizure`/`pendingSeizure` bodies that previously lived
 * directly in {BucketVaultBase}'s "COMPLIANCE — SEIZURE" section. No behavior, ordering, gating,
 * or fail-closed direction differs — see that section's remaining header comment in
 * BucketVaultBase.sol for the full rationale (⚠ SOURCE DISAGREES resolution, the platform-owner
 * gate, the reversed fail-closed direction at execution).
 * @dev Functions are `public` (not `internal`, unlike every existing function in
 * {TimelockedAdmin}) so this library is deployed ONCE and DELEGATECALLed into by both
 * ActiveBucket and PassiveBucket — exactly the mechanism {DexSwapLib.executeBestSwap} already
 * uses to move PassiveBucket's swap logic out of its own bytecode. A storage `mapping` parameter
 * resolves against the CALLER's storage under delegatecall, identically to an internal function
 * reading the same mapping directly would.
 * @dev The one piece that cannot move here: the actual token movement
 * (`ERC20Upgradeable._update`, ERC-1155 balance write) is `internal` to each token contract's own
 * inheritance chain and unreachable from a library with no state of its own. {executeSeizure}'s
 * caller therefore still performs that one line itself, using the `to` address this library's
 * {executeSeizure} validates and returns — everything else, including the destination-blacklist
 * check and the {SeizureExecuted} emission (with a deterministic `afterBalance` of `0`, since a
 * seizure always sweeps `account`'s entire balance), now lives in this library, so the caller-side
 * wrapper is just `balanceOf` + this call + the one `_update`/balance-write line. See
 * BucketVaultBase.executeSeizure's own doc comment.
 */
library SeizureLib {
    using TimelockedAdmin for TimelockedAdmin.SeizureTimelock;

    /// @dev Thrown by {proposeSeizure}/{cancelSeizure} when the caller is not BucketInfo's owner
    /// (the platform).
    error UnauthorizedSeizure();

    /// @dev Thrown by {proposeSeizure} if `account` is not confirmed blacklisted, and by
    /// {prepareExecuteSeizure} if `account` is no longer confirmed blacklisted at execution time.
    error NotBlacklisted(address account);

    /// @dev Thrown when `isBlacklisted` cannot be reached — the seizure ABORTS rather than
    /// proceeding on an unverified compliance state (the mirror image of the usual D2 fail-closed
    /// direction; see BucketVaultBase.sol's COMPLIANCE — SEIZURE header for why).
    error BucketInfoUnreachableForSeizure(address account);

    /// @dev Thrown by {prepareExecuteSeizure} if `account` holds a zero balance at execution
    /// time.
    error NothingToSeize(address account);

    /// @dev Thrown by {proposeSeizure} if `to` is the zero address.
    error ZeroAddress();

    /// @dev Selector-identical to the `Blacklisted(address)` error each token contract's own
    /// `_assertNotBlacklisted` already declares and reverts with — Solidity custom errors match
    /// by selector (name + arg types), not by which contract/library syntactically declared them,
    /// so a test asserting on `Blacklisted(address)` matches this revert too. Declared here
    /// (rather than reusing the contract's) only because a library cannot revert with an error it
    /// did not itself declare or import from a shared location, and duplicating a one-line error
    /// declaration is far cheaper than the alternative of NOT extracting this check at all.
    error Blacklisted(address account);

    event SeizureProposed(address indexed account, address indexed to, bytes32 documentHash, uint256 eta);
    event SeizureCancelled(address indexed account);
    event SeizureExecuted(
        address indexed account, address indexed to, bytes32 documentHash, uint256 beforeBalance, uint256 afterBalance
    );

    function requirePlatformOwner(IBucketInfo bucketInfo) public view {
        if (msg.sender != bucketInfo.owner()) revert UnauthorizedSeizure();
    }

    /// @dev Requires a CONFIRMED blacklisted status — reachable BucketInfo, definite `true`.
    /// Deliberately NOT the usual fail-closed helper each token contract also carries for
    /// gating a user's OWN actions; see BucketVaultBase.sol's header comment for why the two
    /// must never be merged.
    function requireConfirmedBlacklisted(IBucketInfo bucketInfo, address account) public view {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            if (!blacklisted) revert NotBlacklisted(account);
        } catch {
            revert BucketInfoUnreachableForSeizure(account);
        }
    }

    /// @dev The MIRROR IMAGE of {requireConfirmedBlacklisted}: this is the usual fail-closed
    /// direction (unreachable/reverting BucketInfo => treat as blacklisted => block), applied to
    /// the seizure DESTINATION wallet so funds cannot be seized INTO another blacklisted address.
    /// Duplicates each token contract's own `_assertNotBlacklisted`/fail-closed check in effect
    /// (same reasoning INV-9 already accepts for {PureMembership}'s own duplicate copy: the logic
    /// must be identical everywhere, not physically shared everywhere) — see this file's
    /// {Blacklisted} error doc comment for why the duplication is one line, not the whole check.
    function requireNotBlacklistedFailClosed(IBucketInfo bucketInfo, address account) public view {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            if (blacklisted) revert Blacklisted(account);
        } catch {
            revert Blacklisted(account);
        }
    }

    /// @notice Propose seizing whatever `account` currently holds, on a `bytes32` document hash
    /// (e.g. a court order) for the record.
    /// @dev Gated on BucketInfo's owner (the platform). `account` must be confirmed blacklisted
    /// now; execution re-checks this independently. Overwrites any existing pending proposal.
    function proposeSeizure(
        mapping(address => TimelockedAdmin.SeizureTimelock) storage seizureTimelocks,
        IBucketInfo bucketInfo,
        address account,
        address to,
        bytes32 documentHash,
        uint256 delay
    ) public {
        requirePlatformOwner(bucketInfo);
        if (to == address(0)) revert ZeroAddress();
        requireConfirmedBlacklisted(bucketInfo, account);

        seizureTimelocks[account].propose(to, documentHash, delay);

        emit SeizureProposed(account, to, documentHash, block.timestamp + delay);
    }

    /// @notice Cancel a pending seizure proposal for `account` before it takes effect.
    /// @dev Gated on BucketInfo's owner, same as {proposeSeizure} — deliberately no separate
    /// veto party. No-op if nothing is pending, matching `TimelockedAdmin.cancel`'s semantics.
    function cancelSeizure(
        mapping(address => TimelockedAdmin.SeizureTimelock) storage seizureTimelocks,
        IBucketInfo bucketInfo,
        address account
    ) public {
        requirePlatformOwner(bucketInfo);
        seizureTimelocks[account].cancel();
        emit SeizureCancelled(account);
    }

    /// @notice Validates and consumes the pending seizure proposal for `account`, re-confirming
    /// blacklist status on BOTH ends at execution time, and emits {SeizureExecuted}.
    /// @dev Deliberately PERMISSIONLESS once the delay has elapsed, mirroring
    /// `executeUpdateBucketInfo` — but {requireConfirmedBlacklisted} still gates the outcome, so
    /// anyone may trigger it but nobody can make it succeed against an account no longer
    /// confirmed blacklisted, or into a `to` that is itself blacklisted (fail-closed if BucketInfo
    /// is unreachable for that check — see {requireNotBlacklistedFailClosed}). Does NOT move any
    /// tokens — the caller performs the one line that must remain in its own bytecode
    /// (`super._update(account, to, beforeBalance)` / the ERC-1155 balance write) immediately
    /// after this call returns, before any further state change, so a revert anywhere in that
    /// sequence still unwinds the whole transaction including this function's `execute()`
    /// consumption of the timelock slot and its emitted event.
    /// @dev `afterBalance` in the emitted event is hardcoded to `0`, not re-read via a second
    /// `balanceOf` call: seizure always sweeps `account`'s ENTIRE current balance to `to`, so the
    /// post-seizure balance is provably always exactly zero — computing it here is deterministic,
    /// not an approximation, and removes a call the caller would otherwise have to make twice.
    function executeSeizure(
        mapping(address => TimelockedAdmin.SeizureTimelock) storage seizureTimelocks,
        IBucketInfo bucketInfo,
        address account,
        uint256 beforeBalance
    ) public returns (address to) {
        bytes32 documentHash;
        (to, documentHash) = seizureTimelocks[account].execute();

        requireConfirmedBlacklisted(bucketInfo, account);
        requireNotBlacklistedFailClosed(bucketInfo, to);
        if (beforeBalance == 0) revert NothingToSeize(account);

        emit SeizureExecuted(account, to, documentHash, beforeBalance, 0);
    }
}
