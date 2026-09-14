# Roles and permissions

Four privileged roles across three contracts. This page is the user-facing summary — the
complete enumeration with line references lives in `docs/ROLES.md` in the repository.

## Summary

| Role | Holder | Can move assets | Can move share price |
|---|---|---|---|
| **Governance** (`DEFAULT_ADMIN_ROLE`) | Multisig | Yes — via upgrade | Yes — via upgrade |
| **Admin** (`ADMIN_ROLE`) | Multisig | Yes — `emergencyRecover`, whitelist | Indirectly, via parameters |
| **Operator** (`OPERATOR_ROLE`) | Executor | **Yes** — `execute` | No |
| **Rebalancer** (`REBALANCER_ROLE`) | Offchain engine | No | **Yes** — entirely |

The clean way to hold it in your head:

> **Operator** controls where the money physically is.
> **Rebalancer** controls what the books say it is worth.
> **Admin** decides the rules. **Governance** decides the code.

## Governance

Upgrade authority over all three contracts, plus the power to grant and revoke every other
role. Effective immediately, with no timelock.

An upgrade can replace any contract with arbitrary code, which subsumes every other limit
in this documentation — including the hard-coded 1% exit fee cap.

## Admin

Governance parameters, plus two powers that are not parameters at all.

**Parameters:** exit fee (≤1%), cooldown (≤7 days), vesting (≤30 days), performance fee cap
(up to 100%), per-epoch yield cap, reporting interval, redemption cap, minimum deposit.

**Beyond parameters:**

- **The destination whitelist** — the only constraint on where the operator can send
  capital. No timelock, so an address can be whitelisted and receive funds in the same
  block.
- **`emergencyRecover`** — transfers any token out of the vault, including assets earmarked
  for pending redemptions.
- **`pause`** — blocks withdrawals as well as deposits.
- **Repointing the Manager and treasury addresses.**

{% hint style="warning" %}
Admin both sets the whitelist and can extract assets. The whitelist therefore constrains the
operator, not the admin.
{% endhint %}

## Operator

Three functions on the Manager. This role holds the keys to the address custodying every
deposited asset.

**`execute(targets[], data[])`** — arbitrary calls to whitelisted addresses, batched, from
the custody address. Within the whitelist there is no amount cap, no per-destination cap,
and no rate limit. This is how capital reaches the offchain strategy.

**`transferToVault(token, amount)`** — pushes assets back into the vault so redemptions can
be paid. This is the function your withdrawal depends on. It emits no event.

**`redeemFor(vault, user)`** — settles a user's redemption request. Bounded: it can only pay
that user, at the amount already locked in. It does **not** check the cooldown, so it can
settle a request early.

Cannot: change the whitelist, grant roles, upgrade, pause, set parameters, or report yield.

## Rebalancer

One function: `distributeYield(amount, feeAmount, nonce, isProfit)`.

It sets the share price. There is no oracle — the vault books what it is told, bounded by
the per-epoch cap, the minimum interval, strict epoch sequencing, and duplicate rejection.
The figures themselves are unverifiable onchain.

Cannot: move any asset, change the whitelist, grant roles, upgrade, pause, or set
parameters. Its entire surface is the accounting.

## If a role were compromised

| Compromised | Consequence | Bounded by |
|---|---|---|
| Rebalancer | Mispriced redemptions; value leaks gradually | 0.5%/epoch, ~22h interval |
| Operator | Assets sent to whitelisted destinations | The whitelist |
| Admin | Whitelist any address then extract; 100% fee | Nothing |
| Governance | Total — can grant itself every role, or upgrade | Nothing |

## Verifying who holds what

Role holders are onchain state. Do not take them from documentation — read them.

```bash
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ADMIN_ROLE") <address> --rpc-url <rpc>

cast call <proxy> "getRoleMemberCount(bytes32)(uint256)" \
  $(cast keccak "OPERATOR_ROLE") --rpc-url <rpc>
```

If a holder is a Safe, `getOwners()` and `getThreshold()` give the real signing
requirement. Watch `RoleGranted` and `RoleRevoked` for rotations — they take effect
immediately.

## Known weaknesses in the current separation

1. **No timelock anywhere** on the current live deployment. Whitelisting, upgrades, and role
   rotations are all immediate. A 48-hour timelock plus a `GUARDIAN_ROLE` carve-out is
   implemented and pending deployment — see
   [Governance and the timelock](../operations/governance.md), which also shows how to check
   onchain which regime is in force.
2. **Admin mixes risk parameters with custody powers.** `setFee` and `emergencyRecover` sit
   behind the same role, so parameter management cannot be delegated without also
   delegating fund extraction.
3. **The whitelist setter and the fund mover may be the same key.** They must be distinct
   for the whitelist to function as a control.
4. **Two parameters are unbounded in the direction that matters** — the performance fee can
   reach 100%, and the reporting interval can be dropped to one second — while having no
   maximum, so reporting can also stop entirely with no staleness check.
