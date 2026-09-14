# System Overview — townSqVault

*Prepared for inclusion as the System Overview section of the audit report. Commit `b6e5b5c` plus
the uncommitted fee-split change. Deployment targets: Monad, Base, BNB Smart Chain.*

---

## 1. What the protocol does

townSqVault is an ERC-4626 yield vault whose returns are produced offchain. Users deposit a
stablecoin (USDC is the intended asset) and receive `townSqUSD` shares. The deposited capital is
custodied by a `Manager` contract and deployed by an operator into whitelisted external
protocols. Realised profit and loss is reported back onchain by an offchain engine, credited to
the share price, and — for profit — released to holders linearly over a vesting period. Exits go
through a request-then-execute flow with a cooldown.

The design centre is that **the vault is an accounting ledger, not a token custodian**. Four
consequences follow, and they shape most of the risk surface:

1. **`totalAssets()` is an assertion, not a measurement.** It returns
   `virtualAssets - getUnvestedAmount()`, where `virtualAssets` is a running total mutated by
   deposits, redemption requests, and yield reports. It is never reconciled against any token
   balance, and the vault has no visibility into strategy positions.
2. **Yield is trusted input.** `Yield.distributeYield(amount, feeAmount, nonce, isProfit)` books
   whatever it is told. `amount` and `feeAmount` are two *separate* slices of realised P&L —
   `feeAmount` is not deducted from `amount` — and nothing onchain can verify either against
   assets actually held. Percentage caps and a rate limit bound the damage per call; they do not
   validate the figure.
3. **Redemptions must be funded before they can execute.** `_withdraw` transfers from the
   vault's own balance and cannot pull from the `Manager`. A user whose cooldown has elapsed
   still cannot exit until an operator pushes assets in via `Manager.transferToVault`. Liveness
   of withdrawal depends on an offchain actor.
4. **It is not a drop-in ERC-4626.** `withdraw`/`redeem` revert without a prior `requestRedeem`;
   `maxWithdraw`/`maxRedeem` are not overridden and over-report; and allowance-based withdrawal
   is disabled (`_withdraw` requires `caller == owner`). Integrators assuming standard semantics
   will misbehave.

## 2. Scope

| File | SLOC | Description |
| --- | --- | --- |
| `src/TownSqToken.sol` | 309 | ERC-4626 vault. Shares, `virtualAssets` accounting, yield vesting, exit fee, redemption requests and cooldown. |
| `src/Yield.sol` | 150 | Epoch-sequenced profit/loss reporting with caps, rate limiting, replay protection, and treasury fee/debt logic. |
| `src/Manager.sol` | 110 | Custodies all deposited assets. Batched arbitrary calls to whitelisted protocols. Broker for asset/share mutations on behalf of `Yield`. |
| `src/Errors.sol` | 40 | 37 custom errors. |
| `src/Interface/ItownSqUSD.sol` | 46 | Vault interface. |
| `src/Interface/IManager.sol` | 42 | Manager interface and `ManageAssetAndShares` struct. |
| `src/Proxy.sol` | 5 | ERC-1967 proxy wrapper, no added logic. |

**Total in scope: ~702 SLOC** across three upgradeable logic contracts.

Out of scope: OpenZeppelin v5 libraries (`lib/`), tests and scripts, the offchain yield engine,
the operator bot, and the external protocols the `Manager` deploys into. Note that the last
three carry a material share of the system's real risk — see §5.

## 3. Architecture

All three logic contracts are UUPS-upgradeable behind `ERC1967Proxy`. Authorisation is a mix of
role gates and hard-coded contract-address checks.

```
Users ──deposit──────────────► TownSqToken ──forwards all assets──► Manager ──execute──► whitelisted
      ──requestRedeem───────►  (shares +                            (custody)            protocols
      ──withdraw/redeem─────►   accounting)  ◄──transferToVault───┘
                                     ▲                    │
                                     │ transferInRewards  │ mint/burn fee shares
                                     │                    ▼
Rebalancer ──distributeYield──►    Yield ──manageAssetAndShares──► Manager ──► Treasury
```

**Value flow.** Deposits mint shares and are immediately forwarded to the `Manager`; the vault's
own token balance is normally near zero, holding only what has been pushed back to fund pending
redemptions. `Manager.execute` makes arbitrary calls with arbitrary calldata to whitelisted
targets, which is how capital reaches strategies and how it returns.

**Accounting flow.** `Yield` is the only contract permitted to move the share price. It calls
`transferInRewards` on the vault (vesting schedule and `virtualAssets`) and
`Manager.manageAssetAndShares` (treasury share mint/burn). The `Manager` sits in the middle of
the second path purely as an authorisation broker: the vault's `updateTotalAssets`,
`mintVaultToken`, and `burnVaultToken` accept calls only from the `Manager`, and mint/burn are
further restricted to the treasury address.

### 3.1 Yield vesting

Profit does not hit the share price at once. `_updateVestingAmount` adds it to `vestingAmount`
and to `virtualAssets` simultaneously, so `totalAssets()` is initially unchanged and the profit
is released linearly over `vestingPeriod` as `getUnvestedAmount()` decays. This is the system's
principal anti-front-running mechanism: a depositor arriving immediately before a yield report
captures only what vests after their arrival.

Loss is **not** vested. It is applied instantly, first netted against any still-unvested profit
(`_absorbLossIntoUnvested`, which preserves the original vesting end date rather than restarting
the clock), then subtracted from `virtualAssets`. This asymmetry — smooth profit, instant loss —
is deliberate but has consequences worth examining under §5.

### 3.2 Profit fee and treasury debt

On profit, the treasury's slice is minted as shares priced against the fully vested asset base,
so the shares are worth exactly `feeAmount` once the schedule completes. The fee assets are
split by `previewProfitFee`: the portion those shares are already worth against the recognised
base is credited immediately, and the remainder joins the vesting schedule. This keeps the
recognised share price continuous across a distribution rather than stepping upward.

On loss, the treasury's share of the loss is burned from its balance — **clamped** to what it
actually holds, since treasury shares are ordinary transferable ERC-20 and may have been swept.
Any uncovered remainder is booked as `treasuryDebt` and repaid out of future fee entitlements
before the treasury is credited anything further, rather than being silently socialised onto
holders.

### 3.3 Exit flow

`requestRedeem` burns the user's shares immediately and **quotes the asset amount at request
time**, storing it in a per-user `RedeemRequest`. The exit fee is handled by minting
`shares * fee / 100e18` shares to the treasury, which keeps the share price neutral for
remaining holders instead of letting the fee accrue to them implicitly. `virtualAssets` is
reduced by the quoted amount and `totalRequestedAmount` increased.

After `cooldownPeriod`, `withdraw` or `redeem` transfers the quoted amount from the vault's own
balance. Because the quote is frozen at request time, the user is insulated from subsequent share
price movement in both directions — including a loss reported during their cooldown. Only one
pending request per address is permitted. `redeemFor` lets the `Manager` execute a redemption
with **no cooldown check**.

### 3.4 Parameters

| Parameter | Contract | Default | Bound |
| --- | --- | --- | --- |
| `cooldownPeriod` | vault | set at init | ≤ 7 days |
| `vestingPeriod` | vault | set at init | ≤ 30 days |
| `fee` (exit fee) | vault | `0` | ≤ `1e18`, i.e. 1% (`100e18` == 100%) |
| `maxYieldPercentage` | Yield | `50` (0.5%) | 1…10 000 bps of `totalAssets()` |
| `maxFeePercentage` | Yield | `5000` (50%) | 0…10 000 bps of `amount` |
| `minDistributionInterval` | Yield | `79 200` (22 h) | > 0 |
| `minSharesInVaultToken` | Manager | unset | > 0 once set |
| `maxRedeemCap` | Manager | `0` | `0` == uncapped |

The underlying asset must have **≤ 18 decimals**: `_decimalsOffset()` returns
`18 - asset.decimals()` and reverts on underflow.

## 4. Trust model

| Role | Held by | Capabilities |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | multi-sig | Upgrade all three contracts; grant/revoke every role. **No timelock.** |
| `ADMIN_ROLE` | multi-sig | All parameter setters, whitelist management, pause/unpause, `emergencyRecover`. |
| `OPERATOR_ROLE` | bot (hot key) | `Manager.execute` — arbitrary calls to whitelisted targets from the address holding every deposited asset; `redeemFor`; `transferToVault`. |
| `REBALANCER_ROLE` | offchain engine | `Yield.distributeYield`. |
| Treasury | address | Recipient of fee shares; bears loss via share burn. Ordinary EOA/contract, shares are transferable. |

Users are trusted with nothing. The privileged set, however, is unusually powerful, and three
points deserve emphasis in the report's risk framing:

- **`OPERATOR_ROLE` has a total-loss blast radius.** It makes arbitrary calls with arbitrary
  calldata from the custody address. The admin-managed whitelist is the only constraint on
  destination, and it does not exclude the underlying asset token, so an `approve` or `transfer`
  to a whitelisted target is expressible.
- **`REBALANCER_ROLE` sets the share price.** A wrong or malicious `amount`/`feeAmount` is
  indistinguishable onchain from a correct one. Caps bound per-call damage to 0.5% of
  `totalAssets()` at defaults, but the admin can raise `maxYieldPercentage` to 100%.
- **Upgrades are immediate.** `_authorizeUpgrade` on all three contracts is gated only by
  `DEFAULT_ADMIN_ROLE`, with no delay, so a compromised admin key is an instant total loss and
  users have no window to exit.

## 5. Areas warranting attention

Offered as orientation for the findings section, not as findings themselves.

- **The profit/loss asymmetry.** Profit vests; loss is instantaneous. A `distributeYield` loss
  report is visible in the public mempool before it executes, and `requestRedeem` freezes an
  exit quote at the pre-loss price. Whether this is exploitable in practice depends on mempool
  visibility on the target chains and on the redemption funding constraint (§1.3), both of which
  merit explicit analysis.
- **Reconciliation.** Nothing forces `virtualAssets` to correspond to assets held. Drift from a
  mis-specified `amount + feeAmount` is permanent and compounds silently across epochs.
- **Withdrawal liveness.** Pending redemptions depend on an operator funding the vault, and
  `emergencyRecover` can withdraw assets already earmarked for them. Withdrawals are also
  blocked while paused.
- **Replay scope.** The `distributeYield` dedupe hash omits `feeAmount`, so it does not
  distinguish two reports differing only in the fee.
- **Decimals and rounding.** The vault runs a non-standard `_decimalsOffset` against a 6-decimal
  asset, with several hand-rolled `mulDiv` paths in the fee and vesting logic. Directional
  rounding is worth verifying case by case.
- **Compiler hygiene.** Floating pragmas (`^0.8.19` in the vault, `^0.8.20` elsewhere) with no
  pinned version; `via_ir` with `optimizer_runs = 200`.

## 6. Testing and existing documentation

92 tests pass across 13 suites (one fork suite is excluded — its pinned block is unavailable
from a non-archive RPC). Coverage is strongest where it matters: dedicated PoC suites exist for
loss handling, vesting semantics, redemption funding, exit fees, the `totalAssets()` underflow
question, fee share pricing, and the upgrade path. There is **no stateful invariant/fuzz suite**,
which is the most significant gap given that the core risk is accounting drift over long
sequences of operations.

The team maintains its own documentation that the audit should read rather than rediscover:

| Document | Contents |
| --- | --- |
| `docs/ARCHITECTURE.md` | Component and flow detail. |
| `docs/INVARIANTS.md` | Stated invariants across accounting, vesting, economics, access control, upgrade safety, liveness. |
| `docs/KNOWN_ISSUES.md` | Accepted risks (K-01…K-05), intentional design decisions (D-…), and untriaged open questions (Q-01…Q-11). |

`KNOWN_ISSUES.md` is unusually candid and pre-empts several findings an auditor would otherwise
raise — accepted risks around the trusted yield engine, manual redemption funding, operator blast
radius, and absent timelock are all documented as deliberate. The report should engage with these
as accepted risks rather than re-report them as discoveries, while stating plainly where an
accepted risk is, in our assessment, under-priced.

> **Q-11 requires action independent of this audit:** a live Alchemy API key is present in git
> history. Rotate it before this repository is shared with any additional party, including the
> audit team.
