// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {MockBucketInfoForPassive, MockERC20, MockOneInchRouter} from "./PassiveBucket.t.sol";

contract PassiveBucketDepositRedeemHandler is Test {
    PassiveBucket public bucket;
    address[] public actors;

    uint256 public ghost_sumSharesMinted;
    uint256 public ghost_sumSharesBurned;
    uint256 public ghost_depositCalls;
    uint256 public ghost_redeemCalls;
    uint256 public ghost_redeemNothingToRedeemTolerated;
    uint256 public ghost_redeemAttempts;
    uint256 public ghost_redeemNoHolderYet;

    constructor(PassiveBucket _bucket, address[] memory _actors) {
        bucket = _bucket;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 0.001 ether, 5 ether);

        bool isFirstEverDeposit = bucket.totalSupply() == 0;

        uint256 sharesBefore = bucket.balanceOf(actor);
        vm.prank(actor);
        bucket.deposit{value: amount}(address(0), 0);
        uint256 sharesAfter = bucket.balanceOf(actor);

        ghost_sumSharesMinted += (sharesAfter - sharesBefore);
        if (isFirstEverDeposit) {
            ghost_sumSharesMinted += bucket.DEAD_SHARES();
        }
        ghost_depositCalls += 1;
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_redeemAttempts += 1;
        address actor = _actor(actorSeed);
        uint256 actorBalance = bucket.balanceOf(actor);
        if (actorBalance == 0) {
            for (uint256 i = 0; i < actors.length; i++) {
                uint256 bal = bucket.balanceOf(actors[i]);
                if (bal > 0) {
                    actor = actors[i];
                    actorBalance = bal;
                    break;
                }
            }
            if (actorBalance == 0) {
                ghost_redeemNoHolderYet += 1;
                return;
            }
        }

        uint256 shares = bound(sharesSeed, 1, actorBalance);
        vm.prank(actor);
        try bucket.redeem(shares) {
            ghost_sumSharesBurned += shares;
            ghost_redeemCalls += 1;
        } catch (bytes memory lowLevelData) {
            if (bytes4(lowLevelData) != BucketVaultBase.NothingToRedeem.selector) {
                assembly {
                    revert(add(lowLevelData, 0x20), mload(lowLevelData))
                }
            }
            ghost_redeemNothingToRedeemTolerated += 1;
        }
    }
}

contract W0InvariantPassiveBucketTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    MockBucketInfoForPassive public bucketInfo;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockOneInchRouter public oneInchRouter;
    PassiveBucketDepositRedeemHandler public handler;

    uint256 constant ETH_PRICE = 2000e8;
    uint256 constant TOKEN_A_PRICE = 2000e8;
    uint256 constant TOKEN_B_PRICE = 1e8;

    function setUp() public {
        bucketInfo = new MockBucketInfoForPassive();
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        oneInchRouter = new MockOneInchRouter();

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
            address(oneInchRouter),
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("invariantActor0");
        actors[1] = makeAddr("invariantActor1");
        actors[2] = makeAddr("invariantActor2");
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 1000 ether);
        }

        handler = new PassiveBucketDepositRedeemHandler(bucket, actors);

        targetContract(address(handler));
    }

    function invariant_TotalSupplyMatchesGhostMintBurn() public view {
        assertEq(bucket.totalSupply(), handler.ghost_sumSharesMinted() - handler.ghost_sumSharesBurned());
    }

    function invariant_TokenPriceNeverZeroOnceSharesExist() public view {
        if (bucket.totalSupply() > 0) {
            assertGt(bucket.tokenPrice(), 0);
        }
    }

    function afterInvariant() public view {
        console.log("ghost_redeemAttempts (this run):", handler.ghost_redeemAttempts());
        console.log("ghost_redeemCalls (this run):", handler.ghost_redeemCalls());
        console.log("ghost_redeemNothingToRedeemTolerated (this run):", handler.ghost_redeemNothingToRedeemTolerated());
        console.log("ghost_redeemNoHolderYet (this run, genuine no-op):", handler.ghost_redeemNoHolderYet());
    }

    function test_RedeemNoOpRateCollapsesWithActorFallback() public {
        address actor0 = handler.actors(0);
        vm.deal(actor0, 1000 ether);
        handler.deposit(0, 10 ether);

        uint256 iterations = 30;
        for (uint256 i = 0; i < iterations; i++) {
            uint256 fivePercent = bucket.balanceOf(actor0) / 20;
            handler.redeem(i, fivePercent);
        }

        uint256 attempts = handler.ghost_redeemAttempts();
        uint256 noHolderYet = handler.ghost_redeemNoHolderYet();
        console.log("test_RedeemNoOpRateCollapsesWithActorFallback: attempts =", attempts);
        console.log("test_RedeemNoOpRateCollapsesWithActorFallback: noHolderYet =", noHolderYet);
        assertEq(attempts, iterations, "every loop iteration must count as a dispatched attempt");

        assertEq(noHolderYet, 0, "actor-fallback should eliminate every no-op in this sequence");
        assertEq(handler.ghost_redeemCalls(), iterations, "every attempt should have reached a real redeem() call");
    }
}
