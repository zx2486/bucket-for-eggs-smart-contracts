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

### Deploying RedeemForStable

The deployment script reads `BucketInfo`, WETH, the Uniswap V3 router/quoter, fee, and stablecoin addresses from `configs/sepolia.json`. It validates that the configured contracts have code. Set `PRIVATE_KEY` and `SEPOLIA_RPC_URL` in the shell environment; the wrapper does not read `.env` and simulates by default.

```sh
script/deploy-redeem-for-stable-sepolia.sh
```

Review the simulation output, then explicitly authorize a Sepolia broadcast:

```sh
export CONFIRM_SEPOLIA_REDEEM_FOR_STABLE_DEPLOY=YES
script/deploy-redeem-for-stable-sepolia.sh --broadcast
```

Record the emitted address in the deployment address book. This deploys the standalone redeemer only; it does not change vaults or configure stable-token whitelisting in `BucketInfo`.

## Verification and operations

The `verify-activebucket-sepolia.sh`, `verify-passivebucket-sepolia.sh`, and `verify-puremembership-sepolia.sh` scripts verify implementations and factories where supplied, then read proxy state. `verify-bucketinfo-sepolia.sh` checks BucketInfo on-chain and can submit source verification. These scripts are read-oriented except for Etherscan verification submissions.

The `test-activebucket-sepolia.sh`, `test-passivebucket-sepolia.sh`, `test-puremembership-sepolia.sh`, and `test-potentialrugpull-sepolia.sh` scripts run read-only preflights by default. The first three require explicit `SMOKE_*` variables plus `CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES` before any write; use a dedicated Sepolia test wallet because deposits, rebalances, redemptions, and purchases spend real testnet assets and are not automatically reversible. The ActiveBucket live-swap path is not exercised by the shell test because the contract intentionally does not grant router allowances. PotentialRugpull's smoke script is read-only.

Use a dedicated Sepolia test wallet via `SMOKE_PRIVATE_KEY`; do not use the platform deployer/registry owner key. The requested PassiveBucket sequence can be configured with `SMOKE_DEPOSIT_WEI=500000000000000000`, `SMOKE_REBALANCE=YES`, and `SMOKE_REDEEM_BPS=5000`. The ActiveBucket request can use `SMOKE_DEPOSIT_WEI=100000000000000000`, `SMOKE_REDEEM_FOR_STABLE_BPS=8000`, `SMOKE_STABLE_TOKEN_SYMBOL=USDC`, and `SMOKE_MAX_SLIPPAGE_BPS=50`. Note that `redeemForStable` must swap each non-USDC basket token through the configured router; it can revert if the swap route/liquidity or token allowance requirements are not met. PureMembership accepts `SMOKE_MEMBERSHIP_TOKEN_ID=1` and `SMOKE_MEMBERSHIP_PAY_SECTION=1`; when not supplied, the script calculates an ETH payment cap from the current on-chain ETH price with a default 20% buffer, adjustable by `SMOKE_MEMBERSHIP_BUFFER_BPS`. Supplying `SMOKE_MEMBERSHIP_MAX_PAYMENT` overrides that cap in wei. These are write transactions, consume gas/assets, and are not automatically reversible; run one smoke script at a time after reviewing its preflight output.

## Upgrading existing Sepolia vaults

Use `script/upgrade-vaults-sepolia.sh` to upgrade ActiveBucket or PassiveBucket proxies through the registry approval and 48-hour timelock. Each run selects exactly one vault kind with `UPGRADE_VAULT_KIND=active` or `passive`; run every phase separately for each kind. The Sepolia-only script checks the targets, signer role, registry, implementation, pending queue, and timelock. It does not source `.env`. Export the required variables in your shell, and never put secret values in command history or documentation.

Before starting, confirm the deployed vault implementations' source commit and have the storage-layout comparison reviewed. Confirm proxy addresses from authoritative deployment records; do not infer them from `.env`, `broadcast/`, or `configs/sepolia.json`. Export proxy addresses for only the selected kind; comma-separate multiple addresses. Each write phase requires a key that has the required role for every target in that phase.

```sh
export SEPOLIA_RPC_URL='<Sepolia RPC URL>'
export UPGRADE_VAULT_KIND=active # or passive
export ACTIVE_BUCKET_PROXY_ADDRESS='<ActiveBucket proxy>[,<another ActiveBucket proxy>]'
# For a passive run, set PASSIVE_BUCKET_PROXY_ADDRESS instead.
```

First run the read-only snapshot phase for the selected vault kind and save the JSON object it prints. Keep it unchanged for the final `check` phase; the check verifies that vault state is preserved across the upgrade. Foundry may query its default simulation sender during this read-only phase; if the RPC rejects that account lookup, set `UPGRADE_SCRIPT_SENDER` to a known on-chain account to override the simulation sender.

```sh
UPGRADE_SCRIPT_SENDER=... UPGRADE_VAULT_KIND=passive UPGRADE_PHASE=snapshot bash script/upgrade-vaults-sepolia.sh
```

Run these phases in order. The wrapper defaults to a dry run; inspect each simulation, then repeat each write phase with `--broadcast` only when the human operator has reviewed and approved the transactions. Broadcasting also requires `CONFIRM_SEPOLIA_VAULT_UPGRADE=YES`:

```sh
export CONFIRM_SEPOLIA_VAULT_UPGRADE=YES
```

1. **Deploy the selected implementation.** The deployer key deploys only the implementation matching `UPGRADE_VAULT_KIND`; record its printed address. The wrapper uses `--gas-estimate-multiplier 400` by default for Sepolia contract creation; override it with `SEPOLIA_UPGRADE_GAS_MULTIPLIER` only if a measured estimate requires adjustment. Foundry may also emit `CREATE2` transactions to the standard deterministic deployment proxy while deploying Solidity libraries linked into the implementation. These are library deployments, not vault calls to an unrelated contract.

   ```sh
   export PRIVATE_KEY='<deployer private key>'
   UPGRADE_PHASE=deploy-impl bash script/upgrade-vaults-sepolia.sh
   UPGRADE_PHASE=deploy-impl bash script/upgrade-vaults-sepolia.sh --broadcast
   ```

2. **Approve implementations.** Set the new implementation addresses printed above. The key must own the `ImplementationRegistry` used by the target proxies.

   ```sh
   # Active run:
   export NEW_ACTIVE_IMPLEMENTATION='<new ActiveBucket implementation>'
   # Passive run:
   # export NEW_PASSIVE_IMPLEMENTATION='<new PassiveBucket implementation>'
   export PRIVATE_KEY='<ImplementationRegistry owner private key>'
   UPGRADE_PHASE=approve bash script/upgrade-vaults-sepolia.sh
   UPGRADE_PHASE=approve bash script/upgrade-vaults-sepolia.sh --broadcast
   ```

3. **Queue each upgrade.** The key must own every target vault. Queueing starts the 48-hour investor exit window.

   ```sh
   export PRIVATE_KEY='<target vault owner private key>'
   UPGRADE_PHASE=queue bash script/upgrade-vaults-sepolia.sh
   UPGRADE_PHASE=queue bash script/upgrade-vaults-sepolia.sh --broadcast
   ```

4. **Wait at least 48 hours**, then execute with the target vault owner's key. Execution re-checks that the implementation is still approved.

   ```sh
   UPGRADE_PHASE=execute bash script/upgrade-vaults-sepolia.sh
   UPGRADE_PHASE=execute bash script/upgrade-vaults-sepolia.sh --broadcast
   ```

5. **Check the result.** Export the exact pre-upgrade snapshot JSON as `UPGRADE_SNAPSHOT_JSON`, then run the read-only check. It verifies implementation and router addresses, cleared queue, preserved vault state and disabled `redeemForStable` stub.

   ```sh
   export UPGRADE_SNAPSHOT_JSON='<paste the complete JSON object printed by the snapshot phase>'
   UPGRADE_PHASE=check bash script/upgrade-vaults-sepolia.sh
   ```

The `--broadcast` commands submit real Sepolia transactions and spend gas; only a human should run them. Do not use a target whose deployed implementation lacks the 48-hour upgrade queue—the script intentionally stops instead of bypassing the timelock. Existing factories retain their immutable old implementations, so newly created vaults require separately deployed and configured factories.

To deploy and authorize a replacement factory after the corresponding implementation has been deployed and approved, reuse `UPGRADE_PHASE=deploy-factory`. It uses `NEW_ACTIVE_IMPLEMENTATION` or `NEW_PASSIVE_IMPLEMENTATION` according to `UPGRADE_VAULT_KIND`, and takes the canonical `BucketInfo` and registry addresses from `configs/sepolia.json`. The signer must own the registry. It deploys the factory, authorizes it in the registry, and prints the new factory address. The default is simulation only; broadcast only after reviewing the simulation:

```sh
export UPGRADE_VAULT_KIND=active # or passive
export NEW_ACTIVE_IMPLEMENTATION='<approved implementation>' # or NEW_PASSIVE_IMPLEMENTATION for passive
export PRIVATE_KEY='<ImplementationRegistry owner private key>'
UPGRADE_PHASE=deploy-factory bash script/upgrade-vaults-sepolia.sh
UPGRADE_PHASE=deploy-factory bash script/upgrade-vaults-sepolia.sh --broadcast
```

Record the printed `NEW_ACTIVE_FACTORY` / `NEW_PASSIVE_FACTORY` address in the authoritative deployment address book and update consumers to use it. This phase does not create a sample vault.

`DeployMockTokens.s.sol` and `deploy-mock-tokens-sepolia.sh` are for development/test fixtures only. Mock assets are not production tokens; update configuration and validate feeds deliberately if using them.

## Security

No external audit status is claimed. Never grant vaults allowances as a workaround for typed swap protections. Review the actual transaction/calldata and target addresses before signing.

## License

MIT; see SPDX identifiers in source files.
