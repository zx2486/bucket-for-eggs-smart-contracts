# Bucket Token - ERC-20 Smart Contract

A production-ready ERC-20 token implementation built with Foundry and OpenZeppelin contracts. Features minting, burning, pausing, and gasless approvals (EIP-2612).

## Features

- ✅ **ERC-20 Standard**: Full compliance with ERC-20 token standard
- 🔥 **Burnable**: Token holders can burn their tokens
- ⏸️ **Pausable**: Owner can pause/unpause transfers in emergencies
- 👤 **Ownable**: Access control for privileged operations
- ⛽ **Permit (EIP-2612)**: Gasless approvals using signatures
- 🎯 **Max Supply Cap**: Optional maximum supply limit (1 billion tokens)
- ✨ **Gas Optimized**: Built with latest Solidity and optimization enabled
- 🧪 **Thoroughly Tested**: 25+ tests with >95% coverage

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/downloads)

## Installation

1. Clone the repository:
```bash
git clone <your-repo-url>
cd bucket-for-eggs-smart-contracts
```

2. Install dependencies:
```bash
forge install
```

3. Copy environment variables:
```bash
cp .env.example .env
```

4. Update `.env` with your values:
```bash
PRIVATE_KEY=your_private_key_here
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
ETHERSCAN_API_KEY=your_etherscan_api_key_here
```

## Building

Compile the contracts:
```bash
forge build
```

## Testing

Run all tests:
```bash
forge test
```

Run tests with gas reporting:
```bash
forge test --gas-report
```

Run tests with verbosity (for debugging):
```bash
forge test -vvvv
```

Generate coverage report:
```bash
forge coverage
```

## Deployment

### Local Deployment (Anvil)

1. Start Anvil local node:
```bash
anvil
```

2. In a new terminal, deploy:
```bash
./script/deploy-local.sh
```

### Testnet Deployment (Sepolia)

1. Ensure you have Sepolia ETH in your wallet
2. Update `.env` with your credentials
3. Deploy:
```bash
./script/deploy-sepolia.sh
```

### Mainnet Deployment

⚠️ **Warning**: This will deploy to Ethereum mainnet and cost real ETH!

```bash
./script/deploy-mainnet.sh
```

You'll be prompted to confirm before deployment.

## Manual Deployment

You can also deploy manually using Forge:

```bash
forge script script/DeployBucketToken.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

## Contract Verification

Contracts are automatically verified on Etherscan when using the `--verify` flag during deployment.

Manual verification:
```bash
forge verify-contract \
    --chain-id 11155111 \
    --num-of-optimizations 200 \
    --compiler-version v0.8.28 \
    <CONTRACT_ADDRESS> \
    src/BucketToken.sol:BucketToken \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

## Interacting with the Contract

### Using Cast (Foundry CLI)

Check balance:
```bash
cast call <CONTRACT_ADDRESS> "balanceOf(address)(uint256)" <WALLET_ADDRESS> --rpc-url $SEPOLIA_RPC_URL
```

Transfer tokens:
```bash
cast send <CONTRACT_ADDRESS> "transfer(address,uint256)" <TO_ADDRESS> 1000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

Mint tokens (owner only):
```bash
cast send <CONTRACT_ADDRESS> "mint(address,uint256)" <TO_ADDRESS> 1000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

Pause contract (owner only):
```bash
cast send <CONTRACT_ADDRESS> "pause()" --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

## Project Structure

```
bucket-for-eggs-smart-contracts/
├── src/
│   └── BucketToken.sol          # Main ERC-20 token contract
├── test/
│   └── BucketToken.t.sol        # Comprehensive test suite
├── script/
│   ├── DeployBucketToken.s.sol  # Deployment script
│   ├── deploy-local.sh          # Local deployment helper
│   ├── deploy-sepolia.sh        # Sepolia deployment helper
│   └── deploy-mainnet.sh        # Mainnet deployment helper
├── lib/
│   ├── forge-std/               # Foundry standard library
│   └── openzeppelin-contracts/  # OpenZeppelin contracts
├── foundry.toml                 # Foundry configuration
├── .env.example                 # Environment variables template
└── README.md                    # This file
```

## Contract Details

### BucketToken.sol

**Name**: Bucket Token  
**Symbol**: BUCKET  
**Decimals**: 18  
**Max Supply**: 1,000,000,000 tokens (1 billion)

### Main Functions

| Function | Access | Description |
|----------|--------|-------------|
| `transfer(address to, uint256 amount)` | Public | Transfer tokens |
| `approve(address spender, uint256 amount)` | Public | Approve spending |
| `transferFrom(address from, address to, uint256 amount)` | Public | Transfer from approved address |
| `mint(address to, uint256 amount)` | Owner | Mint new tokens |
| `burn(uint256 amount)` | Public | Burn own tokens |
| `burnFrom(address account, uint256 amount)` | Public | Burn approved tokens |
| `pause()` | Owner | Pause all transfers |
| `unpause()` | Owner | Unpause transfers |
| `permit(...)` | Public | Approve via signature (EIP-2612) |

## Gas Optimization

The contract is optimized with:
- Solidity 0.8.28 with optimizer enabled (200 runs)
- Cancun EVM version for latest opcodes
- OpenZeppelin's battle-tested implementations

## Security

- ✅ Based on OpenZeppelin's audited contracts
- ✅ Follows best practices (Checks-Effects-Interactions)
- ✅ Comprehensive test coverage
- ✅ No known vulnerabilities

**Recommendations**:
- Always test on testnet before mainnet deployment
- Consider professional audit for production use
- Use multi-sig wallet for contract ownership
- Monitor contract events for unusual activity

## Common Use Cases

### Token Sale / ICO
1. Deploy with initial supply to treasury
2. Transfer tokens to sale contract
3. Distribute to buyers

### Governance Token
1. Deploy with initial supply
2. Distribute to stakeholders
3. Integrate with governance contracts

### Utility Token
1. Deploy with zero initial supply
2. Mint tokens as needed
3. Users burn tokens for utility

## Troubleshooting

### Build Errors

**Solc version mismatch**:
```bash
forge install
forge update
```

### Test Failures

**RPC connection issues**:
- Check your RPC URL in `.env`
- Ensure you have network connectivity
- Try alternative RPC providers (Alchemy, Infura, Ankr)

### Deployment Issues

**Insufficient funds**:
- Ensure wallet has enough ETH for gas
- Check current gas prices: https://etherscan.io/gastracker

**Verification failed**:
- Wait a minute and try manual verification
- Ensure compiler version matches exactly
- Check Etherscan API key is valid

## Foundry Toolkit

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

### Additional Foundry Commands

Format code:
```bash
forge fmt
```

Gas snapshots:
```bash
forge snapshot
```

Get help:
```bash
forge --help
anvil --help
cast --help
```

## Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Solidity Documentation](https://docs.soliditylang.org/)
- [Ethereum Development Documentation](https://ethereum.org/en/developers/docs/)

## License

This project is licensed under the MIT License.

---

**Made with ❤️ using Foundry and OpenZeppelin**

