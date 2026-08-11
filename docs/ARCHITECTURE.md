# Architecture

Companion to the README, written for auditors. Where the README describes intended
behaviour, this document states what the code actually does and where the trust
boundaries sit.

## Contract Relationships

```
                    ┌──────────────────────┐
   user ──deposit──▶│    townSqToken       │──safeTransferFrom──▶ Manager
   user ──request──▶│  (ERC4626, UUPS)     │                      (holds all assets)
   user ──withdraw─▶│                      │◀──transferToVault────┘
                    └──────────┬───────────┘
                               │ reads manager.treasury()
                               │ reads manager.yield()
                               │ reads manager.maxRedeemCap()
                               │ reads manager.minSharesInVaultToken()
                               ▼
                    ┌──────────────────────┐
                    │      Manager         │──call()──▶ whitelisted DeFi protocols
                    │       (UUPS)         │
                    └──────────▲───────────┘
                               │ manageAssetAndShares()
                    ┌──────────┴───────────┐
   rebalancer ─────▶│       Yield          │──transferInRewards()──▶ townSqToken
                    │       (UUPS)         │
                    └──────────────────────┘
```

All three core contracts sit behind `townSqProxy` (ERC1967 + UUPS).

### Cyclic dependency

`townSqToken.manager` → `Manager`, and `Manager.townSqToken` → `townSqToken`. Both are
admin-settable after deployment (`setManager`, `setManagerAndYield`). `Yield.manager` is
also admin-settable and reads the vault address *through* the Manager
(`getTownSqToken()` → `IManager(manager).townSqToken()`).

**Consequence for auditors:** there is no onchain guarantee that the three contracts
point at each other consistently. A misconfigured `Manager.townSqToken` redirects
`Yield`'s distributions to a different vault while `townSqToken` still authorises the old
`Yield`. Wiring correctness is entirely a deployment/governance concern.

## Where Assets Live

This is the single most counter-intuitive part of the system.

| Location | What is there |
|---|---|
| `Manager` | **All deposited assets.** `_deposit` does `safeTransferFrom(caller, manager, assets)` — the vault never holds deposits. |
| External protocols | Assets deployed by `Manager.execute()` via whitelisted calls |
| `townSqToken` | **Only** whatever has been explicitly pushed back for redemptions |

`townSqToken.totalAssets()` returns `virtualAssets - getUnvestedAmount()`. It is an
**accounting figure**, not a balance — it is never reconciled against any real token
balance anywhere. `virtualAssets` moves only through `_updateTotalAssets`, called from
deposit, redeem-request, `transferInRewards`, and `Manager.manageAssetAndShares`.

**Redemption funding is a manual, offchain-triggered step.** `_withdraw` does
`safeTransfer` from the vault's *own* balance and has no ability to pull from the Manager.
A user whose cooldown has elapsed cannot redeem until someone moves assets into the vault
— either the operator via `Manager.transferToVault` (OPERATOR_ROLE) or any address via a
plain ERC-20 transfer. This is characterised by `test/POC-RedeemFunding.t.sol`.

## Access Control

| Role | Held by | Capabilities |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Multisig (intended) | **UUPS upgrades on all three contracts**, grant/revoke all roles |
| `ADMIN_ROLE` | Multisig (intended) | `setManager`, `setCooldownPeriod`, `setVestingPeriod`, `setFee`, `pause`/`unpause`, `emergencyRecover`, `setWhitelistedAddresses`, `setTreasury`, `setManagerAndYield`, `setMinSharesInVaultToken`, `setMaxRedeemCap`, `setMinDistributionInterval`, `setMaxYieldPercentage`, `setMaxFeePercentage` |
| `OPERATOR_ROLE` | Executor (EOA/bot) | `Manager.execute` (arbitrary calls to whitelisted targets), `Manager.redeemFor`, `Manager.transferToVault` |
| `REBALANCER_ROLE` | Yield engine | `Yield.distributeYield` |
| — | `Manager` only | `townSqToken.updateTotalAssets`, `mintVaultToken`, `burnVaultToken`, `redeemFor` |
| — | `Yield` only | `townSqToken.transferInRewards`, `Manager.manageAssetAndShares` |
| — | anyone | `deposit`, `mint`, `requestRedeem`, `withdraw`, `redeem` (own request only) |

`mintVaultToken` / `burnVaultToken` are additionally constrained to
`to == manager.treasury()`, so the Manager cannot mint shares to arbitrary addresses.

**Privileged-role reality check.** `OPERATOR_ROLE` holds `Manager.execute`, which makes
arbitrary calls with arbitrary calldata to any whitelisted target, from the address that
custodies every deposited asset. The whitelist (set by ADMIN_ROLE) is the only constraint
on where funds can go — it excludes `townSqToken` and `yield` but nothing else. A
compromised operator key plus one over-broad whitelist entry is a total-loss path. This
should be treated as the primary centralisation risk of the system.

## Trust Model

**Fully trusted (no onchain verification):**

- **The offchain yield engine.** `distributeYield` accepts `amount` and `feeAmount` as
  independent trusted values. They are two *separate* slices of realised P&L —
  `feeAmount` is **not** deducted from `amount`. Nothing onchain can check that
  `amount + feeAmount` matches what strategies actually earned, because the vault cannot
  see strategy balances. Overstating `amount` permanently inflates `totalAssets()` against
  assets that do not exist. The only bounds are `amount ≤ totalAssets * maxYieldPercentage
  / 10_000` (default 50 → 0.5%) and `feeAmount ≤ amount * maxFeePercentage / 10_000`
  (default 5000 → 50%), plus a `minDistributionInterval` (default 79200s ≈ 22h).
- **ADMIN_ROLE / DEFAULT_ADMIN_ROLE.** Upgradeable with no timelock in scope.
- **OPERATOR_ROLE.** See above.
- **Whitelisted protocols.** `Manager.execute` return data is bubbled but not validated.

**Partially trusted:**

- **Underlying asset.** Assumed standard ERC-20, ≤ 18 decimals, no fee-on-transfer, no
  rebasing, non-reentrant. USDC is the intended asset; note USDC is itself upgradeable and
  has a blocklist (a blocked vault or treasury address would brick redemptions/fees).

## External Dependencies

| Dependency | Version / Address | Trust assumption |
|---|---|---|
| OpenZeppelin Contracts | v5.7.0 | Fully trusted |
| OpenZeppelin Contracts Upgradeable | v5.7.0 | Fully trusted |
| Underlying asset (USDC intended) | **not pinned** — see `DEPLOYMENT.md` | Standard ERC-20, ≤18 decimals |
| Yield-generating protocols | **not yet specified** | Fully trusted once whitelisted |

No oracle is used. Share price is set entirely by `distributeYield`, i.e. by the offchain
engine. There is no onchain price feed and therefore no oracle-manipulation surface — the
equivalent risk lives entirely in the trusted-input path.

`ReentrancyGuard` is imported from the **non**-upgradeable package. This is intentional
(OZ v5 uses ERC-7201 namespaced storage, so it holds no sequential slot) and is noted in a
code comment; auditors should confirm the reasoning holds for v5.7.0.

## Value Flow

**Deposit.** User approves vault → `deposit(assets, receiver)` → fee shares minted to
treasury, net shares minted to receiver → `virtualAssets += assets` → assets transferred
to Manager → operator deploys via `execute()`.

**Yield (profit).** Engine calls `distributeYield(amount, feeAmount, nonce, true)` →
`transferInRewards(amount, true)` → `_updateVestingAmount` rolls any unvested remainder
into a fresh schedule, restarts the clock, and adds `amount` to `virtualAssets` → fee
shares minted to treasury. `amount` is recognised linearly over `vestingPeriod` via
`getUnvestedAmount()`, which is subtracted from `totalAssets()`.

**Yield (loss).** `transferInRewards(amount, false)` → `virtualAssets -= amount`
**immediately, with no vesting** → `feeAmount` worth of treasury shares burned. Loss
handling is asymmetric with profit by design; see `test/POC-LossHandling.t.sol`.

**Redemption.** `requestRedeem(shares)` burns shares immediately, computes
`assets = previewRedeem(shares)`, **locks that asset amount in**, decrements
`virtualAssets`, and increments `totalRequestedAmount`. After `cooldownPeriod`,
`withdraw`/`redeem` transfers exactly the locked amount from the vault's balance.

**Because the asset amount is fixed at request time, a pending redeemer is fully
insulated from any loss booked during their cooldown; remaining holders absorb it.**
Symmetrically, they forgo any profit. This is characterised in
`test/POC-LossHandling.t.sol::test_Loss_PendingRedeemersAreInsulated_RemainingHoldersAbsorb`.

## Vesting Semantics

`vestingPeriod` is **not** a per-user lockup. It smooths *recognition* of distributed
yield across the whole vault. A depositor's shares appreciate the very next second, with
no lockup. What it prevents is capturing an entire lump sum by depositing immediately
before a distribution — but it only *smooths* that capture, it does not eliminate it: a
mid-schedule depositor still shares in the unvested remainder of yield earned before they
arrived. See `test/POC-VestingSemantics.t.sol`.

## ERC4626 Conformance

The vault deliberately diverges from the standard. Integrators treating it as a drop-in
ERC4626 will break. See `docs/KNOWN_ISSUES.md` (D-01, D-02) for specifics.
