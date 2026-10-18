// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20Upgradeable} from "../src/MockERC20Upgradeable.sol";
import {MockERC20Factory} from "../src/MockERC20Factory.sol";

contract DeployMockTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        MockERC20Upgradeable implementation = new MockERC20Upgradeable();
        MockERC20Factory factory = new MockERC20Factory(address(implementation));

        address tokenA = factory.createToken("Mock USDC", "mUSDC", 6, 1_000_000, deployer);
        address tokenB = factory.createToken("Mock WBTC", "mWBTC", 8, 100_000, deployer);
        address tokenC = factory.createToken("Mock DAI", "mDAI", 18, 1_000_000, deployer);
        vm.stopBroadcast();

        console.log("Mock token implementation:", address(implementation));
        console.log("Mock token factory:", address(factory));
        console.log("Mock USDC:", tokenA);
        console.log("Mock WBTC:", tokenB);
        console.log("Mock DAI:", tokenC);
        console.log("Recipient:", deployer);
    }
}
