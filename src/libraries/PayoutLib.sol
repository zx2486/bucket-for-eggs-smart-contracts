// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Transfers redemption payouts and updates the held-token registry.
library PayoutLib {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error ETHTransferFailed();
    event TokenReturned(address indexed user, address indexed token, uint256 amount);

    /// @notice Add or remove a token based on its current balance.
    function syncHeldTokenByBalance(EnumerableSet.AddressSet storage heldTokens, address token) public {
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (balance == 0) {
            heldTokens.remove(token);
        } else {
            heldTokens.add(token);
        }
    }

    /// @notice Update held-token status for every whitelisted token.
    function syncAllHeldTokensFromWhitelist(
        EnumerableSet.AddressSet storage heldTokens,
        address[] memory whitelistedTokens
    ) public {
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            syncHeldTokenByBalance(heldTokens, whitelistedTokens[i]);
        }
    }

    /// @notice Transfer redemption payouts and update held-token status.
    function payoutAndSync(
        EnumerableSet.AddressSet storage heldTokens,
        // `to` is never attacker-controlled: every current caller passes msg.sender or a
        // msg.sender-derived redeemer, which can never be address(0) on-chain.
        // forge-lint: disable-next-line(missing-zero-check)
        address to,
        address[] memory tokens,
        uint256[] memory returnAmounts
    ) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = returnAmounts[i];
            if (amount > 0) {
                address token = tokens[i];
                if (token == address(0)) {
                    (bool success,) = to.call{value: amount}("");
                    if (!success) revert ETHTransferFailed();
                } else {
                    IERC20(token).safeTransfer(to, amount);
                }

                syncHeldTokenByBalance(heldTokens, token);

                emit TokenReturned(to, token, amount);
            }
        }
    }
}
