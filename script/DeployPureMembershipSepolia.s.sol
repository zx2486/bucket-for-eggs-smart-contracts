// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {console} from "forge-std/console.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {PureMembershipFactory} from "../src/PureMembershipFactory.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";
import {SepoliaDeploymentConfig} from "./SepoliaDeploymentConfig.sol";

contract DeployPureMembershipSepolia is SepoliaDeploymentConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory json = _loadSepoliaConfig();

        address bucketInfoAddr = _configuredAddress(json, ".deployment.bucketInfoAddress");
        address registryAddr = _configuredAddress(json, ".deployment.implementationRegistryAddress");
        string memory uri = vm.parseJsonString(json, ".deployment.pureMembership.uri");

        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in configs/sepolia.json");
        require(bucketInfoAddr.code.length > 0, "BucketInfo has no code");
        require(registryAddr != address(0), "Set deployment.implementationRegistryAddress in configs/sepolia.json");
        require(registryAddr.code.length > 0, "ImplementationRegistry has no code");
        _requireRegistryOwner(registryAddr, deployer);

        uint256 tierCount;
        for (uint256 i = 0; i < 100; i++) {
            string memory tokenIdPath = string.concat(".deployment.pureMembership.tiers[", vm.toString(i), "].tokenId");
            try vm.parseJsonUint(json, tokenIdPath) returns (uint256) {
                tierCount++;
            } catch {
                break;
            }
        }
        require(tierCount > 0, "No membership tiers configured");
        PureMembership.MembershipConfig[] memory configs = new PureMembership.MembershipConfig[](tierCount);
        for (uint256 i = 0; i < tierCount; i++) {
            string memory itemPath = string.concat(".deployment.pureMembership.tiers[", vm.toString(i), "]");
            configs[i] = PureMembership.MembershipConfig({
                tokenId: vm.parseJsonUint(json, string.concat(itemPath, ".tokenId")),
                level: vm.parseJsonUint(json, string.concat(itemPath, ".level")),
                name: vm.parseJsonString(json, string.concat(itemPath, ".name")),
                price: vm.parseJsonUint(json, string.concat(itemPath, ".priceUsd8")),
                duration: vm.parseJsonUint(json, string.concat(itemPath, ".durationSeconds"))
            });
            require(configs[i].duration > 0, "Membership tier duration must be nonzero");
            for (uint256 j = 0; j < i; j++) {
                require(configs[j].tokenId != configs[i].tokenId, "Duplicate membership token ID");
            }
        }

        vm.startBroadcast(deployerPrivateKey);

        PureMembership implementation = new PureMembership(registryAddr);
        PureMembershipFactory factory = new PureMembershipFactory(address(implementation), bucketInfoAddr);

        IImplementationRegistry registry = IImplementationRegistry(registryAddr);
        registry.setAuthorizedFactory(address(factory), true);
        registry.approve(IImplementationRegistry.Kind.PureMembership, address(implementation));

        address payable proxy = factory.createPureMembership(configs, uri);
        PureMembership membership = PureMembership(proxy);

        vm.stopBroadcast();

        console.log("PureMembership implementation:", address(implementation));
        console.log("PureMembership factory:", address(factory));
        console.log("PureMembership proxy:", address(membership));
        console.log("Owner:", membership.owner());
        console.log("BucketInfo:", address(membership.bucketInfo()));
        console.log("ImplementationRegistry:", registryAddr);
        console.log("Configured tiers:", membership.getConfiguredTokenIdCount());
    }
}
