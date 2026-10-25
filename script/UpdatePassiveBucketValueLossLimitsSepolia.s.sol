// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";

/// @notice Set a PassiveBucket's per-operation and per-epoch value-loss limits on Sepolia.
contract UpdatePassiveBucketValueLossLimitsSepolia is Script {
    uint256 private constant PER_OPERATION_LIMIT_BPS = 500; // 5%
    uint256 private constant EPOCH_BUDGET_BPS = 1_000; // 10%

    function run() external {
        require(block.chainid == 11155111, "This script is restricted to Sepolia");
        require(
            keccak256(bytes(vm.envOr("CONFIRM_SEPOLIA_VALUE_LOSS_UPDATE", string("")))) == keccak256(bytes("YES")),
            "Set CONFIRM_SEPOLIA_VALUE_LOSS_UPDATE=YES to confirm this Sepolia update"
        );

        address proxy = vm.envAddress("PASSIVE_BUCKET_PROXY_ADDRESS");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        require(proxy.code.length > 0, "PassiveBucket proxy has no code");

        PassiveBucket bucket = PassiveBucket(payable(proxy));
        require(signer == bucket.owner(), "PRIVATE_KEY must belong to PassiveBucket owner");

        console.log("PassiveBucket proxy:", proxy);
        console.log("Owner:", bucket.owner());
        console.log("Current maxValueLossBps:", bucket.maxValueLossBps());
        console.log("Current epochValueLossBudgetBps:", bucket.epochValueLossBudgetBps());
        console.log("New maxValueLossBps:", PER_OPERATION_LIMIT_BPS);
        console.log("New epochValueLossBudgetBps:", EPOCH_BUDGET_BPS);

        vm.startBroadcast(privateKey);
        bucket.setMaxValueLossBps(PER_OPERATION_LIMIT_BPS, EPOCH_BUDGET_BPS);
        vm.stopBroadcast();

        console.log("PassiveBucket value-loss limits updated.");
    }
}