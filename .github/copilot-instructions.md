# Foundry ERC-20 Smart Contract Project

## Project Overview
This is a Foundry-based Ethereum smart contract project for developing, testing, and deploying ERC-20 tokens using OpenZeppelin contracts.

## Development Guidelines
- Use Solidity best practices and follow OpenZeppelin patterns
- Write comprehensive tests using Foundry's testing framework
- All contracts should be gas-optimized and secure
- Use Foundry's forge for building, testing, and deployment
- Follow the Checks-Effects-Interactions pattern for state changes

## Testing Requirements
- Maintain high test coverage (aim for >95%)
- Test all edge cases and failure scenarios
- Use fuzz testing for critical functions
- Test gas consumption for optimization

## Deployment Guidelines
- Always test on testnet before mainnet deployment
- Use environment variables for sensitive data (private keys, API keys)
- Verify contracts on Etherscan after deployment
- Document all deployment addresses and transaction hashes

## Code Style
- Follow Solidity style guide
- Use NatSpec comments for all public/external functions
- Keep contracts modular and focused
- Use events for all state changes
