// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IImplementationRegistry} from "./interfaces/IImplementationRegistry.sol";

/**
 * @title ImplementationRegistry
 * @notice Platform-owned whitelist of UUPS implementation addresses a vault may upgrade TO.
 * The platform decides WHAT code may run (this contract), the customer decides WHETHER and WHEN
 * their vault adopts it (the vault's own 48h timelock), and investors get a 48-hour window to exit.
 *
 * @dev Deliberately NOT upgradeable, NOT a proxy — same product promise as `BucketInfo`: the
 * contract that decides what code may run must not itself be swappable. A redeploy is the
 * remedy, and it is cheap here because nothing else stores state in it.
 *
 * `Ownable2Step`, platform-owned -- one of exactly two two-step contracts in the system, the
 * other being `BucketInfo`.
 *
 * Fail-closed by construction: a vault pointing at a stale or wrong registry (or at an address
 * with no code) cannot upgrade at all -- `isApproved` on an address with no code either reverts
 * the call (caught by the vault, treated as "not approved") or the call target simply never
 * returns `true`. The failure mode of a misconfigured registry pointer is "no upgrades", never
 * "any upgrade".
 */
contract ImplementationRegistry is Ownable2Step, IImplementationRegistry {
    error RenounceOwnershipDisabled();

    /// @notice kind => implementation => approved. Three separate namespaces (one per
    /// `IImplementationRegistry.Kind` member) inside one mapping, keyed by the enum's `uint8`
    /// discriminant, rather than a single global `mapping(address => bool)`.
    mapping(Kind => mapping(address => bool)) private _approved;

    /// @notice Every implementation ever approved for `kind`, in approval order, for admin
    /// dashboard enumeration. Entries are never removed on revoke -- {isApproved} reflects the
    /// live truth, while this array lets a dashboard distinguish "approved, then revoked" from
    /// "never approved".
    mapping(Kind => address[]) private _everApproved;

    /// @notice factory address => authorized.
    mapping(address => bool) private _authorizedFactories;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IImplementationRegistry
    function approve(Kind kind, address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddressImplementation();
        if (!_approved[kind][implementation]) {
            _approved[kind][implementation] = true;
            _everApproved[kind].push(implementation);
        }
        emit ImplementationApproved(kind, implementation);
    }

    /// @inheritdoc IImplementationRegistry
    function revoke(Kind kind, address implementation) external onlyOwner {
        _approved[kind][implementation] = false;
        emit ImplementationRevoked(kind, implementation);
    }

    /// @inheritdoc IImplementationRegistry
    /// @dev Pure storage read; never reverts. An unknown (kind, implementation) pair simply
    /// returns false.
    function isApproved(Kind kind, address implementation) external view returns (bool) {
        return _approved[kind][implementation];
    }

    /// @notice Every implementation ever approved for `kind`, in approval order. Does not
    /// indicate current approval status -- cross-reference with {isApproved} for that.
    function everApproved(Kind kind) external view returns (address[] memory) {
        return _everApproved[kind];
    }

    /// @inheritdoc IImplementationRegistry
    function setAuthorizedFactory(address factory, bool authorized) external onlyOwner {
        if (factory == address(0)) revert ZeroAddressFactory();
        _authorizedFactories[factory] = authorized;
        emit FactoryAuthorizationChanged(factory, authorized);
    }

    /// @inheritdoc IImplementationRegistry
    /// @dev Pure storage read; never reverts. An unauthorized address simply returns false.
    function isAuthorizedFactory(address factory) external view returns (bool) {
        return _authorizedFactories[factory];
    }

    /// @dev Thrown by {approve} when the implementation address is zero.
    error ZeroAddressImplementation();

    /// @dev Thrown by {setAuthorizedFactory} when the factory address is zero.
    error ZeroAddressFactory();

    /// @notice Always reverts; ownership of this registry can never be renounced.
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }
}
