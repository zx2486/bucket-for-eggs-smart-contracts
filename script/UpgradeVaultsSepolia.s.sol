// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {IImplementationRegistry} from "../src/interfaces/IImplementationRegistry.sol";

interface IUpgradeTarget {
    function owner() external view returns (address);
    function REGISTRY() external view returns (IImplementationRegistry);
    function upgradeToAndCall(address implementation, bytes calldata data) external payable;
    function queueUpgrade(address implementation) external;
    function UPGRADE_TIMELOCK_DELAY() external view returns (uint256);
    function upgradeEta() external view returns (uint256);
    function pendingImplementation() external view returns (address);
    function oneInchRouter() external view returns (address);
    function bucketInfo() external view returns (address);
    function totalSupply() external view returns (uint256);
    function calculateTotalValue() external view returns (uint256);
    function getHeldTokens() external view returns (address[] memory);
    function balanceOf(address account) external view returns (uint256);
    function redeemForStable(uint256, address, uint256) external;
}

contract UpgradeVaultsSepolia is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "This script is restricted to Sepolia");
        string memory phase = vm.envString("UPGRADE_PHASE");
        bool broadcasts = _isWritePhase(phase);
        if (broadcasts) {
            require(
                keccak256(bytes(vm.envOr("CONFIRM_SEPOLIA_VAULT_UPGRADE", string("")))) == keccak256(bytes("YES")),
                "Set CONFIRM_SEPOLIA_VAULT_UPGRADE=YES to confirm"
            );
        }
        address[] memory active = _targets("ACTIVE_BUCKET_PROXY_ADDRESS");
        address[] memory passive = _targets("PASSIVE_BUCKET_PROXY_ADDRESS");
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (broadcasts) require(privateKey != 0, "Export PRIVATE_KEY in your shell");
        address signer = privateKey == 0 ? address(0) : vm.addr(privateKey);
        require(active.length > 0 || passive.length > 0, "Export at least one vault target");
        string memory json = vm.readFile("./configs/sepolia.json");
        address router = vm.parseJsonAddress(json, ".deployment.oneInchRouter");

        _preflight(active, signer, phase);
        _preflight(passive, signer, phase);
        if (_same(phase, "approve")) {
            _requireRegistryOwner(active, signer);
            _requireRegistryOwner(passive, signer);
        }
        if (_same(phase, "deploy-impl")) {
            require(router.code.length > 0, "Configured 1inch router has no code");
        }

        if (_same(phase, "deploy-impl")) {
            _deploy(active, true, router, privateKey);
            _deploy(passive, false, router, privateKey);
        } else if (_same(phase, "approve")) {
            _approve(active, IImplementationRegistry.Kind.ActiveBucket, signer, privateKey);
            _approve(passive, IImplementationRegistry.Kind.PassiveBucket, signer, privateKey);
        } else if (_same(phase, "queue")) {
            _queue(active, "NEW_ACTIVE_IMPLEMENTATION", signer, privateKey);
            _queue(passive, "NEW_PASSIVE_IMPLEMENTATION", signer, privateKey);
        } else if (_same(phase, "execute")) {
            _execute(active, "NEW_ACTIVE_IMPLEMENTATION", signer, privateKey);
            _execute(passive, "NEW_PASSIVE_IMPLEMENTATION", signer, privateKey);
        } else if (_same(phase, "snapshot")) {
            console.log(_snapshotJson(active, passive));
        } else if (_same(phase, "check")) {
            string memory snapshot = vm.envString("UPGRADE_SNAPSHOT_JSON");
            _check(active, "NEW_ACTIVE_IMPLEMENTATION", router, snapshot, "active");
            _check(passive, "NEW_PASSIVE_IMPLEMENTATION", router, snapshot, "passive");
        } else {
            revert("UPGRADE_PHASE must be deploy-impl, approve, queue, execute, snapshot, or check");
        }
    }

    function _preflight(address[] memory targets, address signer, string memory phase) private view {
        if (targets.length == 0) return;
        for (uint256 i; i < targets.length; ++i) {
            IUpgradeTarget vault = IUpgradeTarget(targets[i]);
            require(targets[i].code.length > 0, "Vault proxy has no code");
            address implementation = address(uint160(uint256(vm.load(targets[i], IMPLEMENTATION_SLOT))));
            require(implementation.code.length > 0, "Current implementation has no code");
            (bool delayOk, bytes memory delayData) =
                targets[i].staticcall(abi.encodeWithSelector(IUpgradeTarget.UPGRADE_TIMELOCK_DELAY.selector));
            require(delayOk && delayData.length >= 32, "Vault lacks upgrade timelock; stop and escalate");
            require(abi.decode(delayData, (uint256)) == 48 hours, "Unexpected vault timelock delay");
            (bool pendingOk, bytes memory pendingData) =
                targets[i].staticcall(abi.encodeWithSelector(IUpgradeTarget.pendingImplementation.selector));
            require(pendingOk && pendingData.length >= 32, "Vault lacks upgrade queue state; stop and escalate");
            (bool etaOk, bytes memory etaData) =
                targets[i].staticcall(abi.encodeWithSelector(IUpgradeTarget.upgradeEta.selector));
            require(etaOk && etaData.length >= 32, "Vault lacks upgrade queue state; stop and escalate");
            require(address(vault.REGISTRY()).code.length > 0, "Vault registry has no code");
            if (_same(phase, "queue") || _same(phase, "execute")) {
                require(vault.owner() == signer, "Signer must own every target vault");
            }
            console.log("Preflight vault:", targets[i]);
            console.log("  implementation:", implementation);
            console.log("  owner:", vault.owner());
            console.log("  registry:", address(vault.REGISTRY()));
        }
    }

    function _deploy(address[] memory targets, bool active, address router, uint256 privateKey) private {
        if (targets.length == 0) return;
        address registry = address(IUpgradeTarget(targets[0]).REGISTRY());
        for (uint256 i = 1; i < targets.length; ++i) {
            require(address(IUpgradeTarget(targets[i]).REGISTRY()) == registry, "Targets use different registries");
        }
        vm.startBroadcast(privateKey);
        address implementation =
            active ? address(new ActiveBucket(registry, router)) : address(new PassiveBucket(registry, router));
        vm.stopBroadcast();
        console.log(active ? "NEW_ACTIVE_IMPLEMENTATION:" : "NEW_PASSIVE_IMPLEMENTATION:", implementation);
    }

    function _approve(address[] memory targets, IImplementationRegistry.Kind kind, address signer, uint256 privateKey)
        private
    {
        if (targets.length == 0) return;
        IImplementationRegistry registry = IUpgradeTarget(targets[0]).REGISTRY();
        for (uint256 i = 1; i < targets.length; ++i) {
            require(
                address(IUpgradeTarget(targets[i]).REGISTRY()) == address(registry), "Targets use different registries"
            );
        }
        (bool ownerOk, bytes memory ownerData) = address(registry).staticcall(abi.encodeWithSignature("owner()"));
        require(ownerOk && abi.decode(ownerData, (address)) == signer, "Signer must own ImplementationRegistry");
        string memory implementationEnv = kind == IImplementationRegistry.Kind.ActiveBucket
            ? "NEW_ACTIVE_IMPLEMENTATION"
            : "NEW_PASSIVE_IMPLEMENTATION";
        address implementation = vm.envAddress(implementationEnv);
        require(implementation.code.length > 0, "New implementation has no code");
        require(_implementationRegistry(implementation) == address(registry), "Implementation registry mismatch");
        vm.startBroadcast(privateKey);
        registry.approve(kind, implementation);
        vm.stopBroadcast();
        console.log("Approved implementation:", implementation);
    }

    function _queue(address[] memory targets, string memory implementationEnv, address signer, uint256 privateKey)
        private
    {
        address implementation = vm.envAddress(implementationEnv);
        require(implementation.code.length > 0, "New implementation has no code");
        for (uint256 i; i < targets.length; ++i) {
            IUpgradeTarget vault = IUpgradeTarget(targets[i]);
            require(vault.owner() == signer, "Signer must own target vault");
            require(vault.pendingImplementation() == address(0), "Vault already has a queued upgrade");
            require(
                address(vault.REGISTRY()) == _implementationRegistry(implementation), "Implementation registry mismatch"
            );
            vm.startBroadcast(privateKey);
            vault.queueUpgrade(implementation);
            vm.stopBroadcast();
            require(vault.pendingImplementation() == implementation, "Queued implementation mismatch");
            require(vault.upgradeEta() >= block.timestamp + 48 hours, "Upgrade timelock was shortened");
            console.log("Queued upgrade for:", targets[i]);
            console.log("  execute after timestamp:", vault.upgradeEta());
        }
    }

    function _execute(address[] memory targets, string memory implementationEnv, address signer, uint256 privateKey)
        private
    {
        address implementation = vm.envAddress(implementationEnv);
        require(implementation.code.length > 0, "New implementation has no code");
        for (uint256 i; i < targets.length; ++i) {
            IUpgradeTarget vault = IUpgradeTarget(targets[i]);
            require(vault.owner() == signer, "Signer must own target vault");
            require(vault.pendingImplementation() == implementation, "Pending implementation mismatch");
            vm.startBroadcast(privateKey);
            vault.upgradeToAndCall(implementation, bytes(""));
            vm.stopBroadcast();
            console.log("Upgraded vault:", targets[i]);
        }
    }

    function _snapshotJson(address[] memory active, address[] memory passive) private view returns (string memory) {
        string memory json = string.concat("{\"active\":{", _appendSnapshots(active, "active"), "},\"passive\":{");
        json = string.concat(json, _appendSnapshots(passive, "passive"), "}}");
        return json;
    }

    function _appendSnapshots(address[] memory targets, string memory kind) private view returns (string memory json) {
        for (uint256 i; i < targets.length; ++i) {
            IUpgradeTarget vault = IUpgradeTarget(targets[i]);
            bytes32 snapshot = _snapshotHash(vault, targets[i], kind);
            json = string.concat(
                json, i == 0 ? "" : ",", "\"", vm.toString(targets[i]), "\":\"", vm.toString(snapshot), "\""
            );
        }
    }

    function _snapshotHash(IUpgradeTarget vault, address target, string memory kind) private view returns (bytes32) {
        address[] memory tokens = vault.getHeldTokens();
        bytes memory state = abi.encode(
            target,
            vault.owner(),
            vault.bucketInfo(),
            address(vault.REGISTRY()),
            vault.totalSupply(),
            vault.calculateTotalValue(),
            tokens,
            _tokenBalances(target, tokens),
            _distributions(target, kind)
        );
        return keccak256(state);
    }

    function _tokenBalances(address target, address[] memory tokens) private view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = _tokenBalance(tokens[i], target);
        }
    }

    function _distributions(address target, string memory kind) private view returns (bytes32) {
        if (!_same(kind, "passive")) return bytes32(0);
        PassiveBucket.BucketDistribution[] memory values = PassiveBucket(payable(target)).getBucketDistributions();
        return keccak256(abi.encode(values));
    }

    function _check(
        address[] memory targets,
        string memory implementationEnv,
        address router,
        string memory snapshot,
        string memory kind
    ) private view {
        address expected = vm.envAddress(implementationEnv);
        require(expected.code.length > 0, "Expected implementation has no code");
        for (uint256 i; i < targets.length; ++i) {
            IUpgradeTarget vault = IUpgradeTarget(targets[i]);
            require(
                address(uint160(uint256(vm.load(targets[i], IMPLEMENTATION_SLOT)))) == expected,
                "Implementation slot mismatch"
            );
            require(vault.oneInchRouter() == router, "1inch router mismatch");
            require(vault.pendingImplementation() == address(0), "Upgrade remains pending");
            string memory snapshotPath = string.concat(".", kind, ".", vm.toString(targets[i]));
            bytes32 expectedSnapshot = vm.parseJsonBytes32(snapshot, snapshotPath);
            require(
                _snapshotHash(vault, targets[i], kind) == expectedSnapshot, "Post-upgrade state differs from snapshot"
            );
            (bool stableExitDisabled, bytes memory stableExitResult) =
                targets[i].staticcall(abi.encodeWithSelector(IUpgradeTarget.redeemForStable.selector, 0, address(0), 0));
            require(
                !stableExitDisabled && stableExitResult.length >= 4
                    && bytes4(stableExitResult) == bytes4(keccak256("RedeemForStableDisabled()")),
                "Stable redemption stub did not revert with RedeemForStableDisabled"
            );
            _logSnapshot(vault, targets[i], expected);
        }
    }

    function _logSnapshot(IUpgradeTarget vault, address target, address implementation) private view {
        address[] memory tokens = vault.getHeldTokens();
        console.log("Post-upgrade snapshot vault:", target);
        console.log("  owner:", vault.owner());
        console.log("  BucketInfo:", vault.bucketInfo());
        console.log("  registry:", address(vault.REGISTRY()));
        console.log("  total supply:", vault.totalSupply());
        console.log("  total value:", vault.calculateTotalValue());
        console.log("  held token count:", tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            console.log("  token:", tokens[i]);
            console.log("  balance:", _tokenBalance(tokens[i], target));
        }
        if (_isPassive(implementation)) _logDistributions(target);
    }

    function _targets(string memory variable) private view returns (address[] memory result) {
        string memory value = vm.envOr(variable, string(""));
        require(bytes(value).length > 0, string.concat("Export ", variable, " with comma-separated proxy addresses"));
        bytes memory input = bytes(value);
        uint256 count = 1;
        for (uint256 i; i < input.length; ++i) {
            if (input[i] == ",") ++count;
        }
        result = new address[](count);
        uint256 start;
        uint256 index;
        for (uint256 i; i <= input.length; ++i) {
            if (i == input.length || input[i] == ",") {
                bytes memory item = new bytes(i - start);
                for (uint256 j; j < item.length; ++j) {
                    item[j] = input[start + j];
                }
                result[index++] = vm.parseAddress(string(item));
                start = i + 1;
            }
        }
    }

    function _requireRegistryOwner(address[] memory targets, address signer) private view {
        for (uint256 i; i < targets.length; ++i) {
            address registry = address(IUpgradeTarget(targets[i]).REGISTRY());
            (bool ok, bytes memory result) = registry.staticcall(abi.encodeWithSignature("owner()"));
            require(ok && result.length >= 32 && abi.decode(result, (address)) == signer, "Signer must own registry");
        }
    }

    function _implementationRegistry(address implementation) private view returns (address registry) {
        (bool ok, bytes memory data) = implementation.staticcall(abi.encodeWithSignature("REGISTRY()"));
        require(ok && data.length >= 32, "Cannot read new implementation registry");
        registry = abi.decode(data, (address));
    }

    function _tokenBalance(address token, address account) private view returns (uint256 balance) {
        if (token == address(0)) return account.balance;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(ok && data.length >= 32, "Cannot read held-token balance");
        balance = abi.decode(data, (uint256));
    }

    function _logDistributions(address target) private view {
        PassiveBucket.BucketDistribution[] memory distributions =
            PassiveBucket(payable(target)).getBucketDistributions();
        for (uint256 i; i < distributions.length; ++i) {
            console.log("  distribution token:", distributions[i].token);
            console.log("  distribution weight:", distributions[i].weight);
        }
    }

    function _isPassive(address implementation) private view returns (bool) {
        (bool ok,) = implementation.staticcall(abi.encodeWithSelector(PassiveBucket.getBucketDistributions.selector));
        return ok;
    }

    function _isWritePhase(string memory phase) private pure returns (bool) {
        return
            _same(phase, "deploy-impl") || _same(phase, "approve") || _same(phase, "queue") || _same(phase, "execute");
    }

    function _same(string memory left, string memory right) private pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
