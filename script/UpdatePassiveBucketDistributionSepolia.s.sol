// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";

/// @notice Update the existing Sepolia PassiveBucket target to 75% ETH / 25% LINK.
/// @dev Run with --sig run() and an explicit broadcast only after reviewing the simulation.
contract UpdatePassiveBucketDistributionSepolia is Script {
    uint256 private constant ETH_WEIGHT = 97;
    uint256 private constant LINK_WEIGHT = 3;

    function run() external {
        string memory json = vm.readFile("./configs/sepolia.json");
        address proxy = vm.envAddress("PASSIVE_BUCKET_PROXY_ADDRESS");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        address link = _findToken(json, "LINK");
        address bucketInfoAddress = vm.parseJsonAddress(json, ".deployment.bucketInfoAddress");

        require(block.chainid == 11155111, "This script is restricted to Sepolia");
        require(proxy.code.length > 0, "PassiveBucket proxy has no code");
        require(link != address(0), "LINK address missing from config");
        require(bucketInfoAddress != address(0), "BucketInfo address missing from config");
        require(IBucketInfo(bucketInfoAddress).isTokenValid(address(0)), "ETH is not valid in BucketInfo");
        require(IBucketInfo(bucketInfoAddress).isTokenValid(link), "LINK is not valid in BucketInfo");

        PassiveBucket bucket = PassiveBucket(payable(proxy));
    require(signer == bucket.owner(), "PRIVATE_KEY must belong to PassiveBucket owner");
        require(bucket.isBucketAccountable(), "PassiveBucket owner is not accountable");

        PassiveBucket.BucketDistribution[] memory distributions = new PassiveBucket.BucketDistribution[](2);
        distributions[0] = PassiveBucket.BucketDistribution({token: address(0), weight: ETH_WEIGHT});
        distributions[1] = PassiveBucket.BucketDistribution({token: link, weight: LINK_WEIGHT});

        console.log("PassiveBucket proxy:", proxy);
        console.log("Owner:", bucket.owner());
        console.log("New distribution:");
        console.log("  ETH weight:", ETH_WEIGHT);
        console.log("  LINK address:", link);
        console.log("  LINK weight:", LINK_WEIGHT);

        require(
            keccak256(bytes(vm.envOr("CONFIRM_SEPOLIA_DISTRIBUTION_UPDATE", string("")))) == keccak256(bytes("YES")),
            "Set CONFIRM_SEPOLIA_DISTRIBUTION_UPDATE=YES to confirm this Sepolia update"
        );

        vm.startBroadcast(privateKey);
        bucket.updateBucketDistributions(distributions);
        vm.stopBroadcast();
        console.log("PassiveBucket distribution updated.");
    }

    function _findToken(string memory json, string memory symbol) private pure returns (address) {
        for (uint256 i = 0; i < 100; i++) {
            string memory path = string.concat(".tokens[", vm.toString(i), "]");
            try vm.parseJsonString(json, string.concat(path, ".symbol")) returns (string memory configuredSymbol) {
                if (keccak256(bytes(configuredSymbol)) == keccak256(bytes(symbol))) {
                    return vm.parseJsonAddress(json, string.concat(path, ".tokenAddress"));
                }
            } catch {
                break;
            }
        }
        return address(0);
    }
}