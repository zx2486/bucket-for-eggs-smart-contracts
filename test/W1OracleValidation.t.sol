// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {BucketInfo} from "../src/BucketInfo.sol";
import {MockV3Aggregator} from "@chainlink/tests/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

contract ControllableAggregator is AggregatorV3Interface {
    uint8 private _decimals;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;
    bool public shouldRevert;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "ControllableAggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("getRoundData not implemented");
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!shouldRevert, "feed reverted");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}

contract W1OracleValidationTest is Test {
    BucketInfo public bucketInfo;
    address public nativeToken;

    event TokenPriceInitialized(address indexed token, uint256 price);
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);

    function setUp() public {
        bucketInfo = new BucketInfo();
        nativeToken = address(0);
        vm.warp(1000 days); // clear of genesis so timestamp subtraction cannot underflow
    }

    function _setPriceFeed(address token, address feed) internal {
        bucketInfo.proposePriceFeed(token, feed);
        vm.warp(block.timestamp + bucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        bucketInfo.executePriceFeed(token);
    }

    /*//////////////////////////////////////////////////////////////
                CHAINLINK VALIDATION -- getTokenPrice reverts
    //////////////////////////////////////////////////////////////*/

    function test_RevertGetTokenPriceOnNegativeAnswer() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));

        feed.updateAnswer(-1e8);

        vm.expectRevert("Invalid Chainlink price data");
        bucketInfo.getTokenPrice(nativeToken);
    }

    function test_RevertGetTokenPriceOnZeroAnswer() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));

        feed.updateAnswer(0);

        vm.expectRevert("Invalid Chainlink price data");
        bucketInfo.getTokenPrice(nativeToken);
    }

    function test_RevertGetTokenPriceOnStaleRound() public {
        ControllableAggregator feed = new ControllableAggregator(8);
        _setPriceFeed(nativeToken, address(feed));

        feed.setRound(10, 100e8, block.timestamp, block.timestamp, 7);

        vm.expectRevert("Invalid Chainlink price data");
        bucketInfo.getTokenPrice(nativeToken);
    }

    function test_RevertGetTokenPriceOnIncompleteRound() public {
        ControllableAggregator feed = new ControllableAggregator(8);
        _setPriceFeed(nativeToken, address(feed));

        feed.setRound(1, 100e8, block.timestamp, 0, 1);

        vm.expectRevert("Invalid Chainlink price data");
        bucketInfo.getTokenPrice(nativeToken);
    }

    function test_RevertGetTokenPriceOnStaleByTimestamp() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));

        vm.warp(block.timestamp + bucketInfo.DEFAULT_MAX_PRICE_STALENESS() + 1);

        vm.expectRevert("Invalid Chainlink price data");
        bucketInfo.getTokenPrice(nativeToken);
    }

    function test_GetTokenPriceSucceedsExactlyAtStalenessBoundary() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));
        feed.updateAnswer(100e8);

        vm.warp(block.timestamp + bucketInfo.DEFAULT_MAX_PRICE_STALENESS());

        assertEq(bucketInfo.getTokenPrice(nativeToken), 100e8);
    }

    function test_SetMaxPriceStalenessWidensWindowPerToken() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));
        feed.updateAnswer(100e8);
        bucketInfo.setMaxPriceStaleness(nativeToken, 2 days);

        vm.warp(block.timestamp + 1 days);

        assertEq(bucketInfo.getTokenPrice(nativeToken), 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                tryGetTokenPrice -- never reverts
    //////////////////////////////////////////////////////////////*/

    function test_TryGetTokenPriceNeverRevertsOnNonWhitelistedToken() public {
        (bool ok, uint256 price) = bucketInfo.tryGetTokenPrice(makeAddr("notWhitelisted"));
        assertFalse(ok);
        assertEq(price, 0);
    }

    function test_TryGetTokenPriceNeverRevertsOnNegativeAnswer() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));
        feed.updateAnswer(-1e8);

        (bool ok, uint256 price) = bucketInfo.tryGetTokenPrice(nativeToken);
        assertFalse(ok);
        assertEq(price, 0);
    }

    function test_TryGetTokenPriceNeverRevertsOnRevertingFeed() public {
        ControllableAggregator feed = new ControllableAggregator(8);
        _setPriceFeed(nativeToken, address(feed));
        feed.setRound(1, 100e8, block.timestamp, block.timestamp, 1);
        feed.setShouldRevert(true);

        (bool ok, uint256 price) = bucketInfo.tryGetTokenPrice(nativeToken);
        assertFalse(ok);
        assertEq(price, 0);
    }

    function test_TryGetTokenPriceNeverRevertsOnStaleManualPrice() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        vm.warp(block.timestamp + 31 days);

        (bool ok, uint256 price) = bucketInfo.tryGetTokenPrice(nativeToken);
        assertFalse(ok);
        assertEq(price, 0);
    }

    function test_TryGetTokenPriceReturnsTrueForValidManualPrice() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);

        (bool ok, uint256 price) = bucketInfo.tryGetTokenPrice(nativeToken);
        assertTrue(ok);
        assertEq(price, 100e8);
    }

    function test_TryGetTokenPriceReturnsTrueForValidChainlinkPrice() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));
        feed.updateAnswer(100e8);

        (bool ok, uint256 price) = bucketInfo.tryGetTokenPrice(nativeToken);
        assertTrue(ok);
        assertEq(price, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                isPotentiallyOutpriced (per-token)
    //////////////////////////////////////////////////////////////*/

    function test_IsPotentiallyOutpricedTrueForNonWhitelistedToken() public {
        assertTrue(bucketInfo.isPotentiallyOutpriced(makeAddr("notWhitelisted")));
    }

    function test_IsPotentiallyOutpricedFalseForFreshManualPrice() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        assertFalse(bucketInfo.isPotentiallyOutpriced(nativeToken));
    }

    function test_IsPotentiallyOutpricedTrueForStaleManualPrice() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        vm.warp(block.timestamp + 31 days);
        assertTrue(bucketInfo.isPotentiallyOutpriced(nativeToken));
    }

    function test_IsPotentiallyOutpricedTrueForStaleChainlinkPrice() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 100e8);
        _setPriceFeed(nativeToken, address(feed));
        vm.warp(block.timestamp + bucketInfo.DEFAULT_MAX_PRICE_STALENESS() + 1);

        assertTrue(bucketInfo.isPotentiallyOutpriced(nativeToken));
    }

    /*//////////////////////////////////////////////////////////////
                A1 rate limit
    //////////////////////////////////////////////////////////////*/

    function test_A1_FirstEverSetIsUnboundedAndEmitsTokenPriceInitialized() public {
        vm.expectEmit(true, false, false, true);
        emit TokenPriceInitialized(nativeToken, type(uint256).max);

        bucketInfo.setTokenPrice(nativeToken, type(uint256).max);

        assertEq(bucketInfo.getTokenPrice(nativeToken), type(uint256).max);
    }

    function test_A1_WithinCapUpdateAcceptedAndEmitsTokenPriceUpdated() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        vm.warp(block.timestamp + bucketInfo.MIN_PRICE_UPDATE_INTERVAL());

        uint256 newPrice = 119e8;

        vm.expectEmit(true, false, false, true);
        emit TokenPriceUpdated(nativeToken, 100e8, newPrice);

        bucketInfo.setTokenPrice(nativeToken, newPrice);

        assertEq(bucketInfo.getTokenPrice(nativeToken), newPrice);
    }

    function test_A1_OverCapUpwardUpdateRejected() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        vm.warp(block.timestamp + bucketInfo.MIN_PRICE_UPDATE_INTERVAL());

        vm.expectRevert("Price deviation exceeds cap");
        bucketInfo.setTokenPrice(nativeToken, 121e8);
    }

    function test_A1_OverCapDownwardUpdateRejected() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        vm.warp(block.timestamp + bucketInfo.MIN_PRICE_UPDATE_INTERVAL());

        vm.expectRevert("Price deviation exceeds cap");
        bucketInfo.setTokenPrice(nativeToken, 79e8);
    }

    function test_A1_BeforeIntervalUpdateRejectedEvenWithinCap() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);

        vm.expectRevert("Price update too soon");
        bucketInfo.setTokenPrice(nativeToken, 101e8);
    }

    function test_A1_BeforeIntervalUpdateRejectedOneSecondShort() public {
        bucketInfo.setTokenPrice(nativeToken, 100e8);
        vm.warp(block.timestamp + bucketInfo.MIN_PRICE_UPDATE_INTERVAL() - 1);

        vm.expectRevert("Price update too soon");
        bucketInfo.setTokenPrice(nativeToken, 101e8);
    }

    function test_A1_BatchSetTokenPricesEnforcesSameRateLimit() public {
        address[] memory tokens = new address[](1);
        tokens[0] = nativeToken;
        uint256[] memory prices = new uint256[](1);

        prices[0] = 100e8;
        bucketInfo.batchSetTokenPrices(tokens, prices);

        prices[0] = 121e8;
        vm.expectRevert("Price update too soon");
        bucketInfo.batchSetTokenPrices(tokens, prices);
    }
}
