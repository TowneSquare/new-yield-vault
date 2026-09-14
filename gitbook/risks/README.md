# Risks and trust assumptions

{% hint style="warning" %}
This page is deliberately direct. Every item below is drawn from the protocol's own
technical documentation (`docs/KNOWN_ISSUES.md`, `docs/INVARIANTS.md`) and from the
contract code. None of it is hypothetical.
{% endhint %}

## Counterparty risk

**Your funds are not held onchain.**

Deposits are forwarded to the Manager contract and then transferred to an **offchain
trading counterparty**. What the vault holds is an accounting record of what you are owed —
not the assets themselves.

Once capital leaves via `execute()`, onchain enforcement ends. Recovery depends on the
counterparty honouring an offchain agreement.

**Enforced by code:** deposits reach only the Manager; capital can only go to addresses
governance has whitelisted; every whitelist change and every deployment emits an event, so
the destination set is publicly auditable.

**Not enforced by code:** which addresses get whitelisted, how much leaves, when it returns,
and whether any reserve is kept back.

This is the largest risk in the protocol and it is structural, not a bug.

## Withdrawal liveness

**There is no liquidity buffer.** The vault retains nothing by default.

When your cooldown ends, the assets to pay you must be pushed back onchain by an operator
before you can collect. The contract cannot force this. If it does not happen, your
matured redemption simply cannot execute.

{% hint style="danger" %}
The protocol's invariant documentation states plainly that **"users can always eventually
withdraw" does not hold.** Withdrawal liveness is an offchain operational dependency, not
an onchain guarantee.
{% endhint %}

You can monitor this yourself — see
[Tracking your position](../guides/tracking-your-position.md).

## Unverifiable yield reporting

The share price is set entirely by an offchain engine's reports. There is no oracle, and
the vault has no view of the strategy's actual balances.

From the code's own comment:

> Nothing onchain can verify this: the vault has no view of strategy balances, so the split
> is trusted input from the offchain engine.

**What bounds it:** by default at most 0.5% of vault assets per report, at most one report
roughly every 22 hours, strict epoch sequencing, duplicate rejection.

**What does not bound it:** the truth of the figure. And the caps are per-report, not
cumulative — sustained reporting at the limit compounds. At the default rate, roughly 5.5%
per week could be reported in either direction indefinitely.

Both the magnitude cap and the interval are governance-adjustable. The interval cannot be
set to zero, but it can be set to one second.

### Reporting can also simply stop

The interval is a **floor, not a ceiling**. Nothing in the contracts obliges the rebalancer
to report at all, and there is no staleness check anywhere — unlike a price oracle, which
reverts when its data goes stale.

If reporting stops: any unvested profit finishes vesting, and the share price then
**freezes at its last value indefinitely**. Deposits and redemption requests keep working
and keep quoting against that frozen price. If the strategy is losing money during the
silence, users who redeem are paid at a stale, too-high price and the loss lands entirely
on whoever remains.

Onchain, a stalled reporter is indistinguishable from a flat-performing strategy. The only
detection is manual:

```bash
cast call <yield> "lastDistributionTime()(uint256)" --rpc-url <rpc>
cast call <yield> "epoch()(uint256)" --rpc-url <rpc>
```

A `lastDistributionTime` far in the past, or an `epoch` that has not moved, means reporting
has stalled.

## Withdrawals can be paused

An admin can pause the vault. Pause blocks `withdraw`, `redeem`, and `redeemFor` as well as
deposits — so a pause makes matured redemptions temporarily uncollectable.

Most vaults deliberately keep the exit path open while pausing entry. This one does not.
The protocol documents this as an accepted risk on the basis that pause is a short-lived
emergency measure.

{% hint style="info" %}
**A 48-hour timelock is implemented but not yet deployed.** The two sections below describe
the live deployment as it stands today. Once the handover executes, upgrades and admin
parameter changes will require a 48-hour public delay, with emergency pause and whitelist
removal carved out as instant. See
[Governance and the timelock](../operations/governance.md) for the model and for how to
verify onchain which regime is actually in force.
{% endhint %}

## Upgradeability, with no timelock

All three contracts are UUPS-upgradeable. The governance multisig can replace any of them
with arbitrary code, **effective immediately**.

There is no delay in which to exit ahead of a change you disagree with. An upgrade
subsumes every other limit described in this documentation — including the 1% exit fee cap.

## Broad admin powers

The admin role can, with no timelock:

- Whitelist any destination address, then deploy capital to it in the same block
- Call `emergencyRecover` to transfer any token out of the vault — **including assets
  already earmarked for pending redemptions**, since the function does not check
  `totalRequestedAmount`
- Raise the performance fee to 100% of reported profit
- Set the minimum reporting interval as low as 1 second, effectively removing the rate limit
- Repoint the Manager address, changing which contract controls vault accounting
- Change the treasury, redirecting all fee accrual
- Pause the vault

{% hint style="warning" %}
The same role sets the whitelist **and** can extract assets. That means the whitelist is not
an independent control against the admin — only against the operator. See
[Roles and permissions](../reference/roles.md).
{% endhint %}

## Design behaviours that are not bugs

These are intentional, but they will surprise you if you assume standard ERC-4626:

- **No cancel.** A redemption request cannot be undone or amended.
- **Amount frozen at request.** You forgo profit and are insulated from loss during
  cooldown.
- **One request at a time.** Large positions must be exited sequentially.
- **Self-collection only.** Allowance-based withdrawal is disabled; no other address can
  withdraw for you, ever.
- **`maxWithdraw` / `maxRedeem` over-report.** They are not overridden.
- **An operator can settle your request before the cooldown ends** via `redeemFor`. It can
  only pay you your locked amount, but it can end your position early.

## Smart contract risk

The contracts have been through internal audit preparation, and the repository documents
known issues openly. As with any protocol, undiscovered bugs are possible. The
upgradeability described above cuts both ways — it allows fixes, and it allows changes you
did not consent to.

## Summary

| Risk | Severity | Mitigated by |
|---|---|---|
| Offchain counterparty default | **High** | Whitelist, offchain agreement only |
| Withdrawal not funded | **High** | Operator diligence; nothing onchain |
| False yield reporting | **Medium** | Per-epoch caps, rate limit |
| Admin extraction / fee change | **Medium** | Multisig; no timelock |
| Immediate upgrade | **Medium** | Multisig; no timelock |
| Pause blocking exit | **Low–Medium** | Intended to be short-lived |

{% hint style="info" %}
**Deposit sizing.** Treat this as an allocation to an offchain trading counterparty with an
onchain accounting wrapper, not as a self-custodial DeFi position. Size it accordingly.
{% endhint %}
