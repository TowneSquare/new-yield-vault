# The share price

Your position is worth `your shares x the share price`. The share price starts at 1 and
moves only when the offchain engine reports results. Your share count never changes on its
own — there are no rebases and no auto-compounding transactions.

## Checking it

```bash
# What one share is worth, in underlying asset terms
cast call <vault> "exchangeRate()(uint256)" --rpc-url <rpc>

# Your share balance
cast call <vault> "balanceOf(address)(uint256)" <you> --rpc-url <rpc>

# What you would actually receive if you redeemed now (net of the exit fee)
cast call <vault> "previewRedeem(uint256)(uint256)" <shares> --rpc-url <rpc>
```

{% hint style="info" %}
`previewRedeem` is the number that matters — it is net of the exit fee, so it reflects what
you would actually be quoted. `exchangeRate()` is gross.
{% endhint %}

## Profit arrives gradually

When a profit is reported, it is **not** added to the share price immediately. It is
released linearly over the vesting period (7 days by default).

```
Profit of 1000 reported at day 0, 7-day vesting:

day 0   ─ 0 recognised      ┐
day 1   ─ ~143 recognised   │ share price rises
day 4   ─ ~571 recognised   │ smoothly across
day 7   ─ 1000 recognised   ┘ the window
```

The reason is fairness on entry. Without vesting, a deposit made one second before a report
would capture the same yield as capital that was exposed for the whole epoch. Vesting means
you earn roughly in proportion to how long you were actually in the vault.

The practical consequence: **a reported profit does not immediately show up in your
position.** It accrues over the following days.

```bash
# Profit reported but not yet recognised in the share price
cast call <vault> "getUnvestedAmount()(uint256)" --rpc-url <rpc>
```

## Losses apply immediately

A reported loss is applied at once, with no vesting.

Unvested profit acts as a buffer and absorbs the loss first. If a loss is smaller than the
profit still vesting, the recognised share price does not move at all — the loss is
cancelled against yield that had not yet reached anyone.

If the loss is larger, the excess reduces the share price immediately.

## The treasury absorbs part of a loss

When a loss is reported, the treasury's shares are burned to absorb its share of it — the
mirror of the performance fee it earns on profit.

If the treasury does not hold enough shares to cover its portion, the uncovered amount is
recorded as `treasuryDebt`, and future performance fees are diverted to shareholders until
that debt is cleared. The treasury earns nothing new until it has made good on prior
losses.

```bash
cast call <yield> "treasuryDebt()(uint256)" --rpc-url <rpc>
```

## Limits on each report

| Limit | Default | Meaning |
|---|---|---|
| Max change per epoch | 0.5% of vault assets | Caps how far one report can move the price |
| Min interval between epochs | ~22 hours | Caps how often reports can land |
| Epoch sequencing | strict | Reports must be consecutive; duplicates rejected |

These bound the damage a single bad or malicious report can do. They do **not** bound it
cumulatively — sustained reporting at the cap compounds over time. Both limits are
governance-adjustable.

## Decimals

{% hint style="warning" %}
Your shares always have **18 decimals**, even when the underlying asset has 6 (as USDC
does). Do not assume share amounts and asset amounts use the same scale — converting
between them requires `convertToAssets` / `convertToShares`, not a raw comparison.
{% endhint %}

```bash
cast call <vault> "decimals()(uint8)" --rpc-url <rpc>
cast call <asset> "decimals()(uint8)" --rpc-url <rpc>
```
