# Mock Token Deployment Guide

## Overview

Created an EIP-1167 minimal proxy factory system for gas-efficient test token deployment on Sepolia.

## Files Created

### Contracts
- **`src/MockERC20Upgradeable.sol`**: Upgradeable ERC-20 implementation contract
- **`src/MockERC20Factory.sol`**: Factory contract for creating minimal proxies (EIP-1167)

### Tests
- **`test/MockERC20Upgradeable.t.sol`**: Comprehensive test suite (15 tests, all passing)

### Deployment
- **`script/DeployMockTokens.s.sol`**: Deployment script
- **`script/deploy-mock-tokens-sepolia.sh`**: Shell script for Sepolia deployment

## Gas Efficiency

**Test Results:**
- Implementation deployment: **~756,728 gas**
- Each proxy deployment: **~227,231 gas**

**Total for 1 implementation + 2 proxies:** ~1,211,190 gas

**Savings vs 3 direct deployments:** ~46% reduction (1,211,190 vs 2,270,184 gas)

## Deployment Configuration

The script will deploy:
1. **USDC (Implementation)**: 8 decimals, 1M tokens
2. **DAI (Proxy)**: 16 decimals, 1M tokens
3. **WBTC (Proxy)**: 18 decimals, 1M tokens

All tokens minted to deployer address.

## How to Deploy

### 1. Ensure Environment Variables

Make sure your `.env` file has:
```bash
PRIVATE_KEY=your_private_key
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
SEPOLIA_ETHERSCAN_API_KEY=your_etherscan_api_key
```

### 2. Run Deployment

```bash
./script/deploy-mock-tokens-sepolia.sh
```

### 3. Update Configuration

After deployment, the script will output JSON to update `configs/sepolia.json` with the deployed addresses.

## Running Tests

```bash
# Run all mock token tests
forge test --match-contract MockERC20UpgradeableTest -vv

# Run with gas reporting
forge test --match-contract MockERC20UpgradeableTest --gas-report

# Run specific test
forge test --match-test test_Factory_CreateMultipleTokens -vvv
```

## Key Features

### MockERC20Upgradeable
- ✅ OpenZeppelin upgradeable pattern
- ✅ Configurable decimals (6, 8, 18, etc.)
- ✅ Fixed supply on initialization
- ✅ Mint function for testing
- ✅ Cannot be reinitialized
- ✅ Implementation contract is protected

### MockERC20Factory
- ✅ EIP-1167 minimal proxy clones
- ✅ 40-50k gas per proxy (vs ~1.5M for full deployment)
- ✅ Deterministic deployment option
- ✅ Track all deployed proxies
- ✅ Event emission on creation

## Security Considerations

1. **Implementation Protection**: The implementation contract has `_disableInitializers()` in the constructor, preventing direct initialization
2. **Proxy Independence**: Each proxy maintains its own state completely separate from others
3. **Testing Only**: These contracts are for testing purposes only, not production use

## Next Steps

After deployment:
1. Copy the contract addresses from the deployment output
2. Update `configs/sepolia.json` with the new addresses
3. Run the BucketInfo deployment script to configure the tokens
4. Verify contracts on Etherscan (automatic with `--verify` flag)

## Troubleshooting

### Tests Failing
```bash
# Clean and rebuild
forge clean
forge build

# Re-run tests
forge test --match-contract MockERC20UpgradeableTest -vvv
```

### Deployment Issues
- Ensure you have Sepolia ETH in your wallet
- Verify RPC URL is working: `cast block-number --rpc-url $SEPOLIA_RPC_URL`
- Check private key format (no 0x prefix needed)
