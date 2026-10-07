// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IImplementationRegistry} from "../interfaces/IImplementationRegistry.sol";

// ============================================================
// FactoryAuthLib — task #33 (W1.7 direct-proxy-bypass fix) EIP-170 size relief, same rationale
// as RebalanceFeeLib.sol's doc comment: an `external` library function's bytecode is deployed
// once, separately, instead of being copied into the caller's own runtime bytecode.
//
// `forge build --sizes` after this session's Design B fix landed showed `PassiveBucket` at
// -18 B runtime margin (24,594 B against the 24,576 B EIP-170 limit) -- a regression from the
// +150 B margin recorded at the end of W5 (`W5-SC-NEWFEATURES-REPORT.md` §3), caused by the new
// inline `if (!REGISTRY.isAuthorizedFactory(msg.sender)) revert UnauthorizedInitializer();`
// check added to `initialize()`. That report's own §9 flagged this exact margin as having "no
// planned further size-relief extraction queued for it" -- this is that extraction.
//
// This library's `UnauthorizedInitializer()` error is declared independently of
// `BucketVaultBase.UnauthorizedInitializer` and `PureMembership.UnauthorizedInitializer`, but
// produces a BYTE-IDENTICAL selector: Solidity computes a custom error's 4-byte selector from
// `bytes4(keccak256("UnauthorizedInitializer()"))` -- the name and (empty) parameter list alone,
// never the declaring contract or library. So every existing test asserting
// `vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector)` (or the `PureMembership`
// equivalent) keeps passing unmodified: the revert data this library produces when
// `requireAuthorizedFactory` reverts is indistinguishable from the inline check it replaces, and
// Solidity's default (non-try/catch) external-call semantics bubble that revert data up through
// the caller unchanged.
// ============================================================

library FactoryAuthLib {
    /// @dev Byte-identical selector to `BucketVaultBase.UnauthorizedInitializer` and
    /// `PureMembership.UnauthorizedInitializer` -- see file-level doc comment above.
    error UnauthorizedInitializer();

    /// @notice Reverts with `UnauthorizedInitializer()` unless `caller` is a factory the
    /// platform has authorized in `registry`. Pure relocation of the inline check previously in
    /// each vault's `initialize()` -- no behavior change, only where the bytecode lives.
    function requireAuthorizedFactory(IImplementationRegistry registry, address caller) external view {
        if (!registry.isAuthorizedFactory(caller)) revert UnauthorizedInitializer();
    }
}
