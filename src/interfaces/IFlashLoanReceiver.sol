// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title IFlashLoanReceiver
 * @notice Interface for flash loan callback in ActiveBucket
 */
interface IFlashLoanReceiver {
    /// @notice Called by ActiveBucket after transferring flash loaned tokens
    /// @param initiator The address that initiated the flash loan
    /// @param token The token address being flash loaned
    /// @param amount The amount of tokens flash loaned
    /// @param fee The fee amount that must be repaid on top of the principal
    /// @param data Arbitrary data passed from the flash loan caller
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external;
}
