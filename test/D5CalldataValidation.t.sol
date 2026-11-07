// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {OneInchCalldataLib} from "../src/libraries/OneInchCalldataLib.sol";

contract D5CalldataValidationHarness {
    function validate(bytes calldata data, address src, address dst, uint256 amount, uint256 minReturn) external view {
        OneInchCalldataLib.validateSwapCalldata(data, src, dst, amount, minReturn);
    }
}

contract D5CalldataValidationTest is Test {
    address private constant EXECUTOR = address(0x1234);
    address private constant SRC = address(0x5678);
    address private constant DST = address(0x9abc);
    address private harness;

    function setUp() public {
        harness = address(new D5CalldataValidationHarness());
    }

    function testSwapSelectorMatchesV6Signature() public pure {
        assertEq(
            OneInchCalldataLib.SWAP_SELECTOR,
            bytes4(keccak256("swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)"))
        );
    }

    function testAcceptsPayloadBoundToTypedIntent() public view {
        bytes memory data = _calldata(SRC, DST, harness, 10 ether, 9 ether, 0);
        D5CalldataValidationHarness(harness).validate(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsNonSwapSelector() public {
        bytes memory data = abi.encodePacked(bytes4(0xdeadbeef), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(OneInchCalldataLib.InvalidSwapSelector.selector, bytes4(0xdeadbeef)));
        D5CalldataValidationHarness(harness).validate(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsMalformedSwapPayload() public {
        bytes memory data = abi.encodePacked(OneInchCalldataLib.SWAP_SELECTOR, bytes32(0));
        vm.expectRevert(OneInchCalldataLib.MalformedSwapPayload.selector);
        D5CalldataValidationHarness(harness).validate(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsMismatchedSourceToken() public {
        bytes memory data = _calldata(address(0x1111), DST, harness, 10 ether, 9 ether, 0);
        _expectMalformed(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsMismatchedDestinationToken() public {
        bytes memory data = _calldata(SRC, address(0x2222), harness, 10 ether, 9 ether, 0);
        _expectMalformed(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsRedirectedDestinationReceiver() public {
        bytes memory data = _calldata(SRC, DST, address(0x3333), 10 ether, 9 ether, 0);
        _expectMalformed(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsMismatchedAmount() public {
        bytes memory data = _calldata(SRC, DST, harness, 11 ether, 9 ether, 0);
        _expectMalformed(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsRouterMinimumBelowTypedMinimum() public {
        bytes memory data = _calldata(SRC, DST, harness, 10 ether, 8 ether, 0);
        _expectMalformed(data, SRC, DST, 10 ether, 9 ether);
    }

    function testRejectsPartialFillFlag() public {
        bytes memory data = _calldata(SRC, DST, harness, 10 ether, 9 ether, 1);
        vm.expectRevert(OneInchCalldataLib.PartialFillNotAllowed.selector);
        D5CalldataValidationHarness(harness).validate(data, SRC, DST, 10 ether, 9 ether);
    }

    function testNormalizesOneInchNativeMarker() public view {
        address oneInchNative = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        bytes memory data = _calldata(oneInchNative, DST, harness, 1 ether, 0.9 ether, 0);
        D5CalldataValidationHarness(harness).validate(data, address(0), DST, 1 ether, 0.9 ether);
    }

    function _expectMalformed(bytes memory data, address src, address dst, uint256 amount, uint256 minReturn) private {
        vm.expectRevert(OneInchCalldataLib.MalformedSwapPayload.selector);
        D5CalldataValidationHarness(harness).validate(data, src, dst, amount, minReturn);
    }

    function _calldata(address src, address dst, address recipient, uint256 amount, uint256 minReturn, uint256 flags)
        private
        pure
        returns (bytes memory)
    {
        OneInchCalldataLib.SwapDescription memory description = OneInchCalldataLib.SwapDescription({
            srcToken: src,
            dstToken: dst,
            srcReceiver: address(0),
            dstReceiver: recipient,
            amount: amount,
            minReturnAmount: minReturn,
            flags: flags
        });
        return abi.encodeWithSelector(OneInchCalldataLib.SWAP_SELECTOR, EXECUTOR, description, bytes("route data"));
    }
}
