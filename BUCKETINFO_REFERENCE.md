# BucketInfo Contract Reference

## Overview

BucketInfo is the central information management contract for the Bucket for Eggs platform. It manages whitelisted tokens, price feeds, platform fees, and the global pause state.

## Contract Address

- **Sepolia Testnet**: (Deploy and add address here)
- **Ethereum Mainnet**: (Deploy and add address here)

## Key Features

### 1. Token Whitelist Management
- Add/remove tokens from platform whitelist
- Batch operations supported
- Native ETH (address(0)) whitelisted by default

### 2. Price Management
- Manual price setting with 8 decimal precision (Chainlink standard)
- Chainlink price feed integration ready
- Batch price updates

### 3. Platform Controls
- Global pause/unpause functionality
- Platform fee management (max 10%)
- Ownership controls

## Main Functions

### Whitelist Management

```solidity
// Add or remove a token from whitelist
function setTokenWhitelist(address token, bool whitelisted) external onlyOwner

// Batch whitelist tokens
function batchSetTokenWhitelist(address[] calldata tokens, bool whitelisted) external onlyOwner

// Get all whitelisted tokens
function getWhitelistedTokens() external view returns (address[] memory)

// Check if token is whitelisted
function isWhitelisted(address token) external view returns (bool)
```

### Price Management

```solidity
// Set token price manually (USD with 8 decimals)
function setTokenPrice(address token, uint256 price) external onlyOwner

// Batch set prices
function batchSetTokenPrices(address[] calldata tokens, uint256[] calldata prices) external onlyOwner

// Get token price
function getTokenPrice(address token) external view returns (uint256)

// Set Chainlink price feed
function setPriceFeed(address token, address priceFeed) external onlyOwner
```

### Platform Management

```solidity
// Pause platform
function pausePlatform() external onlyOwner

// Unpause platform
function unpausePlatform() external onlyOwner

// Set platform fee (in basis points, 100 = 1%)
function setPlatformFee(uint256 newFee) external onlyOwner

// Check if platform is operational
function isPlatformOperational() external view returns (bool)
```

### Utility Functions

```solidity
// Calculate fee for given amount
function calculateFee(uint256 amount) external view returns (uint256)

// Check if token is valid for use
function isTokenValid(address token) external view returns (bool)
```

## Usage Examples

### Using Cast (Foundry CLI)

```bash
# Check if token is whitelisted
cast call <CONTRACT_ADDRESS> "isWhitelisted(address)(bool)" <TOKEN_ADDRESS> --rpc-url $SEPOLIA_RPC_URL

# Get token price
cast call <CONTRACT_ADDRESS> "getTokenPrice(address)(uint256)" <TOKEN_ADDRESS> --rpc-url $SEPOLIA_RPC_URL

# Check platform status
cast call <CONTRACT_ADDRESS> "isPlatformOperational()(bool)" --rpc-url $SEPOLIA_RPC_URL

# Get platform fee
cast call <CONTRACT_ADDRESS> "platformFee()(uint256)" --rpc-url $SEPOLIA_RPC_URL
```

### Owner Operations

```bash
# Whitelist a token
cast send <CONTRACT_ADDRESS> "setTokenWhitelist(address,bool)" <TOKEN_ADDRESS> true \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY

# Set token price (e.g., $2000 = 200000000000)
cast send <CONTRACT_ADDRESS> "setTokenPrice(address,uint256)" <TOKEN_ADDRESS> 200000000000 \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY

# Pause platform
cast send <CONTRACT_ADDRESS> "pausePlatform()" \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY

# Set platform fee (e.g., 250 = 2.5%)
cast send <CONTRACT_ADDRESS> "setPlatformFee(uint256)" 250 \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY
```

### Using Ethers.js

```javascript
import { ethers } from 'ethers';

const BUCKET_INFO_ABI = [
  "function isWhitelisted(address) view returns (bool)",
  "function getTokenPrice(address) view returns (uint256)",
  "function isPlatformOperational() view returns (bool)",
  "function platformFee() view returns (uint256)",
  "function setTokenWhitelist(address,bool)",
  "function setTokenPrice(address,uint256)",
  "function pausePlatform()",
  "function setPlatformFee(uint256)"
];

const CONTRACT_ADDRESS = "0x...";
const provider = new ethers.BrowserProvider(window.ethereum);
const bucketInfo = new ethers.Contract(CONTRACT_ADDRESS, BUCKET_INFO_ABI, provider);

// Read operations
const isWhitelisted = await bucketInfo.isWhitelisted(tokenAddress);
const price = await bucketInfo.getTokenPrice(tokenAddress);
const isOperational = await bucketInfo.isPlatformOperational();
const fee = await bucketInfo.platformFee();

// Write operations (requires signer)
const signer = await provider.getSigner();
const bucketInfoWithSigner = bucketInfo.connect(signer);

await bucketInfoWithSigner.setTokenWhitelist(tokenAddress, true);
await bucketInfoWithSigner.setTokenPrice(tokenAddress, ethers.parseUnits("2000", 8));
```

## Price Format

Prices follow the Chainlink standard format:
- **Decimals**: 8
- **Format**: USD per 1 token
- **Example**: 
  - $2000.00 = 200000000000 (2000 * 10^8)
  - $0.50 = 50000000 (0.5 * 10^8)

## Constants

```solidity
uint256 public constant PRICE_DECIMALS = 8;
uint256 public constant MAX_PLATFORM_FEE = 1000; // 10%
address public constant NATIVE_TOKEN = address(0); // ETH
```

## Events

```solidity
event TokenWhitelisted(address indexed token, bool whitelisted);
event PriceUpdated(address indexed token, uint256 price);
event PriceFeedUpdated(address indexed token, address priceFeed);
event PlatformFeeUpdated(uint256 newFee);
```

## Security Considerations

1. **Owner-only functions**: All management functions require owner privileges
2. **Price validation**: Prices must be > 0
3. **Fee limits**: Platform fee capped at 10%
4. **Pause mechanism**: Emergency stop for entire platform
5. **Whitelist enforcement**: Only whitelisted tokens are valid

## Integration with Other Contracts

Other platform contracts should:

1. **Check whitelist** before accepting tokens:
   ```solidity
   require(bucketInfo.isWhitelisted(token), "Token not whitelisted");
   ```

2. **Respect platform pause**:
   ```solidity
   require(bucketInfo.isPlatformOperational(), "Platform paused");
   ```

3. **Use for price oracle**:
   ```solidity
   uint256 price = bucketInfo.getTokenPrice(token);
   ```

4. **Calculate fees**:
   ```solidity
   uint256 fee = bucketInfo.calculateFee(amount);
   ```

## Deployment

### Local Testing
```bash
# Terminal 1: Start Anvil
anvil

# Terminal 2: Deploy
./script/deploy-bucketinfo-local.sh
```

### Sepolia Testnet
```bash
./script/deploy-bucketinfo-sepolia.sh
```

### Manual Deployment
```bash
forge script script/DeployBucketInfo.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

## Testing

Run comprehensive test suite:
```bash
forge test --match-contract BucketInfoTest -vv
```

Test coverage:
```bash
forge coverage --match-contract BucketInfo
```

## Gas Costs

Approximate gas usage:
- `setTokenWhitelist`: ~61,000 gas
- `setTokenPrice`: ~86,000 gas
- `batchSetTokenWhitelist` (5 tokens): ~251,000 gas
- `pausePlatform`: ~14,000 gas
- `setPlatformFee`: ~19,000 gas

## Future Enhancements

1. **Chainlink Integration**: Automatic price updates from Chainlink oracles
2. **Multi-tier fees**: Different fees for different operations
3. **Token metadata**: Store additional token information
4. **Rate limiting**: Prevent excessive price updates
5. **Governance**: DAO-controlled parameter updates

## Support

For issues or questions:
- Review the test suite in `test/BucketInfo.t.sol`
- Check deployment logs in `broadcast/` directory
- Verify contract on Etherscan for transparency

---

**Contract Version**: 1.0.0  
**Solidity Version**: ^0.8.33
**License**: MIT
