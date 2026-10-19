# Tracking your position

Everything below is readable onchain without permission. Set these first:

```bash
VAULT=<vault proxy>
MANAGER=<manager proxy>
YIELD=<yield proxy>
ASSET=<underlying token>
ME=<your address>
RPC=<rpc url>
```

## Your position

```bash
# Shares held
cast call $VAULT "balanceOf(address)(uint256)" $ME --rpc-url $RPC

# Current value, gross
cast call $VAULT "convertToAssets(uint256)(uint256)" <shares> --rpc-url $RPC

# What you would actually be quoted, net of the exit fee
cast call $VAULT "previewRedeem(uint256)(uint256)" <shares> --rpc-url $RPC
```

## Your pending redemption

```bash
# shares, assets, timestamp, exists
cast call $VAULT "getRedeemRequest(address)(uint256,uint256,uint256,bool)" $ME --rpc-url $RPC

# Has the cooldown elapsed?
cast call $VAULT "canExecuteRedeem(address)(bool)" $ME --rpc-url $RPC
```

The `assets` value is what you will receive — fixed at request time and unaffected by
anything that happens afterwards.

## Is your withdrawal actually payable?

Cooldown elapsed is necessary but not sufficient. The vault must also hold enough assets.

```bash
# Owed to everyone with a pending request
cast call $VAULT "totalRequestedAmount()(uint256)" --rpc-url $RPC

# Actually held by the vault
cast call $ASSET "balanceOf(address)(uint256)" $VAULT --rpc-url $RPC
```

{% hint style="info" %}
**This is the most useful health check available to a depositor.** If the vault's balance is
persistently below `totalRequestedAmount()`, redemptions are not being funded promptly.
Tracking this over time tells you more about operational health than the share price does.
{% endhint %}

## Vault-wide state

```bash
# Recognised assets (excludes profit still vesting)
cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC

# Profit reported but not yet in the share price
cast call $VAULT "getUnvestedAmount()(uint256)" --rpc-url $RPC

# Total shares outstanding
cast call $VAULT "totalSupply()(uint256)" --rpc-url $RPC

# Share price
cast call $VAULT "exchangeRate()(uint256)" --rpc-url $RPC

# Paused? Blocks both deposits and withdrawals
cast call $VAULT "paused()(bool)" --rpc-url $RPC
```

## Yield reporting history

```bash
# Current epoch number — increments once per report
cast call $YIELD "epoch()(uint256)" --rpc-url $RPC

# When the last report landed
cast call $YIELD "lastDistributionTime()(uint256)" --rpc-url $RPC

# Cumulative reported profit and loss
cast call $YIELD "profit()(uint256)" --rpc-url $RPC
cast call $YIELD "loss()(uint256)" --rpc-url $RPC

# Unabsorbed loss the treasury owes
cast call $YIELD "treasuryDebt()(uint256)" --rpc-url $RPC
```

Comparing `profit()` against `loss()` gives you the strategy's reported lifetime
performance. A stalled `epoch()` or a `lastDistributionTime()` far in the past means
reporting has stopped.

## Events worth watching

```bash
# Every yield report — this is what moves the share price
cast logs --address $YIELD "DistributeYield(address,address,address,uint256,uint256,bool)" \
  --rpc-url $RPC

# Where capital is allowed to go
cast logs --address $MANAGER "WhitelistUpdated(address,address,bool)" --rpc-url $RPC

# Capital deployment, with full calldata
cast logs --address $MANAGER "BatchExecuted(address,address[],bytes[])" --rpc-url $RPC
```

| Event | Contract | Why you care |
|---|---|---|
| `DistributeYield` | Yield | An epoch's result was reported |
| `TreasuryDebtAccrued` | Yield | A loss exceeded what the treasury could absorb |
| `RedemptionRequested` | Vault | Your request was recorded, with the locked amount |
| `Withdraw` / `WithdrawalExecuted` | Vault | A redemption was paid |
| `FeeSet`, `CooldownPeriodUpdated` | Vault | Your terms changed |
| `Paused` / `Unpaused` | Vault | Deposits and withdrawals halted or resumed |
| `WhitelistUpdated` | Manager | A new destination for capital was authorised |
| `Upgraded` | all three | Contract code was replaced |
| `RoleGranted` / `RoleRevoked` | all three | Privileged access changed hands |

{% hint style="warning" %}
`Upgraded`, `RoleGranted`, and `WhitelistUpdated` are the moment a change takes effect. Every
upgrade, role grant and whitelist addition is first scheduled on the 48-hour timelock, so
watch `CallScheduled` on the timelock too — it fires 48 hours earlier, which makes
monitoring them is preventative, not just reactive. `WhitelistUpdated` with `status = false`
is the exception: the guardian can remove entries instantly. See
[Governance and the timelock](../operations/governance.md).
{% endhint %}

## Monitoring gaps

Two things you cannot track by event:

- **`transferToVault` emits no event.** Redemption funding — the step your withdrawal
  depends on — is only visible as a plain ERC-20 `Transfer` to the vault.
- **`AssetsWithdrawn` is declared but never emitted.** Do not build monitoring against it.
