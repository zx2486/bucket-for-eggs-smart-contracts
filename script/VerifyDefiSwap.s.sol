// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DefiSwap} from "../src/DefiSwap.sol";

/**
 * @title VerifyDefiSwap
 * @notice Script to verify and display DefiSwap contract configuration
 */
contract VerifyDefiSwap is Script {
    function run() external view {
        address defiSwapAddress = vm.envAddress("DEFISWAP_ADDRESS");
        DefiSwap defiSwap = DefiSwap(payable(defiSwapAddress));

        console.log("=== DefiSwap Contract Verification ===");
        console.log("Contract Address:", address(defiSwap));
        console.log("");

        // Basic info
        console.log("=== Contract Configuration ===");
        console.log("Owner:", defiSwap.owner());
        console.log("USDT Token:", address(defiSwap.usdt()));
        console.log("WETH Token:", address(defiSwap.weth()));
        console.log("");

        // Balances
        console.log("=== Contract Balances ===");
        console.log("USDT Balance:", defiSwap.getContractUSDTBalance(), "(6 decimals)");
        console.log("ETH Balance:", defiSwap.getContractETHBalance(), "wei");
        console.log("Total USDT Deposited:", defiSwap.totalUSDTDeposited(), "(6 decimals)");
        console.log("");

        // DEX configurations
        console.log("=== DEX Configurations ===");
        
        // Uniswap V3
        DefiSwap.DEXConfig memory v3Config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V3);
        console.log("Uniswap V3:");
        console.log("  Status:", v3Config.enabled ? "ENABLED" : "DISABLED");
        console.log("  Router:", v3Config.router);
        console.log("  Quoter:", v3Config.quoter);
        console.log("  Fee Tier:", v3Config.fee, "basis points");
        console.log("  DEX Name:", defiSwap.getDEXName(DefiSwap.DEX.UNISWAP_V3));
        console.log("");

        // Uniswap V4
        DefiSwap.DEXConfig memory v4Config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V4);
        console.log("Uniswap V4:");
        console.log("  Status:", v4Config.enabled ? "ENABLED" : "DISABLED");
        console.log("");

        // Fluid
        DefiSwap.DEXConfig memory fluidConfig = defiSwap.getDEXConfig(DefiSwap.DEX.FLUID);
        console.log("Fluid:");
        console.log("  Status:", fluidConfig.enabled ? "ENABLED" : "DISABLED");
        console.log("");

        // Curve
        DefiSwap.DEXConfig memory curveConfig = defiSwap.getDEXConfig(DefiSwap.DEX.CURVE);
        console.log("Curve:");
        console.log("  Status:", curveConfig.enabled ? "ENABLED" : "DISABLED");
        console.log("  Pool:", defiSwap.curvePool());
        console.log("");

        console.log("=== Verification Complete ===");
    }
}
