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
        string memory configPath = vm.envOr("DEPLOYMENT_CONFIG", string("./configs/sepolia.json"));
        string memory json = vm.readFile(configPath);

        console.log("=== BucketInfo Deployment ===");
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

        bucketInfo.proposePlatformFee(platformFee);
        console.log("Platform fee PROPOSED:", platformFee, "basis points -- execute after the timelock elapses");
        console.log("");

        console.log("Proposing token whitelist additions...");
        for (uint256 i = 0; i < tokenCount; i++) {
            if (!bucketInfo.isTokenWhitelisted(tokenAddresses[i])) {
                bucketInfo.proposeWhitelistAddition(tokenAddresses[i]);
            }
        }
        console.log("Proposed whitelist for", tokenCount, "tokens");
        console.log("After the timelock, run runExecute() to apply whitelist and fee and propose price feeds.");
        console.log("");

        vm.stopBroadcast();

        // Deployment summary
        console.log("=== Deployment Summary ===");
        console.log("BucketInfo Address:", address(bucketInfo));
        console.log("Owner:", bucketInfo.owner());
        console.log("Platform fee ETA:", bucketInfo.platformFeeEta());
        console.log("");
        console.log("After the timelock, run runExecute() with this BucketInfo address.");
    }

    /**
     * @notice Second phase: apply fee and whitelist proposals, then propose feeds.
     */
    function runExecute() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envOr("DEPLOYMENT_CONFIG", string("./configs/sepolia.json"));
        string memory json = vm.readFile(configPath);
        address bucketInfoAddr = vm.parseJsonAddress(json, ".deployment.bucketInfoAddress");
        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in configs/sepolia.json");

        uint256 tokenCount = 0;
        for (uint256 i = 0; i < 100; i++) {
            try vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].tokenAddress")) {
                tokenCount++;
            } catch {
                break;
            }
        }
        address[] memory tokenAddresses = _readTokenAddresses(json, tokenCount);
        address[] memory priceFeeds = _readPriceFeeds(json, tokenCount);

        BucketInfo bucketInfo = BucketInfo(payable(bucketInfoAddr));

        vm.startBroadcast(deployerPrivateKey);
        bucketInfo.executePlatformFee();
        for (uint256 i = 0; i < tokenCount; i++) {
            if (bucketInfo.pendingWhitelistAddition(tokenAddresses[i])) {
                bucketInfo.executeWhitelistAddition(tokenAddresses[i]);
            }
        }
        address[] memory newFeedTokens = new address[](tokenCount);
        address[] memory newFeeds = new address[](tokenCount);
        uint256 feedCount;
        for (uint256 i = 0; i < tokenCount; i++) {
            if (bucketInfo.getPriceFeed(tokenAddresses[i]) == address(0)) {
                newFeedTokens[feedCount] = tokenAddresses[i];
                newFeeds[feedCount] = priceFeeds[i];
                feedCount++;
            }
        }
        if (feedCount > 0) {
            assembly ("memory-safe") {
                mstore(newFeedTokens, feedCount)
                mstore(newFeeds, feedCount)
            }
            bucketInfo.proposeBatchPriceFeeds(newFeedTokens, newFeeds);
        }
        vm.stopBroadcast();

        console.log("Applied fee and whitelist proposals. New price-feed proposals are now pending.");
        console.log("After another timelock, run runExecutePriceFeeds().");
    }

    function runExecutePriceFeeds() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_CONFIG", string("./configs/sepolia.json")));
        address bucketInfoAddr = vm.parseJsonAddress(json, ".deployment.bucketInfoAddress");
        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in configs/sepolia.json");
        uint256 tokenCount = _tokenCount(json);
        address[] memory tokenAddresses = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokenAddresses[i] = vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].tokenAddress"));
        }

        BucketInfo bucketInfo = BucketInfo(payable(bucketInfoAddr));
        vm.startBroadcast(deployerPrivateKey);
        for (uint256 i = 0; i < tokenCount; i++) {
            if (bucketInfo.priceFeedEta(tokenAddresses[i]) != 0) {
                bucketInfo.executePriceFeed(tokenAddresses[i]);
            }
        }
        vm.stopBroadcast();

        console.log("Executed price-feed proposals for", bucketInfoAddr);
    }

    function _readTokenAddresses(string memory json, uint256 tokenCount)
        private
        pure
        returns (address[] memory tokenAddresses)
    {
        tokenAddresses = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokenAddresses[i] = vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].tokenAddress"));
        }
    }

    function _readPriceFeeds(string memory json, uint256 tokenCount)
        private
        pure
        returns (address[] memory priceFeeds)
    {
        priceFeeds = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            priceFeeds[i] = vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].priceFeed"));
        }
    }

    function _tokenCount(string memory json) private pure returns (uint256 count) {
        for (uint256 i = 0; i < 100; i++) {
            try vm.parseJsonAddress(json, string.concat(".tokens[", vm.toString(i), "].tokenAddress")) {
                count++;
            } catch {
                break;
            }
        }
    }
}
