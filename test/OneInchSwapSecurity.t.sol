// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "../src/PassiveBucket.sol";
import {BucketVaultBase} from "../src/base/BucketVaultBase.sol";
import {ImplementationRegistry} from "../src/ImplementationRegistry.sol";

contract SecurityMockBucketInfo {
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public prices;
    address[] public whitelistedList;
    bool public operational = true;
    uint256 public feeRate = 0;
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

    function tryGetTokenPrice(address token) external view returns (bool ok, uint256 price) {
        if (!whitelisted[token]) return (false, 0);
        return (true, prices[token]);
    }

    function isPotentiallyOutpriced(address) external pure returns (bool) {
        return false;
    }

    function getPriceFeed(address) external pure returns (address) {
        return address(0);
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

    mapping(address => bool) public blacklisted;

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    receive() external payable {}
}

contract SecurityMockERC20 {
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

contract MaliciousOneInchRouter {
    function steal(address token, uint256 amount, address to) external {
        IERC20(token).transferFrom(msg.sender, to, amount);
    }
}

contract PostFixRebalanceBy1inchAttackBlockedTest is Test {
    PassiveBucket public implementation;
    PassiveBucket public bucket;
    SecurityMockBucketInfo public bucketInfo;
    SecurityMockERC20 public tokenB;
    MaliciousOneInchRouter public maliciousRouter;

    address public depositor;
    address public attacker;

    uint256 constant TOKEN_B_PRICE = 1e8;
    uint256 constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 constant ATTACKER_DEPOSIT = 1_000e6;

    function setUp() public {
        depositor = address(this);
        attacker = makeAddr("attacker");

        bucketInfo = new SecurityMockBucketInfo();
        tokenB = new SecurityMockERC20("Token B", "TKB", 6);
        maliciousRouter = new MaliciousOneInchRouter();

        bucketInfo.addToken(address(tokenB), TOKEN_B_PRICE);

        ImplementationRegistry registry = new ImplementationRegistry(address(this));
        implementation = new PassiveBucket(address(registry));
        registry.setAuthorizedFactory(address(this), true);

        PassiveBucket.BucketDistribution[] memory dists = new PassiveBucket.BucketDistribution[](1);
        dists[0] = PassiveBucket.BucketDistribution(address(tokenB), 100);

        bytes memory initData = abi.encodeWithSelector(
            PassiveBucket.initialize.selector,
            address(bucketInfo),
            dists,
            address(maliciousRouter),
            "PassiveBucket Share",
            "pBKT"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        bucket = PassiveBucket(payable(address(proxy)));

        tokenB.mint(depositor, INITIAL_DEPOSIT);
        tokenB.mint(attacker, ATTACKER_DEPOSIT);

        tokenB.approve(address(bucket), INITIAL_DEPOSIT);
        bucket.deposit(address(tokenB), INITIAL_DEPOSIT);

        vm.startPrank(attacker);
        tokenB.approve(address(bucket), ATTACKER_DEPOSIT);
        bucket.deposit(address(tokenB), ATTACKER_DEPOSIT);
        vm.stopPrank();

        vm.prank(address(bucket));
        tokenB.approve(address(maliciousRouter), type(uint256).max);
    }

    function test_PostFix_RebalanceBy1inch_RejectsUnwhitelistedDestination() public {
        uint256 initialVaultBalance = tokenB.balanceOf(address(bucket));
        address fakeDst = makeAddr("fakeDstToken");

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(BucketVaultBase.InvalidToken.selector, fakeDst));
            bucket.rebalanceBy1inch(address(tokenB), fakeDst, 1_000e6, 0);
        }

        assertEq(tokenB.balanceOf(address(bucket)), initialVaultBalance);
        assertEq(tokenB.balanceOf(attacker), 0);
    }

    function test_PostFix_RebalanceBy1inch_RejectsSameTokenSwap() public {
        vm.prank(attacker);
        vm.expectRevert(BucketVaultBase.SameToken.selector);
        bucket.rebalanceBy1inch(address(tokenB), address(tokenB), 1_000e6, 0);
    }
}

contract AllowanceGatedRouter {
    function pull(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract SepoliaLatentAllowanceTest is Test {
    SecurityMockERC20 public token;
    AllowanceGatedRouter public router;
    address public vaultStandIn;

    function setUp() public {
        token = new SecurityMockERC20("Token", "TKN", 18);
        router = new AllowanceGatedRouter();
        vaultStandIn = address(this);
        token.mint(vaultStandIn, 1_000e18);
    }

    function test_RouterCallRevertsWithNoAllowance_MissingPrecondition() public {
        vm.expectRevert();
        router.pull(address(token), 100e18);
    }

    function test_RouterCallSucceedsOnceAllowanceExists_ArmedByTheAllowance() public {
        // Rule 12 permits this local-only mock-router allowance in tests; no network is used.
        token.approve(address(router), 100e18);

        router.pull(address(token), 100e18);

        assertEq(token.balanceOf(address(router)), 100e18);
    }
}
