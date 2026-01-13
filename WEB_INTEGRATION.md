# Web Integration Guide

This guide shows how to integrate BucketToken with web applications using popular Web3 libraries.

## Table of Contents
- [Ethers.js v6](#ethersjs-v6)
- [Viem](#viem)
- [Web3.js](#web3js)

## Prerequisites

```bash
npm install ethers@6  # or
npm install viem      # or
npm install web3
```

---

## Ethers.js v6

### Setup

```typescript
import { ethers } from 'ethers';

// Contract ABI (minimal for this example)
const BUCKET_TOKEN_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function mint(address to, uint256 amount)",
  "function burn(uint256 amount)",
  "function pause()",
  "function unpause()",
  "function paused() view returns (bool)",
  "event Transfer(address indexed from, address indexed to, uint256 value)",
  "event Approval(address indexed owner, address indexed spender, uint256 value)"
];

const CONTRACT_ADDRESS = "0x..."; // Your deployed contract address

// Connect to provider
const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

// Create contract instance
const bucketToken = new ethers.Contract(
  CONTRACT_ADDRESS,
  BUCKET_TOKEN_ABI,
  signer
);
```

### Read Token Information

```typescript
async function getTokenInfo() {
  const name = await bucketToken.name();
  const symbol = await bucketToken.symbol();
  const decimals = await bucketToken.decimals();
  const totalSupply = await bucketToken.totalSupply();
  
  console.log(`Token: ${name} (${symbol})`);
  console.log(`Decimals: ${decimals}`);
  console.log(`Total Supply: ${ethers.formatUnits(totalSupply, decimals)}`);
}
```

### Check Balance

```typescript
async function getBalance(address: string) {
  const balance = await bucketToken.balanceOf(address);
  const decimals = await bucketToken.decimals();
  return ethers.formatUnits(balance, decimals);
}

// Get current user's balance
const userAddress = await signer.getAddress();
const balance = await getBalance(userAddress);
console.log(`Balance: ${balance} BUCKET`);
```

### Transfer Tokens

```typescript
async function transferTokens(toAddress: string, amount: string) {
  const decimals = await bucketToken.decimals();
  const amountInWei = ethers.parseUnits(amount, decimals);
  
  const tx = await bucketToken.transfer(toAddress, amountInWei);
  console.log(`Transaction hash: ${tx.hash}`);
  
  const receipt = await tx.wait();
  console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
  
  return receipt;
}

// Example: Transfer 100 tokens
await transferTokens("0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb", "100");
```

### Approve and TransferFrom

```typescript
async function approveSpender(spenderAddress: string, amount: string) {
  const decimals = await bucketToken.decimals();
  const amountInWei = ethers.parseUnits(amount, decimals);
  
  const tx = await bucketToken.approve(spenderAddress, amountInWei);
  await tx.wait();
  console.log(`Approved ${amount} BUCKET for ${spenderAddress}`);
}

async function checkAllowance(ownerAddress: string, spenderAddress: string) {
  const allowance = await bucketToken.allowance(ownerAddress, spenderAddress);
  const decimals = await bucketToken.decimals();
  return ethers.formatUnits(allowance, decimals);
}
```

### Listen to Events

```typescript
// Listen for Transfer events
bucketToken.on("Transfer", (from, to, amount, event) => {
  console.log(`Transfer: ${from} -> ${to}: ${ethers.formatUnits(amount, 18)} BUCKET`);
});

// Listen for Approval events
bucketToken.on("Approval", (owner, spender, amount, event) => {
  console.log(`Approval: ${owner} approved ${spender} for ${ethers.formatUnits(amount, 18)} BUCKET`);
});

// Remove listeners when done
bucketToken.removeAllListeners();
```

### Owner Functions

```typescript
// Mint tokens (owner only)
async function mintTokens(toAddress: string, amount: string) {
  const decimals = await bucketToken.decimals();
  const amountInWei = ethers.parseUnits(amount, decimals);
  
  const tx = await bucketToken.mint(toAddress, amountInWei);
  await tx.wait();
  console.log(`Minted ${amount} BUCKET to ${toAddress}`);
}

// Pause contract (owner only)
async function pauseContract() {
  const tx = await bucketToken.pause();
  await tx.wait();
  console.log("Contract paused");
}

// Unpause contract (owner only)
async function unpauseContract() {
  const tx = await bucketToken.unpause();
  await tx.wait();
  console.log("Contract unpaused");
}

// Check if paused
async function isPaused() {
  return await bucketToken.paused();
}
```

---

## Viem

### Setup

```typescript
import { createPublicClient, createWalletClient, custom, http } from 'viem';
import { mainnet } from 'viem/chains';

const CONTRACT_ADDRESS = '0x...' as const;

const publicClient = createPublicClient({
  chain: mainnet,
  transport: http()
});

const walletClient = createWalletClient({
  chain: mainnet,
  transport: custom(window.ethereum)
});

const BUCKET_TOKEN_ABI = [
  // ... same ABI as above
] as const;
```

### Read Token Info

```typescript
async function getTokenInfo() {
  const [name, symbol, decimals, totalSupply] = await publicClient.multicall({
    contracts: [
      { address: CONTRACT_ADDRESS, abi: BUCKET_TOKEN_ABI, functionName: 'name' },
      { address: CONTRACT_ADDRESS, abi: BUCKET_TOKEN_ABI, functionName: 'symbol' },
      { address: CONTRACT_ADDRESS, abi: BUCKET_TOKEN_ABI, functionName: 'decimals' },
      { address: CONTRACT_ADDRESS, abi: BUCKET_TOKEN_ABI, functionName: 'totalSupply' }
    ]
  });

  return { name, symbol, decimals, totalSupply };
}
```

### Transfer Tokens

```typescript
import { parseUnits } from 'viem';

async function transfer(toAddress: string, amount: string) {
  const [account] = await walletClient.getAddresses();
  
  const hash = await walletClient.writeContract({
    address: CONTRACT_ADDRESS,
    abi: BUCKET_TOKEN_ABI,
    functionName: 'transfer',
    args: [toAddress, parseUnits(amount, 18)],
    account
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return receipt;
}
```

### Watch Events

```typescript
const unwatch = publicClient.watchContractEvent({
  address: CONTRACT_ADDRESS,
  abi: BUCKET_TOKEN_ABI,
  eventName: 'Transfer',
  onLogs: (logs) => {
    logs.forEach((log) => {
      console.log(`Transfer from ${log.args.from} to ${log.args.to}`);
    });
  }
});

// Stop watching
unwatch();
```

---

## Web3.js

### Setup

```typescript
import Web3 from 'web3';

const web3 = new Web3(window.ethereum);
const CONTRACT_ADDRESS = '0x...';

const BUCKET_TOKEN_ABI = [
  // ... same ABI as above
];

const bucketToken = new web3.eth.Contract(BUCKET_TOKEN_ABI, CONTRACT_ADDRESS);
```

### Read Token Info

```typescript
async function getTokenInfo() {
  const name = await bucketToken.methods.name().call();
  const symbol = await bucketToken.methods.symbol().call();
  const decimals = await bucketToken.methods.decimals().call();
  const totalSupply = await bucketToken.methods.totalSupply().call();
  
  return { name, symbol, decimals, totalSupply };
}
```

### Transfer Tokens

```typescript
async function transfer(toAddress: string, amount: string) {
  const accounts = await web3.eth.getAccounts();
  const fromAddress = accounts[0];
  
  const amountInWei = web3.utils.toWei(amount, 'ether');
  
  const receipt = await bucketToken.methods
    .transfer(toAddress, amountInWei)
    .send({ from: fromAddress });
    
  return receipt;
}
```

---

## React Example Component

```typescript
import { useState, useEffect } from 'react';
import { ethers } from 'ethers';

function BucketTokenWidget() {
  const [balance, setBalance] = useState<string>('0');
  const [account, setAccount] = useState<string>('');
  const [contract, setContract] = useState<ethers.Contract | null>(null);

  useEffect(() => {
    async function init() {
      if (typeof window.ethereum !== 'undefined') {
        const provider = new ethers.BrowserProvider(window.ethereum);
        const signer = await provider.getSigner();
        const address = await signer.getAddress();
        
        const bucketToken = new ethers.Contract(
          CONTRACT_ADDRESS,
          BUCKET_TOKEN_ABI,
          signer
        );
        
        setAccount(address);
        setContract(bucketToken);
        
        // Get initial balance
        const bal = await bucketToken.balanceOf(address);
        setBalance(ethers.formatUnits(bal, 18));
      }
    }
    
    init();
  }, []);

  const handleTransfer = async (to: string, amount: string) => {
    if (!contract) return;
    
    try {
      const tx = await contract.transfer(
        to,
        ethers.parseUnits(amount, 18)
      );
      await tx.wait();
      
      // Update balance
      const bal = await contract.balanceOf(account);
      setBalance(ethers.formatUnits(bal, 18));
    } catch (error) {
      console.error('Transfer failed:', error);
    }
  };

  return (
    <div>
      <h2>Bucket Token</h2>
      <p>Account: {account}</p>
      <p>Balance: {balance} BUCKET</p>
      {/* Add transfer UI here */}
    </div>
  );
}
```

---

## Best Practices

1. **Error Handling**: Always wrap contract calls in try-catch blocks
2. **Gas Estimation**: Estimate gas before transactions
3. **User Feedback**: Show loading states and transaction confirmations
4. **Security**: Never expose private keys in frontend code
5. **Type Safety**: Use TypeScript for better developer experience
6. **Testing**: Test with testnets before mainnet integration

## Additional Resources

- [Ethers.js Documentation](https://docs.ethers.org/)
- [Viem Documentation](https://viem.sh/)
- [Web3.js Documentation](https://web3js.readthedocs.io/)
- [WalletConnect Integration](https://docs.walletconnect.com/)
- [RainbowKit](https://www.rainbowkit.com/) - React wallet connection
