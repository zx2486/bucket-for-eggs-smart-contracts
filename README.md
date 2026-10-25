# Bucket for Eggs Smart Contracts

Foundry repository for the Bucket for Eggs on-chain platform. Solidity compiler and optimizer settings are defined in `foundry.toml`.

## Setup

Install Foundry and clone the repository with submodules:

```sh
git clone --recurse-submodules https://github.com/zx2486/bucket-for-eggs-smart-contracts.git
cd bucket-for-eggs-smart-contracts
cp .env.example .env
```

Set `PRIVATE_KEY`, `SEPOLIA_RPC_URL`, and optionally `ETHERSCAN_API_KEY` in `.env`. Do not commit `.env` or publish private keys.

```sh
forge build
forge test
forge coverage
```

## Contracts

- `BucketInfo`: non-upgradeable, platform-owned configuration for token whitelist, prices/feeds, platform fee, pause state, and blacklist.
- `ImplementationRegistry`: platform-owned approval list for UUPS implementations and factories.
- `ActiveBucket`: owner-managed ERC-20 share vault with typed swap entry points.
- `PassiveBucket`: ERC-20 share vault with target allocations and optional DEX rebalancing.
- `PureMembership`: ERC-1155 membership tiers with payment, expiry, renewal, and soulbound transfers.
- `PotentialRugpull`: non-upgradeable vault with an immutable cash ratio that limits owner withdrawals.

Factories create ActiveBucket, PassiveBucket, and PureMembership proxies and hand ownership to their callers. PotentialRugpull is directly instantiated by its factory. The products listed above are the supported contract set for this release.

## Sepolia configuration

`configs/sepolia.json` is the single source of truth for non-secret network/deployment settings: BucketInfo and registry addresses, token/feed entries, vault metadata, PassiveBucket allocations and DEX settings, membership tiers, and PotentialRugpull's cash ratio. Review all addresses and feed values independently before deployment. Replace zero-address placeholders as each platform component is deployed.

`.env` contains secrets and connection settings (`PRIVATE_KEY`, `SEPOLIA_RPC_URL`, optional `ETHERSCAN_API_KEY`) and addresses emitted by deployment scripts for later verification. The vault deploy scripts authorize their factory and approve their implementation; therefore the broadcasting account must be the ImplementationRegistry owner.

## Sepolia deployment

All `deploy-*` shell scripts and Foundry deployment scripts broadcast transactions. Confirm chain, signer, address configuration, and fee/whitelist/feed timelock state before running them. No mainnet deployment workflow is provided here.

1. Deploy BucketInfo and propose the platform fee and missing whitelist additions:

   ```sh
   script/deploy-bucketinfo-sepolia.sh
   ```

2. Copy the printed BucketInfo address to `deployment.bucketInfoAddress` in `configs/sepolia.json`.
3. Wait 48 hours, then apply the fee/whitelist proposals and propose Chainlink feed changes:

   ```sh
   set -a
   source .env
   set +a
   forge script script/DeployBucketInfo.s.sol --sig 'runExecute()' --rpc-url "$SEPOLIA_RPC_URL" --broadcast --gas-estimate-multiplier 400 -vvv
   ```

4. Wait a further 48 hours, then apply feed proposals:

   ```sh
   forge script script/DeployBucketInfo.s.sol --sig 'runExecutePriceFeeds()' --rpc-url "$SEPOLIA_RPC_URL" --broadcast --gas-estimate-multiplier 400 -vvv
   ```

   Check BucketInfo's final fee, whitelist, feeds, and live nonzero token prices.
   ```sh
   forge script script/DeployBucketInfo.s.sol --sig 'runVerify()' --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vvv
   ```
5. Deploy ImplementationRegistry:

   ```sh
   script/deploy-implementationregistry-sepolia.sh
   ```

   The initial owner comes from `deployment.implementationRegistryOwner` (zero means the deployer).

   This script passes an explicit `--gas-estimate-multiplier` (800%, i.e. 8x) instead of
   forge's default 130%. forge's gas estimate for contract creation is computed by its own
   local EVM simulator, which assumes the legacy code-deposit cost of 200 gas/byte of
   deployed runtime bytecode. Live Sepolia was confirmed on 2026-10-19 to charge roughly
   1,650-1,700 gas/byte instead -- about 8x -- while the identical bytecode deployed against
   mainnet matched forge's estimate within ~1%. This is Sepolia-specific.
   
   To get the correct gas estimate, one can call
   ```sh
   cast estimate --rpc-url "$SEPOLIA_RPC_URL" --create <contract creation input data> <contract owner address>
   ```

   recompute the ratio before trusting the hardcoded multiplier again if
   `ImplementationRegistry.sol` changes.
6. Copy the registry address to `deployment.implementationRegistryAddress` in `configs/sepolia.json`.
7. Deploy the configured products:

   ```sh
   script/deploy-activebucket-sepolia.sh
   script/deploy-passivebucket-sepolia.sh
   script/deploy-puremembership-sepolia.sh
   script/deploy-potentialrugpull-sepolia.sh
   ```

   These four scripts also pass an explicit `--gas-estimate-multiplier` (plus the mock-tokens
   script in dev/test flows) for the same Sepolia-specific reason as step 5, but **their 800%
   multipliers are unverified placeholders**, not measured values -- ActiveBucket,
   PassiveBucket, and PureMembership's implementation contracts are large (close to the
   EIP-170 24,576-byte size cap for PassiveBucket in particular) and have not been measured
   with the `cast estimate --create` command above. If the ~1,650-1,700 gas/byte shortfall
   scales with contract size, a contract this large could need a multiplier well above 800%,
   and in the worst case more gas than a single Sepolia transaction is allowed to request
   under the post-Fusaka per-tx gas cap (2^24 = 16,777,216 on mainnet; unconfirmed on
   Sepolia). Measure each implementation contract's real creation cost with
   `cast estimate --create` before a production deploy, divide by forge's local estimate for
   that contract to get the real ratio, and override the corresponding
   `SEPOLIA_*_GAS_MULTIPLIER` environment variable (see each script's header comment) if the
   measured ratio differs from 800%. If the measured real gas exceeds the per-tx cap, the
   deploy is not fixable by raising the multiplier further -- escalate.
8. Save the emitted implementation, factory, proxy/instance addresses in `.env`, then run the corresponding `script/verify-*-sepolia.sh` scripts.

The example config specifies a PassiveBucket allocation of **75% WBTC / 25% ETH**, ActiveBucket's **13% performance fee**, PureMembership tiers of **$10/30 days**, **$50/30 days**, and **$300/365 days**, and a PotentialRugpull **10% cash ratio**. These are configuration values, not validation that the assets or feeds are available or liquid.

## Verification and operations

The `verify-activebucket-sepolia.sh`, `verify-passivebucket-sepolia.sh`, and `verify-puremembership-sepolia.sh` scripts verify implementations and factories where supplied, then read proxy state. `verify-bucketinfo-sepolia.sh` checks BucketInfo on-chain and can submit source verification. These scripts are read-oriented except for Etherscan verification submissions.

The `test-activebucket-sepolia.sh`, `test-passivebucket-sepolia.sh`, `test-puremembership-sepolia.sh`, and `test-potentialrugpull-sepolia.sh` scripts run read-only preflights by default. The first three require explicit `SMOKE_*` variables plus `CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES` before any write; use a dedicated Sepolia test wallet because deposits, rebalances, redemptions, and purchases spend real testnet assets and are not automatically reversible. The ActiveBucket live-swap path is not exercised by the shell test because the contract intentionally does not grant router allowances. PotentialRugpull's smoke script is read-only.

Use a dedicated Sepolia test wallet via `SMOKE_PRIVATE_KEY`; do not use the platform deployer/registry owner key. The requested PassiveBucket sequence can be configured with `SMOKE_DEPOSIT_WEI=500000000000000000`, `SMOKE_REBALANCE=YES`, and `SMOKE_REDEEM_BPS=5000`. The ActiveBucket request can use `SMOKE_DEPOSIT_WEI=100000000000000000`, `SMOKE_REDEEM_FOR_STABLE_BPS=8000`, `SMOKE_STABLE_TOKEN_SYMBOL=USDC`, and `SMOKE_MAX_SLIPPAGE_BPS=50`. Note that `redeemForStable` must swap each non-USDC basket token through the configured router; it can revert if the swap route/liquidity or token allowance requirements are not met. PureMembership accepts `SMOKE_MEMBERSHIP_TOKEN_ID=1` and `SMOKE_MEMBERSHIP_PAY_SECTION=1`; when not supplied, the script calculates an ETH payment cap from the current on-chain ETH price with a default 20% buffer, adjustable by `SMOKE_MEMBERSHIP_BUFFER_BPS`. Supplying `SMOKE_MEMBERSHIP_MAX_PAYMENT` overrides that cap in wei. These are write transactions, consume gas/assets, and are not automatically reversible; run one smoke script at a time after reviewing its preflight output.

Upgrade deployment tooling is intentionally omitted from this public deployment path: upgrades require a separately queued implementation, a 48-hour wait, and live registry approval at execution. Follow the platform's reviewed upgrade procedure rather than bypassing those controls.

`DeployMockTokens.s.sol` and `deploy-mock-tokens-sepolia.sh` are for development/test fixtures only. Mock assets are not production tokens; update configuration and validate feeds deliberately if using them.

## Security

No external audit status is claimed. Never grant vaults allowances as a workaround for typed swap protections. Review the actual transaction/calldata and target addresses before signing.

## License

MIT; see SPDX identifiers in source files.
