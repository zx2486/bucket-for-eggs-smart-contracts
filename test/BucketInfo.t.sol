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
    // W1 (sc-oracle): PriceUpdated was split into TokenPriceInitialized (first-ever set,
    // unbounded per A1) and TokenPriceUpdated (subsequent sets, rate-limited per A1).
    event TokenPriceInitialized(address indexed token, uint256 price);
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event PriceFeedUpdated(address indexed token, address priceFeed);
    event PlatformFeeUpdated(uint256 newFee);
    // W3.4: the timelock-proposal events for the three now-timelocked setter families.
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

    /// @dev W3.4 turned setTokenWhitelist's addition path into propose+timelock+execute.
    /// Most tests below are not ABOUT that timelock -- they just need a whitelisted token as
    /// a precondition -- so this helper reproduces the old one-call setup semantics.
    function _whitelistToken(address token) internal {
        bucketInfo.proposeWhitelistAddition(token);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executeWhitelistAddition(token);
    }

    /// @dev Same pattern as {_whitelistToken}, for setPriceFeed's propose+execute conversion.
    function _setPriceFeedFor(address token, address feed) internal {
        bucketInfo.proposePriceFeed(token, feed);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executePriceFeed(token);
    }

    /// @dev Same pattern as {_whitelistToken}, for setPlatformFee's propose+execute conversion.
    function _setPlatformFeeTo(uint256 fee) internal {
        bucketInfo.proposePlatformFee(fee);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executePlatformFee();
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

    function test_ProposeAndExecuteWhitelistAddition() public {
        uint256 expectedEta = block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY();

        vm.expectEmit(true, false, false, true);
        emit WhitelistAdditionProposed(tokenA, expectedEta);
        bucketInfo.proposeWhitelistAddition(tokenA);

        // Not whitelisted yet -- only proposed.
        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertTrue(bucketInfo.pendingWhitelistAddition(tokenA));
        assertEq(bucketInfo.whitelistAdditionEta(tokenA), expectedEta);

        vm.warp(expectedEta);

        vm.expectEmit(true, false, false, true);
        emit TokenWhitelisted(tokenA, true);
        bucketInfo.executeWhitelistAddition(tokenA);

        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 2); // Native + tokenA
        assertFalse(bucketInfo.pendingWhitelistAddition(tokenA));
    }

    function test_RevertExecuteWhitelistAdditionBeforeTimelockElapsed() public {
        bucketInfo.proposeWhitelistAddition(tokenA);
        vm.expectRevert(); // TimelockNotElapsed
        bucketInfo.executeWhitelistAddition(tokenA);
    }

    function test_RevertExecuteWhitelistAdditionWithNoProposal() public {
        vm.expectRevert(); // NoProposalPending
        bucketInfo.executeWhitelistAddition(tokenA);
    }

    function test_CancelWhitelistAddition() public {
        bucketInfo.proposeWhitelistAddition(tokenA);

        vm.expectEmit(true, false, false, true);
        emit WhitelistAdditionCanceled(tokenA);
        bucketInfo.cancelWhitelistAddition(tokenA);

        assertFalse(bucketInfo.pendingWhitelistAddition(tokenA));
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        vm.expectRevert(); // NoProposalPending -- cancel cleared it
        bucketInfo.executeWhitelistAddition(tokenA);
    }

    function test_RemoveTokenFromWhitelist_IsImmediateNoTimelock() public {
        _whitelistToken(tokenA);
        assertTrue(bucketInfo.isTokenWhitelisted(tokenA));

        // B5: removal stays immediate -- no propose/execute split, unlike addition.
        vm.expectEmit(true, false, false, true);
        emit TokenWhitelisted(tokenA, false);

        bucketInfo.removeTokenWhitelist(tokenA);

        assertFalse(bucketInfo.isTokenWhitelisted(tokenA));
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1); // Only native
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
        assertEq(bucketInfo.getWhitelistedTokenCount(), 4); // Native + 3 tokens
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
        assertEq(bucketInfo.getWhitelistedTokenCount(), 1); // Only native
    }

    function test_GetWhitelistedTokens() public {
        _whitelistToken(tokenA);
        _whitelistToken(tokenB);

        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        assertEq(tokens.length, 3);
        assertTrue(tokens[0] == address(0) || tokens[1] == address(0) || tokens[2] == address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTokenPrice() public {
        _whitelistToken(tokenA);

        uint256 price = 2000 * 10 ** 8; // $2000 with 8 decimals

        // First-ever set for tokenA: unbounded per A1, emits TokenPriceInitialized (W1).
        vm.expectEmit(true, false, false, true);
        emit TokenPriceInitialized(tokenA, price);

        bucketInfo.setTokenPrice(tokenA, price);

        assertEq(bucketInfo.getTokenPrice(tokenA), price);
    }

    /// W1 (sc-oracle, A1): a second setTokenPrice call on the same token, within
    /// MAX_PRICE_DEVIATION_BPS and after MIN_PRICE_UPDATE_INTERVAL, succeeds and emits
    /// TokenPriceUpdated(token, oldPrice, newPrice).
    function test_SetTokenPriceSecondUpdateWithinCapEmitsTokenPriceUpdated() public {
        _whitelistToken(tokenA);
        uint256 firstPrice = 2000 * 10 ** 8;
        bucketInfo.setTokenPrice(tokenA, firstPrice);

        vm.warp(block.timestamp + bucketInfo.MIN_PRICE_UPDATE_INTERVAL());
        uint256 secondPrice = 2100 * 10 ** 8; // +5%, within the 20% cap

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
        prices[0] = 2000 * 10 ** 8; // $2000
        prices[1] = 1500 * 10 ** 8; // $1500

        // setTokenPrice/batchSetTokenPrices stay untimelocked by design (W3.4) -- the A1
        // rate limit is the protection here, not a timelock.
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

        // Not applied yet.
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

        vm.expectRevert(); // TimelockNotElapsed
        bucketInfo.executePriceFeed(tokenA);
    }

    function test_CancelPriceFeed() public {
        _whitelistToken(tokenA);
        bucketInfo.proposePriceFeed(tokenA, priceFeed);

        vm.expectEmit(true, false, false, true);
        emit PriceFeedCanceled(tokenA, priceFeed);
        bucketInfo.cancelPriceFeed(tokenA);

        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        vm.expectRevert(); // NoProposalPending -- cancel cleared it
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

    function test_ProposeAndExecutePlatformFee() public {
        uint256 newFee = 200; // 2%
        uint256 expectedEta = block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY();

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeProposed(newFee, expectedEta);
        bucketInfo.proposePlatformFee(newFee);

        // Not applied yet.
        assertEq(bucketInfo.platformFee(), 100);

        vm.warp(expectedEta);

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeUpdated(newFee);
        bucketInfo.executePlatformFee();

        assertEq(bucketInfo.platformFee(), newFee);
    }

    function test_RevertExecutePlatformFeeBeforeTimelockElapsed() public {
        bucketInfo.proposePlatformFee(200);

        vm.expectRevert(); // TimelockNotElapsed
        bucketInfo.executePlatformFee();
    }

    function test_CancelPlatformFee() public {
        bucketInfo.proposePlatformFee(200);

        vm.expectEmit(false, false, false, true);
        emit PlatformFeeCanceled(200);
        bucketInfo.cancelPlatformFee();

        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        vm.expectRevert(); // NoProposalPending -- cancel cleared it
        bucketInfo.executePlatformFee();
    }

    function test_ProposePlatformFeeOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        bucketInfo.proposePlatformFee(200);
    }

    function test_RevertProposePlatformFeeExceedsMaximum() public {
        vm.expectRevert("Fee exceeds maximum");
        bucketInfo.proposePlatformFee(1001); // Max is 1000 (10%)
    }

    function test_IsPlatformOperational() public view {
        assertTrue(bucketInfo.isPlatformOperational());
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateFee() public view {
        uint256 amount = 1000 * 10 ** 18;
        uint256 expectedFee = (amount * 100) / 10000; // 1% of amount

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_CalculateFeeWithDifferentPlatformFee() public {
        _setPlatformFeeTo(250); // 2.5%

        uint256 amount = 1000 * 10 ** 18;
        uint256 expectedFee = (amount * 250) / 10000; // 2.5% of amount

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    function test_IsTokenValid() public {
        _whitelistToken(tokenA);

        assertTrue(bucketInfo.isTokenValid(tokenA));
        assertFalse(bucketInfo.isTokenValid(tokenB)); // Not whitelisted
    }

    function test_IsTokenValidWhenPaused() public {
        _whitelistToken(tokenA);
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
        amount = bound(amount, 0, type(uint128).max); // Prevent overflow

        _setPlatformFeeTo(fee);
        uint256 expectedFee = (amount * fee) / 10000;

        assertEq(bucketInfo.calculateFee(amount), expectedFee);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    /// W3.1: BucketInfo is Ownable2Step now -- transferOwnership only PROPOSES; owner()
    /// does not change until the pending owner calls acceptOwnership(). D-3
    /// (09-DECISION-LOG.md §11.2) scopes this to BucketInfo alone among pre-existing
    /// contracts, which is exactly why this test (and not ActiveBucket/PassiveBucket/
    /// PureMembership's factory-handover tests) is the one that needed the two-step rewrite.
    function test_TransferOwnershipIsTwoStep() public {
        bucketInfo.transferOwnership(user1);

        // Proposed, not yet transferred.
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

    /// Q14.2 (10-BLOCKER-14-DECOMPOSITION-ANSWER.md:6-7): renounceOwnership must always
    /// revert -- the only route to a new owner is transferOwnership (e.g. to a future DAO),
    /// never renunciation. This is the pre-fix-must-fail evidence: on the pre-fix commit
    /// (plain Ownable, no override) this assertion fails because renounceOwnership succeeds
    /// and owner() becomes address(0).
    function test_RenounceOwnershipAlwaysReverts() public {
        vm.expectRevert(BucketInfo.RenounceOwnershipDisabled.selector);
        bucketInfo.renounceOwnership();

        assertEq(bucketInfo.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        GAS TESTS
    //////////////////////////////////////////////////////////////*/

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
