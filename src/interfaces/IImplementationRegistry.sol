// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Interface to the platform implementation registry.
interface IImplementationRegistry {
    /// @notice Contract types with separately managed implementations.
    enum Kind {
        ActiveBucket,
        PassiveBucket,
        PureMembership
    }

    /// @notice Emitted when an implementation is approved.
    event ImplementationApproved(Kind indexed kind, address indexed implementation);

    /// @notice Emitted when an implementation approval is revoked.
    event ImplementationRevoked(Kind indexed kind, address indexed implementation);

    /// @notice Emitted when a factory's authorization changes.
    event FactoryAuthorizationChanged(address indexed factory, bool authorized);

    /// @notice Approve an implementation for a contract type.
    function approve(Kind kind, address implementation) external;

    /// @notice Revoke an implementation approval.
    function revoke(Kind kind, address implementation) external;

    /// @notice Whether an implementation is approved for a contract type.
    function isApproved(Kind kind, address implementation) external view returns (bool);

    /// @notice Authorize or de-authorize a vault factory.
    function setAuthorizedFactory(address factory, bool authorized) external;

    /// @notice Whether a factory is authorized.
    function isAuthorizedFactory(address factory) external view returns (bool);
}
