// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {PureMembershipFactory} from "../src/PureMembershipFactory.sol";

/**
 * @title VerifyPureMembership
 * @notice Read-only script to inspect the state of a deployed PureMembership proxy
 * and its factory. Run without broadcasting.
 * @dev Usage:
 *   PURE_MEMBERSHIP_PROXY_ADDRESS=0x... \
 *   PURE_MEMBERSHIP_FACTORY_ADDRESS=0x... \
 *   forge script script/VerifyPureMembership.s.sol --rpc-url $SEPOLIA_RPC_URL -vvv
 */
contract VerifyPureMembership is Script {
    function run() external view {
        address payable proxyAddr = payable(vm.envAddress("PURE_MEMBERSHIP_PROXY_ADDRESS"));
        address factoryAddr = vm.envOr("PURE_MEMBERSHIP_FACTORY_ADDRESS", address(0));

        PureMembership pm = PureMembership(proxyAddr);

        console.log("======================================");
        console.log(" PureMembership Deployment Verification");
        console.log("======================================");
        console.log("");

        // ── Core config ────────────────────────────────────────────
        console.log("=== Contract Info ===");
        console.log("Proxy Address  :", proxyAddr);
        console.log("Owner          :", pm.owner());
        console.log("BucketInfo     :", address(pm.bucketInfo()));
        console.log("Paused         :", pm.paused());
        console.log("Active Members :", pm.activeMembershipCount(0), "(non-expired)");
        console.log("");

        // ── Membership tiers ──────────────────────────────────────
        uint256 tierCount = pm.getConfiguredTokenIdCount();
        console.log("=== Membership Tiers ===");
        console.log("Total configured tiers:", tierCount);
        console.log("");

        for (uint256 i = 0; i < tierCount; i++) {
            uint256 tokenId = pm.configuredTokenIds(i);
            PureMembership.MembershipConfig memory cfg = pm.getMembershipInfo(tokenId);
            console.log("  --- Tier", i + 1, "---");
            console.log("  TokenId  :", cfg.tokenId);
            console.log("  Level    :", cfg.level);
            console.log("  Name     :", cfg.name);
            console.log("  Price    :", cfg.price, "(8 dec USD)");
            console.log("  Duration :", cfg.duration, "seconds");
            console.log("");
        }

        // ── Revenue overview ──────────────────────────────────────
        console.log("=== Revenue Overview ===");
        try pm.getMembershipRevenue() returns (address[] memory tokens, uint256[] memory amounts) {
            if (tokens.length == 0) {
                console.log("  No revenue accumulated yet.");
            } else {
                for (uint256 i = 0; i < tokens.length; i++) {
                    console.log("  Token  :", tokens[i]);
                    console.log("  Amount :", amounts[i]);
                    console.log("");
                }
            }
        } catch {
            console.log("  (Could not fetch revenue - BucketInfo may be unavailable)");
        }
        console.log("");

        // ── Factory info (optional) ────────────────────────────────
        if (factoryAddr != address(0)) {
            PureMembershipFactory factory = PureMembershipFactory(factoryAddr);
            console.log("=== Factory Info ===");
            console.log("Factory Address     :", factoryAddr);
            console.log("Implementation      :", factory.implementation());
            console.log("Total proxies via factory:", factory.getDeployedProxiesCount());
            console.log("");
        }

        console.log("=== Verification Complete ===");
        console.log("");
        console.log("Etherscan link:");
        console.log(string.concat("https://sepolia.etherscan.io/address/", _toHex(proxyAddr)));
    }

    /// @dev Minimal address → hex string helper (no external deps)
    function _toHex(address addr) internal pure returns (string memory) {
        bytes memory data = abi.encodePacked(addr);
        bytes memory hex_chars = "0123456789abcdef";
        bytes memory result = new bytes(42);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            result[2 + i * 2] = hex_chars[uint8(data[i] >> 4)];
            result[2 + i * 2 + 1] = hex_chars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
