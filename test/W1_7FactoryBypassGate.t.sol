// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ActiveBucket} from "../src/ActiveBucket.sol";
import {ActiveBucketFactory} from "../src/ActiveBucketFactory.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {PassiveBucketFactory} from "../src/PassiveBucketFactory.sol";
import {PureMembership} from "../src/PureMembership.sol";
import {PureMembershipFactory} from "../src/PureMembershipFactory.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {MockBucketInfoForPassive, MockERC20, MockOneInchRouter} from "./PassiveBucket.t.sol";

contract W1_7GateActiveBucketTest is Test {
    ActiveBucket public implementation;
    ImplementationRegistry public registry;

    address public bucketInfoStandIn;
    address public oneInchRouterStandIn;

    function setUp() public {
        registry = new ImplementationRegistry(address(this));
        implementation = new ActiveBucket(address(registry), address(this));
        bucketInfoStandIn = makeAddr("activeBucketInfoStandIn");
        oneInchRouterStandIn = makeAddr("activeOneInchRouterStandIn");
    }

    function test_RevertDirectProxyBypass_UnauthorizedCaller() public {
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, bucketInfoStandIn, "Evil Bucket", "EVIL"
        );
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_RevertDirectProxyBypass_UnauthorizedFactoryLookalike() public {
        ActiveBucketFactory rogueFactory = new ActiveBucketFactory(address(implementation), bucketInfoStandIn);
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        rogueFactory.createActiveBucket("Evil Bucket", "EVIL");
    }

    function test_FactoryPathStillWorks() public {
        ActiveBucketFactory factory = new ActiveBucketFactory(address(implementation), bucketInfoStandIn);
        registry.setAuthorizedFactory(address(factory), true);

        address proxyAddr = factory.createActiveBucket("Active Bucket Share", "aBKT");
        ActiveBucket bucket = ActiveBucket(payable(proxyAddr));

        assertEq(bucket.owner(), address(this));
        assertEq(address(bucket.bucketInfo()), bucketInfoStandIn);
        assertEq(bucket.oneInchRouter(), address(this));
    }
}

contract W1_7GatePassiveBucketTest is Test {
    PassiveBucket public implementation;
    ImplementationRegistry public registry;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA;
    MockOneInchRouter public oneInchRouter;

    address public bucketInfoStandIn;
    address public oneInchRouterStandIn;

    uint256 constant TOKEN_A_PRICE = 2000e8;

    function setUp() public {
        registry = new ImplementationRegistry(address(this));
        implementation = new PassiveBucket(address(registry), address(this));
        bucketInfoStandIn = makeAddr("passiveBucketInfoStandIn");
        oneInchRouterStandIn = makeAddr("passiveOneInchRouterStandIn");

        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        oneInchRouter = new MockOneInchRouter();
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
    }

    function _singleTokenDistributions() internal view returns (PassiveBucket.BucketDistribution[] memory dists) {
        dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(tokenA), 100);
    }

    function test_RevertDirectProxyBypass_UnauthorizedCaller() public {
        PassiveBucket.BucketDistribution[] memory dists = _singleTokenDistributions();
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, bucketInfoStandIn, dists, "Evil Bucket", "EVIL"
        );
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_RevertDirectProxyBypass_UnauthorizedFactoryLookalike() public {
        PassiveBucket.BucketDistribution[] memory dists = _singleTokenDistributions();
        PassiveBucketFactory rogueFactory = new PassiveBucketFactory(address(implementation), bucketInfoStandIn);
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        rogueFactory.createPassiveBucket(dists, "Evil Bucket", "EVIL");
    }

    function test_FactoryPathStillWorks() public {
        PassiveBucket.BucketDistribution[] memory dists = _singleTokenDistributions();
        PassiveBucketFactory factory = new PassiveBucketFactory(address(implementation), address(bucketInfo));
        registry.setAuthorizedFactory(address(factory), true);

        address proxyAddr = factory.createPassiveBucket(dists, "PassiveBucket Share", "pBKT");
        PassiveBucket bucket = PassiveBucket(payable(proxyAddr));

        assertEq(bucket.owner(), address(this));
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), address(this));
    }
}

contract W1_7GateMembershipTest is Test {
    PureMembership public implementation;
    ImplementationRegistry public registry;

    address public bucketInfoStandIn;

    function setUp() public {
        registry = new ImplementationRegistry(address(this));
        implementation = new PureMembership(address(registry));
        bucketInfoStandIn = makeAddr("membershipBucketInfoStandIn");
    }

    function _singleConfig() internal pure returns (PureMembership.MembershipConfig[] memory configs) {
        configs = new PureMembership.MembershipConfig[](1);
        configs[0] =
            PureMembership.MembershipConfig({tokenId: 1, level: 1, name: "Basic", price: 10e8, duration: 30 days});
    }

    function test_RevertDirectProxyBypass_UnauthorizedCaller() public {
        bytes memory initData =
            abi.encodeWithSelector(PureMembership.initialize.selector, _singleConfig(), bucketInfoStandIn, "");
        vm.expectRevert(PureMembership.UnauthorizedInitializer.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_RevertDirectProxyBypass_UnauthorizedFactoryLookalike() public {
        PureMembershipFactory rogueFactory = new PureMembershipFactory(address(implementation), bucketInfoStandIn);
        vm.expectRevert(PureMembership.UnauthorizedInitializer.selector);
        rogueFactory.createPureMembership(_singleConfig(), "");
    }

    function test_FactoryPathStillWorks() public {
        PureMembershipFactory factory = new PureMembershipFactory(address(implementation), bucketInfoStandIn);
        registry.setAuthorizedFactory(address(factory), true);

        address payable proxyAddr = factory.createPureMembership(_singleConfig(), "https://example.com/{id}.json");
        PureMembership membership = PureMembership(proxyAddr);

        assertEq(membership.owner(), address(this));
        assertEq(address(membership.bucketInfo()), bucketInfoStandIn);
    }
}
