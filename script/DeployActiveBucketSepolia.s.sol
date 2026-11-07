// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {console} from "forge-std/console.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {ActiveBucketFactory} from "../src/ActiveBucketFactory.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";
import {SepoliaDeploymentConfig} from "./SepoliaDeploymentConfig.sol";

contract DeployActiveBucketSepolia is SepoliaDeploymentConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory json = _loadSepoliaConfig();

        address bucketInfoAddr = _configuredAddress(json, ".deployment.bucketInfoAddress");
        address registryAddr = _configuredAddress(json, ".deployment.implementationRegistryAddress");
        address router = vm.parseJsonAddress(json, ".deployment.oneInchRouter");
        string memory name = vm.parseJsonString(json, ".deployment.activeBucket.name");
        string memory symbol = vm.parseJsonString(json, ".deployment.activeBucket.symbol");
        uint256 performanceFeeBps = vm.parseJsonUint(json, ".deployment.activeBucket.performanceFeeBps");

        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in configs/sepolia.json");
        require(bucketInfoAddr.code.length > 0, "BucketInfo has no code");
        require(registryAddr != address(0), "Set deployment.implementationRegistryAddress in configs/sepolia.json");
        require(registryAddr.code.length > 0, "ImplementationRegistry has no code");
        require(router != address(0), "Set deployment.oneInchRouter in configs/sepolia.json");
        require(router.code.length > 0, "1inch router has no code");
        require(performanceFeeBps <= 10_000, "Performance fee exceeds 100 percent");
        _requireRegistryOwner(registryAddr, deployer);

        vm.startBroadcast(deployerPrivateKey);

        ActiveBucket implementation = new ActiveBucket(registryAddr, router);
        ActiveBucketFactory factory = new ActiveBucketFactory(address(implementation), bucketInfoAddr);

        IImplementationRegistry registry = IImplementationRegistry(registryAddr);
        registry.setAuthorizedFactory(address(factory), true);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, address(implementation));

        address proxy = factory.createActiveBucket(name, symbol);
        ActiveBucket bucket = ActiveBucket(payable(proxy));
        if (performanceFeeBps != bucket.performanceFeeBps()) {
            bucket.setPerformanceFee(performanceFeeBps);
        }

        vm.stopBroadcast();

        console.log("ActiveBucket implementation:", address(implementation));
        console.log("ActiveBucket factory:", address(factory));
        console.log("ActiveBucket proxy:", proxy);
        console.log("Owner:", bucket.owner());
        console.log("BucketInfo:", address(bucket.bucketInfo()));
        console.log("ImplementationRegistry:", registryAddr);
        console.log("1inch router:", bucket.oneInchRouter());
        console.log("Performance fee bps:", bucket.performanceFeeBps());
    }
}
