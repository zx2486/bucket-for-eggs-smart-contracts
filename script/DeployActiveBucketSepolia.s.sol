// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {ActiveBucketFactory} from "../src/ActiveBucketFactory.sol";

/**
 * @title DeployActiveBucketSepolia
 * @notice Deployment script for ActiveBucket on Sepolia testnet via ActiveBucketFactory.
 * @dev Deploys a shared ActiveBucket implementation, deploys ActiveBucketFactory,
 * then calls createActiveBucket() so the deployer owns the resulting proxy.
 */
contract DeployActiveBucketSepolia is Script {
    // Sepolia addresses (update with actual deployed BucketInfo address)
    address constant BUCKET_INFO = address(0); // TODO: Set deployed BucketInfo address
    address constant ONEINCH_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    // ERC-20 share token metadata
    string constant TOKEN_NAME   = "Active Bucket Share";
    string constant TOKEN_SYMBOL = "aBKT";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address bucketInfoAddr = vm.envOr("BUCKET_INFO_ADDRESS", BUCKET_INFO);
        require(bucketInfoAddr != address(0), "Set BUCKET_INFO_ADDRESS env variable");

        console.log("=== ActiveBucket Sepolia Deployment (via Factory) ===");
        console.log("Deployer:", deployer);
        console.log("BucketInfo:", bucketInfoAddr);
        console.log("1inch Router:", ONEINCH_ROUTER_V6);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy shared implementation (never initialised directly)
        console.log("Step 1: Deploying ActiveBucket implementation...");
        ActiveBucket implementation = new ActiveBucket();
        console.log("Implementation deployed at:", address(implementation));

        // Step 2: Deploy the factory
        console.log("Step 2: Deploying ActiveBucketFactory...");
        ActiveBucketFactory factory = new ActiveBucketFactory(address(implementation));
        console.log("Factory deployed at:", address(factory));

        // Step 3: Create an ActiveBucket proxy via the factory
        console.log("Step 3: Creating ActiveBucket proxy via factory...");
        address proxyAddr = factory.createActiveBucket(
            bucketInfoAddr,
            ONEINCH_ROUTER_V6,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );
        ActiveBucket activeBucket = ActiveBucket(payable(proxyAddr));
        console.log("Proxy deployed at:", proxyAddr);

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Implementation:         ", address(implementation));
        console.log("Factory:                ", address(factory));
        console.log("Proxy (ActiveBucket):   ", address(activeBucket));
        console.log("Owner:                  ", activeBucket.owner());
        console.log("BucketInfo:             ", address(activeBucket.bucketInfo()));
        console.log("1inch Router:           ", activeBucket.oneInchRouter());
        console.log("Performance Fee (bps):  ", activeBucket.performanceFeeBps());
        console.log("Factory proxy count:    ", factory.getDeployedProxiesCount());
        console.log("");
        console.log("Deployment complete!");
    }
}
