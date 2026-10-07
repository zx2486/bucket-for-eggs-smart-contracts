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

        // W3.4: setPlatformFee/batchSetTokenWhitelist/batchSetPriceFeeds no longer exist --
        // every one of these is now propose-then-wait-then-execute (root CLAUDE.md §8: "Build
        // timelocks instead"). This deployment step only PROPOSES; a separate invocation of
        // {runExecute} below (same config, run again after PLATFORM_SETTER_TIMELOCK_DELAY has
        // elapsed) applies the proposals. This is a deliberate two-step deployment, not a bug.
        bucketInfo.proposePlatformFee(platformFee);
        console.log("Platform fee PROPOSED:", platformFee, "basis points -- execute after the timelock elapses");
        console.log("");

        // Configure tokens and price feeds
        console.log("Proposing token whitelist + price feed configuration...");
        bucketInfo.batchProposeWhitelistAdditions(tokenAddresses);
        bucketInfo.proposeBatchPriceFeeds(tokenAddresses, priceFeeds);
        console.log("Proposed configuration for", tokenCount, "tokens -- run runExecute() after the timelock elapses");
        console.log("");

        vm.stopBroadcast();

        // Deployment summary
        console.log("=== Deployment Summary ===");
        console.log("BucketInfo Address:", address(bucketInfo));
        console.log("Owner:", bucketInfo.owner());
        console.log("Platform fee ETA:", bucketInfo.platformFeeEta());
        console.log("");
        console.log("Deployment (proposal phase) complete! Run runExecute() with the same NETWORK");
        console.log("after the timelock elapses to apply the proposed fee/whitelist/price-feed changes.");
    }

    /**
     * @notice Second phase of deployment: applies the fee/whitelist/price-feed proposals made
     * by {run}, once PLATFORM_SETTER_TIMELOCK_DELAY has elapsed. Reads the SAME config file and
     * the already-deployed BucketInfo address (BUCKET_INFO_ADDRESS env var) so the token set
     * proposed and the token set executed can never drift apart.
     */
    function runExecute() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address bucketInfoAddr = vm.envAddress("BUCKET_INFO_ADDRESS");
        string memory network = vm.envOr("NETWORK", string("sepolia"));

        string memory configPath = string.concat("./configs/", network, ".json");
        string memory json = vm.readFile(configPath);

        uint256 tokenCount = 0;
        for (uint256 i = 0; i < 100; i++) {
            try vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].tokenAddress")) {
                tokenCount++;
            } catch {
                break;
            }
        }
        address[] memory tokenAddresses = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            string memory basePath = string.concat(".tokens[", vm.toString(i), "]");
            tokenAddresses[i] = vm.parseJsonAddress(json, string.concat(basePath, ".tokenAddress"));
        }

        BucketInfo bucketInfo = BucketInfo(payable(bucketInfoAddr));

        vm.startBroadcast(deployerPrivateKey);
        bucketInfo.executePlatformFee();
        bucketInfo.batchExecuteWhitelistAdditions(tokenAddresses);
        bucketInfo.executeBatchPriceFeeds(tokenAddresses);
        vm.stopBroadcast();

        console.log("Executed pending platform fee/whitelist/price-feed proposals for", bucketInfoAddr);
    }
}
