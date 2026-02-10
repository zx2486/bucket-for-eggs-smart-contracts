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
    event PriceUpdated(address indexed token, uint256 price);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    event PlatformFeeUpdated(uint256 newFee);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
        priceFeed = makeAddr("priceFeed");

        bucketInfo = new BucketInfo();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deployment() public view {
        assertEq(bucketInfo.owner(), owner);
        assertEq(bucketInfo.platformFee(), 100); // Default 1%
        assertEq(bucketInfo.PRICE_DECIMALS(), 8);
        assertEq(bucketInfo.MAX_PLATFORM_FEE(), 1000);

        // Native token should be whitelisted by default
        assertTrue(bucketInfo.isTokenWhitelisted(address(0)));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1);
    }

    function test_NativeTokenWhitelistedByDefault() public view {
        assertTrue(bucketInfo.isTokenWhitelisted(bucketInfo.NATIVE_TOKEN()));
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTokenWhitelist() public {
        vm.expectEmit(true, false, false, true);
        emit TokenWhitelisted(tokenA, true);

        bucketInfo.setTokenWhitelist(tokenA, true);

        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 2); // Native + tokenA
    }

    function test_RemoveTokenFromWhitelist() public {
        bucketInfo.setTokenWhitelist(tokenA, true);
        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));

        vm.expectEmit(true, false, false, true);
        emit TokenWhitelisted(tokenA, false);

        bucketInfo.setTokenWhitelist(tokenA, false);

        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1); // Only native
    }

    function test_SetTokenWhitelistOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.setTokenWhitelist(tokenA, true);
    }

    function test_RevertWhenAlreadyInDesiredState() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        vm.expectRevert("Already in desired state");
        bucketInfo.setTokenWhitelist(tokenA, true);
    }

    function test_BatchSetTokenWhitelist() public {
        address[] memory tokens = new address[](3);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        tokens[2] = user1;

        bucketInfo.batchSetTokenWhitelist(tokens, true);

        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));
        assertTrue(bucketInfo.isTokenWhitelisted(tokenB));
        assertTrue(bucketInfo.isTokenWhitelisted(user1));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 4); // Native + 3 tokens
    }

    function test_BatchRemoveTokenFromWhitelist() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;

        bucketInfo.batchSetTokenWhitelist(tokens, true);
        assertEq(bucketInfo.getWhitelistedTokenCount(), 3);

        bucketInfo.batchSetTokenWhitelist(tokens, false);

        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertFalse(bucketInfo.isTokenWhitelisted(tokenB));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1); // Only native
    }

    function test_GetWhitelistedTokens() public {
        bucketInfo.setTokenWhitelist(tokenA, true);
        bucketInfo.setTokenWhitelist(tokenB, true);

        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        assertEq(tokens.length, 3);
        assertTrue(tokens[0] == address(0) || tokens[1] == address(0) || tokens[2] == address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTokenPrice() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        uint256 price = 2000 * 10 ** 8; // $2000 with 8 decimals

        vm.expectEmit(true, false, false, true);
        emit PriceUpdated(tokenA, price);

        bucketInfo.setTokenPrice(tokenA, price);

        assertEq(bucketInfo.getTokenPrice(tokenA), price);
    }

    function test_SetTokenPriceOnlyOwner() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.setTokenPrice(tokenA, 2000 * 10 ** 8);
    }

    function test_RevertSetPriceForNonWhitelistedToken() public {
        vm.expectRevert("Token not whitelisted");
        bucketInfo.setTokenPrice(tokenA, 2000 * 10 ** 8);
    }

    function test_RevertSetZeroPrice() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        vm.expectRevert("Price must be greater than 0");
        bucketInfo.setTokenPrice(tokenA, 0);
    }

    function test_BatchSetTokenPrices() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        bucketInfo.batchSetTokenWhitelist(tokens, true);

        uint256[] memory prices = new uint256[](2);
        prices[0] = 2000 * 10 ** 8; // $2000
        prices[1] = 1500 * 10 ** 8; // $1500

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

    function test_SetPriceFeed() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        vm.expectEmit(true, false, false, true);
        emit PriceFeedUpdated(tokenA, priceFeed);

        bucketInfo.setPriceFeed(tokenA, priceFeed);

        assertEq(bucketInfo.getPriceFeed(tokenA), priceFeed);
    }

    function test_RevertSetPriceFeedForNonWhitelistedToken() public {
        vm.expectRevert("Token not whitelisted");
        bucketInfo.setPriceFeed(tokenA, priceFeed);
    }

    function test_RevertSetInvalidPriceFeed() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        vm.expectRevert("Invalid price feed address");
        bucketInfo.setPriceFeed(tokenA, address(0));
    }

    function test_GetTokenPriceRevertForNonWhitelisted() public {
        vm.expectRevert("Token not whitelisted");
        bucketInfo.getTokenPrice(tokenA);
    }

    /*//////////////////////////////////////////////////////////////
                        PLATFORM MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

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

    function test_SetPlatformFee() public {
        uint256 newFee = 200; // 2%

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeUpdated(newFee);

        bucketInfo.setPlatformFee(newFee);

        assertEq(bucketInfo.platformFee(), newFee);
    }

    function test_SetPlatformFeeOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.setPlatformFee(200);
    }

    function test_RevertSetPlatformFeeExceedsMaximum() public {
        vm.expectRevert("Fee exceeds maximum");
        bucketInfo.setPlatformFee(1001); // Max is 1000 (10%)
    }

    function test_IsPlatformOperational() public view {
        assertTrue(bucketInfo.isPlatformOperational());
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateFee() public {
        uint256 amount = 1000 * 10 ** 18;
        uint256 expectedFee = (amount * 100) / 10000; // 1% of amount

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_CalculateFeeWithDifferentPlatformFee() public {
        bucketInfo.setPlatformFee(250); // 2.5%

        uint256 amount = 1000 * 10 ** 18;
        uint256 expectedFee = (amount * 250) / 10000; // 2.5% of amount

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_IsTokenValid() public {
        bucketInfo.setTokenWhitelist(tokenA, true);

        assertTrue(bucketInfo.isTokenValid(tokenA));
        assertFalse(bucketInfo.isTokenValid(tokenB)); // Not whitelisted
    }

    function test_IsTokenValidWhenPaused() public {
        bucketInfo.setTokenWhitelist(tokenA, true);
        assertTrue(bucketInfo.isTokenValid(tokenA));

        bucketInfo.pausePlatform();

        assertFalse(bucketInfo.isTokenValid(tokenA)); // Platform paused
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetTokenPrice(uint256 price) public {
        vm.assume(price > 0);
        vm.assume(price < type(uint256).max);

        bucketInfo.setTokenWhitelist(tokenA, true);
        bucketInfo.setTokenPrice(tokenA, price);

        assertEq(bucketInfo.getTokenPrice(tokenA), price);
    }

    function testFuzz_SetPlatformFee(uint256 fee) public {
        fee = bound(fee, 0, 1000);

        bucketInfo.setPlatformFee(fee);

        assertEq(bucketInfo.platformFee(), fee);
    }

    function testFuzz_CalculateFee(uint256 amount, uint256 fee) public {
        fee = bound(fee, 0, 1000);
        amount = bound(amount, 0, type(uint128).max); // Prevent overflow

        bucketInfo.setPlatformFee(fee);
        uint256 expectedFee = (amount * fee) / 10000;

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership() public {
        bucketInfo.transferOwnership(user1);
        assertEq(bucketInfo.owner(), user1);
    }

    function test_RenounceOwnership() public {
        bucketInfo.renounceOwnership();
        assertEq(bucketInfo.owner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        GAS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Gas_SetTokenWhitelist() public {
        bucketInfo.setTokenWhitelist(tokenA, true);
    }

    function test_Gas_SetTokenPrice() public {
        bucketInfo.setTokenWhitelist(tokenA, true);
        bucketInfo.setTokenPrice(tokenA, 2000 * 10 ** 8);
    }

    function test_Gas_BatchSetTokenWhitelist() public {
        address[] memory tokens = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokens[i] = address(uint160(i + 1000));
        }
        bucketInfo.batchSetTokenWhitelist(tokens, true);
    }
}
