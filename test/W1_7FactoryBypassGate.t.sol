// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// ============================================================
// Task #33 (W1.7 direct-proxy-bypass fix) — gate suite.
//
// Design B: `ImplementationRegistry` gained `isAuthorizedFactory(address)` /
// `setAuthorizedFactory(address, bool)`. Every vault's `initialize()` now requires, as its FIRST
// check, that `REGISTRY.isAuthorizedFactory(msg.sender)` is true. Before this fix, anyone could
// deploy their own `ERC1967Proxy(implementation, initData)` directly against the shared
// implementation and call `initialize()` with an attacker-owned `bucketInfoAddr`, defeating the
// 00:44 oracle protection (root CLAUDE.md §1.1) entirely -- the factory was never in the loop.
//
// The key EVM fact this suite exercises: `new ERC1967Proxy(...)`'s constructor delegatecalls the
// implementation to run `initialize()`, and delegatecall does NOT change `msg.sender` -- it is
// preserved from whoever directly called `new ERC1967Proxy(...)`. So:
//   - a bare EOA/test contract deploying the proxy itself -> msg.sender == that EOA/test contract
//   - a factory's own `createXBucket` deploying the proxy -> msg.sender == the factory's address
// This is why the fix authorizes FACTORY addresses in the registry, not caller addresses, and why
// this suite proves both halves: the bypass is blocked, and the legitimate factory path is not.
//
// Built skeleton-first (workspace CLAUDE.md hard rule 7): three contracts, one per vault type,
// each with the same three-test shape -- (1) bare-proxy bypass rejected, (2) factory-shaped but
// unauthorized contract rejected identically, (3) an authorized factory still works end-to-end.
// ============================================================

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

/// @notice ActiveBucket and PassiveBucket's `initialize()` never call any method on
/// `bucketInfoAddr` -- it is only stored (`bucketInfo = IBucketInfo(bucketInfoAddr)`), see
/// ActiveBucket.sol:155 / PassiveBucket.sol:206. So a plain non-zero address stand-in is
/// sufficient for ActiveBucket; PassiveBucket differs (see its contract below) because
/// `_validateAndStoreDistributions` DOES call into `bucketInfo` via `DistributionLib`.
contract W1_7GateActiveBucketTest is Test {
    ActiveBucket public implementation;
    ImplementationRegistry public registry;

    address public bucketInfoStandIn;
    address public oneInchRouterStandIn;

    function setUp() public {
        registry = new ImplementationRegistry(address(this));
        implementation = new ActiveBucket(address(registry));
        bucketInfoStandIn = makeAddr("activeBucketInfoStandIn");
        oneInchRouterStandIn = makeAddr("activeOneInchRouterStandIn");
    }

    /// @notice THE bypass this task closes: nobody has been authorized in `registry`, so a bare
    /// direct proxy deployment against the shared implementation is rejected before any of
    /// initialize()'s other checks (zero-address bucketInfo/router) ever run.
    function test_RevertDirectProxyBypass_UnauthorizedCaller() public {
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, bucketInfoStandIn, oneInchRouterStandIn, "Evil Bucket", "EVIL"
        );
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @notice A real `ActiveBucketFactory` that the platform has simply never authorized is
    /// rejected identically to a bare proxy deployment -- authorization is keyed on the
    /// registry's explicit allowlist, never on "this contract has the shape of a factory".
    function test_RevertDirectProxyBypass_UnauthorizedFactoryLookalike() public {
        ActiveBucketFactory rogueFactory = new ActiveBucketFactory(address(implementation), bucketInfoStandIn);
        // Deliberately NOT calling registry.setAuthorizedFactory(address(rogueFactory), true).
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        rogueFactory.createActiveBucket(oneInchRouterStandIn, "Evil Bucket", "EVIL");
    }

    /// @notice The legitimate path still works end-to-end once the platform authorizes the
    /// factory: delegatecall's msg.sender inside initialize() is the FACTORY's address (not this
    /// test contract's, and not the external caller's), which is exactly what gets authorized.
    function test_FactoryPathStillWorks() public {
        ActiveBucketFactory factory = new ActiveBucketFactory(address(implementation), bucketInfoStandIn);
        registry.setAuthorizedFactory(address(factory), true);

        address proxyAddr = factory.createActiveBucket(oneInchRouterStandIn, "Active Bucket Share", "aBKT");
        ActiveBucket bucket = ActiveBucket(payable(proxyAddr));

        assertEq(bucket.owner(), address(this));
        assertEq(address(bucket.bucketInfo()), bucketInfoStandIn);
        assertEq(bucket.oneInchRouter(), oneInchRouterStandIn);
    }
}

/// @notice PassiveBucket's `initialize()` calls `_validateAndStoreDistributions`, which calls
/// `DistributionLib.validateDistributions(distributions, bucketInfo, WEIGHT_SUM)` -- a real call
/// into `bucketInfo` (whitelist/price checks), unlike ActiveBucket/PureMembership. So the
/// "factory path still works" test here needs a working `MockBucketInfoForPassive`, not a plain
/// address stand-in; the two "rejected" tests still use a plain stand-in because they revert on
/// the authorization check before `bucketInfo` is ever touched.
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
        implementation = new PassiveBucket(address(registry));
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

    /// @notice Same bypass as ActiveBucket's: no authorization exists in `registry`, so the
    /// authorization check rejects the call before `_validateAndStoreDistributions` -- and
    /// therefore `bucketInfo` -- is ever reached. Uses the plain stand-in deliberately, to prove
    /// the rejection does not depend on bucketInfo being well-formed.
    function test_RevertDirectProxyBypass_UnauthorizedCaller() public {
        PassiveBucket.BucketDistribution[] memory dists = _singleTokenDistributions();
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, bucketInfoStandIn, dists, oneInchRouterStandIn, "Evil Bucket", "EVIL"
        );
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @notice An unauthorized real `PassiveBucketFactory` is rejected identically.
    function test_RevertDirectProxyBypass_UnauthorizedFactoryLookalike() public {
        PassiveBucket.BucketDistribution[] memory dists = _singleTokenDistributions();
        PassiveBucketFactory rogueFactory = new PassiveBucketFactory(address(implementation), bucketInfoStandIn);
        vm.expectRevert(BucketVaultBase.UnauthorizedInitializer.selector);
        rogueFactory.createPassiveBucket(dists, oneInchRouterStandIn, "Evil Bucket", "EVIL");
    }

    /// @notice The legitimate path: once authorized, the factory's own address (preserved through
    /// delegatecall) satisfies the registry check, and the real distribution-validation path
    /// against a real (mock) BucketInfo completes normally.
    function test_FactoryPathStillWorks() public {
        PassiveBucket.BucketDistribution[] memory dists = _singleTokenDistributions();
        PassiveBucketFactory factory = new PassiveBucketFactory(address(implementation), address(bucketInfo));
        registry.setAuthorizedFactory(address(factory), true);

        address proxyAddr = factory.createPassiveBucket(dists, address(oneInchRouter), "PassiveBucket Share", "pBKT");
        PassiveBucket bucket = PassiveBucket(payable(proxyAddr));

        assertEq(bucket.owner(), address(this));
        assertEq(address(bucket.bucketInfo()), address(bucketInfo));
        assertEq(bucket.oneInchRouter(), address(oneInchRouter));
    }
}

/// @notice PureMembership's `initialize()` never calls any method on `bucketInfoAddr` -- it is
/// only stored (PureMembership.sol:362), same as ActiveBucket. Note `UnauthorizedInitializer` is
/// declared LOCALLY on `PureMembership` (it does not extend `BucketVaultBase`), so it is
/// referenced as `PureMembership.UnauthorizedInitializer.selector` here, not
/// `BucketVaultBase`'s.
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

    /// @notice Same bypass, same fix, same shape as the two ERC-20 vaults -- proven independently
    /// here because PureMembership does not share BucketVaultBase and carries its own local copy
    /// of both the check and the error.
    function test_RevertDirectProxyBypass_UnauthorizedCaller() public {
        bytes memory initData =
            abi.encodeWithSelector(PureMembership.initialize.selector, _singleConfig(), bucketInfoStandIn, "");
        vm.expectRevert(PureMembership.UnauthorizedInitializer.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @notice An unauthorized real `PureMembershipFactory` is rejected identically.
    function test_RevertDirectProxyBypass_UnauthorizedFactoryLookalike() public {
        PureMembershipFactory rogueFactory = new PureMembershipFactory(address(implementation), bucketInfoStandIn);
        vm.expectRevert(PureMembership.UnauthorizedInitializer.selector);
        rogueFactory.createPureMembership(_singleConfig(), "");
    }

    /// @notice The legitimate path still works once the platform authorizes the factory.
    function test_FactoryPathStillWorks() public {
        PureMembershipFactory factory = new PureMembershipFactory(address(implementation), bucketInfoStandIn);
        registry.setAuthorizedFactory(address(factory), true);

        address payable proxyAddr = factory.createPureMembership(_singleConfig(), "https://example.com/{id}.json");
        PureMembership membership = PureMembership(proxyAddr);

        assertEq(membership.owner(), address(this));
        assertEq(address(membership.bucketInfo()), bucketInfoStandIn);
    }
}
