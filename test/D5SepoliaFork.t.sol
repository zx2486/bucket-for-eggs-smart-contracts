// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

contract D5SepoliaForkTest is Test {
    address internal constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    bytes4 internal constant V6_SWAP_SELECTOR = 0x07ed2379;
    string internal constant FIXTURE_BLOCK_KEY = ".blockNumber";
    string internal constant FIXTURE_FROM_KEY = ".from";
    string internal constant FIXTURE_ROUTER_KEY = ".tx.to";
    string internal constant FIXTURE_CALLDATA_KEY = ".tx.data";

    function fixturePath(uint256 blockNumber) internal pure returns (string memory) {
        return string.concat("test/fixtures/1inch/sepolia-", vm.toString(blockNumber), ".json");
    }

    function testForkRecordedSepoliaSwap() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        uint256 fixtureBlock = vm.envOr("D5_SEPOLIA_FIXTURE_BLOCK", uint256(0));
        if (bytes(rpcUrl).length == 0 || fixtureBlock == 0) {
            vm.skip(true, "SEPOLIA_RPC_URL or D5_SEPOLIA_FIXTURE_BLOCK is not set");
        }
        string memory path = fixturePath(fixtureBlock);
        if (!vm.isFile(path)) vm.skip(true, "H-1 fixture is not present");

        string memory fixture = vm.readFile(path);
        uint256 blockNumber = vm.parseJsonUint(fixture, FIXTURE_BLOCK_KEY);
        assertEq(blockNumber, fixtureBlock, "fixture filename and block number differ");
        address from = vm.parseJsonAddress(fixture, FIXTURE_FROM_KEY);
        address router = vm.parseJsonAddress(fixture, FIXTURE_ROUTER_KEY);
        bytes memory routerCalldata = vm.parseJsonBytes(fixture, FIXTURE_CALLDATA_KEY);

        assertEq(router, ONEINCH_ROUTER, "fixture router differs from the fixed router");
        assertEq(bytes4(routerCalldata), V6_SWAP_SELECTOR, "fixture is not V6 swap calldata");
        assertEq(V6_SWAP_SELECTOR, bytes4(keccak256("swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)")));

        vm.createSelectFork(rpcUrl, blockNumber);
        assertEq(block.chainid, SEPOLIA_CHAIN_ID, "fork is not Sepolia");
        assertGt(from.code.length, 0, "fixture from address must be a deployed vault");
        assertGt(router.code.length, 0, "1inch router is not deployed at fixture block");

        fail("guarded vault replay awaits W-2 through W-5");
    }
}
