# Quick Deployment Guide

This guide provides step-by-step instructions for deploying BucketToken to different networks.

## Prerequisites Checklist

- [ ] Foundry installed (`foundryup`)
- [ ] Git repository initialized
- [ ] `.env` file configured
- [ ] Wallet funded with ETH (for testnet/mainnet)
- [ ] Etherscan API key obtained (for verification)

## Setup Steps

### 1. Configure Environment

```bash
# Copy example environment file
cp .env.example .env

# Edit .env with your values
nano .env  # or use your preferred editor
```

Required values in `.env`:
- `PRIVATE_KEY`: Your wallet private key (with 0x prefix)
- `SEPOLIA_RPC_URL`: RPC endpoint for Sepolia testnet
- `MAINNET_RPC_URL`: RPC endpoint for Ethereum mainnet
- `ETHERSCAN_API_KEY`: API key from Etherscan

### 2. Get RPC URLs

#### Option A: Alchemy (Recommended)
1. Sign up at https://www.alchemy.com/
2. Create a new app for Ethereum
3. Copy the HTTPS URL
4. Format: `https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY`

#### Option B: Infura
1. Sign up at https://infura.io/
2. Create a new project
3. Copy the endpoint URL
4. Format: `https://sepolia.infura.io/v3/YOUR_PROJECT_ID`

#### Option C: Ankr (Free, No signup)
- Sepolia: `https://rpc.ankr.com/eth_sepolia`
- Mainnet: `https://rpc.ankr.com/eth`

### 3. Get Testnet ETH

For Sepolia testnet:
- Alchemy Faucet: https://sepoliafaucet.com/
- Infura Faucet: https://www.infura.io/faucet/sepolia
- QuickNode Faucet: https://faucet.quicknode.com/ethereum/sepolia

### 4. Get Etherscan API Key

1. Create account at https://etherscan.io/
2. Go to API Keys section: https://etherscan.io/myapikey
3. Create a new API key
4. Copy and add to `.env`

## Deployment

### Test Locally First

```bash
# Terminal 1: Start local Anvil node
anvil

# Terminal 2: Deploy to local network
./script/deploy-local.sh
```

Expected output:
```
Deploying BucketToken...
Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Initial Supply: 100000000 tokens
BucketToken deployed at: 0x5FbDB2315678afecb367f032d93F642f64180aa3
```

### Deploy to Sepolia Testnet

```bash
# Make sure .env is configured
./script/deploy-sepolia.sh
```

The script will:
1. Show your deployer address
2. Deploy the contract
3. Verify on Etherscan
4. Save deployment info to `broadcast/` directory

### Deploy to Mainnet

```bash
# ⚠️ WARNING: This costs real ETH!
./script/deploy-mainnet.sh
```

You'll be prompted to confirm before deployment:
```
⚠️  WARNING: You are about to deploy to MAINNET!
Deployer address: 0x...
Are you sure you want to continue? (yes/no)
```

Type `yes` to proceed.

## Post-Deployment

### 1. Save Deployment Information

After successful deployment, save these details:

```
Contract Address: 0x...
Transaction Hash: 0x...
Deployer Address: 0x...
Network: Sepolia / Mainnet
Block Number: ...
Gas Used: ...
Deployment Date: ...
```

### 2. Verify Contract (if not auto-verified)

```bash
forge verify-contract \
    --chain-id 11155111 \
    --num-of-optimizations 200 \
    --compiler-version v0.8.33 \
    <CONTRACT_ADDRESS> \
    src/BucketToken.sol:BucketToken \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode "constructor(address,uint256)" <OWNER_ADDRESS> <INITIAL_SUPPLY>)
```

### 3. Test Deployed Contract

```bash
# Get token info
cast call <CONTRACT_ADDRESS> "name()(string)" --rpc-url $SEPOLIA_RPC_URL
cast call <CONTRACT_ADDRESS> "symbol()(string)" --rpc-url $SEPOLIA_RPC_URL
cast call <CONTRACT_ADDRESS> "totalSupply()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Check your balance
cast call <CONTRACT_ADDRESS> "balanceOf(address)(uint256)" <YOUR_ADDRESS> --rpc-url $SEPOLIA_RPC_URL
```

### 4. Transfer Ownership (Optional)

If you want to transfer to a multisig or different address:

```bash
cast send <CONTRACT_ADDRESS> "transferOwnership(address)" <NEW_OWNER_ADDRESS> \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY
```

## Verification Checklist

After deployment, verify:

- [ ] Contract deployed successfully
- [ ] Contract verified on Etherscan
- [ ] Initial supply minted correctly
- [ ] Ownership set correctly
- [ ] Can view contract on Etherscan
- [ ] Test transfer works
- [ ] Deployment info saved

## Common Issues & Solutions

### Issue: "Insufficient funds"

**Solution**: Ensure your wallet has enough ETH:
```bash
# Check balance
cast balance <YOUR_ADDRESS> --rpc-url $SEPOLIA_RPC_URL
```

### Issue: "Nonce too low"

**Solution**: Reset nonce or wait for pending transaction to complete.

### Issue: "Contract verification failed"

**Solutions**:
1. Wait 1-2 minutes after deployment
2. Check compiler version matches exactly
3. Verify optimization settings match
4. Try manual verification with constructor args

### Issue: "Invalid API Key"

**Solution**: 
1. Check `.env` file has correct Etherscan API key
2. Verify no extra spaces or quotes
3. Generate new API key if needed

### Issue: "RPC URL not responding"

**Solutions**:
1. Check network connectivity
2. Try alternative RPC provider
3. Verify RPC URL is correct for the network

## Gas Estimation

Approximate gas costs (at 30 gwei):

| Network | Deployment | Mint | Transfer | Burn |
|---------|-----------|------|----------|------|
| Mainnet | ~0.04 ETH | ~0.002 ETH | ~0.002 ETH | ~0.001 ETH |
| Sepolia | Free (from faucet) | Free | Free | Free |

## Security Best Practices

1. **Never commit `.env` file** - It's in `.gitignore` by default
2. **Use hardware wallet** for mainnet deployments
3. **Test on testnet first** - Always!
4. **Verify contract source** on Etherscan
5. **Transfer ownership to multisig** for production
6. **Keep private keys secure** - Never share
7. **Monitor contract** after deployment
8. **Consider audit** for production use

## Next Steps

After deployment:

1. **Add liquidity** (if creating a DEX pair)
2. **List on token trackers** (CoinGecko, CoinMarketCap)
3. **Update documentation** with contract address
4. **Integrate with frontend** (see WEB_INTEGRATION.md)
5. **Set up monitoring** (Tenderly, OpenZeppelin Defender)
6. **Create subgraph** (if using The Graph)

## Useful Commands

```bash
# Check deployment in broadcast directory
cat broadcast/DeployBucketToken.s.sol/11155111/run-latest.json | jq

# Get contract ABI
forge inspect BucketToken abi > BucketToken.abi.json

# Get contract bytecode
forge inspect BucketToken bytecode

# Estimate deployment gas
forge script script/DeployBucketToken.s.sol --estimate

# Simulate deployment (dry-run)
forge script script/DeployBucketToken.s.sol --rpc-url $SEPOLIA_RPC_URL
```

## Support & Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Ethereum Gas Tracker](https://etherscan.io/gastracker)
- [Sepolia Faucet](https://sepoliafaucet.com/)
- [Etherscan](https://etherscan.io/)

---

**Remember**: Always test thoroughly on testnet before mainnet deployment!
