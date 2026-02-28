// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";

/**
 * @title UpgradeActiveBucketSepolia
 * @notice Deploys a new ActiveBucket implementation and upgrades the existing
 *         UUPS proxy (ACTIVE_BUCKET_PROXY_ADDRESS) to point to it.
 * @dev No re-initialisation is required; upgradeToAndCall is called with empty data.
 *      The caller must be the owner of the proxy.
 */
contract UpgradeActiveBucketSepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proxyAddress = vm.envAddress("ACTIVE_BUCKET_PROXY_ADDRESS");

        require(proxyAddress != address(0), "ACTIVE_BUCKET_PROXY_ADDRESS not set");

        ActiveBucket proxy = ActiveBucket(payable(proxyAddress));

        console.log("=== ActiveBucket Upgrade (Sepolia) ===");
        console.log("Deployer / caller  :", deployer);
        console.log("Proxy address      :", proxyAddress);
        console.log("Proxy owner        :", proxy.owner());
        console.log("Current BucketInfo :", address(proxy.bucketInfo()));
        console.log("Current 1inch      :", proxy.oneInchRouter());
        console.log("Current perf fee   :", proxy.performanceFeeBps());
        console.log("Current token price:", proxy.tokenPrice());
        console.log("Current total supply:", proxy.totalSupply());
        console.log("");

        require(proxy.owner() == deployer, "Caller is not proxy owner");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy new implementation (constructor calls _disableInitializers)
        console.log("Step 1: Deploying new ActiveBucket implementation...");
        ActiveBucket newImplementation = new ActiveBucket();
        console.log("New implementation :", address(newImplementation));

        // Step 2: Upgrade proxy to new implementation (no re-init needed)
        console.log("Step 2: Upgrading proxy...");
        proxy.upgradeToAndCall(address(newImplementation), "");
        console.log("Proxy upgraded successfully.");

        vm.stopBroadcast();

        // Post-upgrade state verification
        console.log("");
        console.log("=== Post-Upgrade Verification ===");
        console.log("Proxy address      :", proxyAddress);
        console.log("New implementation :", address(newImplementation));
        console.log("Proxy owner        :", proxy.owner());
        console.log("BucketInfo (preserved)  :", address(proxy.bucketInfo()));
        console.log("1inch router (preserved):", proxy.oneInchRouter());
        console.log("Perf fee (preserved)    :", proxy.performanceFeeBps());
        console.log("Token price (preserved) :", proxy.tokenPrice());
        console.log("Total supply (preserved):", proxy.totalSupply());
        console.log("");
        console.log("Upgrade complete!");
    }
}
