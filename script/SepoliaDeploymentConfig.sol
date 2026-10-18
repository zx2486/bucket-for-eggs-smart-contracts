// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";

abstract contract SepoliaDeploymentConfig is Script {
    function _loadSepoliaConfig() internal view returns (string memory json) {
        return vm.readFile("./configs/sepolia.json");
    }

    function _configuredAddress(string memory json, string memory jsonPath) internal pure returns (address) {
        return vm.parseJsonAddress(json, jsonPath);
    }

    function _tokenAddressForSymbol(string memory json, string memory symbol) internal pure returns (address) {
        for (uint256 i = 0; i < 100; i++) {
            string memory itemPath = string.concat(".tokens[", vm.toString(i), "]");
            try vm.parseJsonString(json, string.concat(itemPath, ".symbol")) returns (string memory configuredSymbol) {
                if (keccak256(bytes(configuredSymbol)) == keccak256(bytes(symbol))) {
                    return vm.parseJsonAddress(json, string.concat(itemPath, ".tokenAddress"));
                }
            } catch {
                break;
            }
        }
        revert(string.concat("Token symbol missing from deployment config: ", symbol));
    }

    function _requireRegistryOwner(address registryAddress, address expectedOwner) internal view {
        require(registryAddress.code.length > 0, "ImplementationRegistry has no code");
        (bool success, bytes memory result) = registryAddress.staticcall(abi.encodeWithSignature("owner()"));
        require(success && result.length >= 32, "Cannot read ImplementationRegistry owner");
        require(abi.decode(result, (address)) == expectedOwner, "Deployer must own ImplementationRegistry");
    }
}
