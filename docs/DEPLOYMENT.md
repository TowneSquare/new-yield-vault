# Deployment Plan

**Status: incomplete — addresses and roles are not yet pinned.** This document records
what must be decided before the audit and before mainnet. Nothing here is verified onchain.

## Target Chains

Monad mainnet, Base, BNB Smart Chain. `README.md` has been updated to match.

> Note for auditors: `test/testCrossChain.t.sol` still forks Ethereum mainnet and
> `rpc.katana.network`, reflecting an earlier chain selection. The fork tests have not been
> retargeted to Monad/Base/BNB and do not exercise the intended deployment chains.

## Deployment Order

`script/Deploy.s.sol` deploys implementations and proxies for `Yield`, `Manager`, and
`townSqToken`. Because the three contracts reference each other cyclically
(see `ARCHITECTURE.md`), wiring completes in follow-up transactions.

Required post-deployment configuration — **the protocol is not safe to use until all of
these have landed and been verified:**

| # | Call | Contract | Why it matters |
|--:|---|---|---|
| 1 | `setTreasury(treasury)` | Manager | Unset ⇒ `treasury == address(0)` ⇒ any deposit with a non-zero fee reverts in `_mint` |
| 2 | `setManagerAndYield(yield, townSqToken)` | Manager | Unset `townSqToken` ⇒ `Yield.getTownSqToken()` returns `address(0)` and distribution reverts |
| 3 | `setManager(manager)` | Yield | Unset ⇒ distribution reverts |
| 4 | `setMinSharesInVaultToken(vault, minShares)` | Manager | **Must be non-zero before first deposit** — `_deposit` requires `shares >= minShares`; `setMinSharesInVaultToken` rejects `0`, so leaving it unset means the check passes trivially at `0` |
| 5 | `setMaxRedeemCap(vault, cap)` | Manager | `0` disables the cap (treated as unlimited in `requestRedeem`) |
| 6 | `setFee(fee)` | townSqToken | Defaults to `0` |
| 7 | Grant `OPERATOR_ROLE`, `REBALANCER_ROLE` | Manager / Yield | Set in `initialize`; verify the addresses |
| 8 | `setWhitelistedAddresses([...], [...])` | Manager | Required before `execute` can deploy capital |

**Verify wiring before the first deposit**, in both directions:

```bash
cast call $MANAGER "townSqToken()(address)"  --rpc-url $RPC   # == $VAULT
cast call $MANAGER "yield()(address)"        --rpc-url $RPC   # == $YIELD
cast call $MANAGER "treasury()(address)"     --rpc-url $RPC   # != 0x0
cast call $VAULT   "manager()(address)"      --rpc-url $RPC   # == $MANAGER
cast call $YIELD   "manager()(address)"      --rpc-url $RPC   # == $MANAGER
cast call $YIELD   "getTownSqToken()(address)" --rpc-url $RPC # == $VAULT
```

## Addresses — TBD

| Chain | Underlying asset | Address | Decimals | Verified |
|---|---|---|---:|---|
| Monad | USDC | **TBD** | **TBD** | ❌ |
| Base | USDC | **TBD** | **TBD** | ❌ |
| BNB Chain | USDC | **TBD** | **TBD** | ❌ |

**Do not populate this table from memory.** Confirm each address against the issuer's
official documentation, then verify onchain before use:

```bash
cast code  $ASSET --rpc-url $RPC                 # must be non-empty
cast call  $ASSET "symbol()(string)"   --rpc-url $RPC
cast call  $ASSET "decimals()(uint8)"  --rpc-url $RPC
```

### Decimals is the load-bearing check

Two places in the code depend on the underlying asset's decimals:

- `_decimalsOffset()` and `exchangeRateScaled()` compute `18 - asset.decimals()` and
  **revert on underflow for any asset with more than 18 decimals**.
- The README's cross-chain exchange-rate arithmetic is written entirely in `1e6`
  ("`1e6` is used for 6 decimal precision (e.g., USDC)").

**USDC does not have 6 decimals on every chain.** On BNB Chain in particular, the widely
used Binance-Peg USDC is an 18-decimal token, and native/bridged variants differ across
chains generally. If any target chain's chosen asset is not 6 decimals, the offchain
engine's `1e6` scaling is wrong for that vault and will misprice yield — while the
contracts themselves keep working, because they read `decimals()` dynamically. This is a
silent, chain-specific mispricing risk, and it is the most likely deployment-time bug in
the current design.

Per chain, confirm and record: (a) native vs bridged USDC, (b) `decimals()`, (c) whether
the offchain engine scales per-vault rather than assuming `1e6`.

### Also confirm per chain

- **Upgradeability of the asset.** USDC is itself an upgradeable proxy with a blocklist on
  most chains. A blocked vault or treasury address would brick redemptions or fee minting.
- **`PUSH0` / EVM version.** `foundry.toml` pins no `evm_version`, so Foundry's default
  applies (Cancun for recent versions, which emits `PUSH0`). Confirm each target chain
  supports the opcodes emitted, and pin `evm_version` explicitly rather than relying on the
  default — this is exactly the kind of thing that differs on a newer chain like Monad.
- **Multisig availability.** Confirm a Safe (or equivalent) is deployed on each chain
  before assigning `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE`; see the role table below.

## Role Assignments — TBD

| Role | Holder | Type | Chain-specific? |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | **TBD** | Multisig required (holds upgrade rights on all three contracts) | |
| `ADMIN_ROLE` | **TBD** | Multisig required | |
| `OPERATOR_ROLE` | **TBD** | Hot key / bot — see K-04 | |
| `REBALANCER_ROLE` | **TBD** | Yield engine key | |
| `treasury` | **TBD** | Fee recipient | |

`OPERATOR_ROLE` can make arbitrary calls to whitelisted targets from the address holding
all deposited assets (`KNOWN_ISSUES.md` K-04, Q-01). Treat it as a hot key with
total-loss blast radius and scope the whitelist accordingly.

## Pre-Deployment Checklist

- [x] Reconcile the chain list between README and scope
- [ ] **Rotate the leaked Alchemy key (Q-11)** and move all fork RPC URLs to env vars
- [ ] Retarget fork tests to Monad/Base/BNB and pin fork block numbers
- [ ] Pin `solidity` version in `foundry.toml`; replace floating pragmas (Q-07)
- [ ] Pin `evm_version` in `foundry.toml` and confirm opcode support per chain
- [ ] Populate and onchain-verify all asset addresses and decimals
- [ ] Confirm the offchain engine scales per-vault by that vault's decimals, not `1e6`
- [ ] Confirm multisigs exist on each chain; assign admin roles to them
- [ ] `forge script script/Deploy.s.sol --rpc-url $RPC` dry run per chain (no `--broadcast`)
- [ ] Capture `forge inspect <C> storage-layout` for all three contracts as the upgrade baseline (I-19)
- [ ] Run all 8 post-deployment configuration calls
- [ ] Verify wiring in both directions with the `cast` commands above
- [ ] Verify contracts on each block explorer
- [ ] Smoke test on testnet: deposit → distributeYield → requestRedeem → fund vault → redeem

## Post-Deployment Verification

```bash
cast code $VAULT --rpc-url $RPC
cast call $VAULT "asset()(address)"        --rpc-url $RPC
cast call $VAULT "totalAssets()(uint256)"  --rpc-url $RPC
cast call $VAULT "cooldownPeriod()(uint256)" --rpc-url $RPC
cast call $VAULT "fee()(uint256)"          --rpc-url $RPC

# Confirm the implementation behind each proxy (ERC-1967 slot)
cast storage $VAULT 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC
```

## Monitoring

At minimum, alert on:
- `totalRequestedAmount` vs `asset.balanceOf(vault)` — the pending-redemption backing gap (I-03)
- `DistributeYield` events: cadence, and `amount` relative to the `maxYieldPercentage` bound
- `EmergencyRecovery` and `Paused` events
- `WhitelistUpdated` — every entry added is new blast radius for `execute`
- Any `Upgraded` event on the three proxies
