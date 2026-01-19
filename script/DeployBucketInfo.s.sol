// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/BucketInfo.sol";

/**
 * @title DeployBucketInfo
 * @dev Script to deploy BucketInfo contract
 *
 * Usage:
 * - Local deployment (Anvil): forge script script/DeployBucketInfo.s.sol --rpc-url localhost --broadcast
 * - Testnet: forge script script/DeployBucketInfo.s.sol --rpc-url sepolia --broadcast --verify
 * - Mainnet: forge script script/DeployBucketInfo.s.sol --rpc-url mainnet --broadcast --verify
 */
contract DeployBucketInfo is Script {
    function run() external returns (BucketInfo) {
        // Get deployer address from private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying BucketInfo...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the contract
        BucketInfo bucketInfo = new BucketInfo();

        vm.stopBroadcast();

        console.log("BucketInfo deployed at:", address(bucketInfo));
        console.log("Owner:", bucketInfo.owner());
        console.log("Platform Fee:", bucketInfo.platformFee(), "basis points");
        console.log(
            "Whitelisted Tokens Count:",
            bucketInfo.getWhitelistedTokenCount()
        );
        console.log(
            "Platform Operational:",
            bucketInfo.isPlatformOperational()
        );

        return bucketInfo;
    }
}
