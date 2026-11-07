// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PotentialRugpull} from "../src/PotentialRugpull.sol";
import {PotentialRugpullFactory} from "../src/PotentialRugpullFactory.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";

// ============================================================
//                      SHARED MOCKS
// ============================================================

/// @dev One IBucketInfo mock covering every method PotentialRugpull/ActiveBucket/PassiveBucket
/// call, same shape/precedent as `GateMockBucketInfo` (test/W4Gate.t.sol) and
/// `MockBucketInfoForRugpull` (test/PotentialRugpull.t.sol). `priceFeedSet` defaults every
/// `addToken`-ed token to Chainlink-priced, since none of this file's tests exercise the
/// manually-priced-token-rejection path.
contract GateMockBucketInfoW5 {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    mapping(address => bool) public priceFeedSet;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
    address public owner;
    mapping(address => bool) public blacklisted;

    constructor() {
        owner = msg.sender;
    }

    function isTokenValid(address token) external view returns (bool) {
        return whitelisted[token] && operational;
    }

    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelisted[token];
    }

    function getTokenPrice(address token) external view returns (uint256) {
        require(whitelisted[token], "Not whitelisted");
        return prices[token];
    }

    function tryGetTokenPrice(address token) external view returns (bool, uint256) {
        if (!whitelisted[token]) return (false, 0);
        return (true, prices[token]);
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address token) external view returns (address) {
        return priceFeedSet[token] ? address(0xFEED) : address(0);
    }

    function isPlatformOperational() external view returns (bool) {
        return operational;
    }

    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * feeRate) / 10000;
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedList;
    }

    function PRICE_DECIMALS() external pure returns (uint256) {
        return 8;
    }

    function platformFee() external view returns (uint256) {
        return feeRate;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    // --- test helpers ---
    function addToken(address token, uint256 price) external {
        if (!whitelisted[token]) {
            whitelisted[token] = true;
            whitelistedList.push(token);
        }
        prices[token] = price;
        priceFeedSet[token] = true;
    }

    function setOperational(bool _operational) external {
        operational = _operational;
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    receive() external payable {}
}

contract GateMockERC20W5 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GateFairRouterW5 {
    mapping(address => uint256) public price; // 8-decimal USD price; address(0) = native ETH
    mapping(address => uint8) public tokenDecimals;

    function setPrice(address token, uint256 price_, uint8 decimals_) external {
        price[token] = price_;
        tokenDecimals[token] = decimals_;
    }

    function execute1inchSwap(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 amount,
        uint256 minReturn
    ) external payable returns (uint256 amountOut) {
        if (srcToken == address(0)) {
            require(msg.value == amount, "router: bad native value");
        } else {
            GateMockERC20W5(srcToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 srcPrice = price[srcToken];
        uint256 dstPrice = price[dstToken];
        require(srcPrice > 0 && dstPrice > 0, "router: no price set");
        uint8 srcDec = tokenDecimals[srcToken];
        uint8 dstDec = tokenDecimals[dstToken];

        amountOut = (amount * srcPrice * (10 ** dstDec)) / ((10 ** srcDec) * dstPrice);
        require(amountOut >= minReturn, "router: below minReturn");

        if (dstToken == address(0)) {
            (bool ok,) = dstReceiver.call{value: amountOut}("");
            require(ok, "router: ETH send failed");
        } else {
            require(GateMockERC20W5(dstToken).transfer(dstReceiver, amountOut), "router: transfer failed");
        }
    }

    receive() external payable {}
}

contract GateShortPayRouterW5 {
    mapping(address => uint256) public price; // 8-decimal USD price; address(0) = native ETH
    mapping(address => uint8) public tokenDecimals;
    uint256 public immutable shortPayBps; // how much LESS than fair value this router pays out

    constructor(uint256 shortPayBps_) {
        shortPayBps = shortPayBps_;
    }

    function setPrice(address token, uint256 price_, uint8 decimals_) external {
        price[token] = price_;
        tokenDecimals[token] = decimals_;
    }

    function execute1inchSwap(
        address srcToken,
        address dstToken,
        address dstReceiver,
        uint256 amount,
        uint256 /* minReturn */
    )
        external
        payable
        returns (uint256 amountOut)
    {
        if (srcToken == address(0)) {
            require(msg.value == amount, "router: bad native value");
        } else {
            GateMockERC20W5(srcToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 srcPrice = price[srcToken];
        uint256 dstPrice = price[dstToken];
        require(srcPrice > 0 && dstPrice > 0, "router: no price set");
        uint8 srcDec = tokenDecimals[srcToken];
        uint8 dstDec = tokenDecimals[dstToken];

        uint256 fairAmountOut = (amount * srcPrice * (10 ** dstDec)) / ((10 ** srcDec) * dstPrice);
        amountOut = (fairAmountOut * (10_000 - shortPayBps)) / 10_000;

        if (dstToken == address(0)) {
            (bool ok,) = dstReceiver.call{value: amountOut}("");
            require(ok, "router: ETH send failed");
        } else {
            require(GateMockERC20W5(dstToken).transfer(dstReceiver, amountOut), "router: transfer failed");
        }
    }

    receive() external payable {}
}

contract ComposerFlashLoanReceiverW5 is IFlashLoanReceiver {
    enum Mode {
        None,
        Deposit,
        Redeem
    }

    Mode public mode;
    ActiveBucket public bucket;

    constructor(ActiveBucket bucket_) {
        bucket = bucket_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata) external override {
        if (mode == Mode.Deposit) {
            bucket.deposit{value: amount}(address(0), 0);
        } else if (mode == Mode.Redeem) {
            bucket.redeem(1);
        }
    }

    receive() external payable {}
}

contract MockFlashLoanReceiverW5 is IFlashLoanReceiver {
    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata) external override {
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount + fee}("");
            require(ok, "repay failed");
        } else {
            IERC20(token).transfer(msg.sender, amount + fee);
        }
    }

    receive() external payable {}
}

/// @notice D1 (`04-CONTRACTS-IMPLEMENTATION-PLAN.md:50`): the floor is
/// `cashRatio * max(assertedPortfolioValue, netInvestorDeposits) / 100`. These two tests each
/// drive one side of that `max()` to be the larger value and prove, BOTH by reading
/// `ownerWithdrawalFloorRequired()` directly AND by exercising `ownerWithdraw`'s exact
/// revert/success boundary, that the floor is actually computed against whichever side is
/// currently higher — not hardcoded to one side, and not silently falling back to the other.
contract W5GateRugpullFloorTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    GateMockERC20W5 public token;
    PotentialRugpullFactory public factory;
    PotentialRugpull public rugpull;

    address public ownerAddr;
    address public investor;

    uint256 constant TOKEN_PRICE = 1e8; // $1, 8-decimal USD
    uint256 constant CASH_RATIO = 50;

    function setUp() public {
        ownerAddr = address(this);
        investor = makeAddr("investor");

        bucketInfo = new GateMockBucketInfoW5();
        token = new GateMockERC20W5("Token", "TKN", 18);
        bucketInfo.addToken(address(token), TOKEN_PRICE);

        token.mint(investor, 10_000e18);

        factory = new PotentialRugpullFactory(address(bucketInfo));
        address instance = factory.createPotentialRugpull(CASH_RATIO, "Rugpull Share", "RUG");
        rugpull = PotentialRugpull(payable(instance));
    }

    function test_G1a_FloorGovernedByAssertedValue_WhenHigherThanDeposits() public {
        rugpull.setAssertedPortfolioValue(1000e8);

        vm.startPrank(investor);
        token.approve(address(rugpull), 600e18);
        rugpull.deposit(address(token), 600e18); // netInvestorDeposits = 600e8
        vm.stopPrank();

        assertEq(rugpull.netInvestorDeposits(), 600e8);
        assertEq(rugpull.assertedPortfolioValue(), 1000e8);

        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertEq(required, 500e8, "required must be 50% of the HIGHER value (asserted: 1000e8)");
        assertTrue(
            required != (CASH_RATIO * rugpull.netInvestorDeposits()) / 100,
            "sanity: the netInvestorDeposits-only formula must give a DIFFERENT number here"
        );

        // Withdraw $150 -> remaining = 600e8 - 150e8 = 450e8 < 500e8 required -> reverts.
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 450e8, 500e8));
        rugpull.ownerWithdraw(address(token), 150e18);

        rugpull.ownerWithdraw(address(token), 90e18);
        assertEq(rugpull.netInvestorDeposits(), 600e8, "non-ratchet: deposit ledger must be untouched");
        assertEq(rugpull.ownerWithdrawnValueUsd8(), 90e8);
        assertEq(token.balanceOf(ownerAddr), 90e18);
    }

    function test_G1b_FloorGovernedByNetInvestorDeposits_WhenHigherThanAssertedValue() public {
        assertEq(rugpull.assertedPortfolioValue(), 1e8);

        vm.startPrank(investor);
        token.approve(address(rugpull), 1000e18);
        rugpull.deposit(address(token), 1000e18); // netInvestorDeposits = 1000e8
        vm.stopPrank();

        assertEq(rugpull.netInvestorDeposits(), 1000e8);

        uint256 required = rugpull.ownerWithdrawalFloorRequired();
        assertEq(required, 500e8, "required must be 50% of the HIGHER value (deposits: 1000e8)");
        assertTrue(
            required != (CASH_RATIO * rugpull.assertedPortfolioValue()) / 100,
            "sanity: the assertedPortfolioValue-only formula must give a DIFFERENT (much smaller) number here"
        );

        // Withdraw $600 -> remaining = 1000e8 - 600e8 = 400e8 < 500e8 required -> reverts.
        vm.expectRevert(abi.encodeWithSelector(PotentialRugpull.OwnerWithdrawalFloorBreached.selector, 400e8, 500e8));
        rugpull.ownerWithdraw(address(token), 600e18);

        rugpull.ownerWithdraw(address(token), 400e18);
        assertEq(rugpull.netInvestorDeposits(), 1000e8, "non-ratchet: deposit ledger must be untouched");
        assertEq(rugpull.ownerWithdrawnValueUsd8(), 400e8);
        assertEq(token.balanceOf(ownerAddr), 400e18);
    }
}

contract W5GateStableExitAtomicityTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    GateMockERC20W5 public stable; // 6 decimals — redemption target, ALSO a basket asset
    GateShortPayRouterW5 public router;
    ImplementationRegistry public registry;
    PassiveBucket public passiveImpl;
    PassiveBucket public passive;

    address public ownerAddr;
    address public user1;

    uint256 constant ETH_PRICE = 2000e8; // $2000
    uint256 constant STABLE_PRICE = 1e8; // $1
    uint256 constant SHORT_PAY_BPS = 1000; // router pays 10% less than fair value

    function setUp() public {
        ownerAddr = address(this);
        user1 = makeAddr("user1");
        vm.deal(user1, 100 ether);

        bucketInfo = new GateMockBucketInfoW5();
        stable = new GateMockERC20W5("Stable", "STB", 6);
        router = new GateShortPayRouterW5(SHORT_PAY_BPS);

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(stable), STABLE_PRICE);

        router.setPrice(address(0), ETH_PRICE, 18);
        router.setPrice(address(stable), STABLE_PRICE, 6);

        stable.mint(address(router), 1_000_000e6);

        registry = new ImplementationRegistry(ownerAddr);
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);

        passiveImpl = new PassiveBucket(address(registry), address(this));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 1);
        dists[1] = PassiveBucket.BucketDistribution(address(stable), 99);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, "Passive Share", "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(passiveImpl), initData);
        passive = PassiveBucket(payable(address(proxy)));

        vm.prank(user1);
        passive.deposit{value: 1 ether}(address(0), 0);

        stable.mint(user1, 198_000e6);
        vm.prank(user1);
        stable.approve(address(passive), 198_000e6);
        vm.prank(user1);
        passive.deposit(address(stable), 198_000e6);
    }

    function test_G2_StableExitRevertsEntirely_OnShortPaidLeg() public {
        uint256 sharesBefore = passive.balanceOf(user1);
        uint256 ethBefore = address(passive).balance;
        uint256 vaultStableBefore = stable.balanceOf(address(passive));
        uint256 userStableBefore = stable.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(BucketVaultBase.RedeemForStableDisabled.selector);
        passive.redeemForStable(sharesBefore, address(stable), 0);

        assertEq(passive.balanceOf(user1), sharesBefore, "shares must survive a short-paid leg completely unburned");
        assertEq(address(passive).balance, ethBefore, "vault ETH balance must be untouched after a short-paid leg");
        assertEq(
            stable.balanceOf(address(passive)),
            vaultStableBefore,
            "vault stable balance must be untouched -- the free leg's payout must not survive the later leg's revert"
        );
        assertEq(
            stable.balanceOf(user1),
            userStableBefore,
            "user must receive NOTHING, not even the free leg's portion, when a later leg reverts"
        );
    }
}

contract W5GateFlashLoanCompositionTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    ActiveBucket public activeImpl;
    ActiveBucket public active;
    ImplementationRegistry public registry;

    address public ownerAddr;
    address public user1;

    uint256 constant ETH_PRICE = 2000e8;

    function setUp() public {
        ownerAddr = address(this);
        user1 = makeAddr("user1");
        vm.deal(user1, 100 ether);

        bucketInfo = new GateMockBucketInfoW5();
        bucketInfo.addToken(address(0), ETH_PRICE);

        registry = new ImplementationRegistry(ownerAddr);
        activeImpl = new ActiveBucket(address(registry), address(this));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), "Active Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(activeImpl), initData);
        active = ActiveBucket(payable(address(proxy)));

        vm.prank(user1);
        active.deposit{value: 10 ether}(address(0), 0);
    }

    function test_G3a_FlashLoanCannotComposeWithDeposit() public {
        ComposerFlashLoanReceiverW5 receiver = new ComposerFlashLoanReceiverW5(active);
        receiver.setMode(ComposerFlashLoanReceiverW5.Mode.Deposit);

        vm.prank(user1);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }

    function test_G3b_FlashLoanCannotComposeWithRedeem() public {
        ComposerFlashLoanReceiverW5 receiver = new ComposerFlashLoanReceiverW5(active);
        receiver.setMode(ComposerFlashLoanReceiverW5.Mode.Redeem);

        vm.prank(user1);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }
}

contract W5GateFlashLoanHolderTest is Test {
    GateMockBucketInfoW5 public bucketInfo;
    ActiveBucket public activeImpl;
    ActiveBucket public active;
    ImplementationRegistry public registry;

    address public ownerAddr;
    address public holder; // deposits, becomes a shareholder -- NOT the owner
    address public nonHolder; // never deposits

    uint256 constant ETH_PRICE = 2000e8;

    function setUp() public {
        ownerAddr = address(this);
        holder = makeAddr("holder");
        nonHolder = makeAddr("nonHolder");
        vm.deal(holder, 100 ether);

        bucketInfo = new GateMockBucketInfoW5();
        bucketInfo.addToken(address(0), ETH_PRICE);

        registry = new ImplementationRegistry(ownerAddr);
        activeImpl = new ActiveBucket(address(registry), address(this));
        // Task #33 (W1.7 direct-proxy-bypass fix): this test deploys its proxy directly, so the
        // test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), "Active Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(activeImpl), initData);
        active = ActiveBucket(payable(address(proxy)));

        vm.prank(holder);
        active.deposit{value: 10 ether}(address(0), 0);
    }

    function test_G4_FlashLoanCallableByHolderWhoIsNotOwner() public {
        assertTrue(active.balanceOf(holder) > 0, "sanity: holder must actually hold shares");
        assertTrue(holder != active.owner(), "sanity: holder must NOT be the owner");

        MockFlashLoanReceiverW5 receiver = new MockFlashLoanReceiverW5();
        vm.deal(address(receiver), 1 ether); // covers the 2% fee on top of the repaid principal

        vm.prank(holder);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }

    function test_G4_FlashLoanRejectsNonHolder() public {
        MockFlashLoanReceiverW5 receiver = new MockFlashLoanReceiverW5();

        vm.prank(nonHolder);
        vm.expectRevert(BucketVaultBase.InsufficientShares.selector);
        active.flashLoan(address(0), 1 ether, address(receiver), "");
    }
}
