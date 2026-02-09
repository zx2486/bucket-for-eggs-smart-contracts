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
    /// @dev Network configuration structure
    struct TokenConfig {
        address tokenAddress;
        address priceFeed;
        string name;
    }

    struct NetworkConfig {
        uint256 platformFee;
        TokenConfig[] tokens;
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
        string memory configPath = string.concat("config/", network, ".json");
        string memory json = vm.readFile(configPath);

        console.log("=== BucketInfo Deployment ===");
        console.log("Network:", network);
        console.log("Config file:", configPath);
        console.log("");

        // Parse configuration
        uint256 platformFee = vm.parseJsonUint(json, ".platformFee");
        bytes memory tokensData = vm.parseJson(json, ".tokens");
        TokenConfig[] memory tokens = abi.decode(tokensData, (TokenConfig[]));

        console.log("Platform Fee:", platformFee, "basis points");
        console.log("Tokens to configure:", tokens.length);
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

        // Configure tokens
        console.log("Configuring tokens and price feeds...");
        // Build arrays of token addresses and price feeds from the TokenConfig memory array
        address[] memory tokenAddresses = new address[](tokens.length);
        address[] memory priceFeeds = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenAddresses[i] = tokens[i].tokenAddress;
            priceFeeds[i] = tokens[i].priceFeed;
        }
        bucketInfo.batchSetTokenWhitelist(tokenAddresses, true);
        bucketInfo.batchSetPriceFeeds(tokenAddresses, priceFeeds);

        vm.stopBroadcast();

        // Deployment summary
        console.log("=== Deployment Summary ===");
        console.log("BucketInfo Address:", address(bucketInfo));
        console.log("Owner:", bucketInfo.owner());
        console.log("Platform Fee:", bucketInfo.platformFee(), "basis points");
        console.log(
            "Whitelisted Tokens:",
            bucketInfo.getWhitelistedTokenCount()
        );
        console.log("");
        console.log("Deployment complete!");
    }
}
