// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";

/**
 * @title UpgradePassiveBucketSepolia
 * @notice Deploys a new PassiveBucket implementation and upgrades the existing
 *         UUPS proxy (PASSIVE_BUCKET_PROXY_ADDRESS) to point to it.
 * @dev No re-initialisation is required; upgradeToAndCall is called with empty data.
 *      The caller must be the owner of the proxy.
 */
contract UpgradePassiveBucketSepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proxyAddress = vm.envAddress("PASSIVE_BUCKET_PROXY_ADDRESS");

        require(proxyAddress != address(0), "PASSIVE_BUCKET_PROXY_ADDRESS not set");

        PassiveBucket proxy = PassiveBucket(payable(proxyAddress));

        console.log("=== PassiveBucket Upgrade (Sepolia) ===");
        console.log("Deployer / caller   :", deployer);
        console.log("Proxy address       :", proxyAddress);
        console.log("Proxy owner         :", proxy.owner());
        console.log("Current BucketInfo  :", address(proxy.bucketInfo()));
        console.log("Current 1inch       :", proxy.oneInchRouter());
        console.log("Current WETH        :", proxy.weth());
        console.log("Current token price :", proxy.tokenPrice());
        console.log("Current total supply:", proxy.totalSupply());
        console.log("Current dexCount    :", proxy.dexCount());
        console.log("Owner fee bps       :", proxy.rebalanceOwnerFeeBps());
        console.log("Caller fee bps      :", proxy.rebalanceCallerFeeBps());
        console.log("");

        require(proxy.owner() == deployer, "Caller is not proxy owner");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy new implementation (constructor calls _disableInitializers)
        console.log("Step 1: Deploying new PassiveBucket implementation...");
        PassiveBucket newImplementation = new PassiveBucket();
        console.log("New implementation  :", address(newImplementation));

        // Step 2: Upgrade proxy to new implementation (no re-init needed)
        console.log("Step 2: Upgrading proxy...");
        proxy.upgradeToAndCall(address(newImplementation), "");
        console.log("Proxy upgraded successfully.");

        vm.stopBroadcast();

        // Post-upgrade state verification
        console.log("");
        console.log("=== Post-Upgrade Verification ===");
        console.log("Proxy address            :", proxyAddress);
        console.log("New implementation       :", address(newImplementation));
        console.log("Proxy owner (preserved)  :", proxy.owner());
        console.log("BucketInfo (preserved)   :", address(proxy.bucketInfo()));
        console.log("1inch router (preserved) :", proxy.oneInchRouter());
        console.log("WETH (preserved)         :", proxy.weth());
        console.log("Token price (preserved)  :", proxy.tokenPrice());
        console.log("Total supply (preserved) :", proxy.totalSupply());
        console.log("DEX count (preserved)    :", proxy.dexCount());
        console.log("Owner fee bps (preserved):", proxy.rebalanceOwnerFeeBps());
        console.log("Caller fee bps (preserved):", proxy.rebalanceCallerFeeBps());
        console.log("");
        console.log("Upgrade complete!");
    }
}
