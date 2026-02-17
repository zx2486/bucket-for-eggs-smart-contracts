# Sepolia Testing Guide

Complete guide for deploying and testing DefiSwap and BasicSwap contracts on Sepolia testnet.

## Prerequisites

1. **Sepolia ETH** - Get testnet ETH from:
   - https://sepoliafaucet.com/
   - https://www.alchemy.com/faucets/ethereum-sepolia
   - Minimum 0.1 ETH recommended for deployment + testing

2. **Sepolia USDT** - Get testnet USDT from:
   - Uniswap V3 on Sepolia (swap ETH → USDT)
   - USDT Address: `0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0`

3. **Environment Setup** - Add to `.env`:
   ```bash
   PRIVATE_KEY=your_private_key_here
   SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
   SEPOLIA_ETHERSCAN_API_KEY=your_etherscan_api_key
   ```

4. **Tools Required**:
   - Foundry (forge, cast)
   - jq (for JSON parsing)
   - bc (for calculations)

## Available Protocols on Sepolia

✅ **Uniswap V3**
- SwapRouter02: `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`
- QuoterV2: `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3`
- Fee Tier: 3000 (0.3%)

✅ **1inch Router V6**
- Router: `0x111111125421cA6dc452d289314280a0f8842A65`
- Requires API integration for swap data

❌ **NOT Available on Sepolia**:
- Curve Finance
- Uniswap V4
- Fluid DEX

## Testing Workflow

### 1. DefiSwap (Uniswap V3 Integration)

#### Step 1: Deploy Contract
```bash
./script/deploy-defiswap-full.sh
```

**What this does**:
- Deploys DefiSwap contract with USDT and WETH addresses
- Configures Uniswap V3 router and quoter
- Sets fee tier to 0.3%
- Verifies contract on Etherscan
- Outputs deployed contract address

**Expected Output**:
```
=== DefiSwap Sepolia Deployment ===
Deployer: 0x...
Network: Sepolia
...
Contract Address: 0x...
Add to your .env file:
DEFISWAP_ADDRESS=0x...
```

**Action Required**: Add `DEFISWAP_ADDRESS` to your `.env` file

---

#### Step 2: Verify Contract Configuration
```bash
./script/verify-defiswap-sepolia.sh
```

**What this does**:
- Verifies contract source code on Etherscan (if not already verified)
- Calls view functions to display:
  - Owner address
  - USDT and WETH token addresses
  - Contract balances (USDT, ETH)
  - DEX configurations (Uniswap V3, V4, Fluid, Curve status)
  - Enabled/disabled DEX status

**Expected Output**:
```
=== DefiSwap Contract Verification ===
Contract Address: 0x...
Owner: 0x...
USDT Token: 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0
WETH Token: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14

Uniswap V3:
  Status: ENABLED
  Router: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
  Fee Tier: 3000 basis points
```

---

#### Step 3: Test Contract Functions
```bash
./script/test-defiswap-sepolia.sh
```

**What this does**:
1. **Check Balances**: Display user and contract USDT/ETH balances
2. **Approve USDT**: Approve DefiSwap to spend 10 USDT
3. **Deposit USDT**: Deposit 1 USDT to contract
4. **Execute Swap**: Swap 50% of contract USDT → ETH via Uniswap V3 (owner only)
5. **Withdraw USDT**: Withdraw 0.5 USDT from contract (owner only)
6. **Withdraw ETH**: Withdraw 50% of contract ETH (owner only)
7. **Final Balances**: Display final balances

**Interactive Prompts**:
- Confirms you are the contract owner before executing owner-only functions
- Shows transaction hashes for each operation
- Waits for transaction confirmations

**Expected Output**:
```
=== DefiSwap Testing Script ===
Test Configuration:
DefiSwap: 0x...
User: 0x...
Test Amount: 1000000 (1 USDT)

Step 1: Checking initial balances
User USDT Balance: 10.000000 USDT
Contract USDT Balance: 0.000000 USDT

Step 2: Approving USDT for DefiSwap
Approval TX: 0x...
✓ Approval confirmed

Step 3: Depositing USDT
Deposit TX: 0x...
✓ Deposit confirmed

Step 5: Executing swap
Swap TX: 0x...
✓ Swap confirmed
Contract ETH Balance: 0.000123 ETH (received from swap)

=== Testing Complete! ===
```

---

### 2. BasicSwap (1inch Integration)

#### Step 1: Deploy Contract
```bash
./script/deploy-basicswap-full.sh
```

**What this does**:
- Deploys BasicSwap contract with USDT and 1inch Router V6
- Verifies contract on Etherscan
- Outputs deployed contract address

**Expected Output**:
```
=== BasicSwap Sepolia Deployment ===
Contract Address: 0x...
Add to your .env file:
BASICSWAP_ADDRESS=0x...
```

**Action Required**: Add `BASICSWAP_ADDRESS` to your `.env` file

---

#### Step 2: Verify Contract Configuration
```bash
./script/verify-basicswap-sepolia.sh
```

**What this does**:
- Verifies contract source code on Etherscan
- Displays:
  - Owner address
  - USDT token address
  - 1inch Router address
  - Contract balances

**Expected Output**:
```
=== BasicSwap Contract Verification ===
Contract Address: 0x...
Owner: 0x...
USDT: 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0
1inch Router: 0x111111125421cA6dc452d289314280a0f8842A65
```

---

#### Step 3: Test Contract Functions
```bash
./script/test-basicswap-sepolia.sh
```

**What this does**:
1. **Check Balances**: Display user and contract balances
2. **Approve USDT**: Approve BasicSwap to spend 10 USDT
3. **Deposit USDT**: Deposit 1 USDT to contract
4. **Swap (Manual)**: Provides instructions for getting swap data from 1inch API
5. **Withdraw USDT**: Withdraw 0.5 USDT from contract (owner only)

**1inch API Integration** (for swap):
```bash
# Get 1inch API key from https://portal.1inch.dev/
# Then make API call:
curl "https://api.1inch.dev/swap/v6.0/11155111/swap?src=0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0&dst=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14&amount=500000&from=0x<BASICSWAP_ADDRESS>&slippage=5" \
  -H "Authorization: Bearer <YOUR_API_KEY>"

# Execute swap with returned data:
cast send $BASICSWAP_ADDRESS "swap(bytes)" <SWAP_DATA_FROM_API> --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

---

## Common Issues & Solutions

### Issue 1: Insufficient USDT Balance
```
Error: You don't have any USDT
```

**Solution**: Get Sepolia USDT
1. Go to Uniswap V3 on Sepolia: https://app.uniswap.org/
2. Connect wallet to Sepolia network
3. Swap ETH → USDT
4. USDT Address: `0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0`

---

### Issue 2: Low ETH Balance
```
Warning: Low balance. You need at least 0.1 ETH for deployment.
```

**Solution**: Get more Sepolia ETH from faucets:
- https://sepoliafaucet.com/
- https://www.alchemy.com/faucets/ethereum-sepolia

---

### Issue 3: Swap Fails with "Insufficient Liquidity"
```
Error: Uniswap swap failed
```

**Possible Causes**:
- Low liquidity on Sepolia USDT/WETH pool
- Slippage tolerance too low
- Swap amount too large

**Solutions**:
1. Use smaller swap amounts (0.1 - 1 USDT)
2. Check Uniswap V3 pool liquidity on Sepolia
3. Consider using mainnet fork for testing:
   ```bash
   anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
   ```

---

### Issue 4: Contract Not Verified on Etherscan
```
Contract may already be verified
```

**Solution**: Verify manually:
```bash
forge verify-contract \
    --chain-id 11155111 \
    --compiler-version 0.8.33 \
    --etherscan-api-key $SEPOLIA_ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode "constructor(address,address)" 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14) \
    $DEFISWAP_ADDRESS \
    src/DefiSwap.sol:DefiSwap
```

---

## Manual Testing Commands

### Query Contract State
```bash
# Get contract USDT balance
cast call $DEFISWAP_ADDRESS "getContractUSDTBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Get contract ETH balance
cast call $DEFISWAP_ADDRESS "getContractETHBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Get user's deposited balance
cast call $DEFISWAP_ADDRESS "getUserBalance(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# Check DEX configuration
cast call $DEFISWAP_ADDRESS "getDEXConfig(uint8)((address,address,uint24,bool))" 0 --rpc-url $SEPOLIA_RPC_URL
```

### Execute Transactions
```bash
# Approve USDT
cast send $USDT_ADDRESS "approve(address,uint256)" $DEFISWAP_ADDRESS 10000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Deposit USDT
cast send $DEFISWAP_ADDRESS "depositUSDT(uint256)" 1000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Execute swap (owner only)
cast send $DEFISWAP_ADDRESS "swap()" --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Withdraw USDT (owner only)
cast send $DEFISWAP_ADDRESS "withdrawUSDT(address,uint256)" $USER_ADDRESS 500000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Withdraw ETH (owner only)
cast send $DEFISWAP_ADDRESS "withdrawETH(address,uint256)" $USER_ADDRESS 100000000000000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

---

## Gas Costs (Approximate)

| Operation | Gas Cost | ETH Cost (20 gwei) |
|-----------|----------|-------------------|
| Deploy DefiSwap | ~2,500,000 | 0.05 ETH |
| Deploy BasicSwap | ~1,800,000 | 0.036 ETH |
| Approve USDT | ~46,000 | 0.00092 ETH |
| Deposit USDT | ~80,000 | 0.0016 ETH |
| Swap (Uniswap V3) | ~150,000 - 250,000 | 0.003 - 0.005 ETH |
| Withdraw USDT | ~50,000 | 0.001 ETH |
| Withdraw ETH | ~30,000 | 0.0006 ETH |

**Total for full testing cycle**: ~0.1 ETH

---

## Script Files Summary

### Deployment Scripts
- `script/DeployDefiSwapSepolia.s.sol` - Solidity deployment script for DefiSwap
- `script/DeployBasicSwapSepolia.s.sol` - Solidity deployment script for BasicSwap
- `script/deploy-defiswap-full.sh` - Shell script with verification and balance checks
- `script/deploy-basicswap-full.sh` - Shell script with verification and balance checks

### Verification Scripts
- `script/VerifyDefiSwap.s.sol` - Displays DefiSwap configuration
- `script/VerifyBasicSwap.s.sol` - Displays BasicSwap configuration
- `script/verify-defiswap-sepolia.sh` - Etherscan verification + config display
- `script/verify-basicswap-sepolia.sh` - Etherscan verification + config display

### Testing Scripts
- `script/test-defiswap-sepolia.sh` - Complete deposit/swap/withdraw test flow
- `script/test-basicswap-sepolia.sh` - Complete deposit/swap/withdraw test flow

---

## Quick Start

1. **Setup environment**:
   ```bash
   # Add to .env
   PRIVATE_KEY=your_key
   SEPOLIA_RPC_URL=your_rpc_url
   SEPOLIA_ETHERSCAN_API_KEY=your_api_key
   ```

2. **Get testnet assets**:
   - Get Sepolia ETH (0.1+ ETH)
   - Swap ETH → USDT on Uniswap (10+ USDT)

3. **Deploy and test DefiSwap**:
   ```bash
   ./script/deploy-defiswap-full.sh
   # Add DEFISWAP_ADDRESS to .env
   ./script/verify-defiswap-sepolia.sh
   ./script/test-defiswap-sepolia.sh
   ```

4. **Deploy and test BasicSwap**:
   ```bash
   ./script/deploy-basicswap-full.sh
   # Add BASICSWAP_ADDRESS to .env
   ./script/verify-basicswap-sepolia.sh
   ./script/test-basicswap-sepolia.sh
   ```

---

## Alternative Testing Approaches

### Option 1: Mainnet Fork (Recommended for thorough testing)
```bash
# Start local fork
anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

# Deploy to fork (in another terminal)
forge script script/DeployDefiSwap.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Run tests on fork
forge test --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY -vvv
```

**Advantages**:
- Full mainnet liquidity
- All DEXs available (Uniswap V3, V4, Curve, Fluid)
- No need for testnet ETH/tokens
- Faster iteration

### Option 2: Tenderly Simulation
- Use Tenderly for transaction simulation
- Test without spending gas
- Full state inspection and debugging

### Option 3: Deploy Mock Tokens
```bash
# Deploy mock USDT with larger supply
./script/deploy-mock-tokens-sepolia.sh

# Use mock token addresses in DefiSwap deployment
# Edit configs/sepolia.json with mock addresses
```

---

## Next Steps After Testing

1. **Analyze Gas Usage**: Check transaction receipts for optimization opportunities
2. **Test Edge Cases**: Large amounts, low liquidity, high slippage
3. **Security Review**: Audit swap logic, access controls, ETH handling
4. **Mainnet Preparation**:
   - Update addresses in `configs/mainnet.json`
   - Test on mainnet fork thoroughly
   - Prepare deployment scripts for production
   - Set up monitoring and alerting

5. **Frontend Integration**: See `WEB_INTEGRATION.md` for dApp connection guide

---

## Support & Resources

- **Sepolia Faucets**: https://sepoliafaucet.com/
- **Uniswap V3 Docs**: https://docs.uniswap.org/
- **1inch API Docs**: https://docs.1inch.io/
- **Foundry Book**: https://book.getfoundry.sh/
- **Sepolia Explorer**: https://sepolia.etherscan.io/

---

## Troubleshooting

### Scripts not executable?
```bash
chmod +x script/*.sh
```

### Missing dependencies?
```bash
# Install jq
brew install jq  # macOS
sudo apt install jq  # Linux

# Install bc
brew install bc  # macOS
sudo apt install bc  # Linux
```

### RPC errors?
- Check Alchemy/Infura rate limits
- Try alternative RPC providers
- Use public Sepolia RPC: `https://rpc.sepolia.org`

### Transaction reverts?
- Check contract balances
- Verify approvals
- Check DEX pool liquidity
- Increase gas limit manually
