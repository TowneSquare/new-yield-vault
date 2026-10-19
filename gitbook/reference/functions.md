# Function reference

Functions available to you as a depositor, plus the standard ERC-4626 surface and where it
deviates.

{% hint style="warning" %}
**Integrators start here.** This vault deviates from ERC-4626 in three ways that will break
naive integrations: withdrawal requires a prior request, `maxWithdraw`/`maxRedeem`
over-report, and allowance-based withdrawal is disabled.
{% endhint %}

## Entering

### `deposit(uint256 assets, address receiver) → uint256 shares`

Standard. Transfers `assets` from you, mints shares to `receiver`. Assets are forwarded to
the Manager in the same transaction.

Reverts: `InvalidMinShares` (below minimum), `InvalidDeposit` (zero amount/shares/receiver),
`EnforcedPause`.

### `mint(uint256 shares, address receiver) → uint256 assets`

Standard. Mints an exact share count, pulling however many assets that requires.

## Exiting

### `requestRedeem(uint256 shares)`

**Step 1 of withdrawal.** Burns your shares immediately, quotes your payout at the current
price net of the exit fee, stores it, and starts the cooldown.

Mints the exit fee to the treasury as shares.

Reverts: `RedemptionRequestAlreadyExists`, `ZeroAmount`, `InsufficientShares`,
`InsufficientAssets`, `MaxRedeemCapExceeded`, `EnforcedPause`.

{% hint style="danger" %}
Irreversible. There is no cancel function.
{% endhint %}

### `redeem(uint256 shares, address receiver, address owner) → uint256 assets`

**Step 2.** Pays out your stored request. `shares` must **exactly equal** the stored share
count. `msg.sender` must equal `owner`.

Reverts: `NoRedemptionRequest`, `CooldownNotFinished`, `InvalidWithdrawalRequest` (inexact
amount), `NotAuthorized` (caller ≠ owner), `EnforcedPause`, or an ERC-20 transfer revert if
the vault is unfunded.

### `withdraw(uint256 assets, address receiver, address owner) → uint256 shares`

Same as `redeem`, but keyed on the stored asset amount instead. Same exact-match and
self-only rules.

## Reading your position

| Function | Returns |
|---|---|
| `balanceOf(address)` | Your share balance |
| `getRedeemRequest(address)` | `(shares, assets, timestamp, exists)` |
| `canExecuteRedeem(address)` | Whether the cooldown has elapsed |
| `previewRedeem(uint256 shares)` | Assets you would be quoted, **net of fee** |
| `convertToAssets(uint256 shares)` | Gross value, no fee applied |
| `convertToShares(uint256 assets)` | Shares for a given asset amount |
| `exchangeRate()` | Current share price |

## Reading vault state

| Function | Returns |
|---|---|
| `totalAssets()` | Recognised assets — excludes profit still vesting |
| `getUnvestedAmount()` | Profit reported but not yet in the share price |
| `totalSupply()` | Shares outstanding |
| `totalRequestedAmount()` | Assets owed to all pending requests |
| `fee()` | Exit fee, `1e18` = 1% |
| `cooldownPeriod()`, `vestingPeriod()` | In seconds |
| `paused()` | Whether deposits and withdrawals are blocked |
| `asset()` | The underlying token address |
| `decimals()` | Share decimals — **18**, even for a 6-decimal asset |

## Reading yield state

On the Yield contract:

| Function | Returns |
|---|---|
| `epoch()` | Current epoch number |
| `lastDistributionTime()` | Timestamp of the last report |
| `profit()`, `loss()` | Cumulative reported figures |
| `treasuryDebt()` | Unabsorbed loss the treasury owes |
| `maxYieldPercentage()`, `maxFeePercentage()` | Caps, in basis points |
| `minDistributionInterval()` | Minimum seconds between reports |

## How profit and loss reach your shares

### `distributeYield(uint256 amount, uint256 feeAmount, uint256 nonce, bool isProfit)`

Callable only by the Rebalancer, on the Yield contract. You cannot call it, but it is the
function that determines what your shares are worth, so it is worth understanding precisely.

#### What gets reported

| Parameter | Meaning |
|---|---|
| `amount` | The shareholders' slice of realised P&L |
| `feeAmount` | The treasury's slice, **on top of** `amount` — not carved out of it |
| `nonce` | Epoch number; must equal `epoch + 1` exactly |
| `isProfit` | Direction of the report |

{% hint style="info" %}
`feeAmount` being additive rather than deductive is the detail most people get wrong. A
report of `amount = 1000, feeAmount = 500` means the strategy realised **1,500** in total:
1,000 to depositors, 500 to the treasury. The vault books both.
{% endhint %}

#### What is checked before anything is booked

| Guard | Effect |
|---|---|
| `amount <= totalAssets() * maxYieldPercentage / 10_000` | Caps report size — default 50 bps (0.5% of assets) |
| `feeAmount <= amount * maxFeePercentage / 10_000` | Caps the fee slice — default 5,000 bps (50% of `amount`) |
| `nonce == epoch + 1` | Strict sequencing; the primary replay defence |
| `trxns[proofHash]` | Duplicate rejection, keyed on `(vaultToken, amount, nonce, isProfit)` |
| `lastDistributionTime + minDistributionInterval <= block.timestamp` | Rate limit — default 79,200s (~22 hours) |

Note that `feeAmount` is **not** part of `proofHash`, so it does not contribute to the
replay identity — the `nonce` check is what actually prevents a report being submitted
twice.

#### The accounting the share price is derived from

Two storage values do all the work:

```
virtualAssets        — every asset the vault believes it is owed
getUnvestedAmount()  — profit reported but not yet released

totalAssets()        = virtualAssets - getUnvestedAmount()
share price          = totalAssets() / totalSupply()   (with ERC-4626 virtual-share offset)
```

`totalAssets()` is an accounting figure, not a token balance, and is never reconciled
against one. Profit is added to `virtualAssets` immediately but withheld from
`totalAssets()` until it vests — which is what makes the share price rise gradually rather
than step.

#### On profit

{% stepper %}
{% step %}
##### Outstanding treasury debt is settled first

If `treasuryDebt > 0`, up to `feeAmount` of it is cleared and that portion is **redirected
to depositors** instead of being paid to the treasury. Shareholders receive
`amount + repaid`. The treasury earns nothing new while it owes.
{% endstep %}

{% step %}
##### The shareholders' slice enters the vesting schedule

`transferInRewards(amount + repaid, true)` adds the profit to `virtualAssets` and sets
`vestingAmount`, then stamps `lastDistributionTimestamp = block.timestamp`.

From there `getUnvestedAmount()` decays linearly to zero across `vestingPeriod`, releasing
the profit into `totalAssets()` as it goes.

{% hint style="warning" %}
A new profit report **restarts the vesting clock for profit already in flight**.
`vestingAmount` is set to `new + still-unvested`, and the timestamp resets — so a
previously reported profit that was partway through vesting is re-spread across a fresh
full period.
{% endhint %}
{% endstep %}

{% step %}
##### The treasury's fee is minted as shares, split across the schedule

`previewProfitFee(netFee)` returns three values:

- `feeShares` — priced against the **fully vested** base (`virtualAssets`), rounded up, so
  they are worth exactly `netFee` once the schedule completes
- `recognisedFee` — the most that can enter `totalAssets()` right now **without the mint
  moving the share price**, rounded down
- `vestingFee` — the remainder, added to the same vesting schedule as everyone else's
  profit

The treasury is paid in full, but on the same timetable as depositors rather than ahead of
them. Pricing the shares against the recognised base instead would hand the treasury extra
shares that then capture part of the depositors' profit as it vests.
{% endstep %}
{% endstepper %}

#### On loss

Losses are applied **instantly, with no vesting** — the assets are already gone, so
withholding the write-down would leave the vault overstating itself while redemptions kept
settling against the inflated price.

{% stepper %}
{% step %}
##### Unvested profit absorbs the loss first

`_absorbLossIntoUnvested(amount)` cancels the loss against profit that has not vested yet.
That profit has been credited to nobody, so destroying it costs no holder anything.

If the loss fits entirely inside the unvested buffer, the recognised share price **does not
move at all**:

```
totalAssets = (virtualAssets - amount) - (unvested - absorbed)
            = virtualAssets - unvested        ← unchanged
```

The surviving profit keeps its **original vesting end date** — `vestingAmount` is rescaled
against the elapsed fraction and `lastDistributionTimestamp` is deliberately left untouched,
rather than restarting the clock.
{% endstep %}

{% step %}
##### The remainder reduces the share price immediately

Whatever the buffer could not absorb is subtracted from `virtualAssets`, and the share
price drops in the same transaction.
{% endstep %}

{% step %}
##### The treasury burns its own shares to absorb its slice

`feeAmount` worth of treasury shares are burned — the mirror of the fee it earns on profit.

The burn is **clamped to the treasury's actual balance**. Treasury shares are ordinary
ERC-20 shares it can transfer or redeem at any time, so burning unconditionally would
revert the entire loss report whenever the treasury had been swept — leaving the vault
priced above its real value while redemptions kept settling.
{% endstep %}

{% step %}
##### Any shortfall becomes `treasuryDebt`

If the treasury could not cover its slice, the uncovered portion is written down against
depositors now (the assets are gone regardless) and recorded as `treasuryDebt` rather than
being silently socialised. Future performance fees repay it before the treasury is paid
again.
{% endstep %}
{% endstepper %}

#### What this means for you

- **Profit shows up over days, not instantly.** Watch `getUnvestedAmount()` to see what is
  still in flight.
- **Losses show up immediately**, unless they fit inside the unvested buffer, in which case
  you may not see them at all.
- **A pending redemption is immune to both.** `requestRedeem` freezes your quote, so
  nothing reported after that point reaches you.
- **The reported figures cannot be verified onchain.** The vault has no view of strategy
  balances. See [Risks](../risks/README.md).

#### Events emitted

| Event | Contract | Meaning |
|---|---|---|
| `DistributeYield` | Yield | The report itself: `amount`, `feeAmount`, `isProfit` |
| `TransferRewards` | Vault | Profit entered the vesting schedule |
| `LossAbsorbedIntoUnvested` | Vault | A loss was cancelled against unvested profit |
| `TotalAssetsUpdated` | Vault | `virtualAssets` moved |
| `TreasuryDebtAccrued` | Yield | A loss exceeded what the treasury could absorb |
| `TreasuryDebtRepaid` | Yield | Debt settled; that profit went to depositors |

## ERC-4626 deviations

| Function | Standard behaviour | Here |
|---|---|---|
| `withdraw` / `redeem` | Immediate | Requires a prior `requestRedeem` and elapsed cooldown |
| `maxWithdraw` / `maxRedeem` | Accurate ceiling | **Not overridden — over-reports** |
| Allowance withdrawal | Approved spender can withdraw | **Disabled** — `caller` must equal `owner` |
| `previewWithdraw` / `previewRedeem` | No fee | Includes the exit fee |
| `previewDeposit` / `previewMint` | — | Unchanged; entry is free |
| `totalAssets` | Token balance | Accounting figure; vault holds no assets |

{% hint style="danger" %}
Do not size a withdrawal from `maxWithdraw` or `maxRedeem`. Use `getRedeemRequest` and pass
the stored value back exactly.
{% endhint %}

## Functions you cannot call

Listed so you know they exist and who controls them:

| Function | Contract | Restricted to |
|---|---|---|
| `execute` | Manager | Operator |
| `transferToVault` | Manager | Operator |
| `redeemFor` | Vault / Manager | Manager only — pays the user their locked amount, no cooldown check |
| `distributeYield` | Yield | Rebalancer — see [above](#how-profit-and-loss-reach-your-shares) |
| `setFee`, `setCooldownPeriod`, `setVestingPeriod`, `setManager` | Vault | Admin |
| `unpause`, `emergencyRecover` | Vault | Admin |
| `pause` | Vault | Admin or Guardian |
| `setWhitelistedAddresses`, `setTreasury`, `setManagerAndYield` | Manager | Admin |
| `setMinSharesInVaultToken`, `setMaxRedeemCap` | Manager | Admin |
| `removeWhitelistedAddresses` | Manager | Admin or Guardian |
| `setMaxYieldPercentage`, `setMaxFeePercentage`, `setMinDistributionInterval`, `setManager` | Yield | Admin |
| `upgradeToAndCall`, `grantRole`, `revokeRole` | all three | Governance |
| `updateTotalAssets`, `mintVaultToken`, `burnVaultToken` | Vault | Manager only |
| `transferInRewards` | Vault | Yield only |
| `manageAssetAndShares` | Manager | Yield only |

What each one does is in [Roles and permissions](roles.md).
