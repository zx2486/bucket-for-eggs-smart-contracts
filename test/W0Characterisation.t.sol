// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BucketInfo} from "../src/BucketInfo.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {MockV3Aggregator} from "@chainlink/tests/MockV3Aggregator.sol";

import {MockBucketInfoForPassive, MockERC20, MockOneInchRouter} from "./PassiveBucket.t.sol";

contract W0CharacterisationBucketInfoTest is Test {
    BucketInfo public bucketInfo;
    address public nativeToken;

    function setUp() public {
        bucketInfo = new BucketInfo();
        nativeToken = address(0);
    }

    function test_CharacterisationManualPriceStalenessBoundaryStillEnforced() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);

        vm.warp(block.timestamp + 30 days);
        assertEq(bucketInfo.getTokenPrice(nativeToken), 100e8);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("Price is outdated"));
        bucketInfo.getTokenPrice(nativeToken);
    }
}

contract W0CharacterisationPassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA; // 18 decimals
    MockERC20 public tokenB; // 6 decimals

    address public user1;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 2000e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    function setUp() public {
        user1 = makeAddr("user1");

        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new PassiveBucket(address(registry));
        registry.setAuthorizedFactory(address(this), true);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(tokenB), 20);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        vm.deal(user1, 100 ether);
        tokenA.mint(user1, 100e18);
        tokenB.mint(user1, 100000e6);
    }

    function test_CharacterisationUpdateBucketInfoGatedOnBucketInfoOwnerNotVaultOwner() public {
        address vaultOwner = bucket.owner();
        address bucketInfoOwner = makeAddr("bucketInfoOwner");
        bucketInfo.setOwner(bucketInfoOwner);
        assertTrue(vaultOwner != bucketInfoOwner);

        MockBucketInfoForPassive newBucketInfo = new MockBucketInfoForPassive();

        vm.prank(vaultOwner);
        vm.expectRevert(BucketVaultBase.UnauthorizedBucketInfoUpdate.selector);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.prank(bucketInfoOwner);
        bucket.proposeUpdateBucketInfo(address(newBucketInfo));

        vm.warp(block.timestamp + bucket.BUCKET_INFO_UPDATE_TIMELOCK_DELAY());
        bucket.executeUpdateBucketInfo(); // permissionless once the delay has elapsed
        assertEq(address(bucket.bucketInfo()), address(newBucketInfo));
    }
}
