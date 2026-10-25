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
        address[] memory tokensToPropose = new address[](tokenCount);
        uint256 proposalCount;
        for (uint256 i = 0; i < tokenCount; i++) {
            if (!bucketInfo.isTokenWhitelisted(tokenAddresses[i])) {
                tokensToPropose[proposalCount] = tokenAddresses[i];
                proposalCount++;
            }
        }
        if (proposalCount > 0) {
            assembly ("memory-safe") {
                mstore(tokensToPropose, proposalCount)
            }
            bucketInfo.batchProposeWhitelistAdditions(tokensToPropose);
        }
        console.log("Proposed whitelist for", proposalCount, "tokens");
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
        address[] memory tokensToExecute = new address[](tokenCount);
        uint256 executionCount;
        for (uint256 i = 0; i < tokenCount; i++) {
            if (bucketInfo.pendingWhitelistAddition(tokenAddresses[i])) {
                tokensToExecute[executionCount] = tokenAddresses[i];
                executionCount++;
            }
        }
        if (executionCount > 0) {
            assembly ("memory-safe") {
                mstore(tokensToExecute, executionCount)
            }
            bucketInfo.batchExecuteWhitelistAdditions(tokensToExecute);
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
        address[] memory feedsToExecute = new address[](tokenCount);
        uint256 executionCount;
        for (uint256 i = 0; i < tokenCount; i++) {
            uint256 eta = bucketInfo.priceFeedEta(tokenAddresses[i]);
            if (eta != 0 && eta <= block.timestamp) {
                feedsToExecute[executionCount] = tokenAddresses[i];
                executionCount++;
            }
        }

        vm.startBroadcast(deployerPrivateKey);
        if (executionCount > 0) {
            assembly ("memory-safe") {
                mstore(feedsToExecute, executionCount)
            }
            bucketInfo.executeBatchPriceFeeds(feedsToExecute);
        }
        vm.stopBroadcast();

        console.log("Executed", executionCount, "price-feed proposals for", bucketInfoAddr);
    }

    /// @notice Set the Chainlink price staleness window to two days for every whitelisted token.
    /// @dev BucketInfo exposes only a per-token setter, so this broadcasts one transaction per
    /// token whose current override differs from the requested value.
    function runExtendPriceStale() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envOr("DEPLOYMENT_CONFIG", string("./configs/sepolia.json"));
        string memory json = vm.readFile(configPath);
        address bucketInfoAddr = vm.parseJsonAddress(json, ".deployment.bucketInfoAddress");
        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in config");

        BucketInfo bucketInfo = BucketInfo(payable(bucketInfoAddr));
        address[] memory tokens = bucketInfo.getWhitelistedTokens();
        uint256 newOverrides;

        vm.startBroadcast(deployerPrivateKey);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (bucketInfo.maxPriceStaleness(tokens[i]) != 2 days) {
                bucketInfo.setMaxPriceStaleness(tokens[i], 2 days);
                newOverrides++;
            }
        }
        vm.stopBroadcast();

        console.log("Whitelisted tokens:", tokens.length);
        console.log("Staleness overrides set to two days:", newOverrides);
    }

    /// @notice Read-only verification of the configured whitelist and price-feed state.
    /// @dev Call after run(), runExecute(), and runExecutePriceFeeds() have completed and
    /// their timelocks have elapsed. Does not broadcast or modify chain state.
    function runVerify() external view {
        string memory configPath = vm.envOr("DEPLOYMENT_CONFIG", string("./configs/sepolia.json"));
        string memory json = vm.readFile(configPath);
        address bucketInfoAddr = vm.parseJsonAddress(json, ".deployment.bucketInfoAddress");
        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in config");

        uint256 tokenCount = _tokenCount(json);
        require(tokenCount > 0, "No tokens configured");
        BucketInfo bucketInfo = BucketInfo(payable(bucketInfoAddr));

        console.log("=== BucketInfo Configuration Verification ===");
        console.log("BucketInfo:", bucketInfoAddr);
        console.log("Configured tokens:", tokenCount);

        for (uint256 i = 0; i < tokenCount; i++) {
            string memory basePath = string.concat(".tokens[", vm.toString(i), "]");
            string memory symbol = vm.parseJsonString(json, string.concat(basePath, ".symbol"));
            address token = vm.parseJsonAddress(json, string.concat(basePath, ".tokenAddress"));
            address expectedFeed = vm.parseJsonAddress(json, string.concat(basePath, ".priceFeed"));

            require(bucketInfo.isTokenWhitelisted(token), string.concat("Token not whitelisted: ", symbol));
            require(
                !bucketInfo.pendingWhitelistAddition(token),
                string.concat("Whitelist addition still pending: ", symbol)
            );

            address actualFeed = bucketInfo.getPriceFeed(token);
            require(actualFeed == expectedFeed, string.concat("Incorrect price feed: ", symbol));
            require(bucketInfo.priceFeedEta(token) == 0, string.concat("Price feed update still pending: ", symbol));

            (bool priceAvailable, uint256 price) = bucketInfo.tryGetTokenPrice(token);
            require(priceAvailable && price > 0, string.concat("No valid price available: ", symbol));

            console.log("Verified token:", symbol);
            console.log("  Address:", token);
            console.log("  Price feed:", actualFeed);
            console.log("  Price (USD, 8 decimals):", price);
        }

        console.log("All configured tokens are whitelisted, correctly priced, and have valid prices.");
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
