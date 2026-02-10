// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {DefiSwap} from "../src/DefiSwap.sol";

/**
 * @title DeployDefiSwap
 * @notice Deployment script for DefiSwap contract with automatic DEX configuration
 * @dev Deploys and configures DefiSwap for the target network
 */
contract DeployDefiSwap is Script {
    /// @dev Sepolia testnet addresses
    address constant SEPOLIA_USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0; // Sepolia USDT
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // Sepolia WETH
    address constant SEPOLIA_UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant SEPOLIA_UNISWAP_V3_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;

    /// @dev Ethereum mainnet addresses
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant MAINNET_UNISWAP_V3_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    address constant MAINNET_CURVE_TRIPOOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory network = vm.envOr("NETWORK", string("sepolia"));

        console.log("=== DefiSwap Deployment ===");
        console.log("Network:", network);
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("");

        // Select network-specific addresses
        address usdt;
        address weth;
        address uniV3Router;
        address uniV3Quoter;
        address curvePool;
        bool isMainnet;

        if (keccak256(bytes(network)) == keccak256(bytes("mainnet"))) {
            usdt = MAINNET_USDT;
            weth = MAINNET_WETH;
            uniV3Router = MAINNET_UNISWAP_V3_ROUTER;
            uniV3Quoter = MAINNET_UNISWAP_V3_QUOTER;
            curvePool = MAINNET_CURVE_TRIPOOL;
            isMainnet = true;
            console.log("Using Ethereum Mainnet addresses");
        } else {
            usdt = SEPOLIA_USDT;
            weth = SEPOLIA_WETH;
            uniV3Router = SEPOLIA_UNISWAP_V3_ROUTER;
            uniV3Quoter = SEPOLIA_UNISWAP_V3_QUOTER;
            curvePool = address(0); // No Curve on Sepolia
            isMainnet = false;
            console.log("Using Sepolia Testnet addresses");
        }

        console.log("USDT:", usdt);
        console.log("WETH:", weth);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy DefiSwap contract
        DefiSwap defiSwap = new DefiSwap(usdt, weth);
        console.log("DefiSwap deployed at:", address(defiSwap));
        console.log("");

        // Configure Uniswap V3
        console.log("Configuring Uniswap V3...");
        defiSwap.configureDEX(
            DefiSwap.DEX.UNISWAP_V3,
            uniV3Router,
            uniV3Quoter,
            3000, // 0.3% fee tier
            true // enabled
        );
        console.log("  Router:", uniV3Router);
        console.log("  Quoter:", uniV3Quoter);
        console.log("  Fee: 3000 (0.3%)");
        console.log("  Status: Enabled");
        console.log("");

        // Configure Uniswap V4 (placeholder - disabled by default)
        console.log("Configuring Uniswap V4...");
        defiSwap.configureDEX(
            DefiSwap.DEX.UNISWAP_V4,
            address(0),
            address(0),
            3000,
            false // disabled until V4 is deployed
        );
        console.log("  Status: Disabled (awaiting V4 deployment)");
        console.log("");

        // Configure Fluid (placeholder - disabled by default)
        console.log("Configuring Fluid...");
        defiSwap.configureDEX(
            DefiSwap.DEX.FLUID,
            address(0),
            address(0),
            3000,
            false // disabled - needs configuration
        );
        console.log("  Status: Disabled (needs router/quoter addresses)");
        console.log("");

        // Configure Curve (mainnet only)
        if (isMainnet && curvePool != address(0)) {
            console.log("Configuring Curve...");
            defiSwap.configureDEX(
                DefiSwap.DEX.CURVE,
                address(0),
                address(0),
                0,
                true // enabled on mainnet
            );
            defiSwap.setCurvePool(curvePool);
            console.log("  Pool:", curvePool);
            console.log("  Status: Enabled");
            console.log("");
        } else {
            console.log("Configuring Curve...");
            defiSwap.configureDEX(
                DefiSwap.DEX.CURVE,
                address(0),
                address(0),
                0,
                false // disabled on testnet
            );
            console.log("  Status: Disabled (not available on testnet)");
            console.log("");
        }

        vm.stopBroadcast();

        // Print deployment summary
        console.log("=== Deployment Summary ===");
        console.log("DefiSwap Address:", address(defiSwap));
        console.log("Owner:", defiSwap.owner());
        console.log("USDT:", address(defiSwap.usdt()));
        console.log("WETH:", defiSwap.weth());
        console.log("");

        console.log("Configured DEXs:");
        DefiSwap.DEXConfig memory v3Config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V3);
        console.log("  Uniswap V3:", v3Config.enabled ? "Enabled" : "Disabled");

        DefiSwap.DEXConfig memory v4Config = defiSwap.getDEXConfig(DefiSwap.DEX.UNISWAP_V4);
        console.log("  Uniswap V4:", v4Config.enabled ? "Enabled" : "Disabled");

        DefiSwap.DEXConfig memory fluidConfig = defiSwap.getDEXConfig(DefiSwap.DEX.FLUID);
        console.log("  Fluid:", fluidConfig.enabled ? "Enabled" : "Disabled");

        DefiSwap.DEXConfig memory curveConfig = defiSwap.getDEXConfig(DefiSwap.DEX.CURVE);
        console.log("  Curve:", curveConfig.enabled ? "Enabled" : "Disabled");
        console.log("");

        console.log("Deployment complete!");
        console.log("");

        if (!isMainnet) {
            console.log("Note: This is a testnet deployment.");
            console.log("Some DEXs may not be available on testnet.");
        } else {
            console.log("WARNING: This is a MAINNET deployment!");
            console.log("Please verify all addresses before using.");
        }
    }
}
