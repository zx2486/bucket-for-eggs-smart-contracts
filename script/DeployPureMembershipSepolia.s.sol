// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {PureMembershipFactory} from "../src/PureMembershipFactory.sol";

/**
 * @title DeployPureMembershipSepolia
 * @notice Deployment script for PureMembership on Sepolia testnet via PureMembershipFactory.
 * @dev Deploys a shared PureMembership implementation, deploys PureMembershipFactory,
 * then calls createPureMembership() so the deployer owns the resulting proxy.
 */
contract DeployPureMembershipSepolia is Script {
    // Sepolia addresses (update with actual deployed BucketInfo address)
    address constant BUCKET_INFO = address(0); // TODO: Set deployed BucketInfo address
    string constant METADATA_URI = "https://api.example.com/metadata/{id}.json"; // Update with actual URI

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address bucketInfoAddr = vm.envOr("BUCKET_INFO_ADDRESS", BUCKET_INFO);
        require(bucketInfoAddr != address(0), "Set BUCKET_INFO_ADDRESS env variable");

        console.log("=== PureMembership Sepolia Deployment (via Factory) ===");
        console.log("Deployer:", deployer);
        console.log("BucketInfo:", bucketInfoAddr);
        console.log("");

        // Prepare membership configurations
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](3);

        // Basic membership: Level 1, $10, 30 days
        configs[0] = PureMembership.MembershipConfig({
            tokenId: 1,
            level: 1,
            name: "Basic",
            price: 10e8, // $10 USD (8 decimals)
            duration: 30 days
        });

        // Premium membership: Level 2, $50, 365 days
        configs[1] = PureMembership.MembershipConfig({
            tokenId: 2,
            level: 2,
            name: "Premium",
            price: 50e8, // $50 USD
            duration: 365 days
        });

        // VIP membership: Level 3, $200, 365 days
        configs[2] = PureMembership.MembershipConfig({
            tokenId: 3,
            level: 3,
            name: "VIP",
            price: 200e8, // $200 USD
            duration: 365 days
        });

        console.log("Membership Configurations:");
        for (uint256 i = 0; i < configs.length; i++) {
            console.log("  TokenId:", configs[i].tokenId);
            console.log("  Level:", configs[i].level);
            console.log("  Name:", configs[i].name);
            console.log("  Price (USD 8dec):", configs[i].price);
            console.log("  Duration (seconds):", configs[i].duration);
            console.log("");
        }

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy shared implementation (never initialised directly)
        console.log("Step 1: Deploying PureMembership implementation...");
        PureMembership implementation = new PureMembership();
        console.log("Implementation deployed at:", address(implementation));

        // Step 2: Deploy the factory
        console.log("Step 2: Deploying PureMembershipFactory...");
        PureMembershipFactory factory = new PureMembershipFactory(address(implementation));
        console.log("Factory deployed at:", address(factory));

        // Step 3: Create a PureMembership proxy via the factory
        // The factory deploys an ERC-1967 proxy, initialises it, then transfers
        // ownership to msg.sender (the deployer).
        console.log("Step 3: Creating PureMembership proxy via factory...");
        address payable proxyAddr = factory.createPureMembership(configs, bucketInfoAddr, METADATA_URI);
        PureMembership pureMembership = PureMembership(proxyAddr);
        console.log("Proxy deployed at:", proxyAddr);

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Implementation:         ", address(implementation));
        console.log("Factory:                ", address(factory));
        console.log("Proxy (PureMembership): ", address(pureMembership));
        console.log("Owner:                  ", pureMembership.owner());
        console.log("BucketInfo:             ", address(pureMembership.bucketInfo()));
        console.log("Configured Token IDs:   ", pureMembership.getConfiguredTokenIdCount());
        console.log("Factory proxy count:    ", factory.getDeployedProxiesCount());
        console.log("");
        console.log("Deployment complete!");
    }
}
