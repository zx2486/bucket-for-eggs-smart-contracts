// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BucketInfo} from "../src/BucketInfo.sol";

/**
 * @title DeployBucketInfo
 * @notice Deployment script for BucketInfo contract with network-specific configurations
 * @dev Reads token and price feed configurations from JSON files based on network
 */
contract DeployBucketInfo is Script {
    /// @dev Token configuration structure matching JSON format
    struct TokenConfig {
        string symbol;
        address tokenAddress;
        address priceFeed;
    }

    /**
     * @notice Main deployment function
     * @dev Reads configuration from JSON based on NETWORK environment variable
     */
    function run() external {
        // Read environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory network = vm.envOr("NETWORK", string("sepolia"));

        // Load network configuration
        string memory configPath = string.concat("./configs/", network, ".json");
        string memory json = vm.readFile(configPath);

        console.log("=== BucketInfo Deployment ===");
        console.log("Network:", network);
        console.log("Config file:", configPath);
        console.log("");

        // Parse configuration
        uint256 platformFee = vm.parseJsonUint(json, ".platformFee");
        // Determine array length by attempting to parse indices
        uint256 tokenCount = 0;
        for (uint256 i = 0; i < 100; i++) {
            try vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].tokenAddress")) {
                tokenCount++;
            } catch {
                break;
            }
        }
        // Initialize arrays
        address[] memory tokenAddresses = new address[](tokenCount);
        address[] memory priceFeeds = new address[](tokenCount);

        console.log("Platform Fee:", platformFee, "basis points");
        console.log("Tokens to configure:", tokenCount);
        console.log("");

        // Parse each token configuration
        for (uint256 i = 0; i < tokenCount; i++) {
            string memory basePath = string.concat(".tokens[", vm.toString(i), "]");
            string memory symbol = vm.parseJsonString(json, string.concat(basePath, ".symbol"));
            tokenAddresses[i] = vm.parseJsonAddress(json, string.concat(basePath, ".tokenAddress"));
            priceFeeds[i] = vm.parseJsonAddress(json, string.concat(basePath, ".priceFeed"));
            
            console.log("Token", i, ":", symbol);
            console.log("  Address:", tokenAddresses[i]);
            console.log("  Price Feed:", priceFeeds[i]);
        }
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy BucketInfo contract
        BucketInfo bucketInfo = new BucketInfo();
        console.log("BucketInfo deployed at:", address(bucketInfo));
        console.log("");

        // Set platform fee
        bucketInfo.setPlatformFee(platformFee);
        console.log("Platform fee set to:", platformFee, "basis points");
        console.log("");

        // Configure tokens and price feeds
        console.log("Configuring tokens and price feeds...");
        bucketInfo.batchSetTokenWhitelist(tokenAddresses, true);
        bucketInfo.batchSetPriceFeeds(tokenAddresses, priceFeeds);
        console.log("Successfully configured", tokenCount, "tokens");
        console.log("");

        vm.stopBroadcast();

        // Deployment summary
        console.log("=== Deployment Summary ===");
        console.log("BucketInfo Address:", address(bucketInfo));
        console.log("Owner:", bucketInfo.owner());
        console.log("Platform Fee:", bucketInfo.platformFee(), "basis points");
        console.log("Whitelisted Tokens:", bucketInfo.getWhitelistedTokenCount());
        console.log("");
        console.log("Deployment complete!");
    }
}
