# Sepolia Testnet DEX Addresses

## Overview

This document lists the available DEX protocols and their contract addresses on Sepolia testnet for testing DefiSwap and BasicSwap contracts.

## Available Protocols

### ✅ Uniswap V3 (AVAILABLE)

**Status:** Fully deployed and functional on Sepolia

**Addresses:**
- **SwapRouter:** `0xE592427A0AEce92De3Edee1F18E0157C05861564`
- **SwapRouter02:** `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` (Recommended)
- **Quoter V2:** `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3`
- **Factory:** `0x0227628f3F023bb0B980b67D528571c95c6DaC1c`
- **NFT Position Manager:** `0x1238536071E1c677A632429e3655c799b22cDA52`

**Pool Fees:**
- 0.01% (100)
- 0.05% (500)
- 0.3% (3000) - Most common
- 1% (10000)

**Key Pairs Available:**
- USDC/ETH
- USDT/ETH
- DAI/ETH
- WBTC/ETH
- LINK/ETH

### ✅ 1inch Router (AVAILABLE)

**Status:** Deployed on Sepolia for testing

**Addresses:**
- **AggregationRouterV6:** `0x111111125421cA6dc452d289314280a0f8842A65`
- **AggregationRouterV5:** `0x1111111254EEB25477B68fb85Ed929f73A960582`

**Note:** 1inch on Sepolia may have limited liquidity compared to mainnet. Use V6 for best results.

### ❌ Curve (NOT AVAILABLE)

**Status:** Not deployed on Sepolia testnet

**Alternative:**
- Use Uniswap V3 for all swaps
- Or deploy a mock Curve pool for testing purposes
- Mainnet only: Use Curve.fi

### ❌ Uniswap V4 (NOT YET AVAILABLE)

**Status:** Not yet deployed on Sepolia (as of Feb 2026)

**Alternative:**
- Use Uniswap V3
- Monitor Uniswap V4 deployments

### ❓ Fluid DEX (NEEDS VERIFICATION)

**Status:** May not be deployed on Sepolia

**Alternative:**
- Contact Fluid team for testnet deployments
- Use Uniswap V3 as primary DEX for testing

## Token Addresses on Sepolia

### Stablecoins

**USDT (Tether):**
- Address: `0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0`
- Decimals: 6
- Faucet: Use Sepolia faucets or deploy your own mock

**USDC (USD Coin):**
- Address: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`
- Decimals: 6

**DAI:**
- Address: `0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357`
- Decimals: 18

### WETH (Wrapped ETH)

- Address: `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`
- Decimals: 18
- Official Sepolia WETH9 contract

### Other Tokens

**WBTC:**
- Address: `0x29f2D40B0605204364af54EC677bD022dA425d03`
- Decimals: 8

**LINK (Chainlink):**
- Address: `0x779877A7B0D9E8603169DdbD7836e478b4624789`
- Decimals: 18

## Testing Recommendations

### For DefiSwap Contract

**Recommended Configuration:**

```solidity
// Configure Uniswap V3 (Primary DEX on Sepolia)
defiSwap.configureDEX(
    DefiSwap.DEX.UNISWAP_V3,
    0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E, // SwapRouter02
    0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3, // QuoterV2
    3000, // 0.3% fee tier
    true  // enabled
);

// Disable Curve (not available)
// Disable Uniswap V4 (not deployed)
// Disable Fluid (not confirmed)
```

**Testing Strategy:**
1. Deploy your mock USDT tokens (from [`DeployMockTokens.s.sol`](script/DeployMockTokens.s.sol))
2. Configure only Uniswap V3
3. Test basic swap functionality
4. Verify ETH unwrapping works correctly

### For BasicSwap Contract

**Recommended Configuration:**

```solidity
// Use 1inch Router V6
basicSwap = new BasicSwap(
    usdtAddress,
    0x111111125421cA6dc452d289314280a0f8842A65 // 1inch V6 Router
);
```

**Testing Strategy:**
1. Use 1inch Router V6 for swap aggregation
2. Test with small amounts first (limited Sepolia liquidity)
3. Expect higher slippage than mainnet

## Complete Testing Setup

### Step 1: Deploy Mock Tokens

```bash
# Deploy USDC, DAI, WBTC mock tokens
./script/deploy-mock-tokens-sepolia.sh
```

### Step 2: Get Sepolia ETH

Use these faucets:
- https://sepoliafaucet.com/
- https://www.alchemy.com/faucets/ethereum-sepolia
- https://faucet.quicknode.com/ethereum/sepolia

### Step 3: Wrap ETH to WETH

```bash
# Wrap 0.1 ETH to WETH
cast send 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 "deposit()" \
    --value 0.1ether \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY
```

### Step 4: Add Liquidity to Uniswap V3 (Optional)

If you need specific pools:
```bash
# Create a USDT/ETH pool if needed
# Use Uniswap V3 Position Manager
# Or use existing pools
```

### Step 5: Deploy and Configure DefiSwap

```bash
# Deploy with Uniswap V3 only
./script/deploy-defiswap-sepolia.sh
```

### Step 6: Test Swaps

```bash
# Deposit USDT
cast send <DEFISWAP_ADDRESS> "depositUSDT(uint256)" 1000000000 \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY

# Execute swap (owner only)
cast send <DEFISWAP_ADDRESS> "swap()" \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY
```

## Known Limitations on Sepolia

1. **Limited Liquidity:** Much less liquidity than mainnet
2. **Higher Slippage:** Expect 5-10% slippage on some pairs
3. **Fewer DEXs:** Only Uniswap V3 and 1inch are reliable
4. **Price Discovery:** Prices may not match mainnet
5. **No Curve:** Cannot test Curve integration

## Alternatives for Full Testing

If you need to test all DEX integrations:

### Option 1: Use Mainnet Fork

```bash
# Fork mainnet for local testing
anvil --fork-url $MAINNET_RPC_URL --fork-block-number 19000000
```

Then test against real mainnet contracts locally.

### Option 2: Deploy Mock DEX Contracts

Create simplified mock versions of missing DEXs for testing:
- MockCurvePool
- MockFluidRouter
- MockUniswapV4

### Option 3: Use Tenderly

- Fork Sepolia or Mainnet on Tenderly
- Simulate transactions
- Test with unlimited gas

## Useful Resources

- **Uniswap V3 Docs:** https://docs.uniswap.org/contracts/v3/overview
- **1inch Docs:** https://docs.1inch.io/
- **Sepolia Etherscan:** https://sepolia.etherscan.io/
- **Chainlist Sepolia:** https://chainlist.org/chain/11155111

## Quick Reference Commands

```bash
# Check WETH balance
cast call 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 "balanceOf(address)(uint256)" <YOUR_ADDRESS> --rpc-url $SEPOLIA_RPC_URL

# Check USDT balance
cast call 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 "balanceOf(address)(uint256)" <YOUR_ADDRESS> --rpc-url $SEPOLIA_RPC_URL

# Approve DefiSwap to spend USDT
cast send 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 "approve(address,uint256)" <DEFISWAP_ADDRESS> 1000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

# Get Uniswap V3 quote
cast call 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3 "quoteExactInputSingle((address,address,uint256,uint24,uint160))" "(0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0,0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,1000000,3000,0)" --rpc-url $SEPOLIA_RPC_URL
```
