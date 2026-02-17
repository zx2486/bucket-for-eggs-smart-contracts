# BucketInfo Contract Verification Guide

## Overview

This guide explains how to verify and inspect the deployed BucketInfo contract on Sepolia testnet after deployment.

## Files Created

### Scripts
- **`script/VerifyBucketInfo.s.sol`**: Solidity script to read and display deployed contract information
- **`script/verify-bucketinfo-sepolia.sh`**: Shell script to verify contract on Etherscan and display summary

## Usage

### Method 1: Automatic Verification (Recommended)

If you just deployed the contract, the script can automatically find it:

```bash
./script/verify-bucketinfo-sepolia.sh
```

This will:
1. Read the contract address from `broadcast/DeployBucketInfo.s.sol/11155111/run-latest.json`
2. Verify the contract on Etherscan
3. Display the deployment summary with all configured tokens

### Method 2: Manual Address

If you know the contract address:

```bash
./script/verify-bucketinfo-sepolia.sh 0xYourContractAddress
```

### Method 3: Using Environment Variable

Set the address in your environment:

```bash
export BUCKETINFO_ADDRESS=0xYourContractAddress
forge script script/VerifyBucketInfo.s.sol --rpc-url $SEPOLIA_RPC_URL -vvv
```

## What the Verification Script Does

### Step 1: Etherscan Verification

Submits the contract source code to Etherscan for public verification using:
- Compiler version: 0.8.33
- Optimization: 200 runs
- Contract path: `src/BucketInfo.sol:BucketInfo`

### Step 2: Display Contract Information

Shows detailed information about the deployed contract:

```
=== Deployment Summary ===
BucketInfo Address: 0x...
Owner: 0x...
Platform Fee: 100 basis points
Whitelisted Tokens Count: 5

=== Whitelisted Tokens ===
Token 0:
  Address: 0x0000000000000000000000000000000000000000
  Price Feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306
  Is Whitelisted: true

Token 1:
  Address: 0x759dFFf3E523CFE1dbcB47BA2852C74D0A0bcD47
  Price Feed: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
  Is Whitelisted: true

... (more tokens)
```

## Integration with Deployment

The verification script is designed to work seamlessly after deployment:

```bash
# Step 1: Deploy BucketInfo
./script/deploy-bucketinfo-sepolia.sh

# Step 2: Verify (automatically finds latest deployment)
./script/verify-bucketinfo-sepolia.sh
```

## Troubleshooting

### Contract Already Verified

If you see:
```
Contract may already be verified
```

This is normal - Etherscan won't verify a contract twice. The script continues to display contract information.

### Cannot Find Deployment

If the script can't find the deployment:
```
Error: No deployment found. Please provide BucketInfo contract address as argument.
```

Solution: Provide the address manually:
```bash
./script/verify-bucketinfo-sepolia.sh 0xYourContractAddress
```

### RPC Connection Issues

Ensure your `.env` file has valid:
- `SEPOLIA_RPC_URL`
- `SEPOLIA_ETHERSCAN_API_KEY`

## Viewing on Etherscan

After verification, visit:
```
https://sepolia.etherscan.io/address/0xYourContractAddress
```

You'll see:
- ✅ Verified source code
- Contract read/write functions
- Transaction history
- Events emitted

## Advanced Usage

### Verify Only (No Info Display)

```bash
forge verify-contract \
    --chain-id 11155111 \
    --num-of-optimizations 200 \
    --compiler-version 0.8.33 \
    --etherscan-api-key $SEPOLIA_ETHERSCAN_API_KEY \
    0xYourContractAddress \
    src/BucketInfo.sol:BucketInfo
```

### Display Info Only (Contract Already Verified)

```bash
export BUCKETINFO_ADDRESS=0xYourContractAddress
forge script script/VerifyBucketInfo.s.sol --rpc-url $SEPOLIA_RPC_URL -vvv
```

## Related Documentation

- [BucketInfo Reference](./BUCKETINFO_REFERENCE.md) - Complete contract reference
- [Deployment Guide](./DEPLOYMENT_GUIDE.md) - Deployment instructions
- [Sepolia Config](./configs/sepolia.json) - Network configuration
