# DefiSwap Contract

A Solidity smart contract for depositing USDT and automatically swapping 50% to ETH using the best price from multiple DEXs (Uniswap V3, Uniswap V4, Fluid, and Curve).

## Features

- ✅ **Multi-DEX Integration** - Supports Uniswap V3, Uniswap V4, Fluid, and Curve
- ✅ **Automatic Best Price Selection** - Queries all DEXs on-chain and uses the one with the best rate
- ✅ **Deposit USDT** - Users can deposit USDT tokens into the contract
- ✅ **On-Chain Price Discovery** - No external API calls needed, all price queries happen on-chain
- ✅ **Dynamic Price Adaptation** - Automatically adapts to changing market conditions
- ✅ **Configurable DEXs** - Enable/disable individual DEXs and configure their parameters
- ✅ **Security First** - Built with OpenZeppelin's battle-tested contracts
- ✅ **Gas Optimized** - Efficient price queries and swap execution

## Architecture

### How It Works

Unlike BasicSwap which requires off-chain API calls to 1inch, **DefiSwap does everything on-chain**:

1. **User Deposits**: Users deposit USDT into the contract
2. **Price Query Phase**: When swap is called, the contract queries all enabled DEXs for quotes
3. **Best Price Selection**: The contract compares all quotes and selects the DEX with the best rate
4. **Swap Execution**: The contract executes the swap on the selected DEX
5. **Result**: Contract receives ETH at the optimal rate

```
┌─────────────┐
│ User Deposit│
│    USDT     │
└──────┬──────┘
       │
       v
┌──────────────────┐
│   DefiSwap       │
│   Contract       │
└──────┬───────────┘
       │ swap() called
       v
┌──────────────────────────────────┐
│  Query Phase (On-Chain)          │
│  ├─ Uniswap V3 Quoter: 0.0005 ETH│
│  ├─ Uniswap V4 Quoter: 0.00051 ETH│
│  ├─ Fluid Quoter: 0.00052 ETH    │
│  └─ Curve Pool: 0.00053 ETH ✓   │
└──────────────┬───────────────────┘
               │ Best: Curve
               v
┌──────────────────────────────────┐
│  Execute Swap on Curve           │
│  USDT → ETH @ 0.00053            │
└──────────────────────────────────┘
```

## Contract Functions

### Main Functions

#### `depositUSDT(uint256 amount)`
Allows users to deposit USDT into the contract.
- **Parameters**: `amount` - Amount of USDT to deposit (6 decimals)
- **Requirements**: User must approve contract to spend USDT first
- **Emits**: `Deposited(user, amount)`

#### `swap()`
Swaps 50% of contract's USDT holdings to ETH using the DEX with the best price (owner only).
- **Returns**: `(usdtSwapped, ethReceived, bestDex)` - Amounts and which DEX was used
- **Requirements**: Only callable by owner, contract must have USDT
- **Process**:
  1. Queries all enabled DEXs for quotes
  2. Selects DEX with highest quote
  3. Executes swap on that DEX
- **Emits**: `Swapped(usdtAmount, ethReceived, dexUsed, dexName)`

#### `getBestQuote(uint256 amount)`
Gets quotes from all enabled DEXs and returns the best one.
- **Parameters**: `amount` - Amount of USDT to quote
- **Returns**: `(bestDex, bestQuote)` - Which DEX has the best rate and the quote
- **View Function**: Can be called to preview best rate before swapping

### Configuration Functions

#### `configureDEX(DEX dex, address router, address quoter, uint24 fee, bool enabled)`
Configure a DEX (owner only).
- **Parameters**:
  - `dex` - Which DEX to configure (UNISWAP_V3, UNISWAP_V4, FLUID, or CURVE)
  - `router` - Router contract address
  - `quoter` - Quoter contract address
  - `fee` - Fee tier (e.g., 3000 = 0.3% for Uniswap)
  - `enabled` - Whether to include this DEX in price queries

#### `setCurvePool(address curvePool)`
Set the Curve pool address (owner only).

### Admin Functions

- `withdrawUSDT(address recipient, uint256 amount)` - Withdraw USDT from contract
- `withdrawETH(address recipient, uint256 amount)` - Withdraw ETH from contract

### View Functions

- `getUserBalance(address user)` - Get user's deposited USDT balance
- `getContractUSDTBalance()` - Get contract's total USDT balance
- `getContractETHBalance()` - Get contract's ETH balance
- `getDEXConfig(DEX dex)` - Get configuration for a specific DEX
- `getDEXName(DEX dex)` - Get human-readable name of DEX

## Supported DEXs

### Uniswap V3
- **Router**: `0xE592427A0AEce92De3Edee1F18E0157C05861564` (Ethereum Mainnet)
- **Quoter**: `0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6`
- **Fee Tiers**: 500 (0.05%), 3000 (0.3%), 10000 (1%)

### Uniswap V4
- **Router**: TBD (V4 addresses)
- **Quoter**: TBD
- **Fee Tiers**: Configurable

### Fluid DEX
- **Router**: Check Fluid documentation
- **Quoter**: Check Fluid documentation
- **Fee Tiers**: Configurable

### Curve
- **Pools**: Various pools (e.g., TriPool for USDT/ETH swaps)
- **No quoter needed**: Uses pool's `get_dy()` function directly

## Deployment

### Prerequisites
- Foundry installed
- USDT token address for your network
- WETH address for your network
- DEX router and quoter addresses

### Deploy Script

```bash
# Deploy contract
forge create src/DefiSwap.sol:DefiSwap \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <USDT_ADDRESS> <WETH_ADDRESS> \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Configure Uniswap V3
cast send <DEFISWAP_ADDRESS> \
  "configureDEX(uint8,address,address,uint24,bool)" \
  0 \
  <UNISWAP_V3_ROUTER> \
  <UNISWAP_V3_QUOTER> \
  3000 \
  true \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# Add other DEXs similarly...
```

## Testing

Run the comprehensive test suite:

```bash
# Run all tests
forge test --match-contract DefiSwapTest -vv

# Run specific test
forge test --match-test test_SwapSelectsCurveWhenBestPrice -vvv

# Run with gas reporting
forge test --match-contract DefiSwapTest --gas-report
```

### Test Coverage

The test suite includes **26 comprehensive tests** covering:
- ✅ Constructor validation
- ✅ Deposit functionality
- ✅ **Best price selection** (core feature)
- ✅ Dynamic price changes
- ✅ Multiple swap scenarios
- ✅ DEX configuration
- ✅ Quote retrieval
- ✅ Admin functions
- ✅ Error cases
- ✅ Integration tests
- ✅ Fuzz testing

### Key Test Results

```
Suite result: ok. 26 passed; 0 failed; 0 skipped
```

Notable tests:
- `test_SwapSelectsCurveWhenBestPrice` - Verifies Curve is selected when it has the best rate
- `test_SwapDynamicPriceSelection` - Confirms contract adapts to changing prices across swaps
- `testFuzz_SwapAlwaysSelectsBestPrice` - Fuzz test with random rates ensures best price is always selected

## Example Usage

```solidity
// 1. Deploy DefiSwap
DefiSwap defiSwap = new DefiSwap(usdtAddress, wethAddress);

// 2. Configure DEXs (one-time setup)
defiSwap.configureDEX(
    DefiSwap.DEX.UNISWAP_V3,
    uniswapV3Router,
    uniswapV3Quoter,
    3000, // 0.3% fee
    true  // enabled
);

defiSwap.configureDEX(
    DefiSwap.DEX.CURVE,
    address(0),
    address(0),
    0,
    true
);

defiSwap.setCurvePool(curvePoolAddress);

// 3. User deposits USDT
user.approve(address(defiSwap), 1000 * 1e6);
defiSwap.depositUSDT(1000 * 1e6);

// 4. Owner executes swap (automatically finds best price)
(uint256 usdtSwapped, uint256 ethReceived, DEX dexUsed) = defiSwap.swap();

// Output: "Swapped 500 USDT for 0.265 ETH using Curve"
```

## Gas Optimization

- Queries are done efficiently with try-catch to handle DEX failures
- Only enabled DEXs are queried
- Single approval per swap (reset to 0 after)
- Immutable variables for USDT and WETH addresses

## Security Considerations

1. **Access Control**: Only owner can execute swaps and configure DEXs
2. **Reentrancy Protection**: Uses OpenZeppelin's ReentrancyGuard
3. **Safe Token Transfers**: Uses SafeERC20 for all token operations
4. **Approval Management**: Resets approvals to 0 after each swap
5. **Quote Validation**: Requires at least one valid quote before swapping
6. **Slippage Protection**: 5% slippage tolerance on actual swap execution

## Advantages vs 1inch Integration

| Feature | DefiSwap (On-Chain) | BasicSwap (1inch) |
|---------|-------------------|------------------|
| **Price Discovery** | On-chain, real-time | Off-chain via API |
| **No External Dependencies** | ✅ | ❌ Requires 1inch API |
| **Decentralized** | ✅ Fully on-chain | ⚠️ Depends on 1inch service |
| **Transaction Count** | 1 (all in one tx) | 2 (get data, then swap) |
| **Gas Cost** | Higher (multiple quotes) | Lower (pre-computed route) |
| **Flexibility** | Custom DEX selection | Uses 1inch's routing |
| **MEV Resistance** | Standard | 1inch provides MEV protection |

## When to Use

**Use DefiSwap when:**
- You want fully on-chain execution
- You need guaranteed decentralization
- You have specific DEXs you want to use
- You want to avoid external API dependencies

**Use BasicSwap (1inch) when:**
- You want the absolute best rates across 100+ DEXs
- Gas optimization is critical
- You're okay with off-chain price discovery
- You want 1inch's additional MEV protection

## License

MIT

## Disclaimer

This contract is for educational/demonstration purposes. Ensure thorough testing and auditing before using in production. DEX integrations should be tested extensively on testnets.
