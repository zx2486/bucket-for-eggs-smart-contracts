// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DefiSwap} from "../src/DefiSwap.sol";

/**
 * @title DeployDefiSwapSepolia
 * @notice Deployment script for DefiSwap on Sepolia testnet with Uniswap V3 configuration
 */
contract DeployDefiSwapSepolia is Script {
    // Sepolia addresses
    address constant USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    
    // Uniswap V3 addresses on Sepolia
    address constant UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E; // SwapRouter02
    address constant UNISWAP_V3_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3; // QuoterV2
    uint24 constant UNISWAP_V3_FEE = 3000; // 0.3%

    function run() external returns (DefiSwap) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DefiSwap Sepolia Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Network: Sepolia (Chain ID: 11155111)");
        console.log("");
        console.log("Token Addresses:");
        console.log("  USDT:", USDT);
        console.log("  WETH:", WETH);
        console.log("");
        console.log("Uniswap V3 Configuration:");
        console.log("  Router:", UNISWAP_V3_ROUTER);
        console.log("  Quoter:", UNISWAP_V3_QUOTER);
        console.log("  Fee Tier:", UNISWAP_V3_FEE, "basis points (0.3%)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy DefiSwap contract
        console.log("Step 1: Deploying DefiSwap contract...");
        DefiSwap defiSwap = new DefiSwap(USDT, WETH);
        console.log("DefiSwap deployed at:", address(defiSwap));
        console.log("");

        // Step 2: Configure Uniswap V3
        console.log("Step 2: Configuring Uniswap V3...");
        defiSwap.configureDEX(
            DefiSwap.DEX.UNISWAP_V3,
            UNISWAP_V3_ROUTER,
            UNISWAP_V3_QUOTER,
            UNISWAP_V3_FEE,
            true // enabled
        );
        console.log("Uniswap V3 configured and enabled");
        console.log("");

        vm.stopBroadcast();

        // Display deployment summary
        console.log("=== Deployment Summary ===");
        console.log("DefiSwap Address:", address(defiSwap));
        console.log("Owner:", defiSwap.owner());
        console.log("WETH:", address(defiSwap.weth()));
        console.log("USDT:", address(defiSwap.usdt()));
        console.log("");
        
        console.log("Configured DEXs:");
        DefiSwap.DEXConfig memory v3Config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V3);
        console.log("  Uniswap V3:", v3Config.enabled ? "Enabled" : "Disabled");
        console.log("    Router:", v3Config.router);
        console.log("    Quoter:", v3Config.quoter);
        console.log("    Fee:", v3Config.fee);
        console.log("");

        console.log("=== Next Steps ===");
        console.log("1. Verify contract on Etherscan");
        console.log("2. Run verification script: ./script/test-defiswap-sepolia.sh");
        console.log("3. Test deposit: cast send", address(defiSwap), '"depositUSDT(uint256)" 1000000');
        console.log("4. Test swap: cast send", address(defiSwap), '"swap()"');
        console.log("");

        return defiSwap;
    }
}
