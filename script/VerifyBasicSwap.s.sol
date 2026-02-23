// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BasicSwap} from "../src/BasicSwap.sol";

/**
 * @title VerifyBasicSwap
 * @notice Script to verify and display BasicSwap contract configuration
 */
contract VerifyBasicSwap is Script {
    function run() external view {
        address basicSwapAddress = vm.envAddress("BASICSWAP_ADDRESS");
        BasicSwap basicSwap = BasicSwap(payable(basicSwapAddress));

        console.log("=== BasicSwap Contract Verification ===");
        console.log("Contract Address:", address(basicSwap));
        console.log("");

        // Basic info
        console.log("=== Contract Configuration ===");
        console.log("Owner:", basicSwap.owner());
        console.log("USDT Token:", address(basicSwap.usdt()));
        console.log("1inch Router:", basicSwap.oneInchRouter());
        console.log("");

        // Balances
        console.log("=== Contract Balances ===");
        console.log("USDT Balance:", basicSwap.getContractUsdtBalance(), "(6 decimals)");
        console.log("ETH Balance:", basicSwap.getContractEthBalance(), "wei");
        console.log("Total USDT Deposited:", basicSwap.totalUSDTDeposited(), "(6 decimals)");
        console.log("");

        console.log("=== Verification Complete ===");
    }
}
