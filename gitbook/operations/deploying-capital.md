---
description: Operational runbook for the OPERATOR_ROLE holder deploying capital and funding redemptions.
---

# Deploying capital

{% hint style="danger" %}
This page covers the highest-privilege operation in the protocol. `Manager.execute` makes
arbitrary calls **from the address custodying 100% of deposited assets**. Within the
whitelist there is no amount cap, no per-destination limit, and no rate limit. Read the
whole page before your first call.
{% endhint %}

`OPERATOR_ROLE` holds three functions on the Manager:

| Function | Purpose |
|---|---|
| `execute(targets[], data[])` | Deploy capital to whitelisted destinations |
| `transferToVault(token, amount)` | Return capital so redemptions can be paid |
| `redeemFor(vault, user)` | Settle a user's matured redemption on their behalf |

## Before you start

```bash
MANAGER=<manager proxy>
VAULT=<vault proxy>
ASSET=<underlying token>
RPC=<rpc url>
```

## `execute` — step by step

{% stepper %}
{% step %}
### Confirm you hold the role

```bash
cast call $MANAGER "hasRole(bytes32,address)(bool)" \
  $(cast keccak "OPERATOR_ROLE") <your address> --rpc-url $RPC
```

`false` reverts with `AccessControlUnauthorizedAccount`.
{% endstep %}

{% step %}
### Confirm every target is whitelisted

**Check this before building anything else.** The whitelist is the only constraint on where
capital can go, and an unlisted target reverts the entire batch with `NotWhitelisted`.

```bash
cast call $MANAGER "whitelistedAddresses(address)(bool)" <target> --rpc-url $RPC
```

To see the full authorised set rather than checking one address at a time, read the event
history:

```bash
cast logs --address $MANAGER "WhitelistUpdated(address,address,bool)" \
  --from-block <deployment block> --rpc-url $RPC
```

{% hint style="info" %}
Whitelisting is `ADMIN_ROLE`, not yours. If a destination is missing, it must be added by
the admin multisig before you can reach it — you cannot self-authorise.
{% endhint %}
{% endstep %}

{% step %}
### Build the calldata

Each entry in `data[]` is a complete ABI-encoded call to the matching entry in `targets[]`.

```bash
# Approve a protocol to pull USDC from the Manager
cast calldata "approve(address,uint256)" <spender> <amount>

# Transfer USDC to a whitelisted destination
cast calldata "transfer(address,uint256)" <recipient> <amount>

# Any protocol function
cast calldata "deposit(uint256,address)" <amount> $MANAGER
```

{% hint style="warning" %}
**Amounts are in the token's own decimals — 6 for USDC, not 18.** `execute` performs no
validation of any kind on the calldata. A misplaced decimal moves 10¹²× the intended
amount, and the only thing standing between that and a loss is whether the destination is
willing to send it back.
{% endhint %}
{% endstep %}

{% step %}
### Simulate the batch

```bash
cast call $MANAGER "execute(address[],bytes[])(bytes[])" \
  "[<target1>,<target2>]" "[<data1>,<data2>]" \
  --from <operator> --rpc-url $RPC
```

This returns each call's return data without sending anything. A successful simulation
confirms the guards pass and no target reverts — it does **not** confirm the amounts are
correct.

{% hint style="danger" %}
Simulate every batch. There is no dry-run mode, no confirmation step, and no way to recall
a transfer once it lands.
{% endhint %}
{% endstep %}

{% step %}
### Send

```bash
cast send $MANAGER "execute(address[],bytes[])" \
  "[<target1>,<target2>]" "[<data1>,<data2>]" \
  --rpc-url $RPC --private-key $PK
```
{% endstep %}

{% step %}
### Verify

```bash
# Manager's remaining balance
cast call $ASSET "balanceOf(address)(uint256)" $MANAGER --rpc-url $RPC

# The batch, with full targets and calldata
cast logs --address $MANAGER "BatchExecuted(address,address[],bytes[])" \
  --from-block latest --rpc-url $RPC
```

`BatchExecuted` records the complete calldata of every call, so each deployment is
publicly auditable after the fact.
{% endstep %}
{% endstepper %}

## Behaviour to know before you rely on it

**The batch is atomic.** One failing call reverts the entire transaction — no partial
application. Ordering within a batch is therefore safe for dependent operations
(`approve` then `deposit` in one batch is fine).

**Reverts bubble up raw.** A failing target's revert data is re-thrown verbatim, so what
you see is the *target's* error, not a Manager error. Decode it against the target's ABI,
not the Manager's:

```bash
cast 4byte <selector>
```

**`execute` cannot send native ETH.** It is not `payable` and passes no `value`, so every
call carries `msg.value == 0`. Native ETH held by the Manager cannot be moved through this
function at all.

**There is no reentrancy guard.** `execute` makes raw calls with no lock. Batching calls to
a target that can call back into the Manager has no protection.

**The whitelist cannot include the vault or Yield contract.** [`setWhitelistedAddresses`](../reference/roles.md)
rejects both. This is load-bearing: without it, `execute` could reach `mintVaultToken` and
`updateTotalAssets` and forge share supply and vault accounting directly.

## `transferToVault` — funding redemptions

The return leg. This is the function that makes withdrawals actually payable.

```bash
# 1. What is owed to everyone with a matured or pending request
cast call $VAULT "totalRequestedAmount()(uint256)" --rpc-url $RPC

# 2. What the vault currently holds
cast call $ASSET "balanceOf(address)(uint256)" $VAULT --rpc-url $RPC

# 3. What the Manager has available to send
cast call $ASSET "balanceOf(address)(uint256)" $MANAGER --rpc-url $RPC

# 4. Push the shortfall in
cast send $MANAGER "transferToVault(address,uint256)" $ASSET <amount> \
  --rpc-url $RPC --private-key $PK
```

{% hint style="warning" %}
**This step is the protocol's withdrawal liveness.** The vault holds no liquidity buffer,
and `_withdraw` transfers only from the vault's own balance — it cannot pull from the
Manager. A user whose cooldown has elapsed cannot exit until this call is made.

The protocol's invariant documentation records that *"users can always eventually
withdraw"* **does not hold** precisely because this step is manual and offchain-triggered.
{% endhint %}

Two rough edges worth knowing:

- **It emits no event.** Redemption funding is visible only as a plain ERC-20 `Transfer`
  into the vault. Do not build monitoring against a `transferToVault` event — there isn't
  one. (`AssetsWithdrawn` is declared in `IManager` but never emitted anywhere.)
- **It has no zero-amount check and no NatSpec** — the only function in `Manager` missing
  both.

Anyone can also fund the vault with a plain ERC-20 transfer; the operator path is simply
the intended one.

## `redeemFor` — settling on a user's behalf

```bash
cast send $MANAGER "redeemFor(address,address)" $VAULT <user> \
  --rpc-url $RPC --private-key $PK
```

Bounded and safe: it pays only that user, only the amount already locked into their
request. It cannot redirect funds or change amounts.

{% hint style="info" %}
This path does **not** check the cooldown. It can settle a request before it has matured —
paying the user their locked amount early. It cannot take anything from them, but it does
end their position sooner than they planned.
{% endhint %}

Requires the vault to be funded, exactly like a user-initiated redemption.

## Preflight script

Committed at `script/operator-preflight.sh`:

```bash
./script/operator-preflight.sh $MANAGER $VAULT $RPC <target> [<target> ...]
```

Checks whitelist status for each target, prints Manager and vault balances, and reports
whether pending redemptions are currently funded.

## Every guard on `execute`

| Guard | Reverts with |
|---|---|
| Caller holds `OPERATOR_ROLE` | `AccessControlUnauthorizedAccount` |
| `targets.length == data.length` | `LengthMismatch` |
| Every target whitelisted | `NotWhitelisted` |
| Every call succeeds | *the target's own revert data, bubbled raw* |

That is the complete list. Note what is absent: no amount limit, no destination-specific
cap, no rate limit, no daily ceiling, no pause check.

## The trust boundary

{% hint style="danger" %}
`execute` is where capital stops being governed by code and starts being governed by an
offchain agreement.

**Enforced onchain:** only whitelisted addresses can receive capital; only ADMIN can change
that list; every deployment emits `BatchExecuted` with full calldata.

**Not enforced onchain:** how much leaves, when it returns, or whether it returns at all.
{% endhint %}

Operational discipline is the actual control here, not the contract. Practical guidance:

- **Simulate every batch**, including ones identical to yesterday's.
- **Prefer exact approvals over infinite ones.** `execute` can grant unlimited allowances to
  whitelisted targets; a compromised or upgradeable target with a standing infinite approval
  can drain the Manager without any further operator action.
- **Check the redemption backlog before deploying**, not after. Deploying capital while
  matured redemptions sit unfunded strands users who have already given up their shares.
- **Reconcile deployed capital against reported P&L.** `BatchExecuted` tells you what left;
  `DistributeYield` tells you what the strategy claims it earned. Nothing onchain connects
  the two — see [Reporting P&L](reporting-pnl.md).
