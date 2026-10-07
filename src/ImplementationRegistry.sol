// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IImplementationRegistry} from "./interfaces/IImplementationRegistry.sol";

/**
 * @title ImplementationRegistry
 * @notice Platform-owned whitelist of UUPS implementation addresses a vault may upgrade TO.
 * W3.10 (04-CONTRACTS-IMPLEMENTATION-PLAN.md §5.6.1a). New contract -- did not exist before
 * `09-DECISION-LOG.md` §10.1 answered "who may upgrade a vault" as: the platform decides WHAT
 * code may run (this contract), the customer decides WHETHER and WHEN their vault adopts it
 * (the vault's own 48h timelock, W3.3), and investors get the 48-hour window to exit.
 *
 * @dev Deliberately NOT upgradeable, NOT a proxy. Same product promise as `BucketInfo` (A2,
 * root CLAUDE.md §8): the contract that decides what code may run must not itself be swappable.
 * A redeploy is the remedy, and it is cheap here because nothing else stores state in it.
 *
 * `Ownable2Step`, platform-owned -- one of exactly TWO two-step contracts in the system, the
 * other being `BucketInfo`. D-3 (`09-DECISION-LOG.md` §11.2, 2026-09-17) narrowed `Ownable2Step`
 * to `BucketInfo` ALONE among the pre-existing contracts and removed it from the three
 * factories -- it does NOT reach this contract, because this is new work created by a later
 * decision (§10.1a) and nobody hands a registry to a customer inside a transaction, so the
 * creation-time-handoff trap that bars `Ownable2Step` from the vaults (04 §5.6.3) does not apply
 * here.
 *
 * Fail-closed by construction (04 §5.6.1a): a vault pointing at a stale or wrong registry (or at
 * an address with no code) cannot upgrade at all -- `isApproved` on an address with no code
 * either reverts the call (caught by the vault, treated as "not approved") or the call target
 * simply never returns `true`. The failure mode of a misconfigured registry pointer is "no
 * upgrades", never "any upgrade".
 */
contract ImplementationRegistry is Ownable2Step, IImplementationRegistry {
    /// @dev Thrown by {renounceOwnership}, which is always disabled here. Q14.2
    /// (`10-BLOCKER-14-DECOMPOSITION-ANSWER.md:6-7`): "If we want to make the contract
    /// ownerless, we will change the owner into a DAO contract (not in scope yet)" --
    /// renouncing is never the path to that, on any contract in this system.
    error RenounceOwnershipDisabled();

    /// @notice kind => implementation => approved. Three separate namespaces (one per
    /// `IImplementationRegistry.Kind` member) inside one mapping, keyed by the enum's `uint8`
    /// discriminant -- NOT a single global `mapping(address => bool)`, which is the defect this
    /// contract exists to prevent (04 §5.6.1a).
    mapping(Kind => mapping(address => bool)) private _approved;

    /// @notice Every implementation ever approved for `kind`, in approval order, for the admin
    /// dashboard's enumeration need (04 §9's view-contract table). Entries are never removed on
    /// revoke -- `isApproved` is the live truth; this array is a historical index, and a revoked
    /// entry stays discoverable here precisely so a dashboard can show "approved, then revoked"
    /// rather than making revocation indistinguishable from "never approved".
    mapping(Kind => address[]) private _everApproved;

    /// @notice factory address => authorized. Task #33 (W1.7 direct-proxy-bypass fix):
    /// deliberately ONE global mapping, not namespaced by `Kind` like {_approved} -- see
    /// {IImplementationRegistry.FactoryAuthorizationChanged}'s doc comment for why that is the
    /// right shape here and not a repeat of the mistake {_approved} exists to prevent.
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
    /// @dev Pure storage read. Never reverts, including for an unknown (kind, implementation)
    /// pair -- Solidity's default mapping value (`false`) already gives the fail-closed answer,
    /// so there is nothing to guard.
    function isApproved(Kind kind, address implementation) external view returns (bool) {
        return _approved[kind][implementation];
    }

    /// @notice Every implementation ever approved for `kind`, in approval order (admin
    /// dashboard). Does not indicate CURRENT approval status -- cross-reference with
    /// {isApproved} for that; see {_everApproved}'s doc comment for why revoked entries stay.
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
    /// @dev Pure storage read. Never reverts, including for an address never authorized --
    /// Solidity's default mapping value (`false`) already gives the fail-closed answer.
    function isAuthorizedFactory(address factory) external view returns (bool) {
        return _authorizedFactories[factory];
    }

    /// @dev Thrown by {approve} for the zero address -- a "no implementation" approval would be
    /// indistinguishable from every vault's zero-initialized "nothing queued" state.
    error ZeroAddressImplementation();

    /// @dev Thrown by {setAuthorizedFactory} for the zero address, same rationale as
    /// {ZeroAddressImplementation} -- an "authorize nobody" call would be indistinguishable from
    /// the default unauthorized state.
    error ZeroAddressFactory();

    /// @notice Always reverts. Q14.2, universal across every contract that has an owner: this
    /// registry must never become ownerless via renunciation -- only via an explicit future
    /// decision to move it to a DAO (not in scope, per the client answer cited above).
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }
}
