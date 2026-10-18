// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {SepoliaDeploymentConfig} from "./SepoliaDeploymentConfig.sol";

contract DeployImplementationRegistrySepolia is SepoliaDeploymentConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory json = _loadSepoliaConfig();
        address initialOwner = vm.parseJsonAddress(json, ".deployment.implementationRegistryOwner");
        if (initialOwner == address(0)) initialOwner = deployer;

        vm.startBroadcast(deployerPrivateKey);
        ImplementationRegistry registry = new ImplementationRegistry(initialOwner);
        vm.stopBroadcast();

        console.log("ImplementationRegistry:", address(registry));
        console.log("Owner:", registry.owner());
        console.log("Deployer:", deployer);
    }
}
