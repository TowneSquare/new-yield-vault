# Events and errors

## Errors you may encounter

All contracts use custom errors. If your wallet shows a raw selector, decode it:

```bash
cast 4byte <selector>
```

### Depositing

| Error | Meaning | Fix |
|---|---|---|
| `InvalidMinShares` | Deposit below the minimum share threshold | Deposit more |
| `InvalidDeposit` | Zero amount, zero shares, or zero receiver | Check your inputs |
| `EnforcedPause` | Vault is paused | Wait for unpause |

### Requesting a redemption

| Error | Meaning | Fix |
|---|---|---|
| `RedemptionRequestAlreadyExists` | You already have one pending | Collect it first |
| `InsufficientShares` | You do not hold that many shares | Check `balanceOf` |
| `InsufficientAssets` | The quoted payout rounds to zero | Request more shares |
| `MaxRedeemCapExceeded` | Above the per-request cap | Split into several requests |
| `ZeroAmount` | You passed zero | — |

### Collecting

| Error | Meaning | Fix |
|---|---|---|
| `NoRedemptionRequest` | No request exists for this address | Call `requestRedeem` first |
| `CooldownNotFinished` | Cooldown has not elapsed | Check `canExecuteRedeem` |
| `InvalidWithdrawalRequest` | Amount does not match your request **exactly** | Read `getRedeemRequest`, pass it back verbatim |
| `NotAuthorized` | You are not the owner of the request | Only the owner can collect |
| ERC-20 transfer revert | The vault has no assets to pay you | Wait for the vault to be funded |

{% hint style="info" %}
`InvalidWithdrawalRequest` is the most common error. Partial withdrawal is not supported —
the amount must match the stored request to the wei.
{% endhint %}

### Access control

| Error | Meaning |
|---|---|
| `NotWhitelisted` | Destination is not on the allowlist (operator-facing) |
| `OnlyManagerContract` / `OnlyYieldContract` | Internal call from the wrong contract |
| `AccessControlUnauthorizedAccount` | Caller lacks the required role |

### Yield reporting

| Error | Meaning |
|---|---|
| `InvalidEpoch` | Report is out of sequence |
| `DuplicateTransaction` | This report was already submitted |
| `DistributionTooFrequent` | Minimum interval has not elapsed |

{% hint style="warning" %}
The two percentage caps on `distributeYield` are plain `require` statements with no message.
A report rejected for exceeding the per-epoch or fee cap reverts with **no reason string** —
this is a known rough edge, not a malfunction.
{% endhint %}

## Events

### Your activity

| Event | Emitted when |
|---|---|
| `Deposit` | You deposit |
| `RedemptionRequested` | Your request is recorded, with the locked amount |
| `Withdraw` | Your redemption is paid |
| `WithdrawalExecuted` | A redemption settled via `redeemFor` |

### Things that affect your position

| Event | Contract | Meaning |
|---|---|---|
| `DistributeYield` | Yield | An epoch's profit or loss was reported |
| `TransferRewards` | Vault | Yield entered the vesting schedule |
| `LossAbsorbedIntoUnvested` | Vault | A loss was cancelled against unvested profit |
| `TreasuryDebtAccrued` | Yield | A loss exceeded what the treasury could absorb |
| `TreasuryDebtRepaid` | Yield | Treasury debt settled; profit routed to depositors |

### Things that change your terms

| Event | Contract |
|---|---|
| `FeeSet` | Vault |
| `CooldownPeriodUpdated` | Vault |
| `VestingPeriodUpdated` | Vault |
| `MaxRedeemCapSet`, `MinSharesInVaultTokenSet` | Manager |
| `MaxYieldPercentageSet`, `MaxFeePercentage`, `MinDistributionIntervalSet` | Yield |
| `Paused` / `Unpaused` | Vault |

### Governance and control

| Event | Contract | Meaning |
|---|---|---|
| `WhitelistUpdated` | Manager | A capital destination was authorised or revoked |
| `BatchExecuted` | Manager | Capital deployed, with full targets and calldata |
| `TreasurySet` | Manager | Fee destination changed |
| `EmergencyRecovery` | Vault | Assets extracted from the vault |
| `RoleGranted` / `RoleRevoked` | all three | Privileged access changed hands |
| `Upgraded` | all three | Contract code replaced |

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

- **`transferToVault` emits nothing.** Redemption funding — the step your withdrawal depends
  on — is visible only as a plain ERC-20 `Transfer` into the vault.
- **`AssetsWithdrawn` is declared in the Manager interface but never emitted.** Do not build
  monitoring against it.

## Naming inconsistencies

Two events break the convention every other setter event follows. Match them exactly when
filtering:

- `MaxFeePercentage` — not `MaxFeePercentageSet`
- `CooldownPeriodUpdated` / `VestingPeriodUpdated` — `Updated`, not `Set`
