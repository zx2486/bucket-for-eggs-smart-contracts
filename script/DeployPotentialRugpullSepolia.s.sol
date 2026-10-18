// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PotentialRugpull} from "../src/PotentialRugpull.sol";
import {PotentialRugpullFactory} from "../src/PotentialRugpullFactory.sol";
import {SepoliaDeploymentConfig} from "./SepoliaDeploymentConfig.sol";

contract DeployPotentialRugpullSepolia is SepoliaDeploymentConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory json = _loadSepoliaConfig();

        address bucketInfoAddr = _configuredAddress(json, ".deployment.bucketInfoAddress");
        uint256 cashRatio = vm.parseJsonUint(json, ".deployment.potentialRugpull.cashRatio");
        string memory name = vm.parseJsonString(json, ".deployment.potentialRugpull.name");
        string memory symbol = vm.parseJsonString(json, ".deployment.potentialRugpull.symbol");

        require(bucketInfoAddr != address(0), "Set deployment.bucketInfoAddress in configs/sepolia.json");
        require(bucketInfoAddr.code.length > 0, "BucketInfo has no code");
        require(cashRatio >= 10 && cashRatio <= 90, "Cash ratio must be from 10 to 90");

        vm.startBroadcast(deployerPrivateKey);

        PotentialRugpullFactory factory = new PotentialRugpullFactory(bucketInfoAddr);
        address instance = factory.createPotentialRugpull(cashRatio, name, symbol);
        PotentialRugpull vault = PotentialRugpull(instance);

        vm.stopBroadcast();

        console.log("PotentialRugpull factory:", address(factory));
        console.log("PotentialRugpull:", instance);
        console.log("Owner:", vault.owner());
        console.log("BucketInfo:", address(vault.bucketInfo()));
        console.log("Cash ratio:", vault.cashRatio());
        console.log("Name:", vault.name());
        console.log("Symbol:", vault.symbol());
        console.log("Deployer:", deployer);
    }
}
