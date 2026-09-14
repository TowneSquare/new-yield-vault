# Depositing

Depositing is standard ERC-4626 and works as you would expect. Approve the vault, then
deposit.

## Steps

{% stepper %}
{% step %}
### Approve the vault

```bash
cast send <asset> "approve(address,uint256)" <vault> <amount> \
  --rpc-url <rpc> --private-key $PK
```
{% endstep %}

{% step %}
### Deposit

```bash
cast send <vault> "deposit(uint256,address)" <amount> <you> \
  --rpc-url <rpc> --private-key $PK
```

Returns the number of shares minted. Alternatively, `mint(shares, receiver)` if you want an
exact share count and are willing to let the asset amount vary.
{% endstep %}

{% step %}
### Confirm

```bash
cast call <vault> "balanceOf(address)(uint256)" <you> --rpc-url <rpc>
```
{% endstep %}
{% endstepper %}

## What to know

**There is no deposit fee.** Entry is free. The only fee you pay as a depositor is the exit
fee on redemption. There is also no ongoing management fee.

**Your assets leave the vault immediately.** The deposit is forwarded to the Manager
contract in the same transaction. This is by design, and it is why withdrawal requires a
cooldown — see [Withdrawing](withdrawing.md).

**There is a minimum deposit size.** It is expressed in shares, not assets. Deposits below
it revert with `InvalidMinShares`.

```bash
cast call <manager> "minSharesInVaultToken(address)(uint256)" <vault> --rpc-url <rpc>
```

**You start earning from the next report.** Yield is credited through periodic reports, and
profit vests over several days. A deposit made shortly before a report will not capture the
full epoch's yield — this is deliberate, and it protects existing depositors from being
diluted. See [The share price](../overview/share-price.md).

## Timing your deposit

There is no advantage to timing a deposit around a report. The vesting mechanism exists
specifically to remove that edge — depositing one second before a profit report earns you
almost none of it.

What is worth checking before you deposit:

```bash
# Is the vault paused? A paused vault rejects deposits (and withdrawals)
cast call <vault> "paused()(bool)" --rpc-url <rpc>

# Current exit fee — this is what you will pay on the way out
cast call <vault> "fee()(uint256)" --rpc-url <rpc>

# Current cooldown — how long your exit will take
cast call <vault> "cooldownPeriod()(uint256)" --rpc-url <rpc>

# Is there a cap on redemption size? Relevant for planning a large position
cast call <manager> "maxRedeemCap(address)(uint256)" <vault> --rpc-url <rpc>
```

{% hint style="info" %}
**Sizing a large position.** If `maxRedeemCap` is non-zero, you can only redeem up to that
amount per request, and you can only have one request pending at a time. A position larger
than the cap must be exited sequentially — cooldown, collect, request again. Factor that
into how long a full exit would take.
{% endhint %}

## Errors you might hit

| Error | Cause |
|---|---|
| `InvalidMinShares` | Deposit is below the minimum share threshold |
| `InvalidDeposit` | Zero amount, zero shares, or zero receiver address |
| `EnforcedPause` | The vault is paused |
| ERC-20 revert | Insufficient approval or balance |

## Next

{% content-ref url="withdrawing.md" %}
[withdrawing.md](withdrawing.md)
{% endcontent-ref %}
