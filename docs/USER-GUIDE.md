# User Guide

How townSqUSD works, written for depositors. Where `ARCHITECTURE.md` and `ROLES.md`
describe the system for auditors, this document describes what you should expect as a user
— including the parts that differ from a standard vault.

Read the [Before you deposit](#before-you-deposit) section. It covers the things that are
genuinely different here and that will otherwise surprise you.

## What this is

townSqUSD is a yield-bearing vault. You deposit a stablecoin and receive `townSqUSD`
shares. The yield is produced by a trading strategy operated **offchain**, and profit or
loss is reported back to the vault periodically. Your shares gain (or lose) value as those
reports land; the number of shares you hold does not change.

It is an ERC-4626 vault, but **not a drop-in one** — withdrawal works differently. See
[Withdrawing](#withdrawing).

```
   You ──deposit──▶ Vault ──▶ Manager ──▶ offchain trading strategy
                     │                              │
   You ◀──withdraw── Vault ◀──── funded back ───────┘
                     ▲
                     └── profit/loss reported each epoch
```

## The share price

Your position is worth `shares x share price`. The share price starts at 1 and moves only
when the operator reports results.

```bash
# What one share is worth right now
cast call <vault> "exchangeRate()(uint256)" --rpc-url <rpc>

# Your share balance
cast call <vault> "balanceOf(address)(uint256)" <you> --rpc-url <rpc>

# What your shares would be worth if you redeemed now (net of fee)
cast call <vault> "previewRedeem(uint256)(uint256)" <shares> --rpc-url <rpc>
```

**Profit arrives gradually, not all at once.** When a profit is reported, it is released
into the share price linearly over the *vesting period* rather than instantly. This stops
someone from depositing just before a report and capturing yield they were not exposed to.
Practically: a reported profit raises your position's value smoothly over the following
days.

**Losses are applied immediately**, with no vesting. Unvested profit is used to cushion a
loss first — if a loss is smaller than the profit still vesting, the share price does not
move at all.

Note your shares always have **18 decimals**, even when the underlying asset has 6 (USDC).
Do not assume share amounts and asset amounts use the same scale.

## Depositing

Standard ERC-4626. Approve the vault, then deposit.

```bash
cast send <asset> "approve(address,uint256)" <vault> <amount> --rpc-url <rpc> ...
cast send <vault> "deposit(uint256,address)" <amount> <you> --rpc-url <rpc> ...
```

- **There is no deposit fee.** Entering the vault is free; the fee is charged only on exit.
- There is a **minimum deposit size**, expressed in shares (`minSharesInVaultToken`). Very
  small deposits revert.
- Your assets do not stay in the vault. They are forwarded immediately to the Manager
  contract, which deploys them to the strategy. This matters for withdrawal — see below.

## Withdrawing

**This is the part that differs from a normal vault.** Withdrawal is a two-step process
with a waiting period, and you cannot skip it.

### Step 1 — request

```bash
cast send <vault> "requestRedeem(uint256)" <shares> --rpc-url <rpc> ...
```

What happens the moment you call this:

- Your shares are **burned immediately**.
- The asset amount you will receive is **calculated and locked in now**, at the current
  share price, net of the exit fee.
- A cooldown timer starts.

### Step 2 — collect, after the cooldown

```bash
# Is it ready?
cast call <vault> "canExecuteRedeem(address)(bool)" <you> --rpc-url <rpc>

# What am I owed, and when did I ask?
cast call <vault> "getRedeemRequest(address)(uint256,uint256,uint256,bool)" <you> --rpc-url <rpc>

# Collect — `shares` must exactly equal the value stored in your request
cast send <vault> "redeem(uint256,address,address)" <shares> <you> <you> --rpc-url <rpc> ...
```

### Rules that will trip you up

- **Your amount is fixed at request time.** Once you request, you are no longer exposed to
  the share price. If a profit is reported during your cooldown you do **not** receive it.
  If a loss is reported you are **not** affected. Requesting is an exit from the strategy,
  not a queued sale.
- **One request at a time.** `requestRedeem` reverts if you already have a pending request.
  You cannot add to it, and there is no cancel function — once requested, you are committed
  to that amount.
- **You must call `withdraw`/`redeem` yourself.** The vault requires the caller to be the
  owner of the request. Approving another address does not let it withdraw for you — this
  intentionally breaks the standard ERC-4626 allowance flow.
- **The amount must match exactly.** `redeem(shares)` requires `shares` to equal your
  request's stored share count exactly; `withdraw(assets)` requires an exact asset match.
  Partial collection is not supported. Read your request and pass the stored value back.
- **`maxWithdraw` and `maxRedeem` are not reliable here.** They are not overridden and will
  over-report what you can actually withdraw. Use `getRedeemRequest` instead.
- There may be a **cap on the size of a single request** (`maxRedeemCap`). If your position
  exceeds it, exit across multiple requests, one after another.

### Current parameters

These are set by governance and can change. **Read them live** — do not rely on the values
below.

| Parameter | Deploy-time value | Maximum | Read with |
|---|---|---|---|
| Cooldown period | 1 day (86400s) | 7 days | `cooldownPeriod()` |
| Vesting period | 7 days (604800s) | 30 days | `vestingPeriod()` |
| Exit fee | set by governance | 1% | `fee()` |
| Max per request | set by governance | — (`0` = no cap) | `maxRedeemCap(<vault>)` on the Manager |

```bash
cast call <vault> "cooldownPeriod()(uint256)" --rpc-url <rpc>
cast call <vault> "fee()(uint256)" --rpc-url <rpc>
```

The exit fee is scaled such that `1e18` = 1%, and 1% is the hard-coded maximum — governance
cannot set it higher.

## Fees

You pay **one** fee as a depositor: the **exit fee**, charged when you request a
redemption. It is capped at 1% and is deducted from the amount you are quoted.

Separately, the protocol treasury takes a **performance fee** on reported profit. This is
not billed to you directly — it is taken out of the yield before the remainder reaches the
share price. It is currently capped at 50% of reported profit, and governance can raise
that cap.

There is no deposit fee and no ongoing management fee.

## Before you deposit

Plainly, the risks that are specific to this design. These are documented in the
protocol's own `KNOWN_ISSUES.md` and `INVARIANTS.md`.

**Your funds are not held onchain.** Deposits are forwarded to the Manager contract and
deployed into an offchain trading strategy. What the vault holds is an accounting record of
what you are owed, not the assets themselves.

**Withdrawal depends on the operator funding the vault.** The vault keeps **no liquidity
buffer**. When your cooldown ends, the assets to pay you must be pushed back onchain by an
operator first. If that does not happen, your redemption cannot execute even though it has
matured — the contract cannot force it. The protocol's own invariant list records that
*"users can always eventually withdraw"* **does not hold**.

**The yield figures are not verifiable onchain.** The vault has no view of the strategy's
actual balances. Profit and loss are values asserted by an offchain engine, and the share
price is whatever those reports say it is. Per-report size is capped (by default 0.5% of
vault assets per report, at most one report roughly every 22 hours), but the direction and
the honesty of the reports are a trust assumption.

**Withdrawals can be paused.** An admin can pause the vault, and pause blocks `withdraw`
and `redeem` as well as deposits. A pause makes matured redemptions temporarily
uncollectable.

**The contracts are upgradeable, with no timelock.** All three contracts can be replaced by
the admin multisig at any time, taking effect immediately. There is no delay in which to
exit ahead of a change you disagree with.

**Admin powers are broad.** The admin can change the fee, cooldown, and caps, and can
transfer assets out of the vault via an emergency-recovery function — including assets
already earmarked for pending redemptions. See `ROLES.md` for the full enumeration.

**An operator can settle your request before the cooldown ends.** `redeemFor`, callable by
the Manager, pays out a matured *or unmatured* request to you at your locked amount. It can
only pay you, at the amount already fixed — but it can end your position earlier than you
planned.

## Checking on your position

```bash
# Pending request: shares, assets, timestamp, exists
cast call <vault> "getRedeemRequest(address)(uint256,uint256,uint256,bool)" <you> --rpc-url <rpc>

# Ready to collect?
cast call <vault> "canExecuteRedeem(address)(bool)" <you> --rpc-url <rpc>

# Vault-wide: total assets recognised, and profit still vesting
cast call <vault> "totalAssets()(uint256)" --rpc-url <rpc>
cast call <vault> "getUnvestedAmount()(uint256)" --rpc-url <rpc>

# Total assets owed to everyone with a pending request
cast call <vault> "totalRequestedAmount()(uint256)" --rpc-url <rpc>
```

Comparing `totalRequestedAmount()` against the vault's actual asset balance tells you
whether pending redemptions are currently funded:

```bash
cast call <asset> "balanceOf(address)(uint256)" <vault> --rpc-url <rpc>
```

If that balance is below `totalRequestedAmount()`, not every matured request can be paid
right now.

## Events worth watching

| Event | Meaning |
|---|---|
| `RedemptionRequested` | Your request was recorded, with the locked amount |
| `Withdraw` / `WithdrawalExecuted` | A redemption was paid out |
| `DistributeYield` | An epoch's profit or loss was reported (this is what moves the share price) |
| `Paused` / `Unpaused` | Deposits and withdrawals halted or resumed |
| `FeeSet`, `CooldownPeriodUpdated` | Terms changed |
| `Upgraded` | Contract implementation replaced |

## Quick reference

| I want to | Call |
|---|---|
| Deposit assets | `deposit(assets, receiver)` |
| Deposit for an exact share count | `mint(shares, receiver)` |
| Start withdrawing | `requestRedeem(shares)` |
| Check if ready | `canExecuteRedeem(you)` |
| See what I am owed | `getRedeemRequest(you)` |
| Collect | `redeem(shares, receiver, owner)` — exact match, self only |
| Check share price | `exchangeRate()` |

## Further reading

- `ARCHITECTURE.md` — how the contracts fit together and where the trust boundaries are
- `ROLES.md` — every privileged role and what it can do
- `KNOWN_ISSUES.md` — accepted risks and intentional design decisions
- `INVARIANTS.md` — the properties the protocol does and does not guarantee
