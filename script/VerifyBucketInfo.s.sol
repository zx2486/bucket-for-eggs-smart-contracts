// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BucketInfo} from "../src/BucketInfo.sol";

/**
 * @title VerifyBucketInfo
 * @notice Script to verify and display information about a deployed BucketInfo contract
 * @dev Reads deployed contract address and displays its configuration
 */
contract VerifyBucketInfo is Script {
    function run() external view {
        // Read the deployed contract address from environment variable or argument
        address payable bucketInfoAddress = payable(vm.envOr("BUCKET_INFO_ADDRESS", address(0)));
        if (bucketInfoAddress == address(0)) revert("Set BUCKET_INFO_ADDRESS");

        BucketInfo bucketInfo = BucketInfo(bucketInfoAddress);

        console.log("=== BucketInfo Contract Verification ===");
        console.log("Contract Address:", address(bucketInfo));
        console.log("");

        // Deployment Summary
        console.log("=== Deployment Summary ===");
        console.log("BucketInfo Address:", address(bucketInfo));
        console.log("Owner:", bucketInfo.owner());
        console.log("Platform Fee:", bucketInfo.platformFee(), "basis points");
        console.log("Whitelisted Tokens Count:", bucketInfo.getWhitelistedTokenCount());
        console.log("");

        // Get all whitelisted tokens
        address[] memory whitelistedTokens = bucketInfo.getWhitelistedTokens();
        console.log("=== Whitelisted Tokens ===");
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            address token = whitelistedTokens[i];
            address priceFeed = bucketInfo.getPriceFeed(token);

            console.log("Token", i, ":");
            console.log("  Address:", token);
            console.log("  Price Feed:", priceFeed);
            console.log("  Is Whitelisted:", bucketInfo.isTokenWhitelisted(token));
        }
        string memory json = vm.readFile("./configs/sepolia.json");
        address[] memory targetTokens = new address[](2);
        targetTokens[0] = _tokenAddress(json, "WBTC");
        targetTokens[1] = _tokenAddress(json, "ETH");
        console.log("=== PassiveBucket Target Assets ===");
        for (uint256 i = 0; i < targetTokens.length; i++) {
            (bool priceOk, uint256 price) = bucketInfo.tryGetTokenPrice(targetTokens[i]);
            require(bucketInfo.isTokenWhitelisted(targetTokens[i]), "Target token not whitelisted");
            require(priceOk && price > 0, "Target token price unavailable");
            console.log("Token:", targetTokens[i]);
            console.log("Price USD-8:", price);
        }
        console.log("");

        console.log("=== Verification Complete ===");
    }

    function _tokenAddress(string memory json, string memory symbol) private pure returns (address) {
        for (uint256 i = 0; i < 100; i++) {
            string memory path = string.concat(".tokens[", vm.toString(i), "]");
            try vm.parseJsonString(json, string.concat(path, ".symbol")) returns (string memory configuredSymbol) {
                if (keccak256(bytes(configuredSymbol)) == keccak256(bytes(symbol))) {
                    return vm.parseJsonAddress(json, string.concat(path, ".tokenAddress"));
                }
            } catch {
                break;
            }
        }
        revert("Target token missing from configs/sepolia.json");
    }
}
