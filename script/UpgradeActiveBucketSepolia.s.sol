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
 *
 *      W3.3 (`09-DECISION-LOG.md` §10.1): `_authorizeUpgrade` now requires, in order,
 *      (1) `newImplementation` to match the proxy's own `pendingImplementation()`,
 *      (2) `block.timestamp >= upgradeEta()`, and (3) the platform's `ImplementationRegistry`
 *      to still report the implementation approved -- re-checked at execution, not just at
 *      queue time. This script performs neither step 1 nor the 48-hour wait; it assumes the
 *      proxy owner has ALREADY called `proxy.queueUpgrade(address(newImplementation))` with
 *      this exact deployed address and that `UPGRADE_TIMELOCK_DELAY` (48h) has elapsed, and
 *      that the platform has approved this implementation in the registry. Running this
 *      script without that prerequisite will revert inside `upgradeToAndCall` --
 *      `NoProposalPending` if nothing was queued, `TimelockNotElapsed` if too early, or
 *      `UpgradeNotApproved` if the registry has not (or no longer) approved it. That is the
 *      intended behaviour, not a bug to route around: the whole point of the split authority
 *      is that a customer cannot self-serve an upgrade without a platform-approved,
 *      time-delayed queue entry.
 */
contract UpgradeActiveBucketSepolia is Script {
    // W3.3: the platform-owned ImplementationRegistry the new implementation is constructed
    // against. Must equal the registry the live proxy's implementation was itself deployed
    // with -- REGISTRY is immutable per-implementation, not read from the proxy.
    address constant IMPLEMENTATION_REGISTRY = address(0); // TODO: Set deployed ImplementationRegistry address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proxyAddress = vm.envAddress("ACTIVE_BUCKET_PROXY_ADDRESS");

        address registryAddr = vm.envOr("REGISTRY_ADDRESS", IMPLEMENTATION_REGISTRY);
        require(registryAddr != address(0), "Set REGISTRY_ADDRESS env variable");

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
        ActiveBucket newImplementation = new ActiveBucket(registryAddr);
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
