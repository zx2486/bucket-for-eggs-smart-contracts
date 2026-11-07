// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActiveBucket} from "../../src/ActiveBucket.sol";
import {ImplementationRegistry} from "../../src/ImplementationRegistry.sol";
import {IImplementationRegistry} from "../../src/interfaces/IImplementationRegistry.sol";
import {BucketInfo} from "../../src/BucketInfo.sol";

contract MockRouter {
    fallback() external payable {}
}

contract UpgradeVaultsSepoliaTest is Test {
    address private router;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private owner = address(0xBEEF);
    address private platform = address(this);
    ImplementationRegistry private registry;
    BucketInfo private bucketInfo;

    function setUp() external {
        registry = new ImplementationRegistry(platform);
        bucketInfo = new BucketInfo(platform, 100, 1);
        router = address(new MockRouter());
    }

    function testLegacyImplementationFixtureLinksAndUpgradesWithStatePreserved() external {
        address oldImplementation = _deployLegacyActiveBucket();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,string,string)", address(bucketInfo), router, "Legacy Active", "LA"
        );
        registry.setAuthorizedFactory(address(this), true);
        ERC1967Proxy proxyContract = new ERC1967Proxy(oldImplementation, initData);
        address proxy = address(proxyContract);
        ActiveBucket oldVault = ActiveBucket(payable(proxy));
        vm.prank(address(this));
        oldVault.transferOwnership(owner);

        ActiveBucket nextImplementation = new ActiveBucket(address(registry), router);
        registry.approve(IImplementationRegistry.Kind.ActiveBucket, address(nextImplementation));
        assertEq(oldVault.pendingImplementation(), address(0));
        assertEq(oldVault.upgradeEta(), 0);
        vm.prank(owner);
        oldVault.queueUpgrade(address(nextImplementation));
        uint256 eta = oldVault.upgradeEta();
        assertEq(eta, block.timestamp + 48 hours);
        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert();
        oldVault.upgradeToAndCall(address(nextImplementation), bytes(""));
        vm.warp(eta);
        vm.prank(owner);
        oldVault.upgradeToAndCall(address(nextImplementation), bytes(""));

        ActiveBucket upgraded = ActiveBucket(payable(proxy));
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), address(nextImplementation));
        assertEq(upgraded.owner(), owner);
        assertEq(address(upgraded.bucketInfo()), address(bucketInfo));
        assertEq(upgraded.oneInchRouter(), router);
        assertEq(upgraded.pendingImplementation(), address(0));
        (bool stableExitDisabled,) =
            proxy.call(abi.encodeWithSignature("redeemForStable(address,uint256,uint256)", address(0), 0, 0));
        assertFalse(stableExitDisabled);
    }

    function _deployLegacyActiveBucket() private returns (address implementation) {
        string memory root = "test/fixtures/d5/old-artifacts/";
        address governance = _deployLegacyLibrary("GovernanceLib");
        address oracle = _deployLegacyLibrary("OraclePricingLib");
        address payout = _deployLegacyLibrary("PayoutLib");
        address seizure = _deployLegacyLibrary("SeizureLib");
        address swapExecution = _deployLegacyLibrary("SwapExecutionLib");
        string memory json = vm.readFile(string.concat(root, "ActiveBucket.json"));
        string memory creationHex = vm.parseJsonString(json, ".bytecode.object");
        creationHex = _link(creationHex, "GovernanceLib", governance);
        creationHex = _link(creationHex, "OraclePricingLib", oracle);
        creationHex = _link(creationHex, "PayoutLib", payout);
        creationHex = _link(creationHex, "SeizureLib", seizure);
        creationHex = _link(creationHex, "SwapExecutionLib", swapExecution);
        bytes memory creation = abi.encodePacked(_decodeHex(creationHex), abi.encode(address(registry)));
        assembly {
            implementation := create(0, add(creation, 0x20), mload(creation))
        }
        require(implementation != address(0), "Legacy ActiveBucket deployment failed");
    }

    function _deployLegacyLibrary(string memory name) private returns (address deployed) {
        string memory json = vm.readFile(string.concat("test/fixtures/d5/old-artifacts/", name, ".json"));
        bytes memory creation = _decodeHex(vm.parseJsonString(json, ".bytecode.object"));
        assembly {
            deployed := create(0, add(creation, 0x20), mload(creation))
        }
        require(deployed != address(0), "Legacy library deployment failed");
    }

    function _referenceOffset(string memory libraryName, uint256 index) private pure returns (uint256) {
        if (keccak256(bytes(libraryName)) == keccak256("GovernanceLib")) {
            uint256[6] memory offsets = [uint256(3599), 5552, 7838, 8140, 10268, 17027];
            return offsets[index];
        }
        if (keccak256(bytes(libraryName)) == keccak256("OraclePricingLib")) {
            uint256[3] memory offsets = [uint256(6431), 10234, 14295];
            return offsets[index];
        }
        if (keccak256(bytes(libraryName)) == keccak256("PayoutLib")) {
            uint256[3] memory offsets = [uint256(14215), 14684, 16108];
            return offsets[index];
        }
        if (keccak256(bytes(libraryName)) == keccak256("SeizureLib")) {
            uint256[3] memory offsets = [uint256(5699), 8000, 9719];
            return offsets[index];
        }
        if (keccak256(bytes(libraryName)) == keccak256("SwapExecutionLib")) {
            uint256[7] memory offsets = [uint256(5011), 13415, 13565, 13613, 13755, 14016, 17282];
            return offsets[index];
        }
        revert("Unknown legacy library");
    }

    function _referenceCount(string memory libraryName) private pure returns (uint256) {
        if (keccak256(bytes(libraryName)) == keccak256("GovernanceLib")) return 6;
        if (keccak256(bytes(libraryName)) == keccak256("OraclePricingLib")) return 3;
        if (keccak256(bytes(libraryName)) == keccak256("PayoutLib")) return 3;
        if (keccak256(bytes(libraryName)) == keccak256("SeizureLib")) return 3;
        if (keccak256(bytes(libraryName)) == keccak256("SwapExecutionLib")) return 7;
        revert("Unknown legacy library");
    }

    function _decodeHex(string memory encoded) private pure returns (bytes memory result) {
        bytes memory input = bytes(encoded);
        require(input.length >= 2 && input[0] == "0" && input[1] == "x", "Invalid fixture bytecode");
        result = new bytes((input.length - 2) / 2);
        for (uint256 i; i < result.length; ++i) {
            result[i] = bytes1((_hexNibble(input[2 + i * 2]) << 4) | _hexNibble(input[3 + i * 2]));
        }
    }

    function _hexNibble(bytes1 character) private pure returns (uint8) {
        if (character >= "0" && character <= "9") return uint8(character) - uint8(bytes1("0"));
        if (character >= "a" && character <= "f") return uint8(character) - uint8(bytes1("a")) + 10;
        if (character >= "A" && character <= "F") return uint8(character) - uint8(bytes1("A")) + 10;
        revert("Invalid fixture bytecode hex");
    }

    function _link(string memory creation, string memory libraryName, address libraryAddress)
        private
        view
        returns (string memory)
    {
        uint256 referenceCount = _referenceCount(libraryName);
        bytes memory hexAddress = bytes(vm.toString(libraryAddress));
        for (uint256 i; i < referenceCount; ++i) {
            uint256 offset = _referenceOffset(libraryName, i);
            uint256 characterOffset = 2 + offset * 2;
            bytes memory patched = bytes(creation);
            for (uint256 j; j < 40; ++j) {
                patched[characterOffset + j] = hexAddress[j + 2];
            }
            creation = string(patched);
        }
        return creation;
    }
}
