// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockERC20Upgradeable} from "../src/MockERC20Upgradeable.sol";
import {MockERC20Factory} from "../src/MockERC20Factory.sol";

contract MockERC20UpgradeableTest is Test {
    MockERC20Upgradeable public implementation;
    MockERC20Factory public factory;
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    event ProxyCreated(
        address indexed proxy,
        string name,
        string symbol,
        uint8 decimals,
        uint256 initialSupply,
        address indexed recipient
    );

    function setUp() public {
        // Deploy implementation
        implementation = new MockERC20Upgradeable();
        
        // Deploy factory
        factory = new MockERC20Factory(address(implementation));
    }

    /*//////////////////////////////////////////////////////////////
                        IMPLEMENTATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Implementation_CannotBeInitialized() public {
        // Implementation contract should not be initializable due to _disableInitializers()
        MockERC20Upgradeable token = new MockERC20Upgradeable();
        
        // Try to initialize - should revert
        vm.expectRevert();
        token.initialize("USD Coin", "USDC", 6, 1_000_000, alice);
    }

    function test_Proxy_Initialization() public {
        // Create proxy through factory
        address proxyAddress = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        MockERC20Upgradeable token = MockERC20Upgradeable(proxyAddress);
        
        assertEq(token.name(), "USD Coin");
        assertEq(token.symbol(), "USDC");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 1_000_000 * 10 ** 6);
        assertEq(token.balanceOf(alice), 1_000_000 * 10 ** 6);
    }

    function test_Proxy_CannotReinitialize() public {
        address proxyAddress = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        MockERC20Upgradeable token = MockERC20Upgradeable(proxyAddress);
        
        // Try to reinitialize - should revert
        vm.expectRevert();
        token.initialize("DAI", "DAI", 18, 1_000_000, bob);
    }

    function test_Proxy_MintFunction() public {
        address proxyAddress = factory.createToken("Test Token", "TEST", 18, 0, alice);
        MockERC20Upgradeable token = MockERC20Upgradeable(proxyAddress);
        
        // Mint tokens
        token.mint(alice, 1000);
        
        assertEq(token.balanceOf(alice), 1000 * 10 ** 18);
    }

    function test_Proxy_DifferentDecimals() public {
        // Test with 6 decimals (USDC)
        address usdcProxy = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        MockERC20Upgradeable usdc = MockERC20Upgradeable(usdcProxy);
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.totalSupply(), 1_000_000 * 10 ** 6);

        // Test with 8 decimals (WBTC)
        address wbtcProxy = factory.createToken("Wrapped Bitcoin", "WBTC", 8, 1_000_000, alice);
        MockERC20Upgradeable wbtc = MockERC20Upgradeable(wbtcProxy);
        assertEq(wbtc.decimals(), 8);
        assertEq(wbtc.totalSupply(), 1_000_000 * 10 ** 8);

        // Test with 18 decimals (DAI)
        address daiProxy = factory.createToken("Dai Stablecoin", "DAI", 18, 1_000_000, alice);
        MockERC20Upgradeable dai = MockERC20Upgradeable(daiProxy);
        assertEq(dai.decimals(), 18);
        assertEq(dai.totalSupply(), 1_000_000 * 10 ** 18);
    }

    /*//////////////////////////////////////////////////////////////
                         FACTORY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Factory_Deployment() public view {
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.getDeployedProxiesCount(), 0);
    }

    function test_Factory_CreateToken() public {
        // Create USDC proxy
        vm.expectEmit(false, false, false, true);
        emit ProxyCreated(address(0), "USD Coin", "USDC", 6, 1_000_000, alice);
        
        address proxyAddress = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        
        MockERC20Upgradeable usdc = MockERC20Upgradeable(proxyAddress);
        
        assertEq(usdc.name(), "USD Coin");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.totalSupply(), 1_000_000 * 10 ** 6);
        assertEq(usdc.balanceOf(alice), 1_000_000 * 10 ** 6);
        assertEq(factory.getDeployedProxiesCount(), 1);
    }

    function test_Factory_CreateMultipleTokens() public {
        // Create USDC
        address usdcProxy = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        
        // Create DAI
        address daiProxy = factory.createToken("Dai Stablecoin", "DAI", 18, 1_000_000, bob);
        
        // Create WBTC
        address wbtcProxy = factory.createToken("Wrapped Bitcoin", "WBTC", 8, 1_000_000, alice);
        
        assertEq(factory.getDeployedProxiesCount(), 3);
        
        MockERC20Upgradeable usdc = MockERC20Upgradeable(usdcProxy);
        MockERC20Upgradeable dai = MockERC20Upgradeable(daiProxy);
        MockERC20Upgradeable wbtc = MockERC20Upgradeable(wbtcProxy);
        
        // Verify USDC
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.balanceOf(alice), 1_000_000 * 10 ** 6);
        
        // Verify DAI
        assertEq(dai.symbol(), "DAI");
        assertEq(dai.decimals(), 18);
        assertEq(dai.balanceOf(bob), 1_000_000 * 10 ** 18);
        
        // Verify WBTC
        assertEq(wbtc.symbol(), "WBTC");
        assertEq(wbtc.decimals(), 8);
        assertEq(wbtc.balanceOf(alice), 1_000_000 * 10 ** 8);
    }

    function test_Factory_DeterministicDeployment() public {
        bytes32 salt = keccak256("USDC");
        
        // Predict address
        address predicted = factory.predictDeterministicAddress(salt);
        
        // Create token with salt
        address deployed = factory.createTokenDeterministic(
            "USD Coin",
            "USDC",
            6,
            1_000_000,
            alice,
            salt
        );
        
        // Verify addresses match
        assertEq(predicted, deployed);
        
        MockERC20Upgradeable usdc = MockERC20Upgradeable(deployed);
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.balanceOf(alice), 1_000_000 * 10 ** 6);
    }

    function test_Factory_GetAllDeployedProxies() public {
        address usdc = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        address dai = factory.createToken("Dai Stablecoin", "DAI", 18, 1_000_000, bob);
        
        address[] memory proxies = factory.getAllDeployedProxies();
        
        assertEq(proxies.length, 2);
        assertEq(proxies[0], usdc);
        assertEq(proxies[1], dai);
    }

    function test_Factory_ProxiesAreIndependent() public {
        // Create two tokens
        address usdcProxy = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        address daiProxy = factory.createToken("Dai Stablecoin", "DAI", 18, 2_000_000, bob);
        
        MockERC20Upgradeable usdc = MockERC20Upgradeable(usdcProxy);
        MockERC20Upgradeable dai = MockERC20Upgradeable(daiProxy);
        
        // Transfer USDC
        vm.prank(alice);
        usdc.transfer(bob, 100 * 10 ** 6);
        
        // Verify USDC balances changed
        assertEq(usdc.balanceOf(alice), 999_900 * 10 ** 6);
        assertEq(usdc.balanceOf(bob), 100 * 10 ** 6);
        
        // Verify DAI balances unchanged
        assertEq(dai.balanceOf(alice), 0);
        assertEq(dai.balanceOf(bob), 2_000_000 * 10 ** 18);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CreateToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint96 initialSupply // Use uint96 to avoid overflow
    ) public {
        vm.assume(decimals <= 18); // Reasonable decimals range
        vm.assume(bytes(name).length > 0 && bytes(name).length < 32);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length < 16);
        
        address proxy = factory.createToken(
            name,
            symbol,
            decimals,
            initialSupply,
            alice
        );
        
        MockERC20Upgradeable token = MockERC20Upgradeable(proxy);
        
        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);
        assertEq(token.balanceOf(alice), uint256(initialSupply) * 10 ** decimals);
    }

    /*//////////////////////////////////////////////////////////////
                          GAS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Gas_ImplementationDeployment() public {
        uint256 gasBefore = gasleft();
        new MockERC20Upgradeable();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for implementation deployment:", gasUsed);
    }

    function test_Gas_ProxyDeployment() public {
        uint256 gasBefore = gasleft();
        address proxy = factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for proxy deployment:", gasUsed);
        assertTrue(proxy != address(0));
    }

    function test_Gas_MultipleProxyDeployments() public {
        uint256 totalGas = 0;
        
        // First proxy
        uint256 gas1 = gasleft();
        factory.createToken("USD Coin", "USDC", 6, 1_000_000, alice);
        totalGas += gas1 - gasleft();
        
        // Second proxy
        uint256 gas2 = gasleft();
        factory.createToken("Dai Stablecoin", "DAI", 18, 1_000_000, bob);
        totalGas += gas2 - gasleft();
        
        console.log("Total gas for 2 proxies:", totalGas);
        console.log("Average gas per proxy:", totalGas / 2);
    }
}
