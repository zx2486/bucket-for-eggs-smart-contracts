// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DexConfig} from "../src/libraries/DexSwapLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {RedeemForStable} from "../src/RedeemForStable.sol";

contract RFSRejectETHReceiver {
    receive() external payable {
        revert("rejected");
    }
}

contract RFSBucketInfoMock {
    mapping(address => bool) public valid;
    mapping(address => uint256) public prices;
    bool public operational = true;
    mapping(address => bool) public blacklisted;

    function isTokenValid(address token) external view returns (bool) {
        return valid[token] && operational;
    }

    function isPlatformOperational() external view returns (bool) {
        return operational;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function getTokenPrice(address token) external view returns (uint256) {
        require(valid[token], "invalid token");
        return prices[token];
    }

    function setToken(address token, uint256 price) external {
        valid[token] = true;
        prices[token] = price;
    }

    function setValid(address token, bool value) external {
        valid[token] = value;
    }

    function setOperational(bool value) external {
        operational = value;
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function PRICE_DECIMALS() external pure returns (uint256) {
        return 8;
    }

    function getWhitelistedTokens() external pure returns (address[] memory tokens) {
        tokens = new address[](0);
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }
}

contract RFSTokenMock {
    string public name = "Test token";
    string public symbol = "TST";
    uint8 public immutable decimals;
    uint256 public feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address account, uint256 amount) public {
        balanceOf[account] += amount;
    }

    function burn(address account, uint256 amount) external {
        balanceOf[account] -= amount;
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function transferFrom(address account, address recipient, uint256 amount) external returns (bool) {
        uint256 approved = allowance[account][msg.sender];
        require(approved >= amount, "allowance");
        if (approved != type(uint256).max) allowance[account][msg.sender] = approved - amount;
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[account] -= amount;
        balanceOf[recipient] += amount - fee;
        return true;
    }
}

contract RFSPhantomPermitTokenMock is RFSTokenMock {
    constructor() RFSTokenMock(18) {}

    fallback() external {}
}

contract RFSPermitTokenMock is RFSTokenMock {
    mapping(address => uint256) public nonces;
    address public immutable signer;

    constructor(address signer_) RFSTokenMock(18) {
        signer = signer_;
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        require(owner == signer, "wrong signer");
        nonces[owner]++;
        allowance[owner][spender] = value;
    }
}

contract RFSQuoterMock {
    uint256 public quoteOut;

    function setQuoteOut(uint256 amount) external {
        quoteOut = amount;
    }

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory)
        external
        returns (uint256, uint160, uint32, uint256)
    {
        return (quoteOut, 0, 0, 0);
    }
}

contract RFSRouterMock {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    uint256 public amountOut;
    uint256 public lastAmountIn;
    bool public reenterSwap;
    bool public reenterPermit;
    bool public reentrySucceeded;
    RedeemForStable public target;
    address[] private _tokens;
    uint256[] private _amounts;
    address private _stable;

    function setAmountOut(uint256 amount) external {
        amountOut = amount;
    }

    function configureReentry(
        RedeemForStable target_,
        address[] memory tokens_,
        uint256[] memory amounts_,
        address stable_,
        bool swap_,
        bool permit_
    ) external {
        target = target_;
        _tokens = tokens_;
        _amounts = amounts_;
        _stable = stable_;
        reenterSwap = swap_;
        reenterPermit = permit_;
        reentrySucceeded = false;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        lastAmountIn = params.amountIn;
        require(amountOut >= params.amountOutMinimum, "router min output");
        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn));
        if (reenterSwap) {
            try target.swapForStable(_tokens, _amounts, _stable, 100, 0) {}
            catch {
                reentrySucceeded = true;
            }
        }
        if (reenterPermit) {
            RedeemForStable.PermitData[] memory permits = new RedeemForStable.PermitData[](0);
            try target.permitMany(permits) {}
            catch {
                reentrySucceeded = true;
            }
        }
        require(IERC20(params.tokenOut).transfer(params.recipient, amountOut));
        return amountOut;
    }
}

contract RedeemForStableContractTest is Test {
    uint256 private constant UNIT = 1e18;
    address private caller = makeAddr("caller");
    address private attacker = makeAddr("attacker");

    RFSBucketInfoMock private bucketInfo;
    RFSTokenMock private input;
    RFSTokenMock private stable;
    RFSTokenMock private weth;
    RFSQuoterMock private quoter;
    RFSRouterMock private router;
    RedeemForStable private swapper;

    function setUp() public {
        bucketInfo = new RFSBucketInfoMock();
        input = new RFSTokenMock(18);
        stable = new RFSTokenMock(18);
        weth = new RFSTokenMock(18);
        quoter = new RFSQuoterMock();
        router = new RFSRouterMock();
        bucketInfo.setToken(address(input), 1e8);
        bucketInfo.setToken(address(stable), 1e8);
        bucketInfo.setToken(address(0), 1e8);
        DexConfig[] memory dexes = new DexConfig[](1);
        dexes[0] = DexConfig(address(router), address(quoter), 3000, true);
        address[] memory stables = new address[](1);
        stables[0] = address(stable);
        swapper = new RedeemForStable(address(bucketInfo), address(weth), dexes, stables);
    }

    function testOwnerCanWithdrawTokenAndETH() public {
        input.mint(address(swapper), 3 * UNIT);
        vm.deal(address(swapper), 2 * UNIT);

        swapper.withdrawToken(caller, address(input), UNIT);
        swapper.withdrawETH(payable(caller), UNIT);

        assertEq(input.balanceOf(caller), UNIT);
        assertEq(input.balanceOf(address(swapper)), 2 * UNIT);
        assertEq(caller.balance, UNIT);
        assertEq(address(swapper).balance, UNIT);
    }

    function testNonOwnerCannotWithdrawTokenOrETH() public {
        input.mint(address(swapper), UNIT);
        vm.deal(address(swapper), UNIT);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        swapper.withdrawToken(caller, address(input), UNIT);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        swapper.withdrawETH(payable(caller), UNIT);
        vm.stopPrank();

        assertEq(input.balanceOf(address(swapper)), UNIT);
        assertEq(address(swapper).balance, UNIT);
    }

    function testWithdrawFunctionsRejectZeroRecipientAndAmount() public {
        vm.expectRevert(bytes("Invalid recipient"));
        swapper.withdrawToken(address(0), address(input), UNIT);
        vm.expectRevert(bytes("Amount must be greater than 0"));
        swapper.withdrawToken(caller, address(input), 0);
        vm.expectRevert(bytes("Invalid recipient"));
        swapper.withdrawETH(payable(address(0)), UNIT);
        vm.expectRevert(bytes("Amount must be greater than 0"));
        swapper.withdrawETH(payable(caller), 0);
    }

    function testWithdrawETHRejectsInsufficientBalanceAndFailedRecipient() public {
        vm.deal(address(swapper), UNIT);
        vm.expectRevert(bytes("Insufficient ETH balance"));
        swapper.withdrawETH(payable(caller), 2 * UNIT);

        RFSRejectETHReceiver rejectingRecipient = new RFSRejectETHReceiver();
        vm.expectRevert(bytes("ETH transfer failed"));
        swapper.withdrawETH(payable(address(rejectingRecipient)), UNIT);
        assertEq(address(swapper).balance, UNIT);
    }

    function testStableInputPassesThroughAndPaysCaller() public {
        uint256 amount = 10 * UNIT;
        stable.mint(caller, amount);
        vm.startPrank(caller);
        stable.approve(address(swapper), amount);
        address[] memory tokens = _one(address(stable));
        uint256[] memory amounts = _oneAmount(amount);
        uint256 out = swapper.swapForStable(tokens, amounts, address(stable), 100, amount);
        vm.stopPrank();

        assertEq(out, amount);
        assertEq(stable.balanceOf(caller), amount);
        assertEq(stable.balanceOf(address(swapper)), 0);
    }

    function testCannotPullVictimTokensFromAttackerCall() public {
        uint256 amount = UNIT;
        input.mint(caller, amount);
        vm.prank(caller);
        input.approve(address(swapper), amount);

        vm.startPrank(attacker);
        address[] memory tokens = _one(address(input));
        uint256[] memory amounts = _oneAmount(amount);
        vm.expectRevert();
        swapper.swapForStable(tokens, amounts, address(stable), 100, 0);
        vm.stopPrank();

        assertEq(input.balanceOf(caller), amount);
        assertEq(input.balanceOf(address(swapper)), 0);
    }

    function testSuccessfulSwapLeavesNoBalancesOrRouterAllowance() public {
        uint256 amount = UNIT;
        input.mint(caller, amount);
        stable.mint(address(router), 2 * UNIT);
        quoter.setQuoteOut(2 * UNIT);
        router.setAmountOut(2 * UNIT);
        vm.startPrank(caller);
        input.approve(address(swapper), amount);
        uint256 out = swapper.swapForStable(_one(address(input)), _oneAmount(amount), address(stable), 100, 2 * UNIT);
        vm.stopPrank();

        assertEq(out, 2 * UNIT);
        assertEq(stable.balanceOf(caller), 2 * UNIT);
        assertEq(input.balanceOf(address(swapper)), 0);
        assertEq(stable.balanceOf(address(swapper)), 0);
        assertEq(input.allowance(address(swapper), address(router)), 0);
        assertEq(weth.allowance(address(swapper), address(router)), 0);
    }

    function testMeasuredOutputBelowOracleMinimumReverts() public {
        uint256 amount = UNIT;
        input.mint(caller, amount);
        stable.mint(address(router), UNIT);
        quoter.setQuoteOut(UNIT);
        router.setAmountOut(96e16);
        vm.startPrank(caller);
        input.approve(address(swapper), amount);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.ReceivedBelowMinReturn.selector, 96e16, 99e16));
        swapper.swapForStable(_one(address(input)), _oneAmount(amount), address(stable), 100, 0);
        vm.stopPrank();
    }

    function testFeeOnTransferInputUsesMeasuredReceivedAmount() public {
        uint256 requested = UNIT;
        uint256 received = 9e17;
        input.mint(caller, requested);
        input.setFeeBps(1000);
        stable.mint(address(router), 2 * UNIT);
        quoter.setQuoteOut(received);
        router.setAmountOut(received);
        vm.prank(caller);
        input.approve(address(swapper), requested);

        vm.prank(caller);
        uint256 out = swapper.swapForStable(_one(address(input)), _oneAmount(requested), address(stable), 100, 0);

        assertEq(out, received);
        assertEq(input.balanceOf(caller), 0);
        assertEq(input.balanceOf(address(swapper)), 0);
        assertEq(router.lastAmountIn(), received);
        assertEq(input.balanceOf(address(router)), received - (received * input.feeBps()) / 10_000);
    }

    function testInvalidStableAndInputsRevert() public {
        address[] memory tokens = _one(address(input));
        uint256[] memory amounts = _oneAmount(UNIT);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.UnsupportedStable.selector, address(input)));
        swapper.swapForStable(tokens, amounts, address(input), 100, 0);

        address[] memory noPoolInput = _one(address(input));
        uint256[] memory noPoolAmount = _oneAmount(UNIT);
        input.mint(caller, UNIT);
        vm.prank(caller);
        input.approve(address(swapper), UNIT);
        vm.expectRevert("No DEX available for pair");
        vm.prank(caller);
        swapper.swapForStable(noPoolInput, noPoolAmount, address(stable), 100, 0);
        assertEq(input.balanceOf(address(swapper)), 0);

        address[] memory duplicateTokens = new address[](2);
        duplicateTokens[0] = address(stable);
        duplicateTokens[1] = address(stable);
        uint256[] memory duplicateAmounts = new uint256[](2);
        duplicateAmounts[0] = 1;
        duplicateAmounts[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.DuplicateToken.selector, address(stable)));
        swapper.swapForStable(duplicateTokens, duplicateAmounts, address(stable), 100, 0);

        vm.expectRevert(RedeemForStable.InvalidInputLengths.selector);
        swapper.swapForStable(_one(address(stable)), new uint256[](0), address(stable), 100, 0);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.InvalidAmount.selector, address(stable)));
        swapper.swapForStable(_one(address(stable)), _oneAmount(0), address(stable), 100, 0);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.SlippageTooHigh.selector, 1001));
        swapper.swapForStable(_one(address(stable)), _oneAmount(1), address(stable), 1001, 0);
    }

    function testMinTotalOutUsesMeasuredCallerReceipt() public {
        uint256 amount = UNIT;
        stable.mint(caller, amount);
        stable.setFeeBps(100);
        vm.startPrank(caller);
        stable.approve(address(swapper), amount);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.ReceivedBelowMinReturn.selector, 99e16, amount));
        swapper.swapForStable(_one(address(stable)), _oneAmount(amount), address(stable), 100, amount);
        vm.stopPrank();
    }

    function testNativeInputWrapsAndSwaps() public {
        bucketInfo.setToken(address(weth), 1e8);
        vm.deal(caller, UNIT);
        stable.mint(address(router), 2 * UNIT);
        quoter.setQuoteOut(2 * UNIT);
        router.setAmountOut(2 * UNIT);
        vm.prank(caller);
        uint256 out =
            swapper.swapForStable{value: UNIT}(_one(address(0)), _oneAmount(UNIT), address(stable), 100, 2 * UNIT);
        assertEq(out, 2 * UNIT);
        assertEq(stable.balanceOf(caller), 2 * UNIT);
        assertEq(address(swapper).balance, 0);
        assertEq(weth.balanceOf(address(swapper)), 0);
    }

    function testNativeValueMustMatchSingleNativeLeg() public {
        address[] memory tokens = _one(address(0));
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.InvalidNativeValue.selector, UNIT, 0));
        vm.prank(caller);
        swapper.swapForStable(tokens, _oneAmount(UNIT), address(stable), 100, 0);
        stable.mint(caller, UNIT);
        vm.deal(caller, UNIT);
        vm.prank(caller);
        stable.approve(address(swapper), UNIT);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.UnexpectedNativeValue.selector, UNIT));
        vm.prank(caller);
        swapper.swapForStable{value: UNIT}(_one(address(stable)), _oneAmount(UNIT), address(stable), 100, 0);
    }

    function testReentrantSwapAndPermitManyAreBlocked() public {
        uint256 amount = UNIT;
        input.mint(caller, amount);
        stable.mint(address(router), 2 * UNIT);
        quoter.setQuoteOut(2 * UNIT);
        router.setAmountOut(2 * UNIT);
        vm.prank(caller);
        input.approve(address(swapper), amount);
        router.configureReentry(swapper, _one(address(stable)), _oneAmount(1), address(stable), true, true);
        vm.prank(caller);
        swapper.swapForStable(_one(address(input)), _oneAmount(amount), address(stable), 100, 2 * UNIT);
        assertTrue(router.reentrySucceeded());
        assertEq(stable.balanceOf(caller), 2 * UNIT);
    }

    function testPermitManyUsesCallerAndFixedSpenderAndHandlesFrontRun() public {
        RFSPermitTokenMock permitToken = new RFSPermitTokenMock(caller);
        permitToken.mint(caller, 2 * UNIT);
        permitToken.permit(caller, address(swapper), UNIT, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
        RedeemForStable.PermitData[] memory permits = new RedeemForStable.PermitData[](1);
        permits[0] = RedeemForStable.PermitData(
            address(permitToken), UNIT, block.timestamp + 1 days, 27, bytes32(0), bytes32(0)
        );
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RedeemForStable.PermitAllowanceInsufficient.selector, address(permitToken), UNIT, 0)
        );
        swapper.permitMany(permits);
        vm.prank(caller);
        swapper.permitMany(permits);
        assertEq(permitToken.allowance(caller, address(swapper)), UNIT);
    }

    function testPermitManyRejectsPhantomPermitWithoutAllowance() public {
        RFSPhantomPermitTokenMock phantom = new RFSPhantomPermitTokenMock();
        RedeemForStable.PermitData[] memory permits = new RedeemForStable.PermitData[](1);
        permits[0] =
            RedeemForStable.PermitData(address(phantom), 1, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(RedeemForStable.PermitAllowanceInsufficient.selector, address(phantom), 1, 0)
        );
        vm.prank(caller);
        swapper.permitMany(permits);
    }

    function testStableMustRemainWhitelistedAndPlatformOperational() public {
        address[] memory tokens = _one(address(stable));
        uint256[] memory amounts = _oneAmount(1);
        bucketInfo.setValid(address(stable), false);
        // Constructor allowlisting alone is insufficient after a platform revocation.
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.UnsupportedStable.selector, address(stable)));
        swapper.swapForStable(tokens, amounts, address(stable), 100, 0);

        bucketInfo.setValid(address(stable), true);
        bucketInfo.setOperational(false);
        vm.expectRevert(RedeemForStable.PlatformNotOperational.selector);
        swapper.swapForStable(tokens, amounts, address(stable), 100, 0);

        bucketInfo.setOperational(true);
        bucketInfo.setBlacklisted(attacker, true);
        vm.expectRevert(abi.encodeWithSelector(RedeemForStable.Blacklisted.selector, attacker));
        vm.prank(attacker);
        swapper.swapForStable(tokens, amounts, address(stable), 100, 0);
    }

    function testVaultRedeemForStableStubsAndPlainRedeemRemainsAvailable() public {
        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        registry.setAuthorizedFactory(address(this), true);
        ActiveBucket activeImplementation = new ActiveBucket(address(registry), address(router));
        bytes memory activeInit =
            abi.encodeWithSelector(ActiveBucket.initialize.selector, address(bucketInfo), "Active", "ACT");
        ActiveBucket active =
            ActiveBucket(payable(address(new ERC1967Proxy(address(activeImplementation), activeInit))));

        PassiveBucket passiveImplementation = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory distributions = new PassiveBucket.BucketDistribution[](1);
        distributions[0] = PassiveBucket.BucketDistribution(address(stable), 100);
        bytes memory passiveInit = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), distributions, "Passive", "PAS"
        );
        PassiveBucket passive =
            PassiveBucket(payable(address(new ERC1967Proxy(address(passiveImplementation), passiveInit))));

        stable.mint(caller, 10 * UNIT);
        vm.startPrank(caller);
        stable.approve(address(passive), 10 * UNIT);
        passive.deposit(address(stable), 10 * UNIT);
        uint256 shares = passive.balanceOf(caller);
        vm.expectRevert(BucketVaultBase.RedeemForStableDisabled.selector);
        passive.redeemForStable(shares, address(stable), 100);
        passive.redeem(shares);
        vm.stopPrank();

        assertEq(passive.balanceOf(caller), 0);
        assertEq(stable.balanceOf(caller), 9 * UNIT);
        assertEq(active.owner(), address(this));
    }

    function _one(address token) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = token;
    }

    function _oneAmount(uint256 amount) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = amount;
    }
}
