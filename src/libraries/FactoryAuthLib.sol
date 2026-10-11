// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IImplementationRegistry} from "../interfaces/IImplementationRegistry.sol";

/// @notice Validates factory authorization during vault initialization.

library FactoryAuthLib {
    error UnauthorizedInitializer();

    /// @notice Reverts with `UnauthorizedInitializer()` unless `caller` is a factory the
    /// platform has authorized in `registry`.
    function requireAuthorizedFactory(IImplementationRegistry registry, address caller) external view {
        if (!registry.isAuthorizedFactory(caller)) revert UnauthorizedInitializer();
    }
}
