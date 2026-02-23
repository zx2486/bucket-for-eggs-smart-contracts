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
        address bucketInfoAddress = vm.envAddress("BUCKETINFO_ADDRESS");

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
        console.log("");

        console.log("=== Verification Complete ===");
    }
}
