---
description: How governance works once DEFAULT_ADMIN and ADMIN sit behind a 48-hour TimelockController.
---

# Governance and the timelock

{% hint style="warning" %}
**Status: implemented, not yet deployed.** The contracts, deployment scripts and tests
exist in the repository, but the live deployment still has the admin multisig holding
`DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` directly, with no delay. Verify onchain before
relying on anything on this page — see [Verifying it is live](#verifying-it-is-live).
{% endhint %}

## The model

Every governance action — upgrades, fee changes, whitelist additions, cooldown and cap
changes — is scheduled, waits **48 hours**, and only then executes.

```
Safe ──schedule()──► TimelockController ──48h──► execute() ──► ADMIN_ROLE ──► vault.setFee()
```

Two emergency actions are deliberately exempt and remain instant:

| Action | Path | Delay |
|---|---|---|
| `pause()` | `GUARDIAN_ROLE` | none |
| `removeWhitelistedAddresses()` | `GUARDIAN_ROLE` | none |
| Everything else governance-related | `ADMIN_ROLE` via timelock | **48 hours** |
| `execute`, `transferToVault`, `redeemFor` | `OPERATOR_ROLE` | none — operational |
| `distributeYield` | `REBALANCER_ROLE` | none — operational |

## How it is wired

There is **no code coupling**. No contract imports `TimelockController` or stores its
address. The integration is purely a role assignment: `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE`
are held by the timelock's address instead of the Safe's.

The vault sees a call from an address holding `ADMIN_ROLE` and has no idea a delay occurred.
All enforcement lives inside `TimelockController`, which refuses to forward a call until the
delay has elapsed.

Upgrades inherit the delay for free: `_authorizeUpgrade` was already
`onlyRole(DEFAULT_ADMIN_ROLE)`, so moving that role behind the timelock delays every
upgrade with no change to the upgrade path itself.

## The guardian

`GUARDIAN_ROLE` is held by the Safe and exists only because the timelock is uniform. It is
**deliberately asymmetric**:

| Can | Cannot |
|---|---|
| `pause()` the vault | `unpause()` it |
| Remove whitelist entries | Add whitelist entries |
| | Change any parameter, upgrade, or grant itself anything |

The reasoning: the worst a compromised guardian achieves is a denial of service, and the
timelock can undo all of it. It can never create a path for funds to leave, and it can never
lift a halt it caused.

Pause-fast/resume-slow is intentional. Pause blocks user withdrawals, so lifting it carries
the delay and the public visibility that comes with it.

## Proposing an action

The helper script records every parameter needed to execute later:

```bash
export RPC_URL=$ROBINHOOD_RPC_URL
export PRIVATE_KEY=$PK

./script/timelock-propose.sh propose <TIMELOCK> <VAULT> "setFee(uint256)" 200000000000000000
```

It computes the calldata, generates a dated salt, schedules the operation, and writes a
record to `safe/timelock/<label>.json`.

{% hint style="danger" %}
**Never schedule by hand without recording the salt.** An operation's id is
`keccak256(target, value, data, predecessor, salt)`, and execution must pass the *same*
salt. Lose it and the proposal is unexecutable — you wait out a fresh 48 hours with a salt
you did keep. The script exists to make that failure impossible.
{% endhint %}

Check progress at any time:

```bash
./script/timelock-propose.sh status safe/timelock/setFee-20260914.json
./script/timelock-propose.sh list
```

Then, after the delay:

```bash
./script/timelock-propose.sh execute safe/timelock/setFee-20260914.json
```

Omit `PRIVATE_KEY` and the script sends nothing — it prints the exact `cast send` command
instead, which is what you want when the proposer is a Safe rather than an EOA.

## Cancelling

The Safe holds `CANCELLER_ROLE`, so a pending proposal can be withdrawn before it executes:

```bash
./script/timelock-propose.sh cancel safe/timelock/<label>.json
```

## `salt` and `predecessor`

Both feed the operation id, which is why they matter.

**`salt`** disambiguates otherwise-identical operations. A completed operation's id is
recorded permanently and cannot be rescheduled, so setting the fee to `5e17`, then later
back to `5e17` again, needs different salts or the second attempt reverts. Use a dated,
descriptive label — it appears in `CallScheduled`, making governance history readable
onchain.

**`predecessor`** forces another operation to be `done` first. Pass `bytes32(0)` — no
dependency — for essentially every proposal here. Note it enforces *order*, not atomicity:
if A executes and B reverts, A stays applied. For steps that must be all-or-nothing, use
`scheduleBatch`, which is one id and one atomic execution.

## Verifying it is live

Do not take this page's word for it. Read the roles onchain:

```bash
# The timelock should hold governance
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ADMIN_ROLE") <timelock> --rpc-url $RPC   # expect true

# The Safe should NOT
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ADMIN_ROLE") <safe> --rpc-url $RPC       # expect false

# The Safe should hold the guardian carve-out
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "GUARDIAN_ROLE") <safe> --rpc-url $RPC    # expect true

# And the delay itself
cast call <timelock> "getMinDelay()(uint256)" --rpc-url $RPC   # expect 172800
```

Also confirm no **external** account holds a standing bypass:

```bash
cast call <timelock> "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 <safe> \
  --rpc-url $RPC   # expect false — and false for every EOA or multisig you check
```

The timelock is deployed with `admin = address(0)` precisely so no such account exists.

{% hint style="info" %}
**The timelock itself does hold `DEFAULT_ADMIN_ROLE` over itself**, and that is correct.
OpenZeppelin v5 grants it in the constructor ("self administration") whatever the `admin`
argument says. It is how `updateDelay` and role changes are possible at all — and because
the holder *is* the timelock, exercising it still requires a proposal that has served the
full delay.

So this returns `true`, and should:

```bash
cast call <timelock> "hasRole(bytes32,address)(bool)" 0x00...00 <timelock> --rpc-url $RPC
```

What must be `false` is every *external* address.
{% endhint %}

## What a depositor sees

Every pending change is public for 48 hours before it takes effect. Watch:

| Event | Contract | Meaning |
|---|---|---|
| `CallScheduled` | Timelock | A governance action was proposed — the 48h clock started |
| `CallExecuted` | Timelock | It took effect |
| `Cancelled` | Timelock | It was withdrawn |
| `RoleGranted` / `RoleRevoked` | any proxy | Privileged access changed hands |

```bash
cast logs --address <timelock> "CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)" \
  --rpc-url $RPC
```

With a 1-day cooldown, 48 hours is enough for a depositor who sees a proposal they dislike
to request and complete a full exit before it lands. That is the whole point of the delay.

{% hint style="info" %}
The delay does **not** cover everything. `execute` (capital deployment) and
`distributeYield` (P&L reporting) remain instant, because delaying them would break normal
operation. See [Deploying capital](deploying-capital.md) and [Reporting P&L](reporting-pnl.md).
{% endhint %}

## Deploying the timelock

Four steps, in order:

{% stepper %}
{% step %}
### Deploy the guardian-aware implementations

New `TownSqToken` and `Manager` implementations. `Yield` is unchanged — it has no emergency
surface.
{% endstep %}

{% step %}
### Deploy the TimelockController

```bash
forge script script/DeployTimelock.s.sol --rpc-url <chain> --broadcast
```

48h delay, Safe as proposer/executor/canceller, `admin = address(0)`.
{% endstep %}

{% step %}
### Generate and execute the handover batch

```bash
forge script script/TimelockRoleChange.s.sol --rpc-url <chain>
```

Writes `safe/timelock-handover.json` for the Safe Transaction Builder. Sixteen transactions,
**order is load-bearing**: the guardian is granted before any admin is revoked, and
`DEFAULT_ADMIN` is revoked last on each proxy.
{% endstep %}

{% step %}
### Verify

Run the checks in [Verifying it is live](#verifying-it-is-live). The final transaction is
irreversible from the Safe's side: afterwards the Safe cannot grant itself anything back,
and only the timelock can, on a 48-hour delay.
{% endstep %}
{% endstepper %}

Simulate the whole handover against live state first:

```bash
forge test --match-path test/TimelockHandover.fork.t.sol -vv
```

That forks the live chain, deploys the implementations and timelock, runs the exact batch as
the Safe, and asserts that live storage (fee, cooldown, `totalAssets`, supply, epoch,
whitelist entries) survives unchanged.
