// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RedeemForStable} from "../src/RedeemForStable.sol";
import {DexConfig} from "../src/libraries/DexSwapLib.sol";
import {SepoliaDeploymentConfig} from "./SepoliaDeploymentConfig.sol";

contract DeployRedeemForStableSepolia is SepoliaDeploymentConfig {
    uint256 private constant MAX_STABLES = 8;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        string memory json = _loadSepoliaConfig();

        address bucketInfo = _configuredAddress(json, ".deployment.bucketInfoAddress");
        address weth = _configuredAddress(json, ".deployment.passiveBucket.weth");
        address router = _configuredAddress(json, ".deployment.passiveBucket.dexRouter");
        address quoter = _configuredAddress(json, ".deployment.passiveBucket.dexQuoter");
        uint24 fee = uint24(vm.parseJsonUint(json, ".deployment.passiveBucket.dexFee"));

        require(bucketInfo.code.length > 0, "BucketInfo has no code");
        require(weth.code.length > 0, "WETH has no code");
        require(router.code.length > 0, "DEX router has no code");
        require(quoter.code.length > 0, "DEX quoter has no code");

        DexConfig[] memory dexes = new DexConfig[](1);
        dexes[0] = DexConfig({router: router, quoter: quoter, fee: fee, enabled: true});
        address[] memory stables = _configuredStables(json);

        vm.startBroadcast(deployerPrivateKey);
        RedeemForStable redeemer = new RedeemForStable(bucketInfo, weth, dexes, stables);
        vm.stopBroadcast();

        console.log("RedeemForStable:", address(redeemer));
        console.log("Owner:", redeemer.owner());
        console.log("BucketInfo:", address(redeemer.BUCKET_INFO()));
        console.log("WETH:", redeemer.WETH());
        console.log("Stable token count:", stables.length);
        console.log("Deployer:", deployer);
    }

    function _configuredStables(string memory json) private pure returns (address[] memory stables) {
        address[MAX_STABLES] memory configured;
        uint256 count;
        for (uint256 i; i < MAX_STABLES; ++i) {
            string memory itemPath = string.concat(".stablecoins[", vm.toString(i), "].tokenAddress");
            try vm.parseJsonAddress(json, itemPath) returns (address stable) {
                configured[count++] = stable;
            } catch {
                break;
            }
        }
        require(count != 0, "No stablecoins configured");

        stables = new address[](count);
        for (uint256 i; i < count; ++i) stables[i] = configured[i];
    }
}
