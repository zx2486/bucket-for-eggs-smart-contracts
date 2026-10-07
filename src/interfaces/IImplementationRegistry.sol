// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title IImplementationRegistry
 * @notice Frozen interface for the platform-owned {ImplementationRegistry} contract (W3.10).
 * @dev Frozen ahead of the concrete contract per 04-CONTRACTS-IMPLEMENTATION-PLAN.md §8.4 note 2:
 * this is a cross-agent artefact (consumed by every vault's `_authorizeUpgrade` and by the
 * adversarial test suite), so its shape is decided once, here, rather than drifting while the
 * three vault call sites and the concrete registry are written.
 *
 * Namespacing (`09-DECISION-LOG.md` §10.1a): approval is per contract KIND -- `ActiveBucket`,
 * `PassiveBucket`, `PureMembership` are three SEPARATE namespaces, never one global
 * `mapping(address => bool)`. An implementation approved for one kind must never read as
 * approved for another; `PureMembership` is an ERC-1155 with different storage from an ERC-20
 * vault, so a cross-kind install is a storage-layout catastrophe the 48h timelock would
 * faithfully wait to deliver.
 */
interface IImplementationRegistry {
    /// @notice The three contract kinds this registry namespaces approvals by. Extending this
    /// enum is additive (new kinds append) and never reorders existing members, since the
    /// numeric value is what every vault's immutable `REGISTRY_KIND` is compiled against.
    enum Kind {
        ActiveBucket,
        PassiveBucket,
        PureMembership
    }

    /// @notice Emitted when the platform approves `implementation` for `kind`.
    event ImplementationApproved(Kind indexed kind, address indexed implementation);

    /// @notice Emitted when the platform revokes a previously-approved `implementation` for
    /// `kind`. This is what lets a watcher on an open 48h upgrade window learn that the pending
    /// upgrade has just become unexecutable -- nothing on the vault itself changes when
    /// approval is revoked (04 §5.6.1c).
    event ImplementationRevoked(Kind indexed kind, address indexed implementation);

    /// @notice Emitted when the platform authorizes or de-authorizes `factory` as a legitimate
    /// caller of a vault's `initialize()`. Task #33 (W1.7 direct-proxy-bypass fix): this is a
    /// single global namespace, deliberately NOT split by `Kind` like {_approved} above --
    /// unlike implementation approval, "is this address a factory we deployed" is not a
    /// per-vault-type question, and a factory that creates `ActiveBucket`s is never also
    /// expected to create `PureMembership`s under a different identity.
    event FactoryAuthorizationChanged(address indexed factory, bool authorized);

    /// @notice Approve `implementation` for `kind`. Immediate, no timelock -- the customer-side
    /// 48 hours already gives investors an exit window, so a second delay on approval would only
    /// slow security fixes (`09-DECISION-LOG.md` §10.1a). Platform-owner-gated by the concrete
    /// contract.
    function approve(Kind kind, address implementation) external;

    /// @notice Revoke a previously-approved `implementation` for `kind`. Immediate, no timelock,
    /// for the same reason as {approve}. Platform-owner-gated by the concrete contract.
    function revoke(Kind kind, address implementation) external;

    /// @notice Pure storage read, never reverts on an unknown (kind, implementation) pair --
    /// mirrors the fail-closed shape INV-7 requires of `isBlacklisted`. A vault's
    /// `_authorizeUpgrade` calls this at EXECUTION time, not just at proposal time, so a
    /// mid-window revocation actually blocks the upgrade (04 §10.1, test 3).
    function isApproved(Kind kind, address implementation) external view returns (bool);

    /// @notice Authorize or de-authorize `factory` as a legitimate deployer of new vault
    /// proxies. Task #33: each vault's `initialize()` checks this at call time so that an
    /// `ERC1967Proxy` deployed directly against the shared implementation (bypassing the
    /// factory entirely) cannot self-initialize with attacker-controlled constructor-equivalent
    /// parameters (most dangerously, an attacker-owned `BucketInfo`, defeating the 00:44 oracle
    /// protection). Platform-owner-gated by the concrete contract, immediate, no timelock -- same
    /// rationale as {approve}: this is a platform admin action, not a customer-facing one, so no
    /// exit window is owed.
    function setAuthorizedFactory(address factory, bool authorized) external;

    /// @notice Pure storage read, never reverts for an unknown factory address -- Solidity's
    /// default mapping value (`false`) already gives the fail-closed answer: an address nobody
    /// explicitly authorized is never treated as a legitimate factory.
    function isAuthorizedFactory(address factory) external view returns (bool);
}
