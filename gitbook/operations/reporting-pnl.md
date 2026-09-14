---
description: Operational runbook for the REBALANCER_ROLE holder reporting each epoch's realised P&L.
---

# Reporting P&L

{% hint style="info" %}
This page is for the operator holding `REBALANCER_ROLE`. Depositors cannot call any of
these functions — see [How profit and loss reach your shares](../reference/functions.md#how-profit-and-loss-reach-your-shares)
for what the reports mean from a user's perspective.
{% endhint %}

Reporting P&L is **one function call**. `distributeYield` is the only function
`REBALANCER_ROLE` gates anywhere in the protocol:

```solidity
distributeYield(uint256 amount, uint256 feeAmount, uint256 nonce, bool isProfit)
```

Everything else below is preflight work to compute arguments that will not revert — and to
avoid the one class of mistake that cannot be undone.

## Before you start

```bash
YIELD=<yield proxy>
VAULT=<vault proxy>
RPC=<rpc url>
```

## Step by step

{% stepper %}
{% step %}
### Read the current epoch

```bash
cast call $YIELD "epoch()(uint256)" --rpc-url $RPC
```

`nonce` must equal `epoch + 1` **exactly**. Off by one reverts with `InvalidEpoch`. There
is no way to skip an epoch or backfill a missed one.
{% endstep %}

{% step %}
### Confirm the rate limit has elapsed

```bash
cast call $YIELD "lastDistributionTime()(uint256)" --rpc-url $RPC
cast call $YIELD "minDistributionInterval()(uint256)" --rpc-url $RPC
cast block latest -f timestamp --rpc-url $RPC
```

Requires `lastDistributionTime + minDistributionInterval <= block.timestamp`, else
`DistributionTooFrequent`. Default interval is 79,200s (22 hours).

The very first report is exempt — the check is skipped while `lastDistributionTime == 0`.
{% endstep %}

{% step %}
### Compute the `amount` ceiling

```bash
cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC
cast call $YIELD "maxYieldPercentage()(uint256)" --rpc-url $RPC
```

`amount <= totalAssets() * maxYieldPercentage / 10_000`. Default `maxYieldPercentage` is
`50` = 0.5% of recognised assets.

{% hint style="warning" %}
The cap is evaluated against **live** `totalAssets()` at execution time, not at the time
you read it. A deposit or redemption landing between your read and your transaction shifts
the ceiling. Leave headroom on a report near the cap.
{% endhint %}
{% endstep %}

{% step %}
### Compute the `feeAmount` ceiling

```bash
cast call $YIELD "maxFeePercentage()(uint256)" --rpc-url $RPC
```

`feeAmount <= amount * maxFeePercentage / 10_000`. Default `5000` = 50% **of `amount`** —
not of total realised P&L.
{% endstep %}

{% step %}
### Split the realised P&L into the two arguments

This is the step that permanently corrupts vault accounting if you get it wrong.

`feeAmount` is **additive**, not deducted from `amount`. If the strategy realised 5 USDC
and the protocol takes 20%:

| | Correct | Wrong |
|---|---|---|
| `amount` | `4e6` | `5e6` |
| `feeAmount` | `1e6` | `1e6` |
| Booked | 5 USDC | **6 USDC against 5 real** |

The wrong version overstates the vault permanently. Nothing onchain will catch it — the
vault has no view of strategy balances.

{% hint style="danger" %}
**Both values are in underlying asset decimals — 6 for USDC, not 18.** Passing an
18-decimal figure books a 10¹²× overstatement. This is the single highest-consequence
input error available here.
{% endhint %}
{% endstep %}

{% step %}
### Simulate before sending

```bash
cast call $YIELD "distributeYield(uint256,uint256,uint256,bool)" \
  <amount> <feeAmount> <nonce> <isProfit> \
  --from <rebalancer> --rpc-url $RPC
```

A successful `call` means the guards pass. It does **not** validate that your figures are
economically correct — only that they are accepted.
{% endstep %}

{% step %}
### Send

```bash
cast send $YIELD "distributeYield(uint256,uint256,uint256,bool)" \
  <amount> <feeAmount> <nonce> <isProfit> \
  --rpc-url $RPC --private-key $PK
```
{% endstep %}

{% step %}
### Verify it landed as intended

```bash
cast call $YIELD "epoch()(uint256)" --rpc-url $RPC           # incremented by 1
cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC
cast call $VAULT "getUnvestedAmount()(uint256)" --rpc-url $RPC
cast call $YIELD "treasuryDebt()(uint256)" --rpc-url $RPC    # non-zero: loss exceeded treasury
```

Confirm the `DistributeYield` event carries the figures you intended.
{% endstep %}
{% endstepper %}

## Preflight script

Committed at `script/rebalancer-preflight.sh`:

```bash
./script/rebalancer-preflight.sh $YIELD $VAULT $RPC
```

Prints the next valid nonce, whether the interval has elapsed, and both computed ceilings.

## Every guard, in one place

| Guard | Reverts with | Default |
|---|---|---|
| `amount <= totalAssets * maxYieldPercentage / 10_000` | *(no reason string)* | 50 bps |
| `feeAmount <= amount * maxFeePercentage / 10_000` | *(no reason string)* | 5,000 bps |
| `nonce == epoch + 1` | `InvalidEpoch` | — |
| `trxns[proofHash]` unseen | `DuplicateTransaction` | — |
| Interval elapsed | `DistributionTooFrequent` | 79,200s |
| Caller holds `REBALANCER_ROLE` | `AccessControlUnauthorizedAccount` | — |

{% hint style="warning" %}
The two percentage caps are bare `require` statements with no message — unlike every other
check, which uses a named custom error. Exceeding either cap reverts with **no reason
string**. If a transaction fails with nothing to decode, check the caps first.
{% endhint %}

`proofHash` is keyed on `(vaultToken, amount, nonce, isProfit)` — `feeAmount` is **not**
part of the replay identity, so the `nonce` check is what actually prevents a duplicate
submission.

## Two things this role does not do

### It does not move any assets

`distributeYield` writes accounting only. There is not a single underlying-asset transfer
in `Yield.sol`. Reporting a profit does **not** bring capital back onchain.

Returning capital is `Manager.transferToVault`, which requires `OPERATOR_ROLE`. These are
independent systems:

| | Function | Role | Effect |
|---|---|---|---|
| Books | `distributeYield` | Rebalancer | `virtualAssets` changes |
| Assets | `transferToVault` | Operator | Real tokens arrive at the vault |

Reporting profit while the vault stays unfunded raises the share price without making a
single redemption payable.

### It cannot correct a mistake

There is no reversal path. `nonce` is strictly sequential, and a bad report can only be
offset by an opposing report in a later epoch — itself bounded by the per-epoch cap.

A materially wrong figure could take many epochs to unwind, and throughout that window
`requestRedeem` keeps freezing quotes at the wrong price. Those quotes are final: users who
requested during the error are paid the wrong amount permanently.

{% hint style="danger" %}
Simulate every report. A misplaced decimal cannot be undone in one transaction, and the
users harmed by it are the ones who exit before you finish unwinding it.
{% endhint %}

## Cadence

There is **no required reporting frequency**. The interval is a floor, not a ceiling —
nothing obliges a report, and there is no staleness check anywhere.

If reporting stops, unvested profit finishes vesting and the share price freezes at its
last value indefinitely, while deposits and redemption requests keep quoting against it.
Onchain this is indistinguishable from a flat-performing strategy.

The 22-hour default paired with a 7-day vesting period implies **daily reporting** — each
epoch's profit vests across roughly seven subsequent reports, so the schedules overlap and
the share price moves smoothly instead of stepping.

{% hint style="info" %}
Note that a new profit report restarts the vesting clock for profit still in flight:
`vestingAmount` becomes `new + still-unvested` and the timestamp resets. Under continuous
daily reporting, profit is perpetually re-spread and never fully vests, so `totalAssets()`
structurally lags `virtualAssets`. This is inherent to the design.
{% endhint %}

## Monitoring after each report

| Signal | Read | Meaning |
|---|---|---|
| Epoch advanced | `epoch()` | Report was accepted |
| Vesting in flight | `getUnvestedAmount()` | Profit not yet in the share price |
| Treasury debt | `treasuryDebt()` | A loss exceeded what the treasury could absorb; fees now route to depositors |
| Redemption backlog | `totalRequestedAmount()` vs the vault's asset balance | Whether matured redemptions are actually payable |

That last row is the one worth alerting on. It is the only onchain signal that separates a
healthy vault from one whose books look fine while users cannot exit.
