# Quick Reference: Sepolia Testing Commands

## Environment Setup
```bash
# Required in .env file:
PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
SEPOLIA_ETHERSCAN_API_KEY=YOUR_KEY
DEFISWAP_ADDRESS=0x...    # Add after deployment
BASICSWAP_ADDRESS=0x...   # Add after deployment
```

## DefiSwap Testing (3 Steps)

### 1. Deploy
```bash
./script/deploy-defiswap-full.sh
```
→ Copy address to `.env` as `DEFISWAP_ADDRESS=0x...`

### 2. Verify
```bash
./script/verify-defiswap-sepolia.sh
```
→ Confirms contract is set up correctly

### 3. Test
```bash
./script/test-defiswap-sepolia.sh
```
→ Tests deposit → swap → withdraw

---

## BasicSwap Testing (3 Steps)

### 1. Deploy
```bash
./script/deploy-basicswap-full.sh
```
→ Copy address to `.env` as `BASICSWAP_ADDRESS=0x...`

### 2. Verify
```bash
./script/verify-basicswap-sepolia.sh
```
→ Confirms contract is set up correctly

### 3. Test
```bash
./script/test-basicswap-sepolia.sh
```
→ Tests deposit → (manual swap) → withdraw

---

## Prerequisites Checklist

- [ ] Sepolia ETH (0.1+ ETH) - https://sepoliafaucet.com/
- [ ] Sepolia USDT (10+ USDT) - Swap on Uniswap V3
- [ ] `.env` configured with keys
- [ ] `jq` and `bc` installed

---

## Manual Commands

### Check Balances
```bash
# Contract USDT balance
cast call $DEFISWAP_ADDRESS "getContractUSDTBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Contract ETH balance
cast call $DEFISWAP_ADDRESS "getContractETHBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL
```

### Execute Functions
```bash
# Approve USDT (10 USDT)
cast send 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 "approve(address,uint256)" $DEFISWAP_ADDRESS 10000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Deposit USDT (1 USDT)
cast send $DEFISWAP_ADDRESS "depositUSDT(uint256)" 1000000 --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Execute swap (owner only)
cast send $DEFISWAP_ADDRESS "swap()" --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

---

## Sepolia Token Addresses

```
USDT: 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0
WETH: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
```

## Sepolia DEX Addresses

```
Uniswap V3 Router: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
Uniswap V3 Quoter: 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3
1inch Router V6:   0x111111125421cA6dc452d289314280a0f8842A65
```

---

## All Scripts at a Glance

| Script | Purpose |
|--------|---------|
| `deploy-defiswap-full.sh` | Deploy DefiSwap with Uniswap V3 config |
| `deploy-basicswap-full.sh` | Deploy BasicSwap with 1inch config |
| `verify-defiswap-sepolia.sh` | Verify + display DefiSwap config |
| `verify-basicswap-sepolia.sh` | Verify + display BasicSwap config |
| `test-defiswap-sepolia.sh` | Full test: deposit/swap/withdraw |
| `test-basicswap-sepolia.sh` | Full test: deposit/swap/withdraw |

---

## Expected Gas Costs

```
Deploy DefiSwap:    ~2.5M gas  (~0.05 ETH @ 20 gwei)
Deploy BasicSwap:   ~1.8M gas  (~0.036 ETH @ 20 gwei)
Approve USDT:       ~46K gas   (~0.001 ETH)
Deposit:            ~80K gas   (~0.002 ETH)
Swap:               ~200K gas  (~0.004 ETH)
Withdraw:           ~50K gas   (~0.001 ETH)

Total needed: ~0.1 ETH for full testing
```

---

## Troubleshooting

**Scripts won't run?**
```bash
chmod +x script/*.sh
```

**Missing tools?**
```bash
brew install jq bc  # macOS
```

**No USDT?**
1. Go to https://app.uniswap.org/
2. Connect to Sepolia
3. Swap ETH → USDT (address: `0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0`)

**Low liquidity on Sepolia?**
- Use smaller amounts (0.1 - 1 USDT)
- Or test on mainnet fork instead:
  ```bash
  anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
  ```

---

## Success Indicators

✅ Deployment successful:
- Contract address displayed
- Verified on Etherscan
- Configuration matches expected values

✅ Testing successful:
- USDT deposit confirms
- Swap executes and ETH received
- Withdrawals complete successfully
- Gas usage within expected range

---

For detailed explanations, see `SEPOLIA_TESTING_GUIDE.md`
