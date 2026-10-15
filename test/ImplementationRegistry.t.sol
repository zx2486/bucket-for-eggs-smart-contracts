// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

contract ImplementationRegistryTest is Test {
    ImplementationRegistry internal registry;

    address internal owner;
    address internal user1;
    address internal user2;

    address internal implA;
    address internal implB;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        registry = new ImplementationRegistry(owner);

        implA = makeAddr("implA");
        implB = makeAddr("implB");
    }

    function test_Approve_SetsIsApprovedTrue() public {
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));

        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);

        assertTrue(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
    }

    function test_Approve_EmitsImplementationApproved() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IImplementationRegistry.ImplementationApproved(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
    }

    function test_RevertApprove_ZeroAddress() public {
        vm.expectRevert(ImplementationRegistry.ZeroAddressImplementation.selector);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, address(0));
    }

    function test_RevertApprove_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
    }

    /// @dev `isApproved` on a never-touched (kind, implementation) pair must return `false`
    /// rather than revert -- the fail-closed contract this registry promises (source header:
    /// "the failure mode of a misconfigured registry pointer is 'no upgrades', never 'any
    /// upgrade'"). This is the vacuous-default case, distinct from an explicit revoke.
    function test_IsApproved_FalseForNeverApproved() public view {
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.PassiveBucket, implA));
    }

    function test_Approve_DoesNotCrossKindNamespaces() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);

        assertTrue(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.PassiveBucket, implA));
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.PureMembership, implA));
    }

    function test_Approve_SameAddressIndependentAcrossAllThreeKinds() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        assertTrue(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.PassiveBucket, implA));
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.PureMembership, implA));

        registry.approve(IImplementationRegistry.Kind.PassiveBucket, implA);
        assertTrue(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
        assertTrue(registry.isApproved(IImplementationRegistry.Kind.PassiveBucket, implA));
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.PureMembership, implA));

        registry.approve(IImplementationRegistry.Kind.PureMembership, implA);
        assertTrue(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
        assertTrue(registry.isApproved(IImplementationRegistry.Kind.PassiveBucket, implA));
        assertTrue(registry.isApproved(IImplementationRegistry.Kind.PureMembership, implA));
    }

    function test_Revoke_OnlyClearsItsOwnKind() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.approve(IImplementationRegistry.Kind.PassiveBucket, implA);

        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);

        assertFalse(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
        assertTrue(
            registry.isApproved(IImplementationRegistry.Kind.PassiveBucket, implA),
            "revoking one kind must not clear a different kind's approval for the same address"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                REVOKE
    //////////////////////////////////////////////////////////////*/

    function test_Revoke_SetsIsApprovedFalse() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);

        assertFalse(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
    }

    function test_Revoke_EmitsImplementationRevoked() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IImplementationRegistry.ImplementationRevoked(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);
    }

    /// @dev Revoking something never approved is a no-op, not a revert -- there is no existence
    /// check in {ImplementationRegistry.revoke}, mirroring the fail-closed default everywhere
    /// else in this contract.
    function test_Revoke_NoOpWhenNeverApproved() public {
        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));
    }

    function test_RevertRevoke_NotOwner() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);
    }

    /*//////////////////////////////////////////////////////////////
                            EVERAPPROVED HISTORY
    //////////////////////////////////////////////////////////////*/
    // src/ImplementationRegistry.sol:47-52 -- entries are never removed on revoke; `isApproved`
    // is the live truth, `everApproved` is a historical index so a revoked entry stays
    // discoverable ("approved, then revoked" vs. indistinguishable from "never approved").

    function test_EverApproved_ListsApprovalsInOrder() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implB);

        address[] memory history = registry.everApproved(IImplementationRegistry.Kind.ActiveBucket);
        assertEq(history.length, 2);
        assertEq(history[0], implA);
        assertEq(history[1], implB);
    }

    function test_EverApproved_SurvivesRevoke() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);

        // Live truth says no.
        assertFalse(registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA));

        // Historical index still remembers it was approved once.
        address[] memory history = registry.everApproved(IImplementationRegistry.Kind.ActiveBucket);
        assertEq(history.length, 1);
        assertEq(history[0], implA);
    }

    /// @dev CORRECTED after a real run against source (root CLAUDE.md hard rule 5): this test
    /// originally asserted that approve -> revoke -> approve again produces ONE history entry.
    /// That assertion was wrong and `forge test` caught it --
    /// `ImplementationRegistry.sol:59`'s guard is `if (!_approved[kind][implementation])`, which
    /// is `false` again once {revoke} has run, so the second {approve} call legitimately pushes
    /// a SECOND entry. That is correct, intended behaviour, not a bug: `_everApproved`'s own doc
    /// comment (`ImplementationRegistry.sol:47-52`) wants the dashboard to be able to show
    /// "approved, then revoked, then approved again" as two distinct approval events, not
    /// collapse them into one. This test now asserts THAT.
    function test_EverApproved_PushesNewEntryOnReapprovalAfterRevoke() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.revoke(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);

        address[] memory history = registry.everApproved(IImplementationRegistry.Kind.ActiveBucket);
        assertEq(
            history.length,
            2,
            "a revoke-then-reapprove cycle is two distinct approval events and both must be visible in the history"
        );
        assertEq(history[0], implA);
        assertEq(history[1], implA);
        assertTrue(
            registry.isApproved(IImplementationRegistry.Kind.ActiveBucket, implA),
            "the live truth after the second approve must be approved again"
        );
    }

    /// @dev The guard's ACTUAL job: calling {approve} twice in a row on an address that is
    /// ALREADY approved (no intervening {revoke}) must not push a duplicate entry. This is what
    /// `ImplementationRegistry.sol:59`'s `if (!_approved[kind][implementation])` check protects
    /// against, distinct from the revoke-then-reapprove case above.
    function test_EverApproved_NoDuplicateOnRepeatedApprovalWhileStillApproved() public {
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, implA);

        address[] memory history = registry.everApproved(IImplementationRegistry.Kind.ActiveBucket);
        assertEq(
            history.length,
            1,
            "calling approve() twice while already approved (no revoke in between) must not duplicate the history entry"
        );
        assertEq(history[0], implA);
    }

    function test_EverApproved_EmptyForUntouchedKind() public view {
        address[] memory history = registry.everApproved(IImplementationRegistry.Kind.PureMembership);
        assertEq(history.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    OWNABLE2STEP / RENOUNCEOWNERSHIP
    //////////////////////////////////////////////////////////////*/
    // Root CLAUDE.md §8: this registry is one of exactly TWO Ownable2Step contracts in the
    // system (the other is BucketInfo) -- D-3 does not reach it. Mirrors
    // BucketInfo.t.sol's test_TransferOwnershipIsTwoStep /
    // test_RevertTransferOwnershipAcceptByWrongAccount / test_RenounceOwnershipAlwaysReverts.

    function test_TransferOwnershipIsTwoStep() public {
        registry.transferOwnership(user1);

        // Proposed, not yet transferred.
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), user1);

        vm.prank(user1);
        registry.acceptOwnership();

        assertEq(registry.owner(), user1);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_RevertTransferOwnershipAcceptByWrongAccount() public {
        registry.transferOwnership(user1);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user2));
        registry.acceptOwnership();
    }

    /// @dev Manual pre-fix-must-fail evidence for hard rule 13, matching BucketInfo.t.sol's own
    /// analogous test: on a hypothetical pre-fix `ImplementationRegistry` using plain
    /// `Ownable2Step` with NO `renounceOwnership` override, this assertion would fail because
    /// `renounceOwnership()` would succeed and `owner()` would become `address(0)`. The override
    /// at `ImplementationRegistry.sol:94-96` is what makes it revert instead.
    function test_RenounceOwnershipAlwaysReverts() public {
        vm.expectRevert(ImplementationRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();

        assertEq(registry.owner(), owner);
    }

    function test_RevertRenounceOwnership_NotOwnerStillRevertsWithDisabledError() public {
        // Even a non-owner calling renounceOwnership hits the override before any onlyOwner
        // check would run, since renounceOwnership carries no onlyOwner modifier of its own in
        // OZ's Ownable -- it is guarded implicitly by only ever being callable by the owner in
        // normal usage, but this override makes the point moot by disabling the function
        // entirely regardless of caller.
        vm.prank(user1);
        vm.expectRevert(ImplementationRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();
    }
}
