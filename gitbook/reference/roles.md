# Roles and permissions

Five privileged roles across three contracts, plus a handful of functions that only the
protocol's own contracts can call. This page is the user-facing summary — the complete
enumeration with line references lives in `docs/ROLES.md` in the repository.

{% hint style="info" %}
**Governance and Admin sit behind a 48-hour timelock.** `DEFAULT_ADMIN_ROLE` and
`ADMIN_ROLE` are held by a `TimelockController` on all three contracts, so every function
in those two sections is scheduled publicly and can only execute 48 hours later. The Safe
proposes and executes, and holds `GUARDIAN_ROLE` for the two actions that stay instant.
Operator and Rebalancer are operational and have no delay. See
[Governance and the timelock](../operations/governance.md).
{% endhint %}

## Summary

| Role | Holder | Can move assets | Can move share price |
|---|---|---|---|
| **Governance** (`DEFAULT_ADMIN_ROLE`) | Timelock (48h) | Yes — via upgrade | Yes — via upgrade |
| **Admin** (`ADMIN_ROLE`) | Timelock (48h) | Yes — `emergencyRecover`, whitelist | Indirectly, via parameters |
| **Guardian** (`GUARDIAN_ROLE`) | Safe (instant) | No | No |
| **Operator** (`OPERATOR_ROLE`) | Executor | **Yes** — `execute` | No |
| **Rebalancer** (`REBALANCER_ROLE`) | Offchain engine | No | **Yes** — entirely |

The clean way to hold it in your head:

> **Operator** controls where the money physically is.
> **Rebalancer** controls what the books say it is worth.
> **Admin** decides the rules. **Governance** decides the code.
> **Guardian** can only stop things.

Where each role exists:

| Role | Vault | Manager | Yield |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | ✓ | ✓ | ✓ |
| `ADMIN_ROLE` | ✓ | ✓ | ✓ |
| `GUARDIAN_ROLE` | ✓ | ✓ | — |
| `OPERATOR_ROLE` | — | ✓ | — |
| `REBALANCER_ROLE` | — | — | ✓ |

## Governance

`DEFAULT_ADMIN_ROLE`. Upgrade authority over all three contracts, and the admin of every
other role. No contract calls `_setRoleAdmin`, so this one role can grant and revoke all
of them.

| Function | Contracts | What it does |
|---|---|---|
| `upgradeToAndCall(newImplementation, data)` | all three | Replaces the contract's code behind its proxy, optionally running a call on the new code in the same transaction. |
| `grantRole(role, account)` | all three | Gives `account` any role on that contract — including `DEFAULT_ADMIN_ROLE` itself. |
| `revokeRole(role, account)` | all three | Removes any role from any account. |

An upgrade can replace any contract with arbitrary code, which subsumes every other limit
in this documentation — including the hard-coded 1% exit fee cap.

{% hint style="info" %}
`renounceRole(role, yourself)` is also callable by any role holder, but only to give up a
role it holds itself. It is not a power over anyone else.
{% endhint %}

## Admin

`ADMIN_ROLE`. Governance parameters, plus powers over custody and the pause switch.

### Vault

| Function | What it does |
|---|---|
| `setFee(newFee)` | Sets the exit fee charged on redemption. Reverts above 1% (`1e18`). |
| `setCooldownPeriod(newPeriod)` | Sets how long a redemption request must wait before it can be collected. Reverts above 7 days. |
| `setVestingPeriod(newPeriod)` | Sets how long reported profit takes to reach the share price. Reverts above 30 days. Profit still in flight is re-spread across the new period from now. |
| `setManager(newManager)` | Repoints the vault at a different Manager contract — which controls minting, burning and asset bookkeeping. |
| `pause()` | Blocks deposits **and** withdrawals, including operator-settled redemptions. Shared with the Guardian. |
| `unpause()` | Lifts the pause. **Admin only** — the Guardian cannot. |
| `emergencyRecover(token, amount, recipient)` | Transfers any token or ETH held by the vault to any address — including assets earmarked for pending redemptions. |

### Manager

| Function | What it does |
|---|---|
| `setWhitelistedAddresses(wallets[], statuses[])` | Adds or removes destinations the Operator may call through `execute`. Refuses the zero address and the protocol's own contracts, and refuses to run before the vault address is set. |
| `removeWhitelistedAddresses(wallets[])` | Removal-only version of the above. Shared with the Guardian. |
| `setTreasury(treasury)` | Changes where performance and exit fees are minted — and whose shares are burned on a loss. |
| `setManagerAndYield(yield, vault)` | Repoints the Manager at a different Yield contract and vault. (Despite the name, it sets Yield and the vault.) Refuses addresses that are currently whitelisted. |
| `setMinSharesInVaultToken(vault, minShares)` | Sets the minimum shares a deposit must mint. Must be non-zero. |
| `setMaxRedeemCap(vault, cap)` | Sets the largest amount of assets a single redemption request may be for. `0` removes the cap. |

### Yield

| Function | What it does |
|---|---|
| `setMaxYieldPercentage(bps)` | Caps each report's `amount` as a share of the vault's recognised assets, in basis points. Must be between 1 and 10,000. Default 50 (0.5%). |
| `setMaxFeePercentage(bps)` | Caps each report's `feeAmount` as a share of `amount`, in basis points. Up to 10,000 (100%). Default 5,000 (50%). |
| `setMinDistributionInterval(seconds)` | Sets the minimum gap between reports. Must be non-zero; no other floor. Default 79,200s (22 hours). |
| `setManager(manager)` | Repoints Yield at a different Manager. |

{% hint style="warning" %}
Admin both sets the whitelist and can extract assets. The whitelist therefore constrains the
operator, not the admin.
{% endhint %}

## Guardian

`GUARDIAN_ROLE`, on the vault and the Manager, held by the Safe. It exists because the timelock applies one delay to everything, and two emergency actions
cannot wait 48 hours.

| Function | Contract | What it does |
|---|---|---|
| `pause()` | Vault | Halts deposits and withdrawals immediately. |
| `removeWhitelistedAddresses(wallets[])` | Manager | Cuts off capital destinations immediately. Can only ever write `false`. |

It is deliberately asymmetric. It can pause but not unpause, and remove whitelist entries
but not add them. It cannot change any parameter, upgrade anything, or grant itself
anything. The worst a compromised Guardian achieves is a denial of service that the timelock
can undo — it can never create a path for funds to leave.

## Operator

`OPERATOR_ROLE`, on the Manager only. This role holds the keys to the address custodying
every deposited asset.

| Function | What it does |
|---|---|
| `execute(targets[], data[])` | Makes arbitrary calls to whitelisted addresses, batched, from the Manager. Within the whitelist there is no amount cap, no per-destination cap, and no rate limit. This is how capital reaches the offchain strategy. |
| `transferToVault(token, amount)` | Pushes assets from the Manager back into the vault so redemptions can be paid. This is the function your withdrawal depends on. It emits no event. |
| `redeemFor(vault, user)` | Settles a user's redemption request. Bounded: it can only pay that user, at the amount already locked in. It does **not** check the cooldown, so it can settle a request early. Blocked while paused. |

Cannot: change the whitelist, grant roles, upgrade, pause, set parameters, or report yield.

## Rebalancer

`REBALANCER_ROLE`, on Yield only.

| Function | What it does |
|---|---|
| `distributeYield(amount, feeAmount, nonce, isProfit)` | Reports one epoch's profit or loss. `amount` goes to shareholders and `feeAmount` to the treasury, as two separate slices. `nonce` must be exactly `epoch + 1`. See [How profit and loss reach your shares](functions.md#how-profit-and-loss-reach-your-shares). |

It sets the share price. There is no oracle — the vault books what it is told, bounded by
the per-epoch cap, the minimum interval, strict epoch sequencing, and duplicate rejection.
The figures themselves are unverifiable onchain.

Cannot: move any asset, change the whitelist, grant roles, upgrade, pause, or set
parameters. Its entire surface is the accounting.

## Contract-only functions

These are not roles. Each function checks `msg.sender` against another protocol contract's
address, so no person or key can call them directly — only the contract named. They are
listed because the addresses they trust are set by Admin (`setManager`,
`setManagerAndYield`).

| Function | On | Only callable by | What it does |
|---|---|---|---|
| `transferInRewards(amount, profit)` | Vault | Yield | Puts profit on the vesting schedule, or applies a loss. |
| `updateTotalAssets(amount, add)` | Vault | Manager | Moves `virtualAssets` up or down. |
| `mintVaultToken(to, shares)` | Vault | Manager | Mints shares — and only to the treasury. |
| `burnVaultToken(from, shares)` | Vault | Manager | Burns shares — and only from the treasury. |
| `redeemFor(user)` | Vault | Manager | The vault side of the Operator's `redeemFor`. |
| `manageAssetAndShares(to, order)` | Manager | Yield | Books the treasury's fee: adjusts assets, then mints or burns treasury shares. |

## If a role were compromised

| Compromised | Consequence | Bounded by |
|---|---|---|
| Rebalancer | Mispriced redemptions; value leaks gradually | 0.5%/epoch, ~22h interval |
| Operator | Assets sent to whitelisted destinations | The whitelist |
| Guardian | Vault paused, whitelist emptied — a denial of service | Admin can unpause and re-whitelist, after 48h |
| Admin | Whitelist any address then extract; 100% fee | 48h public delay — needs the Safe to propose |
| Governance | Total — can grant itself every role, or upgrade | 48h public delay — needs the Safe to propose |

## Verifying who holds what

Role holders are onchain state. Do not take them from documentation — read them.

```bash
# Does <address> hold ADMIN_ROLE on this proxy?
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ADMIN_ROLE") <address> --rpc-url <rpc>

# DEFAULT_ADMIN_ROLE is the zero hash, not keccak("DEFAULT_ADMIN_ROLE")
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 <address> --rpc-url <rpc>
```

The contracts use plain `AccessControl`, not the Enumerable variant, so there is no
`getRoleMember` or `getRoleMemberCount`. To list every holder of a role, replay its grant
history:

```bash
cast logs --address <proxy> --from-block <deploy-block> \
  "RoleGranted(bytes32,address,address)" $(cast keccak "OPERATOR_ROLE") --rpc-url <rpc>
```

Then check each account with `hasRole` — a later `RoleRevoked` may have removed it.

If a holder is a Safe, `getOwners()` and `getThreshold()` give the real signing
requirement. The Governance and Admin holder should be the timelock, not the Safe —
[Governance](../operations/governance.md#verifying-it-is-live) has the full check. Watch
`RoleGranted` and `RoleRevoked` for rotations; for anything behind the timelock, a
`CallScheduled` event on the timelock warns 48 hours ahead.

## Known weaknesses in the current separation

1. **The timelock delays, it does not prevent.** Whitelisting, upgrades, and role rotations
   now take 48 hours and are public, but one Safe is still proposer, executor, canceller and
   guardian. It can also pause instantly and unpausing takes 48 hours, so a pause can block
   depositors from exiting during a pending change. See
   [Governance and the timelock](../operations/governance.md).
2. **Admin mixes risk parameters with custody powers.** `setFee` and `emergencyRecover` sit
   behind the same role, so parameter management cannot be delegated without also
   delegating fund extraction. The timelock delays both but does not separate them.
3. **The whitelist setter and the fund mover may be the same key.** They must be distinct
   for the whitelist to function as a control.
4. **Two parameters are unbounded in the direction that matters** — the performance fee can
   reach 100%, and the reporting interval can be dropped to one second — while having no
   maximum, so reporting can also stop entirely with no staleness check.
