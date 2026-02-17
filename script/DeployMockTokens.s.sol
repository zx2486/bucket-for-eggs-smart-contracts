// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20Upgradeable} from "../src/MockERC20Upgradeable.sol";
import {MockERC20Factory} from "../src/MockERC20Factory.sol";

/**
 * @title DeployMockTokens
 * @notice Deploy mock ERC20 tokens using minimal proxy pattern for gas efficiency
 * @dev Deploys one implementation and three proxies (USDC, DAI, WBTC)
 */
contract DeployMockTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Mock Token Deployment (EIP-1167 Minimal Proxy) ===");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy the implementation contract
        console.log("Step 1: Deploying implementation contract...");
        MockERC20Upgradeable implementation = new MockERC20Upgradeable();
        console.log("Implementation deployed at:", address(implementation));
        console.log("(Note: Implementation is not initialized - this is correct for upgradeable contracts)");
        console.log("");

        // Step 2: Deploy factory
        console.log("Step 2: Deploying factory contract...");
        MockERC20Factory factory = new MockERC20Factory(address(implementation));
        console.log("Factory deployed at:", address(factory));
        console.log("Factory implementation:", factory.implementation());
        console.log("");

        // Step 3: Create USDC proxy (8 decimals, 1M supply)
        console.log("Step 3: Creating USDC proxy...");
        address usdcProxy = factory.createToken(
            "USD Coin",
            "USDC",
            8,
            1_000_000,
            deployer
        );
        MockERC20Upgradeable usdc = MockERC20Upgradeable(usdcProxy);
        console.log("USDC (Proxy):", usdcProxy);
        console.log("  Name:", usdc.name());
        console.log("  Symbol:", usdc.symbol());
        console.log("  Decimals:", usdc.decimals());
        console.log("  Total Supply:", usdc.totalSupply());
        console.log("  Deployer Balance:", usdc.balanceOf(deployer));
        console.log("");

        // Step 4: Create DAI proxy (16 decimals, 1M supply)
        console.log("Step 4: Creating DAI proxy...");
        address daiProxy = factory.createToken(
            "Dai Stablecoin",
            "DAI",
            16,
            1_000_000,
            deployer
        );
        MockERC20Upgradeable dai = MockERC20Upgradeable(daiProxy);
        console.log("DAI (Proxy):", daiProxy);
        console.log("  Name:", dai.name());
        console.log("  Symbol:", dai.symbol());
        console.log("  Decimals:", dai.decimals());
        console.log("  Total Supply:", dai.totalSupply());
        console.log("  Deployer Balance:", dai.balanceOf(deployer));
        console.log("");

        // Step 5: Create WBTC proxy (18 decimals, 1M supply)
        console.log("Step 5: Creating WBTC proxy...");
        address wbtcProxy = factory.createToken(
            "Wrapped Bitcoin",
            "WBTC",
            18,
            1_000_000,
            deployer
        );
        MockERC20Upgradeable wbtc = MockERC20Upgradeable(wbtcProxy);
        console.log("WBTC (Proxy):", wbtcProxy);
        console.log("  Name:", wbtc.name());
        console.log("  Symbol:", wbtc.symbol());
        console.log("  Decimals:", wbtc.decimals());
        console.log("  Total Supply:", wbtc.totalSupply());
        console.log("  Deployer Balance:", wbtc.balanceOf(deployer));
        console.log("");

        vm.stopBroadcast();

        // Display summary
        console.log("=== Deployment Summary ===");
        console.log("Implementation:", address(implementation));
        console.log("Factory:", address(factory));
        console.log("USDC Proxy:", usdcProxy);
        console.log("DAI Proxy:", daiProxy);
        console.log("WBTC Proxy:", wbtcProxy);
        console.log("");
        console.log("=== Update configs/sepolia.json with these addresses ===");
        console.log('{');
        console.log('  "platformFee": 100,');
        console.log('  "tokens": [');
        console.log('    {');
        console.log('      "symbol": "ETH",');
        console.log('      "tokenAddress": "0x0000000000000000000000000000000000000000",');
        console.log('      "priceFeed": "0x694AA1769357215DE4FAC081bf1f309aDC325306"');
        console.log('    },');
        console.log('    {');
        console.log('      "symbol": "USDC",');
        console.log('      "tokenAddress": "', vm.toString(usdcProxy), '",');
        console.log('      "priceFeed": "0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E"');
        console.log('    },');
        console.log('    {');
        console.log('      "symbol": "DAI",');
        console.log('      "tokenAddress": "', vm.toString(daiProxy), '",');
        console.log('      "priceFeed": "0x14866185B1962B63C3Ea9E03Bc1da838bab34C19"');
        console.log('    },');
        console.log('    {');
        console.log('      "symbol": "WBTC",');
        console.log('      "tokenAddress": "', vm.toString(wbtcProxy), '",');
        console.log('      "priceFeed": "0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43"');
        console.log('    },');
        console.log('    {');
        console.log('      "symbol": "LINK",');
        console.log('      "tokenAddress": "0x6641415a61bCe80D97a715054d1334360Ab833Eb",');
        console.log('      "priceFeed": "0xc59E3633BAAC79493d908e63626716e204A45EdF"');
        console.log('    }');
        console.log('  ]');
        console.log('}');
    }
}
