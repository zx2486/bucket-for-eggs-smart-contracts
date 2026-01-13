// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/BucketToken.sol";

/**
 * @title DeployBucketToken
 * @dev Script to deploy BucketToken contract
 * 
 * Usage:
 * - Local deployment (Anvil): forge script script/DeployBucketToken.s.sol --rpc-url localhost --broadcast
 * - Testnet: forge script script/DeployBucketToken.s.sol --rpc-url sepolia --broadcast --verify
 * - Mainnet: forge script script/DeployBucketToken.s.sol --rpc-url mainnet --broadcast --verify
 */
contract DeployBucketToken is Script {
    // Initial supply: 100 million tokens (adjustable)
    uint256 constant INITIAL_SUPPLY = 100_000_000 * 10**18;

    function run() external returns (BucketToken) {
        // Get deployer address from private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying BucketToken...");
        console.log("Deployer:", deployer);
        console.log("Initial Supply:", INITIAL_SUPPLY / 10**18, "tokens");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the token
        BucketToken token = new BucketToken(deployer, INITIAL_SUPPLY);

        vm.stopBroadcast();

        console.log("BucketToken deployed at:", address(token));
        console.log("Token Name:", token.name());
        console.log("Token Symbol:", token.symbol());
        console.log("Total Supply:", token.totalSupply() / 10**18, "tokens");
        console.log("Owner:", token.owner());

        return token;
    }
}
