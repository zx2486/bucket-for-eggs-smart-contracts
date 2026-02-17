// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BasicSwap} from "../src/BasicSwap.sol";

/**
 * @title DeployBasicSwapSepolia
 * @notice Deployment script for BasicSwap on Sepolia testnet with 1inch Router V6
 */
contract DeployBasicSwapSepolia is Script {
    // Sepolia addresses
    address constant USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;
    
    // 1inch Router V6 on Sepolia
    address constant ONEINCH_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    function run() external returns (BasicSwap) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== BasicSwap Sepolia Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Network: Sepolia (Chain ID: 11155111)");
        console.log("");
        console.log("Configuration:");
        console.log("  USDT:", USDT);
        console.log("  1inch Router V6:", ONEINCH_ROUTER_V6);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy BasicSwap contract
        console.log("Deploying BasicSwap contract...");
        BasicSwap basicSwap = new BasicSwap(USDT, ONEINCH_ROUTER_V6);
        console.log("BasicSwap deployed at:", address(basicSwap));
        console.log("");

        vm.stopBroadcast();

        // Display deployment summary
        console.log("=== Deployment Summary ===");
        console.log("BasicSwap Address:", address(basicSwap));
        console.log("Owner:", basicSwap.owner());
        console.log("USDT:", address(basicSwap.usdt()));
        console.log("1inch Router:", basicSwap.oneInchRouter());
        console.log("");

        console.log("=== Next Steps ===");
        console.log("1. Verify contract on Etherscan");
        console.log("2. Run verification script: ./script/test-basicswap-sepolia.sh");
        console.log("3. Test deposit: cast send", address(basicSwap), '"depositUSDT(uint256)" 1000000');
        console.log("4. Get swap data from 1inch API and execute swap");
        console.log("");

        return basicSwap;
    }
}
