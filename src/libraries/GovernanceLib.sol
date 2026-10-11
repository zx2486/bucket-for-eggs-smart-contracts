// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {IImplementationRegistry} from "../interfaces/IImplementationRegistry.sol";
import {TimelockedAdmin} from "../libs/TimelockedAdmin.sol";

/// @notice Shared vault governance operations.

library GovernanceLib {
    using TimelockedAdmin for TimelockedAdmin.AddressTimelock;

    error ZeroAddress();
    error UnauthorizedBucketInfoUpdate();
    error UpgradeImplementationMismatch(address expected, address provided);
    error UpgradeNotApproved(address implementation);
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed newBucketInfo, address indexed proposedBy, uint256 eta
    );

    event UpgradeQueued(address indexed vault, address indexed newImplementation, uint256 eta);

    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);

    event UpgradeCancelled(address indexed vault, address indexed implementation);

    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);

    /// @notice Propose a BucketInfo contract address update.
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

    /// @notice Authorize a queued UUPS upgrade.
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

    /// @notice Queue a UUPS upgrade.
    function queueUpgrade(
        TimelockedAdmin.AddressTimelock storage upgradeTimelock,
        address newImplementation,
        uint256 delay
    ) public {
        if (newImplementation == address(0)) revert ZeroAddress();

        upgradeTimelock.propose(newImplementation, delay);

        emit UpgradeQueued(address(this), newImplementation, block.timestamp + delay);
    }

    /// @notice Cancel a pending BucketInfo update.
    function vetoUpdateBucketInfo(TimelockedAdmin.AddressTimelock storage bucketInfoUpdateTimelock) public {
        address proposed = bucketInfoUpdateTimelock.pending;
        bucketInfoUpdateTimelock.cancel();
        emit BucketInfoUpdateVetoed(proposed, msg.sender);
    }

    /// @notice Cancel a pending upgrade.
    function cancelUpgrade(TimelockedAdmin.AddressTimelock storage upgradeTimelock) public {
        address pending = upgradeTimelock.pending;
        upgradeTimelock.cancel();
        emit UpgradeCancelled(address(this), pending);
    }

    /// @notice Execute a matured BucketInfo update and return the new address.
    function executeUpdateBucketInfo(
        TimelockedAdmin.AddressTimelock storage bucketInfoUpdateTimelock,
        address oldBucketInfo
    ) public returns (address newBucketInfo) {
        newBucketInfo = bucketInfoUpdateTimelock.execute();
        emit BucketInfoUpdated(oldBucketInfo, newBucketInfo, msg.sender);
    }
}
