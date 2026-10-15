// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

contract BucketInfoSurfaceConformanceTest is Test {
    string[] private ownerAddressSurface;
    string[] private platformFeeSurface;
    string[] private tokenPriceSurface;
    string[] private tokenWhitelistSurface;
    string[] private priceFeedSurface;

    string[] private blacklistManagementSurface;

    string[] private allowedExceptions;

    function setUp() public {
        ownerAddressSurface.push("transferOwnership");
        ownerAddressSurface.push("acceptOwnership");
        ownerAddressSurface.push("renounceOwnership");

        platformFeeSurface.push("proposePlatformFee");
        platformFeeSurface.push("executePlatformFee");
        platformFeeSurface.push("cancelPlatformFee");

        tokenPriceSurface.push("setTokenPrice");
        tokenPriceSurface.push("batchSetTokenPrices");

        tokenWhitelistSurface.push("proposeWhitelistAddition");
        tokenWhitelistSurface.push("executeWhitelistAddition");
        tokenWhitelistSurface.push("cancelWhitelistAddition");
        tokenWhitelistSurface.push("removeTokenWhitelist");
        tokenWhitelistSurface.push("batchProposeWhitelistAdditions");
        tokenWhitelistSurface.push("batchExecuteWhitelistAdditions");
        tokenWhitelistSurface.push("batchRemoveTokenWhitelist");

        priceFeedSurface.push("proposePriceFeed");
        priceFeedSurface.push("executePriceFeed");
        priceFeedSurface.push("cancelPriceFeed");
        priceFeedSurface.push("proposeBatchPriceFeeds");
        priceFeedSurface.push("executeBatchPriceFeeds");
        priceFeedSurface.push("setMaxPriceStaleness");

        allowedExceptions.push("pausePlatform");
        allowedExceptions.push("unpausePlatform");
        allowedExceptions.push("withdrawAccumulatedFees");
        allowedExceptions.push("withdrawAccumulatedETHFees");
        allowedExceptions.push("withdrawAccumulatedFeesToStable");

        blacklistManagementSurface.push("blacklistAddress");
        blacklistManagementSurface.push("removeBlacklist");
        blacklistManagementSurface.push("batchBlacklistAddresses");
        blacklistManagementSurface.push("batchRemoveBlacklist");
    }

    function test_BucketInfoMutableSurfaceIsExactlyTheAllowedSet() public view {
        string memory json = vm.readFile("out/BucketInfo.sol/BucketInfo.json");

        uint256 checked = 0;
        for (uint256 i = 0; i < 1000; i++) {
            string memory typePath = string.concat(".abi[", vm.toString(i), "].type");
            string memory typ;
            try vm.parseJsonString(json, typePath) returns (string memory t) {
                typ = t;
            } catch {
                break;
            }

            if (!_streq(typ, "function")) continue;

            string memory mutability =
                vm.parseJsonString(json, string.concat(".abi[", vm.toString(i), "].stateMutability"));
            if (_streq(mutability, "view") || _streq(mutability, "pure")) continue;

            string memory name = vm.parseJsonString(json, string.concat(".abi[", vm.toString(i), "].name"));
            checked++;

            assertTrue(_isInAnyBucket(name), string.concat("Unrecognised mutable function on BucketInfo: ", name));
        }

        assertGe(
            checked, 25, "Expected at least 25 mutable functions on BucketInfo -- ABI read may have failed silently"
        );
    }

    function _isInAnyBucket(string memory name) private view returns (bool) {
        return _contains(ownerAddressSurface, name) || _contains(platformFeeSurface, name)
            || _contains(tokenPriceSurface, name) || _contains(tokenWhitelistSurface, name)
            || _contains(priceFeedSurface, name) || _contains(blacklistManagementSurface, name)
            || _contains(allowedExceptions, name);
    }

    function _contains(string[] memory list, string memory needle) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (_streq(list[i], needle)) return true;
        }
        return false;
    }

    function _streq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
