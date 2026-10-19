# Fees

There are two fees in the protocol. Only one is charged to you directly.

| Fee | Who pays | When | Cap |
|---|---|---|---|
| **Exit fee** | You | On `requestRedeem` | **1%** — hard-coded, cannot be raised |
| **Performance fee** | Taken from yield | On each profit report | 50% of profit by default; governance can raise |

There is **no deposit fee** and **no management fee**. Entry is free, and holding costs
nothing.

## The exit fee

Charged when you call `requestRedeem`. It is deducted from the amount you are quoted, so
the figure stored in your request is already net of it.

```bash
# Current fee — scaled so that 1e18 = 1%
cast call <vault> "fee()(uint256)" --rpc-url <rpc>

# What you would actually receive, net of fee
cast call <vault> "previewRedeem(uint256)(uint256)" <shares> --rpc-url <rpc>
```

{% hint style="success" %}
**The 1% cap is enforced in the contract**, not by policy. `setFee` reverts on any value
above it. This is one of the few parameters governance genuinely cannot raise beyond its
stated bound.
{% endhint %}

### Where it goes

The fee is not burned. It is minted to the treasury as shares.

This design keeps the share price neutral: your shares are burned in full, but only the
net asset amount is removed from the vault. Without the offsetting mint, the difference
would silently raise the share price for everyone who stayed. Minting the fee to the
treasury instead makes it an explicit claim rather than an implicit subsidy.

## The performance fee

Taken from reported profit before the remainder reaches the share price. You are not billed
for it — it reduces the yield you receive rather than being deducted from your principal.

```bash
# Cap, in basis points. 5000 = 50% of profit
cast call <yield> "maxFeePercentage()(uint256)" --rpc-url <rpc>
```

{% hint style="warning" %}
**This cap is adjustable up to 100%.** The contract only checks that the value is at most
`10_000` basis points, so governance can in principle assign all reported profit to the
treasury. The change goes through the 48-hour timelock, so it is public before it takes
effect (see [Governance](../operations/governance.md)). Unlike the exit fee, there is no structural
ceiling here.
{% endhint %}

The fee is paid to the treasury in shares, priced so that they are worth exactly the fee
amount once vesting completes — the treasury is paid on the same schedule as depositors,
not ahead of them.

### The treasury also absorbs losses

The performance fee is not one-directional. When a loss is reported, the treasury's shares
are burned to absorb its proportional share of it.

If the treasury does not hold enough shares to cover its portion, the shortfall is recorded
as `treasuryDebt`, and future performance fees are redirected to depositors until it is
repaid. The treasury earns nothing new while it owes.

```bash
cast call <yield> "treasuryDebt()(uint256)" --rpc-url <rpc>
```

A non-zero `treasuryDebt` means depositors are currently receiving 100% of reported profit.

## Worked example

You deposit 10,000 USDC and receive shares. Over time, 1,000 USDC of profit is reported at
a 50% performance fee — meaning `amount = 1000` to shareholders and `feeAmount = 500` to
the treasury, as two separate slices of realised P&L.

| | |
|---|---|
| Your deposit | 10,000 USDC |
| Profit credited to shareholders | +1,000 USDC (vesting over 7 days) |
| Your position after vesting | ~11,000 USDC |
| Exit fee at 1% on redemption | −110 USDC |
| **You receive** | **~10,890 USDC** |

The treasury separately holds shares worth ~500 USDC plus your 110 USDC exit fee.

{% hint style="info" %}
Note that `feeAmount` is reported **on top of** `amount`, not carved out of it. In this
example the strategy realised 1,500 USDC in total: 1,000 to depositors, 500 to the
treasury.
{% endhint %}

## Checking current terms

Fees can change, with 48 hours' public notice through the timelock. Before depositing:

```bash
cast call <vault> "fee()(uint256)" --rpc-url <rpc>
cast call <yield> "maxFeePercentage()(uint256)" --rpc-url <rpc>
```

Watch `FeeSet` on the vault and `MaxFeePercentage` on the Yield contract for changes.
