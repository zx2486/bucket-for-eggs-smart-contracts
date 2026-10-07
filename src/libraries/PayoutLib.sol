// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title PayoutLib
 * @notice EIP-170 size-relief extraction (same pattern as {SeizureLib}/{DexSwapLib}/
 * {OraclePricingLib}) for the redeem payout-transfer loop that, before this extraction, was
 * duplicated VERBATIM in both `ActiveBucket.redeem` (`ActiveBucket.sol:227-235` pre-extraction)
 * and `PassiveBucket.redeem` (`PassiveBucket.sol:285-292` pre-extraction): iterate the tokens a
 * redeem call is paying out, transfer each nonzero amount, keep the held-tokens registry
 * accurate, and emit {TokenReturned} per nonzero payout. Needed because the W5-oracle inventory
 * views ({OraclePricingLib}) pushed PassiveBucket's `forge build --sizes` margin negative
 * (-106 B) even after that extraction alone — this is the next-cheapest real win, not a cosmetic
 * dedup: the loop body itself (an external token transfer + an external balance read per
 * iteration) is the same shape of "loop with real per-iteration cost" that made
 * {OraclePricingLib}'s own extraction pay off, as opposed to a trivial one-line getter (measured
 * this session to make size WORSE when extracted).
 * @notice ALSO carries {syncHeldTokenByBalance}/{syncAllHeldTokensFromWhitelist} — formerly
 * `BucketVaultBase._syncHeldTokenByBalance`/`_syncAllHeldTokensFromWhitelist`
 * (pre-extraction bodies identical to these). Moved here, rather than to a third library, because
 * {payoutAndSync} already contains its own copy of the exact same held/not-held re-derivation
 * logic — collapsing both onto one shared implementation inside this library is itself a further
 * size win (see {payoutAndSync}'s body, which now calls {syncHeldTokenByBalance} instead of
 * duplicating the balance read inline) on top of the relief from moving the loop out of
 * {BucketVaultBase}/each child in the first place. Reusing +137 B margin, still only +31 B after
 * the payout extraction alone — measured insufficient headroom to stop here.
 * @dev Functions are `public` (not `internal`) so this library is deployed ONCE and
 * DELEGATECALLed into by both ActiveBucket and PassiveBucket, exactly as {SeizureLib},
 * {DexSwapLib} and {OraclePricingLib} already are. DELEGATECALL preserves `address(this)` and
 * `msg.sender` exactly as they were when this logic ran inline inside each vault (see
 * {DexSwapLib}'s header comment for the same point) -- the native-ETH branch's `.call{value}`
 * and the post-transfer `balanceOf(address(this))` read both still execute with the VAULT as
 * `address(this)`, identically to before.
 * @dev This is a PURE bytecode-location change: every check, transfer branch, registry update and
 * emitted event below is copied unchanged from the inline loop each vault's `redeem` function
 * previously ran directly. No behavior, ordering, or event differs.
 */
library PayoutLib {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Selector-identical to `BucketVaultBase.ETHTransferFailed()` (same technique
    /// {SeizureLib}'s {Blacklisted} error doc comment explains: a library cannot revert with an
    /// error it did not itself declare, and duplicating a one-line error declaration is far
    /// cheaper than not extracting this loop at all).
    error ETHTransferFailed();

    /// @dev Selector-identical to `BucketVaultBase.TokenReturned(address,address,uint256)`.
    event TokenReturned(address indexed user, address indexed token, uint256 amount);

    /// @notice Re-derives held/not-held for `token` from its current on-contract balance: adds
    /// it to `heldTokens` if balance > 0, removes it if balance == 0. Pure bytecode relocation of
    /// the former `BucketVaultBase._syncHeldTokenByBalance` — same body, same semantics.
    function syncHeldTokenByBalance(EnumerableSet.AddressSet storage heldTokens, address token) public {
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (balance == 0) {
            heldTokens.remove(token);
        } else {
            heldTokens.add(token);
        }
    }

    /// @notice Re-syncs every token in `whitelistedTokens` via {syncHeldTokenByBalance}. Pure
    /// bytecode relocation of the former `BucketVaultBase._syncAllHeldTokensFromWhitelist`.
    function syncAllHeldTokensFromWhitelist(
        EnumerableSet.AddressSet storage heldTokens,
        address[] memory whitelistedTokens
    ) public {
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            syncHeldTokenByBalance(heldTokens, whitelistedTokens[i]);
        }
    }

    /// @notice Transfers each nonzero `returnAmounts[i]` of `tokens[i]` to `to`, re-derives
    /// `tokens[i]`'s held/not-held status from its post-transfer balance, and emits
    /// {TokenReturned} once per nonzero payout.
    /// @dev `tokens` and `returnAmounts` must be the same length (both vaults' `redeem` always
    /// pass same-length arrays built together, exactly as before this extraction).
    function payoutAndSync(
        EnumerableSet.AddressSet storage heldTokens,
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

                // Keep the held-tokens registry accurate if this payout fully drains a token --
                // shares {syncHeldTokenByBalance}'s implementation rather than duplicating it.
                syncHeldTokenByBalance(heldTokens, token);

                emit TokenReturned(to, token, amount);
            }
        }
    }
}
