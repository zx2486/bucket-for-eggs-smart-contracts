// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {console} from "forge-std/console.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PassiveBucketFactory} from "../src/PassiveBucketFactory.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";
import {SepoliaDeploymentConfig} from "./SepoliaDeploymentConfig.sol";

contract DeployPassiveBucketSepolia is SepoliaDeploymentConfig {
    struct PassiveConfig {
        address bucketInfo;
        address registry;
        address weth;
        address dexRouter;
        address dexQuoter;
        uint24 dexFee;
        string name;
        string symbol;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory json = _loadSepoliaConfig();
        PassiveConfig memory config = _loadPassiveConfig(json);
        PassiveBucket.BucketDistribution[] memory distributions = _loadDistributions(json);
        require(config.bucketInfo != address(0), "Set deployment.bucketInfoAddress in configs/sepolia.json");
        require(config.bucketInfo.code.length > 0, "BucketInfo has no code");
        require(config.registry != address(0), "Set deployment.implementationRegistryAddress in configs/sepolia.json");
        require(config.weth != address(0), "WETH is zero");
        require(config.dexRouter != address(0) && config.dexQuoter != address(0), "DEX router or quoter is zero");
        require(config.registry.code.length > 0, "ImplementationRegistry has no code");
        require(
            config.dexRouter.code.length > 0 && config.dexQuoter.code.length > 0, "DEX router or quoter has no code"
        );
        _requireRegistryOwner(config.registry, deployer);

        for (uint256 i = 0; i < distributions.length; i++) {
            require(
                IBucketInfo(config.bucketInfo).isTokenValid(distributions[i].token),
                "Distribution token is not valid in BucketInfo"
            );
            (bool priceOk, uint256 price) = IBucketInfo(config.bucketInfo).tryGetTokenPrice(distributions[i].token);
            require(priceOk && price > 0, "Distribution token price unavailable");
        }

        vm.startBroadcast(deployerPrivateKey);

        PassiveBucket implementation = new PassiveBucket(config.registry);
        PassiveBucketFactory factory = new PassiveBucketFactory(address(implementation), config.bucketInfo);

        IImplementationRegistry registry = IImplementationRegistry(config.registry);
        registry.setAuthorizedFactory(address(factory), true);
        registry.approve(IImplementationRegistry.Kind.PassiveBucket, address(implementation));

        address proxy = factory.createPassiveBucket(distributions, config.name, config.symbol);
        PassiveBucket bucket = PassiveBucket(payable(proxy));
        bucket.configureDEX(0, config.dexRouter, config.dexQuoter, config.dexFee, true);
        bucket.setWETH(config.weth);

        vm.stopBroadcast();

        console.log("PassiveBucket implementation:", address(implementation));
        console.log("PassiveBucket factory:", address(factory));
        console.log("PassiveBucket proxy:", proxy);
        console.log("Owner:", bucket.owner());
        console.log("BucketInfo:", address(bucket.bucketInfo()));
        console.log("ImplementationRegistry:", config.registry);
        console.log("WETH:", bucket.weth());
    }

    function _loadPassiveConfig(string memory json) private pure returns (PassiveConfig memory config) {
        config.bucketInfo = _configuredAddress(json, ".deployment.bucketInfoAddress");
        config.registry = _configuredAddress(json, ".deployment.implementationRegistryAddress");
        config.name = vm.parseJsonString(json, ".deployment.passiveBucket.name");
        config.symbol = vm.parseJsonString(json, ".deployment.passiveBucket.symbol");
        config.weth = vm.parseJsonAddress(json, ".deployment.passiveBucket.weth");
        config.dexRouter = vm.parseJsonAddress(json, ".deployment.passiveBucket.dexRouter");
        config.dexQuoter = vm.parseJsonAddress(json, ".deployment.passiveBucket.dexQuoter");
        config.dexFee = uint24(vm.parseJsonUint(json, ".deployment.passiveBucket.dexFee"));
    }

    function _loadDistributions(string memory json)
        private
        pure
        returns (PassiveBucket.BucketDistribution[] memory distributions)
    {
        uint256 count;
        for (uint256 i = 0; i < 100; i++) {
            string memory path = string.concat(".deployment.passiveBucket.distributions[", vm.toString(i), "].weight");
            try vm.parseJsonUint(json, path) returns (uint256) {
                count++;
            } catch {
                break;
            }
        }
        require(count > 0, "No passive distributions configured");
        distributions = new PassiveBucket.BucketDistribution[](count);
        uint256 weightTotal;
        for (uint256 i = 0; i < count; i++) {
            (distributions[i], weightTotal) = _loadDistribution(json, i, weightTotal);
        }
        require(weightTotal == 100, "Passive distribution weights must sum to 100");
    }

    function _loadDistribution(string memory json, uint256 index, uint256 totalWeight)
        private
        pure
        returns (PassiveBucket.BucketDistribution memory distribution, uint256 newTotalWeight)
    {
        string memory path = string.concat(".deployment.passiveBucket.distributions[", vm.toString(index), "]");
        string memory tokenSymbol = vm.parseJsonString(json, string.concat(path, ".symbol"));
        uint256 weight = vm.parseJsonUint(json, string.concat(path, ".weight"));
        distribution = PassiveBucket.BucketDistribution(_tokenAddressForSymbol(json, tokenSymbol), weight);
        newTotalWeight = totalWeight + weight;
        console.log("Distribution token:", tokenSymbol);
        console.log("Weight:", weight);
    }
}
