// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PassiveBucketFactory} from "../src/PassiveBucketFactory.sol";

/**
 * @title DeployPassiveBucketSepolia
 * @notice Deployment script for PassiveBucket on Sepolia testnet via PassiveBucketFactory.
 * @dev Deploys a shared PassiveBucket implementation, deploys PassiveBucketFactory,
 * then calls createPassiveBucket() so the deployer owns the resulting proxy.
 */
contract DeployPassiveBucketSepolia is Script {
    // Sepolia addresses (update with actual deployed BucketInfo address)
    address constant BUCKET_INFO = address(0); // TODO: Set deployed BucketInfo address
    address constant ONEINCH_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Example distribution tokens on Sepolia (update with actual addresses)
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;

    // Uniswap V3 on Sepolia
    address constant UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant UNISWAP_V3_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    uint24 constant UNISWAP_V3_FEE = 3000;

    // ERC-20 share token metadata
    string constant TOKEN_NAME   = "PassiveBucket Share";
    string constant TOKEN_SYMBOL = "pBKT";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Allow overriding BucketInfo address via env
        address bucketInfoAddr = vm.envOr("BUCKET_INFO_ADDRESS", BUCKET_INFO);
        require(bucketInfoAddr != address(0), "Set BUCKET_INFO_ADDRESS env variable");

        console.log("=== PassiveBucket Sepolia Deployment (via Factory) ===");
        console.log("Deployer:", deployer);
        console.log("BucketInfo:", bucketInfoAddr);
        console.log("1inch Router:", ONEINCH_ROUTER_V6);
        console.log("");

        // Prepare initial distributions: 50% ETH, 30% WETH, 20% USDT
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);  // 50% ETH
        dists[1] = PassiveBucket.BucketDistribution(WETH, 30);         // 30% WETH
        dists[2] = PassiveBucket.BucketDistribution(USDT, 20);         // 20% USDT

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy shared implementation (never initialised directly)
        console.log("Step 1: Deploying PassiveBucket implementation...");
        PassiveBucket implementation = new PassiveBucket();
        console.log("Implementation deployed at:", address(implementation));

        // Step 2: Deploy the factory
        console.log("Step 2: Deploying PassiveBucketFactory...");
        PassiveBucketFactory factory = new PassiveBucketFactory(address(implementation));
        console.log("Factory deployed at:", address(factory));

        // Step 3: Create a PassiveBucket proxy via the factory
        console.log("Step 3: Creating PassiveBucket proxy via factory...");
        address proxyAddr = factory.createPassiveBucket(
            bucketInfoAddr,
            dists,
            ONEINCH_ROUTER_V6,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );
        PassiveBucket passiveBucket = PassiveBucket(payable(proxyAddr));
        console.log("Proxy deployed at:", proxyAddr);

        // Step 4: Configure DEXs (owner is now deployer)
        console.log("Step 4: Configuring Uniswap V3...");
        passiveBucket.configureDEX(0, UNISWAP_V3_ROUTER, UNISWAP_V3_QUOTER, UNISWAP_V3_FEE, true);

        // Step 5: Set WETH address
        console.log("Step 5: Setting WETH address...");
        passiveBucket.setWETH(WETH);

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Implementation:         ", address(implementation));
        console.log("Factory:                ", address(factory));
        console.log("Proxy (PassiveBucket):  ", address(passiveBucket));
        console.log("Owner:                  ", passiveBucket.owner());
        console.log("BucketInfo:             ", address(passiveBucket.bucketInfo()));
        console.log("1inch Router:           ", passiveBucket.oneInchRouter());
        console.log("WETH:                   ", passiveBucket.weth());
        console.log("Factory proxy count:    ", factory.getDeployedProxiesCount());
        console.log("");

        PassiveBucket.BucketDistribution[] memory storedDists = passiveBucket.getBucketDistributions();
        console.log("Distributions:");
        for (uint256 i = 0; i < storedDists.length; i++) {
            console.log("  Token:", storedDists[i].token, "Weight:", storedDists[i].weight);
        }
        console.log("");
        console.log("Deployment complete!");
    }
}
