# BasicSwap Contract

A Solidity smart contract for depositing USDT and swapping 50% to ETH using 1inch aggregation protocol.

## Features

- ✅ **Deposit USDT** - Users can deposit USDT tokens into the contract
- ✅ **1inch Integration** - Swap 50% of USDT holdings to ETH via 1inch for optimal rates
- ✅ **User Balance Tracking** - Track individual user deposits
- ✅ **Admin Controls** - Owner can manage funds and router configuration
- ✅ **Security** - Built with OpenZeppelin's battle-tested contracts
- ✅ **Gas Optimized** - Uses SafeERC20 and ReentrancyGuard for safety

## Contract Overview

### Main Functions

#### `depositUSDT(uint256 amount)`
Allows users to deposit USDT into the contract.
- **Parameters**: `amount` - Amount of USDT to deposit (6 decimals)
- **Requirements**: User must approve contract to spend USDT first
- **Emits**: `Deposited(user, amount)`

#### `swap(bytes calldata swapCalldata)`
Swaps 50% of contract's USDT holdings to ETH via 1inch (owner only).
- **Parameters**: `swapCalldata` - The swap data from 1inch API
- **Returns**: `(usdtSwapped, ethReceived)` - Amounts swapped and received
- **Requirements**: Only callable by owner, contract must have USDT
- **Emits**: `Swapped(usdtAmount, ethReceived)`

#### Admin Functions
- `setOneInchRouter(address newRouter)` - Update 1inch router address
- `withdrawUSDT(address recipient, uint256 amount)` - Withdraw USDT from contract
- `withdrawETH(address recipient, uint256 amount)` - Withdraw ETH from contract

#### View Functions
- `getUserBalance(address user)` - Get user's deposited USDT balance
- `getContractUSDTBalance()` - Get contract's total USDT balance
- `getContractETHBalance()` - Get contract's ETH balance

## How to Use with 1inch

### 1. Get Swap Calldata from 1inch API

To swap USDT to ETH, you need to get the swap calldata from the 1inch API:

```bash
# Example API call to 1inch (Ethereum mainnet)
curl "https://api.1inch.dev/swap/v5.2/1/swap?src=0xdAC17F958D2ee523a2206206994597C13D831ec7&dst=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE&amount=1000000000&from=YOUR_CONTRACT_ADDRESS&slippage=1" \
  -H "Authorization: Bearer YOUR_1INCH_API_KEY"
```

Parameters:
- `src`: USDT contract address (0xdAC17F958D2ee523a2206206994597C13D831ec7 on mainnet)
- `dst`: ETH address (0xEeee...EEeE represents native ETH)
- `amount`: Amount to swap (in USDT's smallest unit, 6 decimals)
- `from`: Your BasicSwap contract address
- `slippage`: Slippage tolerance (e.g., 1 = 1%)

### 2. Execute Swap

```solidity
// Get the 'data' field from 1inch API response
bytes memory swapCalldata = /* data from 1inch API */;

// Call swap function (owner only)
basicSwap.swap(swapCalldata);
```

## Deployment

### Prerequisites
- Foundry installed
- USDT token address for your network
- 1inch router address for your network

### 1inch Router Addresses

- **Ethereum Mainnet**: `0x1111111254EEB25477B68fb85Ed929f73A960582`
- **Polygon**: `0x1111111254EEB25477B68fb85Ed929f73A960582`
- **BSC**: `0x1111111254EEB25477B68fb85Ed929f73A960582`
- **Arbitrum**: `0x1111111254EEB25477B68fb85Ed929f73A960582`
- **Optimism**: `0x1111111254EEB25477B68fb85Ed929f73A960582`

### Deploy Script

```bash
# Deploy to network
forge create src/BasicSwap.sol:BasicSwap \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <USDT_ADDRESS> <ONEINCH_ROUTER_ADDRESS> \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Testing

Run the comprehensive test suite:

```bash
# Run all tests
forge test --match-contract BasicSwapTest -vv

# Run specific test
forge test --match-test test_SwapWith1inch -vvv

# Run with gas reporting
forge test --match-contract BasicSwapTest --gas-report
```

### Test Coverage

The test suite includes **34 comprehensive tests** covering:
- ✅ Constructor validation
- ✅ Deposit functionality (single & multiple users)
- ✅ Swap functionality with 1inch integration
- ✅ Admin functions (router updates, withdrawals)
- ✅ Access control
- ✅ Error cases and edge conditions
- ✅ View functions
- ✅ Full workflow integration
- ✅ Fuzz testing

## Example Usage Flow

```solidity
// 1. User deposits USDT
user.approve(address(basicSwap), 1000 * 1e6); // Approve 1000 USDT
basicSwap.depositUSDT(1000 * 1e6); // Deposit 1000 USDT

// 2. Owner gets 1inch swap data
// (via 1inch API - see "How to Use with 1inch" section)

// 3. Owner executes swap (swaps 50% of contract USDT to ETH)
basicSwap.swap(swapCalldata);

// 4. Owner can withdraw funds
basicSwap.withdrawETH(recipient, amount);
basicSwap.withdrawUSDT(recipient, amount);
```

## Security Considerations

1. **Access Control**: Only owner can execute swaps and withdrawals
2. **Reentrancy Protection**: Uses OpenZeppelin's ReentrancyGuard
3. **Safe Token Transfers**: Uses SafeERC20 for token operations
4. **Approval Management**: Resets 1inch router approval to 0 after each swap
5. **Validation**: All inputs are validated before execution

## Gas Optimization

- Uses `immutable` for USDT address
- Efficient approval management
- Optimized storage reads

## 1inch Integration Notes

- The contract uses 1inch's aggregation router for optimal swap rates
- Swap calldata must be obtained from 1inch API before calling `swap()`
- The contract approves exact swap amount to router (not unlimited)
- Approval is reset to 0 after each swap for security

## License

MIT

## Disclaimer

This contract is for educational/demonstration purposes. Ensure thorough testing and auditing before using in production.
