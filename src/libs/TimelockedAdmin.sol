// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// TimelockedAdmin — one propose/execute/cancel module, reused everywhere a
// timelock is needed in this system.
//
// This library stores a single pending value plus its execution timestamp
// (`eta`) and enforces that `execute` cannot succeed before `eta`. It does
// NOT enforce who may call propose/execute/cancel -- every caller in this
// codebase gates that itself, because the callers need different access
// rules, and folding authorization into a library shared this widely would
// force one rule onto all of them.
//
// Known call sites and why each needs its OWN access-control wrapper even
// though all of them share this same storage/timing engine:
//  - BucketInfo.sol: setPlatformFee / setPriceFeed / batchSetPriceFeeds /
//    whitelist ADDITIONS -- propose and execute both `onlyOwner` (the
//    platform). Whitelist REMOVAL and setTokenPrice stay untimelocked by
//    design and do not use this library at all.
//  - BucketVaultBase.sol updateBucketInfo: propose is gated on the CURRENT
//    bucketInfo's owner, NOT this vault's onlyOwner. Veto (= cancel) is
//    gated on the VAULT owner instead, and execute is permissionless once
//    the delay has elapsed and no veto arrived.
//  - ActiveBucket.sol / PassiveBucket.sol / PureMembership.sol upgrade queue:
//    propose (`queueUpgrade`) and cancel are `onlyOwner` (the vault's
//    customer-owner); `execute` is folded into `_authorizeUpgrade` itself,
//    called via UUPS's own `upgradeToAndCall` entry point, and additionally
//    requires a live ImplementationRegistry approval re-checked at that same
//    moment -- a check this library cannot express, since it knows nothing
//    about the registry.
//  - ActiveBucket.sol / PassiveBucket.sol / PureMembership.sol seizure:
//    propose and cancel are gated on `IBucketInfo(bucketInfo).owner()` (the
//    PLATFORM, not this contract's own `onlyOwner`) -- the same "gated on
//    BucketInfo's owner, not this vault's" pattern `proposeUpdateBucketInfo`
//    already uses, since seizure is a platform compliance action, not a
//    vault-owner action. `execute` re-verifies `isBlacklisted(account)` at
//    the moment of execution -- a check this library cannot express -- and,
//    unlike every other call site above, an unreachable BucketInfo at that
//    moment must ABORT the seizure rather than proceed. See each contract's
//    own COMPLIANCE -- SEIZURE section.
//
// This library therefore owns exactly: "is a value pending, and has enough
// time passed to apply it." Nothing about WHO, and nothing about what ELSE
// must be true. That split is deliberate -- folding registry approval or
// owner checks in here would make this module's behaviour depend on which
// caller it is compiled into, defeating the point of sharing it.
// ============================================================

library TimelockedAdmin {
    error NoProposalPending();
    error TimelockNotElapsed(uint256 eta, uint256 currentTimestamp);

    /// @notice A pending `address`-valued change (e.g. a price feed, a registry-approved
    /// implementation, a new BucketInfo pointer) plus the timestamp at which it may be executed.
    /// `eta == 0` means "nothing pending" -- callers must never construct a real proposal with
    /// `eta == 0`.
    struct AddressTimelock {
        address pending;
        uint256 eta;
    }

    /// @notice The `uint256` analogue of {AddressTimelock} (e.g. a proposed
    /// platform fee).
    struct UintTimelock {
        uint256 pending;
        uint256 eta;
    }

    /// @dev Overwrites any existing proposal in this slot -- "replaces the
    /// pending transfer if there is one", the same semantics OpenZeppelin's
    /// own Ownable2Step.transferOwnership uses for its single pending slot.
    function propose(AddressTimelock storage self, address newValue, uint256 delay) internal {
        self.pending = newValue;
        self.eta = block.timestamp + delay;
    }

    /// @dev Reverts if nothing is pending or the delay has not elapsed.
    /// Clears the slot before returning, so a proposal can only ever be
    /// executed once -- re-entering or calling twice hits NoProposalPending.
    function execute(AddressTimelock storage self) internal returns (address value) {
        if (self.eta == 0) revert NoProposalPending();
        if (block.timestamp < self.eta) revert TimelockNotElapsed(self.eta, block.timestamp);
        value = self.pending;
        delete self.pending;
        delete self.eta;
    }

    /// @dev Clears a pending proposal without applying it.
    function cancel(AddressTimelock storage self) internal {
        delete self.pending;
        delete self.eta;
    }

    function hasPending(AddressTimelock storage self) internal view returns (bool) {
        return self.eta != 0;
    }

    // ---------------------------------------------------------------
    // uint256-valued proposals
    // ---------------------------------------------------------------

    function propose(UintTimelock storage self, uint256 newValue, uint256 delay) internal {
        self.pending = newValue;
        self.eta = block.timestamp + delay;
    }

    function execute(UintTimelock storage self) internal returns (uint256 value) {
        if (self.eta == 0) revert NoProposalPending();
        if (block.timestamp < self.eta) revert TimelockNotElapsed(self.eta, block.timestamp);
        value = self.pending;
        delete self.pending;
        delete self.eta;
    }

    function cancel(UintTimelock storage self) internal {
        delete self.pending;
        delete self.eta;
    }

    function hasPending(UintTimelock storage self) internal view returns (bool) {
        return self.eta != 0;
    }

    struct SeizureTimelock {
        address to;
        bytes32 documentHash;
        uint256 eta;
    }

    /// @dev Overwrites any existing proposal for this account, mirroring every other `propose`
    /// in this library ("replaces the pending transfer if there is one").
    function propose(SeizureTimelock storage self, address to, bytes32 documentHash, uint256 delay) internal {
        self.to = to;
        self.documentHash = documentHash;
        self.eta = block.timestamp + delay;
    }

    function execute(SeizureTimelock storage self) internal returns (address to, bytes32 documentHash) {
        if (self.eta == 0) revert NoProposalPending();
        if (block.timestamp < self.eta) revert TimelockNotElapsed(self.eta, block.timestamp);
        to = self.to;
        documentHash = self.documentHash;
        delete self.to;
        delete self.documentHash;
        delete self.eta;
    }

    function cancel(SeizureTimelock storage self) internal {
        delete self.to;
        delete self.documentHash;
        delete self.eta;
    }

    function hasPending(SeizureTimelock storage self) internal view returns (bool) {
        return self.eta != 0;
    }
}
