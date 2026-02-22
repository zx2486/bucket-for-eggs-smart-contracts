// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {ActiveBucketFactory} from "../src/ActiveBucketFactory.sol";

/**
 * @title VerifyActiveBucket
 * @notice Read-only script to inspect the on-chain state of a deployed ActiveBucket proxy
 * and its factory. Run without broadcasting.
 * @dev Usage:
 *   ACTIVE_BUCKET_PROXY_ADDRESS=0x... \
 *   ACTIVE_BUCKET_FACTORY_ADDRESS=0x... \
 *   forge script script/VerifyActiveBucket.s.sol --rpc-url $SEPOLIA_RPC_URL -vvv
 */
contract VerifyActiveBucket is Script {
    function run() external view {
        address proxyAddr   = vm.envAddress("ACTIVE_BUCKET_PROXY_ADDRESS");
        address factoryAddr = vm.envOr("ACTIVE_BUCKET_FACTORY_ADDRESS", address(0));

        ActiveBucket ab = ActiveBucket(payable(proxyAddr));

        console.log("======================================");
        console.log(" ActiveBucket Deployment Verification");
        console.log("======================================");
        console.log("");

        // ── Core config ────────────────────────────────────────────
        console.log("=== Contract Info ===");
        console.log("Proxy Address    :", proxyAddr);
        console.log("Name             :", ab.name());
        console.log("Symbol           :", ab.symbol());
        console.log("Owner            :", ab.owner());
        console.log("BucketInfo       :", address(ab.bucketInfo()));
        console.log("1inch Router     :", ab.oneInchRouter());
        console.log("Paused           :", ab.paused());
        console.log("Swap Paused      :", ab.swapPaused());
        console.log("Token Price      :", ab.tokenPrice(), "(8 dec USD)");
        console.log("Total Supply     :", ab.totalSupply());
        console.log("Total Deposit Val:", ab.totalDepositValue(), "(8 dec USD)");
        console.log("Total Withdraw   :", ab.totalWithdrawValue(), "(8 dec USD)");
        console.log("Owner Accountable:", ab.isBucketAccountable());
        console.log("");

        // ── Fee parameters ──────────────────────────────────────────
        console.log("=== Fee Parameters ===");
        console.log("Performance Fee (bps):", ab.performanceFeeBps());
        console.log("Flash Loan Fee (bps) :", ab.FLASH_LOAN_FEE_BPS());
        console.log("Max Value Loss (bps) :", ab.MAX_VALUE_LOSS_BPS());
        console.log("Min Owner Holding(bps):", ab.MIN_OWNER_BPS());
        console.log("");

        // ── Total value ────────────────────────────────────────────
        console.log("=== Portfolio Value ===");
        try ab.calculateTotalValue() returns (uint256 totalVal) {
            console.log("Total Value (USD 8 dec):", totalVal);
        } catch {
            console.log("(Could not calculate total value - BucketInfo may be unavailable)");
        }
        console.log("");

        // ── Factory info (optional) ────────────────────────────────
        if (factoryAddr != address(0)) {
            ActiveBucketFactory factory = ActiveBucketFactory(factoryAddr);
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
            result[2 + i * 2]     = hexChars[uint8(data[i] >> 4)];
            result[2 + i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
