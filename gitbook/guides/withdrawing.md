# Withdrawing

{% hint style="warning" %}
Withdrawal does not work the way a standard ERC-4626 vault works. Read this page before
you deposit, not after.
{% endhint %}

Withdrawing is two steps with a mandatory waiting period between them.

## Step 1 — request

```bash
cast send <vault> "requestRedeem(uint256)" <shares> \
  --rpc-url <rpc> --private-key $PK
```

Three things happen immediately:

1. **Your shares are burned.** They are gone from your balance right away.
2. **Your payout is calculated and locked in**, at the current share price, net of the exit
   fee.
3. **The cooldown timer starts.**

{% hint style="danger" %}
**There is no cancel function.** Once you request, you are committed to that amount. You
cannot undo it, change it, or add to it.
{% endhint %}

## Step 2 — collect, after the cooldown

Check whether your request has matured:

```bash
cast call <vault> "canExecuteRedeem(address)(bool)" <you> --rpc-url <rpc>
```

Read back your request — you need the exact stored values:

```bash
cast call <vault> "getRedeemRequest(address)(uint256,uint256,uint256,bool)" <you> \
  --rpc-url <rpc>
# returns: shares, assets, timestamp, exists
```

Then collect, passing the stored share count exactly:

```bash
cast send <vault> "redeem(uint256,address,address)" <shares> <you> <you> \
  --rpc-url <rpc> --private-key $PK
```

Or by asset amount instead, again matching exactly:

```bash
cast send <vault> "withdraw(uint256,address,address)" <assets> <you> <you> \
  --rpc-url <rpc> --private-key $PK
```

## The rules that catch people out

### Your amount is frozen at request time

From the moment you request, you are out of the strategy. If a profit is reported during
your cooldown you do **not** receive any of it. If a loss is reported you are **not**
affected by it.

Requesting is an exit, not a queued sale order.

### One request at a time

`requestRedeem` reverts with `RedemptionRequestAlreadyExists` if you already have one
pending. To exit a position larger than `maxRedeemCap`, you must go through the full cycle
repeatedly: request, wait, collect, request again.

### You must collect it yourself

The vault requires the caller to be the owner of the request. Approving another address
does **not** let it withdraw on your behalf — the standard ERC-4626 allowance flow is
intentionally disabled. Calls from anyone else revert with `NotAuthorized`.

This means: if you deposit from an address you later lose access to, no other address can
recover the position for you.

### The amount must match exactly

`redeem(shares)` requires `shares` to equal your request's stored share count exactly.
`withdraw(assets)` requires an exact asset match. Anything else reverts with
`InvalidWithdrawalRequest`.

**Partial collection is not supported.** Always read `getRedeemRequest` and pass the stored
value straight back.

### `maxWithdraw` and `maxRedeem` lie

They are not overridden and will report far more than you can actually withdraw. Ignore
them; use `getRedeemRequest` and `canExecuteRedeem`.

{% hint style="danger" %}
This is the most common integration failure. Any tooling that sizes a withdrawal from
`maxWithdraw` will build a transaction that reverts.
{% endhint %}

## Your redemption may not be payable immediately

Even after your cooldown ends, collection can fail — because **the vault holds no liquidity
buffer**. The assets to pay you must be pushed back onchain by an operator first.

You can check whether pending redemptions are currently funded:

```bash
# Total owed to everyone with a pending request
cast call <vault> "totalRequestedAmount()(uint256)" --rpc-url <rpc>

# What the vault actually holds
cast call <asset> "balanceOf(address)(uint256)" <vault> --rpc-url <rpc>
```

If the balance is below `totalRequestedAmount()`, not every matured request can be paid
right now. The contract cannot force funding — this is an offchain operational step.

{% hint style="danger" %}
The protocol's own invariant documentation records that **"users can always eventually
withdraw" does not hold**. Withdrawal liveness depends on an offchain actor. See
[Risks](../risks/README.md).
{% endhint %}

## An operator can settle your request early

The Manager can call `redeemFor` to pay out your request, and this path does **not** check
the cooldown. It can only pay you, at the amount already locked in — so it cannot be used
to take anything from you — but it can end your position earlier than you planned.

## Errors you might hit

| Error | Meaning |
|---|---|
| `RedemptionRequestAlreadyExists` | You already have a pending request |
| `NoRedemptionRequest` | You called `redeem`/`withdraw` without requesting first |
| `CooldownNotFinished` | The cooldown has not elapsed yet |
| `InvalidWithdrawalRequest` | The amount does not exactly match your stored request |
| `NotAuthorized` | You are not the owner of the request |
| `MaxRedeemCapExceeded` | Your request exceeds the per-request cap |
| `InsufficientShares` | You do not hold the shares you are trying to request |
| ERC-20 transfer revert | The vault is not funded — nothing to pay you with yet |
| `EnforcedPause` | The vault is paused; withdrawals are blocked |

## Full worked example

```bash
VAULT=<vault>; ASSET=<asset>; ME=<you>; RPC=<rpc>

# 1. See what your shares are worth net of fee
cast call $VAULT "previewRedeem(uint256)(uint256)" \
  $(cast call $VAULT "balanceOf(address)(uint256)" $ME --rpc-url $RPC) --rpc-url $RPC

# 2. Request the full balance
SHARES=$(cast call $VAULT "balanceOf(address)(uint256)" $ME --rpc-url $RPC)
cast send $VAULT "requestRedeem(uint256)" $SHARES --rpc-url $RPC --private-key $PK

# 3. Wait out the cooldown, then check
cast call $VAULT "canExecuteRedeem(address)(bool)" $ME --rpc-url $RPC

# 4. Read the stored request and collect with the exact value
cast call $VAULT "getRedeemRequest(address)(uint256,uint256,uint256,bool)" $ME --rpc-url $RPC
cast send $VAULT "redeem(uint256,address,address)" $SHARES $ME $ME \
  --rpc-url $RPC --private-key $PK
```
