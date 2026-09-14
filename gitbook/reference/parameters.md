# Parameters

{% hint style="warning" %}
Every parameter here is governance-adjustable with **no timelock** on the current live
deployment. Read the live value before you rely on it — the defaults below are deploy-time
values, not current state.

A 48-hour timelock is implemented and pending deployment; once live, every change on this
page requires a 48-hour public delay. See
[Governance and the timelock](../operations/governance.md).
{% endhint %}

## Vault parameters

| Parameter | Deploy default | Maximum | Read with |
|---|---|---|---|
| Cooldown period | 1 day (86,400s) | **7 days** (hard-coded) | `cooldownPeriod()` |
| Vesting period | 7 days (604,800s) | **30 days** (hard-coded) | `vestingPeriod()` |
| Exit fee | governance-set | **1%** (hard-coded) | `fee()` |

```bash
cast call <vault> "cooldownPeriod()(uint256)" --rpc-url <rpc>
cast call <vault> "vestingPeriod()(uint256)" --rpc-url <rpc>
cast call <vault> "fee()(uint256)" --rpc-url <rpc>
```

The exit fee is scaled so that `1e18` = 1%. The three maximums above are enforced in the
contract — `setFee`, `setCooldownPeriod`, and `setVestingPeriod` all revert beyond them.

## Yield parameters

| Parameter | Deploy default | Maximum | Read with |
|---|---|---|---|
| Max change per epoch | 50 bps (0.5% of assets) | 10,000 bps (100%) | `maxYieldPercentage()` |
| Performance fee cap | 5,000 bps (50% of profit) | 10,000 bps (100%) | `maxFeePercentage()` |
| Min interval between epochs | 79,200s (22 hours) | — (**no minimum**) | `minDistributionInterval()` |

```bash
cast call <yield> "maxYieldPercentage()(uint256)" --rpc-url <rpc>
cast call <yield> "maxFeePercentage()(uint256)" --rpc-url <rpc>
cast call <yield> "minDistributionInterval()(uint256)" --rpc-url <rpc>
```

{% hint style="warning" %}
These three have no meaningful ceiling. The performance fee can be raised to 100% of
profit, and the minimum interval can be set as low as 1 second — effectively removing the
rate limit that bounds a compromised or dishonest reporter. Unlike the vault parameters,
there is no meaningful structural bound here.

Note also that there is **no maximum** interval. Nothing requires yield to be reported at
all: if reporting stops, the share price simply freezes at its last value with no staleness
check and no warning.
{% endhint %}

## Capacity parameters

Held on the Manager, keyed by vault address.

| Parameter | Meaning | Read with |
|---|---|---|
| Min deposit | Minimum shares per deposit | `minSharesInVaultToken(<vault>)` |
| Max redeem | Max assets per redemption request; `0` = uncapped | `maxRedeemCap(<vault>)` |

```bash
cast call <manager> "minSharesInVaultToken(address)(uint256)" <vault> --rpc-url <rpc>
cast call <manager> "maxRedeemCap(address)(uint256)" <vault> --rpc-url <rpc>
```

## Which caps are real

Worth being precise about, since "capped" means two different things here:

**Enforced by the contract, unchangeable without an upgrade:**

- Exit fee ≤ 1%
- Cooldown ≤ 7 days
- Vesting ≤ 30 days

**Nominal — a current setting governance can change at will:**

- Performance fee (up to 100%)
- Per-epoch yield magnitude (up to 100%)
- Reporting interval (down to 1 second; and with no maximum at all)
- Redemption cap and minimum deposit

Note that even the enforced caps are only as durable as the implementation — an upgrade can
change them, with no delay.

## Checking everything at once

```bash
VAULT=<vault>; YIELD=<yield>; MANAGER=<manager>; RPC=<rpc>

for f in "cooldownPeriod()(uint256)" "vestingPeriod()(uint256)" "fee()(uint256)" \
         "paused()(bool)" "totalAssets()(uint256)" "exchangeRate()(uint256)"; do
  printf "%-32s " "$f"; cast call $VAULT "$f" --rpc-url $RPC
done

for f in "maxYieldPercentage()(uint256)" "maxFeePercentage()(uint256)" \
         "minDistributionInterval()(uint256)" "epoch()(uint256)" "treasuryDebt()(uint256)"; do
  printf "%-32s " "$f"; cast call $YIELD "$f" --rpc-url $RPC
done
```

## Watching for changes

| Event | Contract | Parameter |
|---|---|---|
| `FeeSet` | Vault | Exit fee |
| `CooldownPeriodUpdated` | Vault | Cooldown |
| `VestingPeriodUpdated` | Vault | Vesting |
| `MaxYieldPercentageSet` | Yield | Per-epoch cap |
| `MaxFeePercentage` | Yield | Performance fee cap |
| `MinDistributionIntervalSet` | Yield | Reporting interval |
| `MaxRedeemCapSet` | Manager | Redemption cap |
| `MinSharesInVaultTokenSet` | Manager | Minimum deposit |
