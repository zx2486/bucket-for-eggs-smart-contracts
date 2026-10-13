// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// W5.2 (SC-9, task #64): dedicated unit coverage for `BucketVaultBase.redeemForStable()`.
//
// New, self-contained file rather than additions to the existing (large) PassiveBucket.t.sol /
// ActiveBucket.t.sol — this file owns and defines its OWN mocks (root CLAUDE.md hard rule 6),
// following the established convention in this repo (see OneInchSwapSecurity.t.sol) of each
// test file keeping its own fixtures rather than importing another test file's, to avoid
// merge-conflict risk and cross-file coupling.
//
// Key platform constraint this file's design works around (root CLAUDE.md hard rule 12 / A4):
// NO allowance is ever granted to the 1inch router for ANY token, so an ERC20-sourced swap leg
// always reverts in reality. Only a native-ETH-sourced leg (`srcToken == address(0)`) can ever
// succeed, since the router call carries `value: amount` directly. `FairValueOneInchRouter`
// below mirrors this exactly: it performs a genuine zero-slippage, oracle-priced conversion for
// a native-ETH-sourced leg, and genuinely fails an ERC20-sourced leg via a real `transferFrom`
// that reverts for lack of allowance (not a hardcoded `require(false)`) — the same mechanism a
// real router would hit.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {ActiveBucket} from "../src/ActiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";
import {BucketInfo} from "../src/BucketInfo.sol";

// ============================================================
//                      MOCK CONTRACTS
// ============================================================

/// @dev Same shape as MockBucketInfoForPassive/MockBucketInfoForActive in the sibling test
/// files — duplicated here deliberately (hard rule 6) rather than imported.
contract MockBucketInfoRFS {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 100; // 1%
    address public owner;

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

    function addToken(address token, uint256 price) external {
        if (!whitelisted[token]) {
            whitelisted[token] = true;
            whitelistedList.push(token);
        }
        prices[token] = price;
    }

    function setOperational(bool _operational) external {
        operational = _operational;
    }

    mapping(address => bool) public blacklisted;

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
    }

    receive() external payable {}
}

contract MockERC20RFS {
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

/// @dev Fair-value 1inch router mock: performs a genuine zero-slippage, zero-fee conversion
/// using oracle prices the test configures via `setPrice`, so `redeemForStable`'s multi-leg
/// accumulation logic can be exercised with an actually-successful swap. Function signature
/// matches `BucketVaultBase.ONEINCH_SWAP_SELECTOR` exactly
/// (`execute1inchSwap(address,address,address,uint256,uint256)`), so Solidity's own selector
/// derivation lines up with the vault's hand-built calldata without any extra wiring here.
///
/// Deliberately does NOT special-case the ERC20-`srcToken` path into some shortcut success —
/// it genuinely attempts `MockERC20RFS.transferFrom(vault, router, amount)`, exactly as a real
/// 1inch router would to pull its input, which genuinely reverts (arithmetic underflow on the
/// zero allowance) because hard rule 12 means the vault never approves this router for
/// anything. This is the SAME mechanism — not a stand-in for it — that makes every ERC20-sourced
/// 1inch swap in the real contracts revert today (A4).
contract FairValueOneInchRouter {
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
            // Genuinely attempts the pull a real router would make. The vault never approves
            // this router (hard rule 12), so this reverts with an arithmetic-underflow panic —
            // exactly how an ERC20-sourced leg fails against the real router today.
            MockERC20RFS(srcToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 srcPrice = price[srcToken];
        uint256 dstPrice = price[dstToken];
        require(srcPrice > 0 && dstPrice > 0, "router: no price set");
        uint8 srcDec = tokenDecimals[srcToken];
        uint8 dstDec = tokenDecimals[dstToken];

        // Multiply before dividing (workspace CLAUDE.md §6) — exact zero-slippage conversion.
        amountOut = (amount * srcPrice * (10 ** dstDec)) / ((10 ** srcDec) * dstPrice);
        require(amountOut >= minReturn, "router: below minReturn");

        if (dstToken == address(0)) {
            (bool ok,) = dstReceiver.call{value: amountOut}("");
            require(ok, "router: ETH send failed");
        } else {
            require(MockERC20RFS(dstToken).transfer(dstReceiver, amountOut), "router: transfer failed");
        }
    }

    receive() external payable {}
}

// ============================================================
//                      TEST CONTRACT
// ============================================================

contract RedeemForStableTest is Test {
    BucketInfo public feeBucketInfo;
    MockBucketInfoRFS public bucketInfo;
    MockERC20RFS public tokenA; // 18 decimals — "volatile" basket asset
    MockERC20RFS public stable; // 6 decimals — redemption target
    FairValueOneInchRouter public router;
    ImplementationRegistry public registry;

    PassiveBucket public passiveImpl;
    PassiveBucket public passive;
    ActiveBucket public activeImpl;
    ActiveBucket public active;

    address public owner;
    address public user1;

    // Owner-accountability tests (§5 below) call `redeemForStable(..., address(0), ...)`
    // directly as `owner == address(this)` (no `vm.prank`), so a successful ETH-denominated
    // redemption pays this test contract itself via `_transferToken`'s low-level
    // `.call{value: amount}("")` (BucketVaultBase.sol:751). forge-std's `Test` base declares no
    // `receive`/`fallback` (verified: zero matches across `lib/forge-std/src`), so without this,
    // that payout leg reverts `ETHTransferFailed()` for lack of a receiver — not a source bug,
    // just this test contract needing to be able to hold ETH like any other owner would.
    receive() external payable {}

    uint256 constant ETH_PRICE = 2000e8; // $2000, 8-decimal USD
    uint256 constant TOKEN_A_PRICE = 50e8; // $50
    uint256 constant STABLE_PRICE = 1e8; // $1

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        vm.deal(owner, 1000 ether);
        vm.deal(user1, 1000 ether);

        bucketInfo = new MockBucketInfoRFS();
        feeBucketInfo = new BucketInfo();
        tokenA = new MockERC20RFS("Token A", "TKA", 18);
        stable = new MockERC20RFS("Stable", "STB", 6);
        router = new FairValueOneInchRouter();

        bucketInfo.addToken(address(0), ETH_PRICE);
        bucketInfo.addToken(address(tokenA), TOKEN_A_PRICE);
        bucketInfo.addToken(address(stable), STABLE_PRICE);

        router.setPrice(address(0), ETH_PRICE, 18);
        router.setPrice(address(tokenA), TOKEN_A_PRICE, 18);
        router.setPrice(address(stable), STABLE_PRICE, 6);

        registry = new ImplementationRegistry(owner);
        // Task #33 (W1.7 direct-proxy-bypass fix): `_deployPassive()`/`_deployActive()` below
        // deploy proxies directly, so the test contract itself must be an authorized "factory".
        registry.setAuthorizedFactory(address(this), true);
    }

    /// @dev Deploys a fresh PassiveBucket (ETH 50% / tokenA 30% / stable 20%) wired to the
    /// shared mocks from setUp(). Each test calls this itself — rather than one shared
    /// setUp()-deployed instance — since several tests need DIFFERENT router/token funding.
    function _deployPassive() internal {
        passiveImpl = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](3);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(tokenA), 30);
        dists[2] = PassiveBucket.BucketDistribution(address(stable), 20);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector, address(bucketInfo), dists, address(router), "Passive Share", "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(passiveImpl), initData);
        passive = PassiveBucket(payable(address(proxy)));
    }

    /// @dev Deploys a fresh ActiveBucket wired to the shared mocks from setUp(). ActiveBucket
    /// has no distribution concept — deposit() accepts any `isTokenValid` token directly.
    function _deployActive() internal {
        activeImpl = new ActiveBucket(address(registry));
        bytes memory initData = abi.encodeWithSelector(
            ActiveBucket.initialize.selector, address(bucketInfo), address(router), "Active Share", "aBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(activeImpl), initData);
        active = ActiveBucket(payable(address(proxy)));
    }

    function _deployFeeWithdrawalPassive() internal returns (PassiveBucket bucket) {
        PassiveBucket implementation = new PassiveBucket(address(registry));
        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](2);
        dists[0] = PassiveBucket.BucketDistribution(address(0), 50);
        dists[1] = PassiveBucket.BucketDistribution(address(stable), 50);
        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(router),
            "Fee Share",
            "fBKT"
        );
        bucket = PassiveBucket(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _depositAndTransferSharesToBucketInfo(PassiveBucket bucket, uint256 ethAmount, uint256 stableAmount)
        internal
        returns (uint256 shares)
    {
        stable.mint(user1, stableAmount);
        vm.startPrank(user1);
        if (ethAmount > 0) bucket.deposit{value: ethAmount}(address(0), 0);
        if (stableAmount > 0) {
            stable.approve(address(bucket), stableAmount);
            bucket.deposit(address(stable), stableAmount);
        }
        vm.stopPrank();

        shares = bucket.balanceOf(user1);
        vm.prank(user1);
        bucket.transfer(address(feeBucketInfo), shares);
    }

    function _setUpFeeWithdrawalPrices() internal {
        feeBucketInfo.proposeWhitelistAddition(address(stable));
        vm.warp(block.timestamp + feeBucketInfo.PLATFORM_SETTER_TIMELOCK_DELAY());
        feeBucketInfo.executeWhitelistAddition(address(stable));
        router.setPrice(address(feeBucketInfo), 1e8, 18);
        router.setPrice(address(stable), STABLE_PRICE, 6);
        stable.mint(address(router), 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                    1. MULTI-LEG REDEMPTION, GENUINE SUCCESS
    //////////////////////////////////////////////////////////////*/

    /// @notice A two-asset basket (ETH, stable) redeemed for `stable`: the stable leg takes the
    /// "already dstToken" skip path, the ETH leg genuinely swaps via the zero-slippage
    /// `FairValueOneInchRouter`. Asserts the returned/transferred total matches an INDEPENDENTLY
    /// computed pro-rata + fair-value figure, not a hardcoded number.
    ///
    /// Deliberately does NOT also deposit `tokenA`: hard rule 12 / A4 means an ERC20-sourced
    /// 1inch leg always reverts for lack of allowance (the vault never approves the router for
    /// any token) — that is exactly what `test_RedeemForStable_RevertsNotPartialFill_WhenLegSwapFails`
    /// exercises below. A "genuine success" test can therefore only ever contain a native-ETH leg
    /// plus a dstToken skip-path leg; adding a second ERC20 that needs swapping would make this
    /// test assert something the real contract cannot do today.
    function test_RedeemForStable_MultiLegRedemption_Success() public {
        _deployPassive();
        stable.mint(address(router), 1_000_000e6);

        stable.mint(user1, 100_000e6);
        vm.startPrank(user1);
        passive.deposit{value: 10 ether}(address(0), 0);
        stable.approve(address(passive), 20_000e6);
        passive.deposit(address(stable), 20_000e6);
        vm.stopPrank();

        uint256 shares = passive.balanceOf(user1);
        uint256 supply = passive.totalSupply();

        // Independently reproduce `_previewRedeemCore`'s exact `(balance * shares) / supply`
        // formula off the vault's own live balances.
        uint256 ethAmount = (address(passive).balance * shares) / supply;
        uint256 stableAmount = (stable.balanceOf(address(passive)) * shares) / supply;

        // Same zero-slippage conversion formula `FairValueOneInchRouter` itself uses.
        uint256 ethLegOut = (ethAmount * ETH_PRICE * (10 ** 6)) / ((10 ** 18) * STABLE_PRICE);
        uint256 expectedTotal = stableAmount + ethLegOut;

        uint256 stableBefore = stable.balanceOf(user1);

        // NOT 100 bps: `minReturnForStableLeg` rounds a USD value DOWN into a dstToken amount,
        // and `validateSwapLeg` independently rounds that token amount back UP into USD to
        // compare against its own freshly-derived floor (SwapExecutionLib.sol:208-235, :133-177)
        // — a lossy USD->token->USD round trip that can only ever lose value. At exactly the
        // 100bps floor there is zero margin to absorb that loss, so this reverts
        // `MinReturnBelowFloor` by a few raw units even though the swap is genuinely fair-value.
        // 50bps leaves a comfortable margin above that rounding noise while still exercising a
        // real (non-trivial) caller-chosen tolerance.
        vm.prank(user1);
        uint256 totalStableOut = passive.redeemForStable(shares, address(stable), 50);

        assertEq(totalStableOut, expectedTotal, "returned total must match independent fair-value computation");
        assertEq(stable.balanceOf(user1) - stableBefore, expectedTotal, "actual transfer must match returned total");
        assertEq(passive.balanceOf(user1), 0, "all redeemed shares must be burned");
    }

    /*//////////////////////////////////////////////////////////////
                  BUCKETINFO STABLE-FEE WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawAccumulatedFeesToStable_RedeemsAndTransfers() public {
        _setUpFeeWithdrawalPrices();
        PassiveBucket bucket = _deployFeeWithdrawalPassive();
        uint256 shares = _depositAndTransferSharesToBucketInfo(bucket, 1 ether, 2_000e6);
        address[] memory vaults = new address[](1);
        vaults[0] = address(bucket);

        uint256 stableBefore = stable.balanceOf(user1);
        vm.expectEmit(true, true, false, true, address(feeBucketInfo));
        emit BucketInfo.FeesWithdrawn(address(stable), user1, 3_999e6);
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);

        assertEq(stable.balanceOf(user1) - stableBefore, 3_999e6);
        assertEq(bucket.balanceOf(address(feeBucketInfo)), 0);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(bucket)), shares);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(stable)), 0);
    }

    function test_WithdrawAccumulatedFeesToStable_SkipsVaultWithoutShares() public {
        _setUpFeeWithdrawalPrices();
        PassiveBucket emptyBucket = _deployFeeWithdrawalPassive();
        PassiveBucket fundedBucket = _deployFeeWithdrawalPassive();
        uint256 shares = _depositAndTransferSharesToBucketInfo(fundedBucket, 1 ether, 2_000e6);
        address[] memory vaults = new address[](2);
        vaults[0] = address(emptyBucket);
        vaults[1] = address(fundedBucket);

        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);

        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(emptyBucket)), 0);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(fundedBucket)), shares);
        assertEq(stable.balanceOf(user1), 3_999e6);
    }

    function test_WithdrawAccumulatedFeesToStable_RevertsWhenNoSharesToRedeem() public {
        _setUpFeeWithdrawalPrices();
        PassiveBucket emptyBucket = _deployFeeWithdrawalPassive();
        address[] memory vaults = new address[](1);
        vaults[0] = address(emptyBucket);

        vm.expectRevert(bytes("No fees to withdraw"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);
    }

    function test_WithdrawAccumulatedFeesToStable_RevertsForNonOwner() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(0xBEEF);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);
    }

    function test_WithdrawAccumulatedFeesToStable_RejectsInvalidArguments() public {
        _setUpFeeWithdrawalPrices();
        address[] memory noVaults = new address[](0);
        vm.expectRevert(bytes("Invalid recipient"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(address(0), noVaults, address(stable), 50);

        vm.expectRevert(bytes("No tokens specified"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, noVaults, address(stable), 50);

        address[] memory vaults = new address[](1);
        vaults[0] = address(0xBEEF);
        vm.expectRevert(bytes("Invalid destination token"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(0), 50);

        vm.expectRevert(bytes("Destination token not whitelisted"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, user1, 50);

        vm.expectRevert(bytes("Invalid max slippage"));
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 0);
    }

    function test_WithdrawAccumulatedFeesToStable_FailedVaultRedemptionIsAtomic() public {
        PassiveBucket bucket = _deployFeeWithdrawalPassive();
        uint256 shares = _depositAndTransferSharesToBucketInfo(bucket, 1 ether, 2_000e6);
        address[] memory vaults = new address[](1);
        vaults[0] = address(bucket);
        uint256 stableBefore = stable.balanceOf(user1);

        vm.expectRevert();
        feeBucketInfo.withdrawAccumulatedFeesToStable(user1, vaults, address(stable), 50);

        assertEq(bucket.balanceOf(address(feeBucketInfo)), shares);
        assertEq(feeBucketInfo.accumulatedFeesWithdrawn(address(bucket)), 0);
        assertEq(stable.balanceOf(user1), stableBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    2. dstToken WHITELIST PRECONDITION
    //////////////////////////////////////////////////////////////*/

    function test_RedeemForStable_RevertsIfDstTokenNotWhitelisted() public {
        _deployPassive();

        vm.prank(user1);
        passive.deposit{value: 1 ether}(address(0), 0);

        address notWhitelisted = address(0xBEEF);
        uint256 shares = passive.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, notWhitelisted));
        passive.redeemForStable(shares, notWhitelisted, 100);
    }

    function test_RedeemForStable_DstTokenWhitelistPrecondition_ActiveBucket() public {
        _deployActive();

        vm.prank(user1);
        active.deposit{value: 1 ether}(address(0), 0);

        address notWhitelisted = address(0xBEEF);
        uint256 shares = active.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, notWhitelisted));
        active.redeemForStable(shares, notWhitelisted, 100);
    }

    /*//////////////////////////////////////////////////////////////
                    3. SLIPPAGE: TIGHTENS, NEVER LOOSENS, THE FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @notice A tighter-than-platform-floor `maxSlippageBps` (10 bps vs. the hardcoded 100 bps)
    /// must still succeed against a genuinely fair (zero-slippage) swap.
    function test_RedeemForStable_TighterSlippage_Succeeds() public {
        _deployPassive();
        stable.mint(address(router), 1_000_000e6);

        vm.prank(user1);
        passive.deposit{value: 5 ether}(address(0), 0);

        uint256 shares = passive.balanceOf(user1);
        uint256 supply = passive.totalSupply();
        uint256 ethAmount = (address(passive).balance * shares) / supply;
        uint256 expectedOut = (ethAmount * ETH_PRICE * (10 ** 6)) / ((10 ** 18) * STABLE_PRICE);

        vm.prank(user1);
        uint256 totalStableOut = passive.redeemForStable(shares, address(stable), 10);

        assertEq(totalStableOut, expectedOut, "tighter-than-floor tolerance must still succeed at fair value");
    }

    /// @notice A looser-than-platform-floor `maxSlippageBps` (500 bps vs. the hardcoded 100 bps)
    /// must revert `MinReturnBelowFloor` — `_validateSwapLeg` always re-derives and enforces its
    /// own 1% floor regardless of what the caller's own tolerance would have allowed, so a
    /// looser caller tolerance can never loosen the platform floor. The router is intentionally
    /// never funded here: the revert happens inside `_validateSwapLeg`, strictly before
    /// `dispatchSwap`/the router is ever reached.
    function test_RedeemForStable_LooserSlippageThanPlatformFloor_Reverts() public {
        _deployPassive();

        vm.prank(user1);
        passive.deposit{value: 5 ether}(address(0), 0);

        uint256 shares = passive.balanceOf(user1);

        // This forge-std's `vm.expectRevert(bytes4)` requires an EXACT match of the full revert
        // data (lib/forge-std/src/Vm.sol: "Expects an error on next call that exactly matches the
        // revert data"), and `MinReturnBelowFloor(uint256,uint256)` reverts with 68 bytes (4-byte
        // selector + two uint256 args), not 4. `vm.expectPartialRevert` is the selector-prefix
        // variant ("starts with the revert data") and is what this test actually wants: it only
        // cares that the right ERROR fired, not the exact USD figures involved.
        vm.prank(user1);
        vm.expectPartialRevert(BucketVaultBase.MinReturnBelowFloor.selector);
        passive.redeemForStable(shares, address(stable), 500);
    }

    /*//////////////////////////////////////////////////////////////
                    4. ATOMICITY — NO PARTIAL FILLS
    //////////////////////////////////////////////////////////////*/

    /// @notice When one leg's swap fails (here: the router cannot pay out `stable` because it
    /// was deliberately left unfunded), the ENTIRE call reverts — shares stay unburned and every
    /// basket balance is untouched. There is no try/catch anywhere in `redeemForStable`, so this
    /// is not merely the expected outcome but a structural guarantee the function's own doc
    /// comment claims; this test is the proof.
    function test_RedeemForStable_RevertsNotPartialFill_WhenLegSwapFails() public {
        _deployPassive();
        // Deliberately NOT funding `router` with `stable` — the first non-skip leg's payout
        // will fail.

        tokenA.mint(user1, 100e18);
        vm.startPrank(user1);
        passive.deposit{value: 5 ether}(address(0), 0);
        tokenA.approve(address(passive), 20e18);
        passive.deposit(address(tokenA), 20e18);
        vm.stopPrank();

        uint256 sharesBefore = passive.balanceOf(user1);
        uint256 ethBefore = address(passive).balance;
        uint256 tokenABefore = tokenA.balanceOf(address(passive));

        vm.prank(user1);
        vm.expectRevert();
        passive.redeemForStable(sharesBefore, address(stable), 100);

        assertEq(passive.balanceOf(user1), sharesBefore, "shares must not be burned on a failed leg");
        assertEq(address(passive).balance, ethBefore, "ETH balance must be unchanged after revert");
        assertEq(tokenA.balanceOf(address(passive)), tokenABefore, "tokenA balance must be unchanged after revert");
    }

    /*//////////////////////////////////////////////////////////////
                    5. OWNER-ACCOUNTABILITY PARITY / DEVIATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Mirrors PassiveBucket.t.sol's `test_OwnerRedeemAccountabilityCheck` pattern
    /// exactly, but through `redeemForStable` with `dstToken == address(0)` (ETH) — every leg is
    /// then the "already dstToken" skip path, so this isolates the accountability guard itself
    /// with no router interaction at all.
    function test_RedeemForStable_OwnerAccountabilityParity_PassiveBucket() public {
        _deployPassive();

        passive.deposit{value: 10 ether}(address(0), 0);
        vm.prank(user1);
        passive.deposit{value: 100 ether}(address(0), 0);

        uint256 minOwnerBps = passive.MIN_OWNER_BPS();
        uint256 bpsDenom = passive.BPS_DENOMINATOR();

        uint256 ownerShares = passive.balanceOf(owner);

        uint256 smallRedeem = ownerShares / 4;
        passive.redeemForStable(smallRedeem, address(0), 100);
        assertTrue(passive.isBucketAccountable(), "owner should still be accountable after small redeem");

        // `redeemForStable` charges `_enforceSwapCooldown(msg.sender)` once per call
        // (BucketVaultBase.sol:1779) and `owner` is about to call it a second time — without
        // clearing CALLER_SWAP_COOLDOWN (5 minutes, BucketVaultBase.sol:251) first, the second
        // call reverts `SwapCooldownActive` before ever reaching the accountability check this
        // test means to isolate.
        vm.warp(block.timestamp + 5 minutes + 1);

        uint256 remainingOwner = passive.balanceOf(owner);
        uint256 newSupply = passive.totalSupply();
        uint256 threshold = ((remainingOwner * bpsDenom) - (newSupply * minOwnerBps)) / (bpsDenom - minOwnerBps);
        uint256 tooMuch = threshold + 1e18;

        if (tooMuch <= remainingOwner) {
            vm.expectRevert(BucketVaultBase.OwnerNotAccountable.selector);
            passive.redeemForStable(tooMuch, address(0), 100);
        }
    }

    /// @notice ⚠ Proves the DELIBERATE deviation flagged in `redeemForStable`'s own doc comment:
    /// `ActiveBucket.redeem()` has NO owner-accountability guard at all today (confirmed via
    /// source review — no such check exists in `ActiveBucket.redeem()`), but `redeemForStable`
    /// applies PassiveBucket's stricter before-AND-after `isBucketAccountable()` guard
    /// unconditionally to BOTH vault types, since the function lives only in `base/` and is
    /// shared verbatim. Net effect verified here: an ActiveBucket owner is held to a
    /// restriction `redeem()` itself does not impose on them for this vault type.
    function test_RedeemForStable_OwnerAccountabilityNowApplies_ActiveBucket() public {
        _deployActive();

        active.deposit{value: 10 ether}(address(0), 0);
        vm.prank(user1);
        active.deposit{value: 100 ether}(address(0), 0);

        uint256 minOwnerBps = active.MIN_OWNER_BPS();
        uint256 bpsDenom = active.BPS_DENOMINATOR();

        uint256 ownerShares = active.balanceOf(owner);

        uint256 smallRedeem = ownerShares / 4;
        active.redeemForStable(smallRedeem, address(0), 100);
        assertTrue(active.isBucketAccountable(), "owner should still be accountable after small redeem");

        // See the identical comment in the PassiveBucket counterpart above: a second
        // `redeemForStable` call from the same `msg.sender` without warping past
        // CALLER_SWAP_COOLDOWN (5 minutes) reverts `SwapCooldownActive`, not `OwnerNotAccountable`.
        vm.warp(block.timestamp + 5 minutes + 1);

        uint256 remainingOwner = active.balanceOf(owner);
        uint256 newSupply = active.totalSupply();
        uint256 threshold = ((remainingOwner * bpsDenom) - (newSupply * minOwnerBps)) / (bpsDenom - minOwnerBps);
        uint256 tooMuch = threshold + 1e18;

        if (tooMuch <= remainingOwner) {
            vm.expectRevert(BucketVaultBase.OwnerNotAccountable.selector);
            active.redeemForStable(tooMuch, address(0), 100);
        }
    }
}
