// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PassiveBucketFactory} from "../src/PassiveBucketFactory.sol";

/**
 * @title VerifyPassiveBucket
 * @notice Read-only script to inspect the on-chain state of a deployed PassiveBucket proxy
 * and its factory. Run without broadcasting.
 * @dev Usage:
 *   PASSIVE_BUCKET_PROXY_ADDRESS=0x... \
 *   PASSIVE_BUCKET_FACTORY_ADDRESS=0x... \
 *   forge script script/VerifyPassiveBucket.s.sol --rpc-url $SEPOLIA_RPC_URL -vvv
 */
contract VerifyPassiveBucket is Script {
    function run() external view {
        address proxyAddr = vm.envAddress("PASSIVE_BUCKET_PROXY_ADDRESS");
        address factoryAddr = vm.envOr("PASSIVE_BUCKET_FACTORY_ADDRESS", address(0));

        PassiveBucket pb = PassiveBucket(payable(proxyAddr));

        console.log("======================================");
        console.log(" PassiveBucket Deployment Verification");
        console.log("======================================");
        console.log("");

        // ── Core config ────────────────────────────────────────────
        console.log("=== Contract Info ===");
        console.log("Proxy Address    :", proxyAddr);
        console.log("Name             :", pb.name());
        console.log("Symbol           :", pb.symbol());
        console.log("Owner            :", pb.owner());
        console.log("BucketInfo       :", address(pb.bucketInfo()));
        console.log("1inch Router     :", pb.oneInchRouter());
        console.log("WETH             :", pb.weth());
        console.log("Paused           :", pb.paused());
        console.log("Swap Paused      :", pb.swapPaused());
        console.log("Token Price      :", pb.tokenPrice(), "(8 dec USD)");
        console.log("Total Supply     :", pb.totalSupply());
        console.log("Total Deposit Val:", pb.totalDepositValue(), "(8 dec USD)");
        console.log("Total Withdraw   :", pb.totalWithdrawValue(), "(8 dec USD)");
        console.log("Owner Accountable:", pb.isBucketAccountable());
        console.log("");

        // ── Distributions ──────────────────────────────────────────
        PassiveBucket.BucketDistribution[] memory dists = pb.getBucketDistributions();
        console.log("=== Bucket Distributions ===");
        console.log("Count:", dists.length);
        for (uint256 i = 0; i < dists.length; i++) {
            console.log("  Token  :", dists[i].token);
            console.log("  Weight :", dists[i].weight, "%");
            console.log("");
        }

        // ── Total value ────────────────────────────────────────────
        console.log("=== Portfolio Value ===");
        try pb.calculateTotalValue() returns (uint256 totalVal) {
            console.log("Total Value (USD 8 dec):", totalVal);
        } catch {
            console.log("(Could not calculate total value - BucketInfo may be unavailable)");
        }
        console.log("");

        // ── DEX configs ────────────────────────────────────────────
        uint8 dexCount = pb.dexCount();
        console.log("=== DEX Configurations ===");
        console.log("DEX Count:", uint256(dexCount));
        for (uint8 i = 0; i < dexCount; i++) {
            (address router, address quoter, uint24 fee, bool enabled) = pb.dexConfigs(i);
            console.log("  --- DEX", uint256(i), "---");
            console.log("  Router  :", router);
            console.log("  Quoter  :", quoter);
            console.log("  Fee     :", uint256(fee));
            console.log("  Enabled :", enabled);
            console.log("");
        }

        // ── Fee parameters ──────────────────────────────────────────
        console.log("=== Rebalance Fees ===");
        console.log("Owner Fee (bps)  :", pb.rebalanceOwnerFeeBps());
        console.log("Caller Fee (bps) :", pb.rebalanceCallerFeeBps());
        console.log("");

        // ── Factory info (optional) ────────────────────────────────
        if (factoryAddr != address(0)) {
            PassiveBucketFactory factory = PassiveBucketFactory(factoryAddr);
            console.log("=== Factory Info ===");
            console.log("Factory Address      :", factoryAddr);
            console.log("Implementation       :", factory.implementation());
            console.log("Total proxies        :", factory.getDeployedProxiesCount());
            console.log("");
        }

        console.log("=== Verification Complete ===");
        console.log("");
        console.log("Etherscan link:");
        console.log(string.concat("https://sepolia.etherscan.io/address/", _toHex(proxyAddr)));
    }

    /// @dev Minimal address → hex string helper
    function _toHex(address addr) internal pure returns (string memory) {
        bytes memory data = abi.encodePacked(addr);
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(42);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            result[2 + i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
