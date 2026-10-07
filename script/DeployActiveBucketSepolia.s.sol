// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {ActiveBucketFactory} from "../src/ActiveBucketFactory.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

/**
 * @title DeployActiveBucketSepolia
 * @notice Deployment script for ActiveBucket on Sepolia testnet via ActiveBucketFactory.
 * @dev Deploys a shared ActiveBucket implementation, deploys ActiveBucketFactory,
 * then calls createActiveBucket() so the deployer owns the resulting proxy.
 */
contract DeployActiveBucketSepolia is Script {
    // Sepolia addresses (update with actual deployed BucketInfo address)
    address constant BUCKET_INFO = address(0); // TODO: Set deployed BucketInfo address
    // W3.3: the platform-owned ImplementationRegistry ActiveBucket's upgrade path checks against.
    // Immutable, constructor-set on the implementation itself -- see ActiveBucket.sol's REGISTRY
    // doc comment. TODO: Set deployed ImplementationRegistry address.
    address constant IMPLEMENTATION_REGISTRY = address(0);
    address constant ONEINCH_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    // ERC-20 share token metadata
    string constant TOKEN_NAME = "Active Bucket Share";
    string constant TOKEN_SYMBOL = "aBKT";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address bucketInfoAddr = vm.envOr("BUCKET_INFO_ADDRESS", BUCKET_INFO);
        require(bucketInfoAddr != address(0), "Set BUCKET_INFO_ADDRESS env variable");

        address registryAddr = vm.envOr("REGISTRY_ADDRESS", IMPLEMENTATION_REGISTRY);
        require(registryAddr != address(0), "Set REGISTRY_ADDRESS env variable");

        console.log("=== ActiveBucket Sepolia Deployment (via Factory) ===");
        console.log("Deployer:", deployer);
        console.log("BucketInfo:", bucketInfoAddr);
        console.log("ImplementationRegistry:", registryAddr);
        console.log("1inch Router:", ONEINCH_ROUTER_V6);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy shared implementation (never initialised directly)
        console.log("Step 1: Deploying ActiveBucket implementation...");
        ActiveBucket implementation = new ActiveBucket(registryAddr);
        console.log("Implementation deployed at:", address(implementation));

        // Step 2: Deploy the factory
        // W1.7: bucketInfoAddr is now a constructor-time, factory-immutable parameter, not a
        // per-call argument to createActiveBucket -- see src/ActiveBucketFactory.sol `bucketInfo`.
        console.log("Step 2: Deploying ActiveBucketFactory...");
        ActiveBucketFactory factory = new ActiveBucketFactory(address(implementation), bucketInfoAddr);
        console.log("Factory deployed at:", address(factory));

        // Step 2b: Authorize this factory in the ImplementationRegistry (task #33, W1.7
        // direct-proxy-bypass fix). Without this, every vault's `initialize()` now rejects the
        // factory's own `new ERC1967Proxy(...)` call with `UnauthorizedInitializer()` -- delegatecall
        // preserves msg.sender from whoever directly deployed the proxy, which here is the factory
        // itself, not this script's deployer. This call requires `deployer` to be the registry's
        // owner; if the platform's ImplementationRegistry is owned by a different key, this step
        // (and therefore Step 3 below) must instead be run by that owner before this script
        // proceeds -- it is not something this script can route around.
        console.log("Step 2b: Authorizing factory in ImplementationRegistry...");
        IImplementationRegistry(registryAddr).setAuthorizedFactory(address(factory), true);

        // Step 3: Create an ActiveBucket proxy via the factory
        console.log("Step 3: Creating ActiveBucket proxy via factory...");
        address proxyAddr = factory.createActiveBucket(ONEINCH_ROUTER_V6, TOKEN_NAME, TOKEN_SYMBOL);
        ActiveBucket activeBucket = ActiveBucket(payable(proxyAddr));
        console.log("Proxy deployed at:", proxyAddr);

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Implementation:         ", address(implementation));
        console.log("Factory:                ", address(factory));
        console.log("Proxy (ActiveBucket):   ", address(activeBucket));
        console.log("Owner:                  ", activeBucket.owner());
        console.log("BucketInfo:             ", address(activeBucket.bucketInfo()));
        console.log("1inch Router:           ", activeBucket.oneInchRouter());
        console.log("Performance Fee (bps):  ", activeBucket.performanceFeeBps());
        console.log("Factory proxy count:    ", factory.getDeployedProxiesCount());
        console.log("");
        console.log("Deployment complete!");
    }
}
