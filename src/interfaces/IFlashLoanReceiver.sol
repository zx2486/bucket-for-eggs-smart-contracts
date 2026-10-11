// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Callback interface for flash-loan receivers.
interface IFlashLoanReceiver {
    /// @notice Called after the flash-loaned tokens are transferred.
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external;
}
