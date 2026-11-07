// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IBucketInfo} from "../src/interfaces/IBucketInfo.sol";
import {OneInchCalldataLib} from "../src/libraries/OneInchCalldataLib.sol";

// hard rule 12 / 09 §4.2a, R-V1: test-only, local EVM allowance coverage.
contract D5ExecutionToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function burn(address account, uint256 amount) external {
        balanceOf[account] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "allowance");
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract D5ExecutionBucketInfo is IBucketInfo {
    address[] private _tokens;

    constructor(address[] memory tokens) {
        _tokens = tokens;
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return _tokens;
    }

    function isTokenValid(address) external pure returns (bool) {
        return true;
    }

    function isTokenWhitelisted(address) external pure returns (bool) {
        return true;
    }

    function getTokenPrice(address) external pure returns (uint256) {
        return 1;
    }

    function tryGetTokenPrice(address) external pure returns (bool, uint256) {
        return (true, 1);
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function isPlatformOperational() external pure returns (bool) {
        return true;
    }

    function calculateFee(uint256) external pure returns (uint256) {
        return 0;
    }

    function PRICE_DECIMALS() external pure returns (uint256) {
        return 8;
    }

    function platformFee() external pure returns (uint256) {
        return 0;
    }

    function owner() external pure returns (address) {
        return address(1);
    }

    function isBlacklisted(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
    }
}

contract D5ExecutionRouter {
    D5ExecutionToken public immutable src;
    D5ExecutionToken public immutable dst;
    D5ExecutionToken public immutable protectedToken;
    bool public shouldRevert;
    uint256 public spendBps = 10_000;
    uint256 public outputBps = 10_000;
    bool public drainProtectedToken;

    constructor(D5ExecutionToken src_, D5ExecutionToken dst_, D5ExecutionToken protectedToken_) {
        src = src_;
        dst = dst_;
        protectedToken = protectedToken_;
    }

    function configure(bool shouldRevert_, uint256 spendBps_, uint256 outputBps_, bool drainProtectedToken_) external {
        shouldRevert = shouldRevert_;
        spendBps = spendBps_;
        outputBps = outputBps_;
        drainProtectedToken = drainProtectedToken_;
    }

    function swap(address, OneInchCalldataLib.SwapDescription calldata description, bytes calldata)
        external
        returns (uint256)
    {
        require(!shouldRevert, "router reverted");
        uint256 spend = description.amount * spendBps / 10_000;
        require(src.transferFrom(msg.sender, address(this), spend));
        uint256 output = description.minReturnAmount * outputBps / 10_000;
        require(dst.transfer(description.dstReceiver, output));
        if (drainProtectedToken) protectedToken.burn(msg.sender, 1);
        return description.minReturnAmount;
    }
}

contract D5CalldataExecutionHarness {
    function execute(
        address bucketInfo,
        address[] calldata protectedTokens,
        address router,
        address src,
        address dst,
        uint256 amount,
        uint256 minReturn,
        bytes calldata routerCalldata
    ) external returns (uint256 spent, uint256 received) {
        OneInchCalldataLib.SwapRequest memory request = OneInchCalldataLib.SwapRequest({
            router: router,
            srcToken: src,
            dstToken: dst,
            amount: amount,
            minReturn: minReturn,
            routerCalldata: routerCalldata
        });
        return OneInchCalldataLib.executeSwap(IBucketInfo(bucketInfo), protectedTokens, request);
    }
}

contract D5CalldataExecutionTest is Test {
    uint256 private constant AMOUNT = 10 ether;
    uint256 private constant MIN_RETURN = 9 ether;
    address private constant EXECUTOR = address(0x1234);

    D5ExecutionToken private src;
    D5ExecutionToken private dst;
    D5ExecutionToken private other;
    D5ExecutionBucketInfo private bucketInfo;
    D5ExecutionRouter private router;
    D5CalldataExecutionHarness private vault;

    function setUp() public {
        src = new D5ExecutionToken();
        dst = new D5ExecutionToken();
        other = new D5ExecutionToken();
        address[] memory whitelisted = new address[](3);
        whitelisted[0] = address(src);
        whitelisted[1] = address(dst);
        whitelisted[2] = address(other);
        bucketInfo = new D5ExecutionBucketInfo(whitelisted);
        vault = new D5CalldataExecutionHarness();
        router = new D5ExecutionRouter(src, dst, other);
        src.mint(address(vault), AMOUNT);
        dst.mint(address(router), MIN_RETURN);
        other.mint(address(vault), 5 ether);
    }

    function testExactAllowanceIsClearedAfterSuccessfulSwapEvenWhenRouterPullsLess() public {
        router.configure(false, 5_000, 10_000, false);
        (uint256 spent, uint256 received) = _execute();

        assertEq(spent, 5 ether);
        assertEq(received, MIN_RETURN);
        assertEq(src.allowance(address(vault), address(router)), 0);
        assertEq(src.balanceOf(address(vault)), 5 ether);
        assertEq(dst.balanceOf(address(vault)), MIN_RETURN);
    }

    function testReceivedBelowMinimumRevertsAndRollsBackSwap() public {
        router.configure(false, 10_000, 5_000, false);
        vm.expectRevert(
            abi.encodeWithSelector(OneInchCalldataLib.ReceivedBelowMinimum.selector, MIN_RETURN / 2, MIN_RETURN)
        );
        _execute();

        assertEq(src.balanceOf(address(vault)), AMOUNT);
        assertEq(dst.balanceOf(address(vault)), 0);
        assertEq(src.allowance(address(vault), address(router)), 0);
    }

    function testRouterRevertRollsBackTransientAllowance() public {
        router.configure(true, 10_000, 10_000, false);
        vm.expectRevert(bytes("router reverted"));
        _execute();

        assertEq(src.allowance(address(vault), address(router)), 0);
        assertEq(src.balanceOf(address(vault)), AMOUNT);
        assertEq(dst.balanceOf(address(vault)), 0);
    }

    function testSpendingAnotherWhitelistedTokenReverts() public {
        router.configure(false, 10_000, 10_000, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                OneInchCalldataLib.UnexpectedTokenBalanceDecrease.selector, address(other), 5 ether, 5 ether - 1
            )
        );
        _execute();

        assertEq(src.allowance(address(vault), address(router)), 0);
        assertEq(src.balanceOf(address(vault)), AMOUNT);
        assertEq(other.balanceOf(address(vault)), 5 ether);
    }

    function _execute() private returns (uint256 spent, uint256 received) {
        address[] memory protectedTokens = new address[](1);
        protectedTokens[0] = address(other);
        bytes memory routerCalldata = _routerCalldata();
        return vault.execute(
            address(bucketInfo),
            protectedTokens,
            address(router),
            address(src),
            address(dst),
            AMOUNT,
            MIN_RETURN,
            routerCalldata
        );
    }

    function _routerCalldata() private view returns (bytes memory) {
        OneInchCalldataLib.SwapDescription memory description = OneInchCalldataLib.SwapDescription({
            srcToken: address(src),
            dstToken: address(dst),
            srcReceiver: address(0),
            dstReceiver: address(vault),
            amount: AMOUNT,
            minReturnAmount: MIN_RETURN,
            flags: 0
        });
        return abi.encodeWithSelector(OneInchCalldataLib.SWAP_SELECTOR, EXECUTOR, description, bytes("route data"));
    }
}
