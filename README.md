# Contracts for the bucket for eggs project

This repository keeps the list of smart contracts used in the bucket for eggs platform.
All contracts are built with Foundry and OpenZeppelin contracts.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/downloads)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/zx2486/bucket-for-eggs-smart-contracts.git
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

## Contract Descriptions
This section discusses the contracts in this repository and where they are used in the platform.

### BucketToken.sol
This is the base and core contract of the bucket for eggs platform. It is based on ERC-20 with mint, burn, pause, ownable and gas less approval (EIP-2612) features.

This contract gives the very basic feature of the platform: 
A pool contract for others to suppport an user / project and get back a token. The token can be used to claim back something from the same contract if there is sufficient balance. 

User can send in coins or tokens on the whitelist and get newly minted tokens (deposit()).
User with tokens can burn the token and get back some coins or tokens (withdraw()).
What a unit of token can get is calculated by a pre-defined function (tokenBalance()) and it is updated whenever deposit() or rebalance() is called.
Contract owner can take away coins / tokens for their own good (ownerWithdraw()), deposit and give newly minted tokens to another address (assistDeposit()) and clean tokens in the contract which is not whitelisted (cleanDusts()).

New users setting up a pay for nothing contract is actually a proxy contract pointing to this contract.

### BucketMembership.sol
This is another base contract. It is based on ERC-721 with mint, burn, pause, ownable and gas less approval (EIP-2612) features.

This contract is more or less the same as BucketToken.sol. But the return is a NFT representing a membership with grades. Withdraw will get back coin / token based on the remaining validity period of the membership.
There is also a simple function (checkMembership()) to check if an user has a valid membership of a certain grade.

### BucketInfo.sol
This contract keeps information neccessary for other contracts.
This includes the whitelist of coins / tokens, whether the whole platform should be paused, prices of each coins or tokens. Price feed will go to this contract (likely by chainlink).

## Deployment (Bucket Token Contract)

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

You can also deploy manually using Forge. This is also the recommanded way to deploy a single contract.
The following is an example for deploying Bucket Token contract

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
    --compiler-version v0.8.33 \
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

## Gas Optimization

The contract is optimized with:
- Solidity 0.8.33 with optimizer enabled (200 runs)
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
