// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IBucketInfo} from "../interfaces/IBucketInfo.sol";
import {TimelockedAdmin} from "../libs/TimelockedAdmin.sol";

/// @notice Validates and records platform-authorized account seizures.
library SeizureLib {
    using TimelockedAdmin for TimelockedAdmin.SeizureTimelock;

    error UnauthorizedSeizure();
    error NotBlacklisted(address account);
    error BucketInfoUnreachableForSeizure(address account);
    error NothingToSeize(address account);
    error ZeroAddress();
    error Blacklisted(address account);

    event SeizureProposed(address indexed account, address indexed to, bytes32 documentHash, uint256 eta);
    event SeizureCancelled(address indexed account);
    event SeizureExecuted(
        address indexed account, address indexed to, bytes32 documentHash, uint256 beforeBalance, uint256 afterBalance
    );

    function requirePlatformOwner(IBucketInfo bucketInfo) public view {
        if (msg.sender != bucketInfo.owner()) revert UnauthorizedSeizure();
    }

    /// @dev Reverts unless the account is confirmed blacklisted.
    function requireConfirmedBlacklisted(IBucketInfo bucketInfo, address account) public view {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            if (!blacklisted) revert NotBlacklisted(account);
        } catch {
            revert BucketInfoUnreachableForSeizure(account);
        }
    }

    /// @dev Reverts if the destination is blacklisted or BucketInfo is unreachable.
    function requireNotBlacklistedFailClosed(IBucketInfo bucketInfo, address account) public view {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            if (blacklisted) revert Blacklisted(account);
        } catch {
            revert Blacklisted(account);
        }
    }

    /// @notice Propose seizing a blacklisted account's balance.
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

    /// @notice Cancel a pending seizure proposal.
    function cancelSeizure(
        mapping(address => TimelockedAdmin.SeizureTimelock) storage seizureTimelocks,
        IBucketInfo bucketInfo,
        address account
    ) public {
        requirePlatformOwner(bucketInfo);
        seizureTimelocks[account].cancel();
        emit SeizureCancelled(account);
    }

    /// @notice Validate and consume a matured seizure proposal.
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
