// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/BucketInfo.sol";

contract BucketInfoTest is Test {
    BucketInfo public bucketInfo;
    address public owner;
    address public user1;
    address public user2;
    address public tokenA;
    address public tokenB;
    address public priceFeed;

    event TokenWhitelisted(address indexed token, bool whitelisted);
    event TokenPriceInitialized(address indexed token, uint256 price);
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    event PlatformFeeUpdated(uint256 newFee);
    event WhitelistAdditionProposed(address indexed token, uint256 eta);
    event WhitelistAdditionCanceled(address indexed token);
    event PriceFeedProposed(address indexed token, address priceFeed, uint256 eta);
    event PriceFeedCanceled(address indexed token, address canceledPriceFeed);
    event PlatformFeeProposed(uint256 newFee, uint256 eta);
    event PlatformFeeCanceled(uint256 canceledFee);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
        priceFeed = makeAddr("priceFeed");

        bucketInfo = new BucketInfo();
    }

    function _whitelistToken(address token) internal {
        bucketInfo.proposeWhitelistAddition(token);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executeWhitelistAddition(token);
    }

    function _setPriceFeedFor(address token, address feed) internal {
        bucketInfo.proposePriceFeed(token, feed);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executePriceFeed(token);
    }

    function _setPlatformFeeTo(uint256 fee) internal {
        bucketInfo.proposePlatformFee(fee);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executePlatformFee();
    }

    function test_Deployment() public view {
        assertEq(bucketInfo.owner(), owner);
        assertEq(bucketInfo.platformFee(), 200);
        assertEq(bucketInfo.PRICE_DECIMALS(), 8);
        assertEq(bucketInfo.MAX_PLATFORM_FEE(), 1000);

        assertTrue(bucketInfo.isTokenWhitelisted(address(0)));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1);
    }

    function test_NativeTokenWhitelistedByDefault() public view {
        assertTrue(bucketInfo.isTokenWhitelisted(bucketInfo.NATIVE_TOKEN()));
    }

    function test_ProposeAndExecuteWhitelistAddition() public {
        uint256 expectedEta = block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY();

        vm.expectEmit(true, false, false, true);
        emit WhitelistAdditionProposed(tokenA, expectedEta);
        bucketInfo.proposeWhitelistAddition(tokenA);

        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertTrue(bucketInfo.pendingWhitelistAddition(tokenA));
        assertEq(bucketInfo.whitelistAdditionEta(tokenA), expectedEta);

        vm.warp(expectedEta);

        vm.expectEmit(true, false, false, true);
        emit TokenWhitelisted(tokenA, true);
        bucketInfo.executeWhitelistAddition(tokenA);

        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 2);
        assertFalse(bucketInfo.pendingWhitelistAddition(tokenA));
    }

    function test_RevertExecuteWhitelistAdditionBeforeTimelockElapsed() public {
        bucketInfo.proposeWhitelistAddition(tokenA);
        vm.expectRevert();
        bucketInfo.executeWhitelistAddition(tokenA);
    }

    function test_RevertExecuteWhitelistAdditionWithNoProposal() public {
        vm.expectRevert();
        bucketInfo.executeWhitelistAddition(tokenA);
    }

    function test_CancelWhitelistAddition() public {
        bucketInfo.proposeWhitelistAddition(tokenA);

        vm.expectEmit(true, false, false, true);
        emit WhitelistAdditionCanceled(tokenA);
        bucketInfo.cancelWhitelistAddition(tokenA);

        assertFalse(bucketInfo.pendingWhitelistAddition(tokenA));
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        vm.expectRevert();
        bucketInfo.executeWhitelistAddition(tokenA);
    }

    function test_RemoveTokenFromWhitelist_IsImmediateNoTimelock() public {
        _whitelistToken(tokenA);
        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));

        vm.expectEmit(true, false, false, true);
        emit TokenWhitelisted(tokenA, false);

        bucketInfo.removeTokenWhitelist(tokenA);

        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1);
    }

    function test_ProposeWhitelistAdditionOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.proposeWhitelistAddition(tokenA);
    }

    function test_RemoveTokenWhitelistOnlyOwner() public {
        _whitelistToken(tokenA);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.removeTokenWhitelist(tokenA);
    }

    function test_RevertProposeWhitelistAdditionWhenAlreadyWhitelisted() public {
        _whitelistToken(tokenA);

        vm.expectRevert("Already in desired state");
        bucketInfo.proposeWhitelistAddition(tokenA);
    }

    function test_RevertRemoveTokenWhitelistWhenNotWhitelisted() public {
        vm.expectRevert("Already in desired state");
        bucketInfo.removeTokenWhitelist(tokenA);
    }

    function test_BatchProposeAndExecuteWhitelistAdditions() public {
        address[] memory tokens = new address[](3);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        tokens[2] = user1;

        bucketInfo.batchProposeWhitelistAdditions(tokens);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.batchExecuteWhitelistAdditions(tokens);

        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));
        assertTrue(bucketInfo.isTokenWhitelisted(tokenB));
        assertTrue(bucketInfo.isTokenWhitelisted(user1));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 4);
    }

    function test_BatchRemoveTokenFromWhitelist() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;

        bucketInfo.batchProposeWhitelistAdditions(tokens);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.batchExecuteWhitelistAdditions(tokens);
        assertEq(bucketInfo.getWhitelistedTokenCount(), 3);

        bucketInfo.batchRemoveTokenWhitelist(tokens);

        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertFalse(bucketInfo.isTokenWhitelisted(tokenB));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1);
    }

    function test_GetWhitelistedTokens() public {
        _whitelistToken(tokenA);
        _whitelistToken(tokenB);

        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        assertEq(tokens.length, 3);
        assertTrue(tokens[0] == address(0) || tokens[1] == address(0) || tokens[2] == address(0));
    }

    function test_SetTokenPrice() public {
        _whitelistToken(tokenA);

        uint256 price = 2000 * 10 ** 8;

        vm.expectEmit(true, false, false, true);
        emit TokenPriceInitialized(tokenA, price);

        bucketInfo.setTokenPrice(tokenA, price);

        assertEq(bucketInfo.getTokenPrice(tokenA), price);
    }

    function test_SetTokenPriceSecondUpdateWithinCapEmitsTokenPriceUpdated() public {
        _whitelistToken(tokenA);
        uint256 firstPrice = 2000 * 10 ** 8;
        bucketInfo.setTokenPrice(tokenA, firstPrice);

        vm.warp(block.timestamp + bucketInfo.MIN_PRICE_UPDATE_INTERVAL());
        uint256 secondPrice = 2100 * 10 ** 8;

        vm.expectEmit(true, false, false, true);
        emit TokenPriceUpdated(tokenA, firstPrice, secondPrice);

        bucketInfo.setTokenPrice(tokenA, secondPrice);

        assertEq(bucketInfo.getTokenPrice(tokenA), secondPrice);
    }

    function test_SetTokenPriceOnlyOwner() public {
        _whitelistToken(tokenA);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.setTokenPrice(tokenA, 2000 * 10 ** 8);
    }

    function test_RevertSetPriceForNonWhitelistedToken() public {
        vm.expectRevert("Token not whitelisted");
        bucketInfo.setTokenPrice(tokenA, 2000 * 10 ** 8);
    }

    function test_RevertSetZeroPrice() public {
        _whitelistToken(tokenA);

        vm.expectRevert("Price must be greater than 0");
        bucketInfo.setTokenPrice(tokenA, 0);
    }

    function test_BatchSetTokenPrices() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        bucketInfo.batchProposeWhitelistAdditions(tokens);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.batchExecuteWhitelistAdditions(tokens);

        uint256[] memory prices = new uint256[](2);
        prices[0] = 2000 * 10 ** 8;
        prices[1] = 1500 * 10 ** 8;

        bucketInfo.batchSetTokenPrices(tokens, prices);

        assertEq(bucketInfo.getTokenPrice(tokenA), prices[0]);
        assertEq(bucketInfo.getTokenPrice(tokenB), prices[1]);
    }

    function test_RevertBatchSetPricesArrayMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;

        uint256[] memory prices = new uint256[](1);
        prices[0] = 2000 * 10 ** 8;

        vm.expectRevert("Arrays length mismatch");
        bucketInfo.batchSetTokenPrices(tokens, prices);
    }

    function test_ProposeAndExecutePriceFeed() public {
        _whitelistToken(tokenA);

        uint256 expectedEta = block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY();

        vm.expectEmit(true, false, false, true);
        emit PriceFeedProposed(tokenA, priceFeed, expectedEta);
        bucketInfo.proposePriceFeed(tokenA, priceFeed);

        assertEq(bucketInfo.getPriceFeed(tokenA), address(0));

        vm.warp(expectedEta);

        vm.expectEmit(true, false, false, true);
        emit PriceFeedUpdated(tokenA, priceFeed);
        bucketInfo.executePriceFeed(tokenA);

        assertEq(bucketInfo.getPriceFeed(tokenA), priceFeed);
    }

    function test_RevertExecutePriceFeedBeforeTimelockElapsed() public {
        _whitelistToken(tokenA);
        bucketInfo.proposePriceFeed(tokenA, priceFeed);

        vm.expectRevert();
        bucketInfo.executePriceFeed(tokenA);
    }

    function test_CancelPriceFeed() public {
        _whitelistToken(tokenA);
        bucketInfo.proposePriceFeed(tokenA, priceFeed);

        vm.expectEmit(true, false, false, true);
        emit PriceFeedCanceled(tokenA, priceFeed);
        bucketInfo.cancelPriceFeed(tokenA);

        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        vm.expectRevert();
        bucketInfo.executePriceFeed(tokenA);
    }

    function test_ProposePriceFeedOnlyOwner() public {
        _whitelistToken(tokenA);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.proposePriceFeed(tokenA, priceFeed);
    }

    function test_RevertProposePriceFeedForNonWhitelistedToken() public {
        vm.expectRevert("Token not whitelisted");
        bucketInfo.proposePriceFeed(tokenA, priceFeed);
    }

    function test_RevertProposeInvalidPriceFeed() public {
        _whitelistToken(tokenA);

        vm.expectRevert("Invalid price feed address");
        bucketInfo.proposePriceFeed(tokenA, address(0));
    }

    function test_GetTokenPriceRevertForNonWhitelisted() public {
        vm.expectRevert("Token not whitelisted");
        bucketInfo.getTokenPrice(tokenA);
    }

    function test_PausePlatform() public {
        bucketInfo.pausePlatform();
        assertTrue(bucketInfo.paused());
        assertFalse(bucketInfo.isPlatformOperational());
    }

    function test_UnpausePlatform() public {
        bucketInfo.pausePlatform();
        bucketInfo.unpausePlatform();
        assertFalse(bucketInfo.paused());
        assertTrue(bucketInfo.isPlatformOperational());
    }

    function test_PausePlatformOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.pausePlatform();
    }

    function test_UnpausePlatformOnlyOwner() public {
        bucketInfo.pausePlatform();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.unpausePlatform();
    }

    function test_ProposeAndExecutePlatformFee() public {
        uint256 newFee = 300;
        uint256 expectedEta = block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY();

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeProposed(newFee, expectedEta);
        bucketInfo.proposePlatformFee(newFee);

        assertEq(bucketInfo.platformFee(), 200);

        vm.warp(expectedEta);

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeUpdated(newFee);
        bucketInfo.executePlatformFee();

        assertEq(bucketInfo.platformFee(), newFee);
    }

    function test_RevertExecutePlatformFeeBeforeTimelockElapsed() public {
        bucketInfo.proposePlatformFee(200);

        vm.expectRevert();
        bucketInfo.executePlatformFee();
    }

    function test_CancelPlatformFee() public {
        bucketInfo.proposePlatformFee(200);

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeCanceled(200);
        bucketInfo.cancelPlatformFee();

        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        vm.expectRevert();
        bucketInfo.executePlatformFee();
    }

    function test_ProposePlatformFeeOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.proposePlatformFee(200);
    }

    function test_RevertProposePlatformFeeExceedsMaximum() public {
        vm.expectRevert("Fee exceeds maximum");
        bucketInfo.proposePlatformFee(1001);
    }

    function test_IsPlatformOperational() public view {
        assertTrue(bucketInfo.isPlatformOperational());
    }

    function test_CalculateFee() public view {
        uint256 amount = 1000 * 10 ** 18;
        uint256 expectedFee = (amount * 200) / 10000;

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_CalculateFeeWithDifferentPlatformFee() public {
        _setPlatformFeeTo(250);

        uint256 amount = 1000 * 10 ** 18;
        uint256 expectedFee = (amount * 250) / 10000;

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_IsTokenValid() public {
        _whitelistToken(tokenA);

        assertTrue(bucketInfo.isTokenValid(tokenA));
        assertFalse(bucketInfo.isTokenValid(tokenB));
    }

    function test_IsTokenValidWhenPaused() public {
        _whitelistToken(tokenA);
        assertTrue(bucketInfo.isTokenValid(tokenA));

        bucketInfo.pausePlatform();

        assertFalse(bucketInfo.isTokenValid(tokenA));
    }

    function testFuzz_SetTokenPrice(uint256 price) public {
        vm.assume(price > 0);
        vm.assume(price < type(uint256).max);

        _whitelistToken(tokenA);
        bucketInfo.setTokenPrice(tokenA, price);

        assertEq(bucketInfo.getTokenPrice(tokenA), price);
    }

    function testFuzz_SetPlatformFee(uint256 fee) public {
        fee = bound(fee, 0, 1000);

        _setPlatformFeeTo(fee);

        assertEq(bucketInfo.platformFee(), fee);
    }

    function testFuzz_CalculateFee(uint256 amount, uint256 fee) public {
        fee = bound(fee, 0, 1000);
        amount = bound(amount, 0, type(uint128).max);

        _setPlatformFeeTo(fee);
        uint256 expectedFee = (amount * fee) / 10000;

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_TransferOwnershipIsTwoStep() public {
        bucketInfo.transferOwnership(user1);

        assertEq(bucketInfo.owner(), owner);
        assertEq(bucketInfo.pendingOwner(), user1);

        vm.prank(user1);
        bucketInfo.acceptOwnership();

        assertEq(bucketInfo.owner(), user1);
        assertEq(bucketInfo.pendingOwner(), address(0));
    }

    function test_RevertTransferOwnershipAcceptByWrongAccount() public {
        bucketInfo.transferOwnership(user1);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user2));
        bucketInfo.acceptOwnership();
    }

    function test_RenounceOwnershipAlwaysReverts() public {
        vm.expectRevert(BucketInfo.RenounceOwnershipDisabled.selector);
        bucketInfo.renounceOwnership();

        assertEq(bucketInfo.owner(), owner);
    }

    function test_Gas_ProposeWhitelistAddition() public {
        bucketInfo.proposeWhitelistAddition(tokenA);
    }

    function test_Gas_SetTokenPrice() public {
        _whitelistToken(tokenA);
        bucketInfo.setTokenPrice(tokenA, 2000 * 10 ** 8);
    }

    function test_Gas_BatchProposeWhitelistAdditions() public {
        address[] memory tokens = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            tokens[i] = address(uint160(i + 1000));
        }
        bucketInfo.batchProposeWhitelistAdditions(tokens);
    }
}
