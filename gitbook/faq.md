# FAQ

## Depositing

<details>

<summary>Is there a fee to deposit?</summary>

No. Entry is free, and there is no ongoing management fee. The only fee you pay as a
depositor is the exit fee on redemption, capped at 1%.

</details>

<details>

<summary>Is there a minimum deposit?</summary>

Yes, expressed in shares rather than assets. Read it with
`minSharesInVaultToken(<vault>)` on the Manager. Deposits below it revert with
`InvalidMinShares`.

</details>

<details>

<summary>Should I time my deposit around a yield report?</summary>

No — there is no advantage. Profit vests linearly over several days precisely so that
depositing just before a report earns you almost none of it. You earn roughly in proportion
to how long your capital was actually exposed.

</details>

<details>

<summary>Why did my share balance not increase after a profit was reported?</summary>

Share balances never change on their own. There are no rebases and no auto-compounding
transactions — the *value* of each share rises instead. Check `exchangeRate()` or
`previewRedeem`, not `balanceOf`.

</details>

## Withdrawing

<details>

<summary>How long does a withdrawal take?</summary>

The cooldown is 1 day by default and can be up to 7 days. Read the live value with
`cooldownPeriod()`.

Note that the cooldown is the *minimum*. Collection also requires the vault to hold enough
assets to pay you, which depends on an operator funding it.

</details>

<details>

<summary>Can I cancel a redemption request?</summary>

No. There is no cancel function. Once you call `requestRedeem`, your shares are burned and
you are committed to that amount.

</details>

<details>

<summary>I requested a redemption and then a profit was reported. Do I get it?</summary>

No. Your payout was locked in at the moment you requested. You forgo profit reported during
your cooldown — and equally, you are insulated from any loss reported during it.

Requesting is an exit from the strategy, not a queued sale order.

</details>

<details>

<summary>My cooldown has elapsed but `redeem` reverts. Why?</summary>

Most likely one of:

1. **The vault is unfunded.** It holds no liquidity buffer, so assets must be pushed back
   onchain by an operator before you can collect. Compare
   `totalRequestedAmount()` against the vault's actual asset balance.
2. **The amount does not match exactly.** `redeem` requires the exact stored share count.
   Read `getRedeemRequest` and pass that value back verbatim.
3. **The vault is paused.** Pause blocks withdrawals as well as deposits.

</details>

<details>

<summary>Can I withdraw part of my request?</summary>

No. Partial collection is not supported — the amount must match the stored request to the
wei. Plan the size at request time, not collection time.

</details>

<details>

<summary>Can someone else withdraw for me?</summary>

No. The vault requires the caller to be the owner of the request, and the standard ERC-4626
allowance flow is deliberately disabled. Approving another address does not help.

If you lose access to the depositing address, no other address can recover the position.

</details>

<details>

<summary>Why did `maxWithdraw` tell me I could withdraw more than I can?</summary>

`maxWithdraw` and `maxRedeem` are not overridden in this vault and over-report. Ignore them.
Use `getRedeemRequest` and `canExecuteRedeem` instead.

This is the most common integration mistake — see
[Function reference](reference/functions.md).

</details>

<details>

<summary>My position is larger than the redemption cap. How do I exit fully?</summary>

Sequentially: request up to the cap, wait out the cooldown, collect, then request again.
Only one request can be pending at a time, so a full exit takes multiple cooldown cycles.
Factor this in before depositing a large amount — check `maxRedeemCap(<vault>)`.

</details>

<details>

<summary>Someone redeemed my request before my cooldown ended. Is that normal?</summary>

Yes. The Manager can call `redeemFor`, and that path does not check the cooldown. It can
only pay you, at the amount already locked in, so nothing can be taken from you — but it
can end your position earlier than you planned.

</details>

## Yield and fees

<details>

<summary>Where does the yield come from?</summary>

An offchain trading strategy. Capital is transferred to an offchain counterparty, and
returns come from that counterparty's trading activity — not from onchain lending or
liquidity provision.

The vault cannot see the trading book. What you see is the reported result. See
[Risks](risks/README.md).

</details>

<details>

<summary>Can I verify the reported yield?</summary>

Not directly — that is the core trust assumption. The vault has no view of strategy
balances, so profit and loss are figures asserted by an offchain engine.

What you *can* verify: the reports themselves are onchain and public. Watch
`DistributeYield`, and compare cumulative `profit()` against `loss()` for lifetime reported
performance. Each report is capped at 0.5% of vault assets by default, with a minimum ~22
hours between them.

</details>

<details>

<summary>What happens if the strategy loses money?</summary>

The loss applies to the share price immediately, with no vesting. Profit that has not
vested yet absorbs it first — if the loss is smaller than that buffer, the share price does
not move at all.

The treasury also burns its own shares to absorb its proportional share of the loss. If it
cannot cover it, the shortfall becomes `treasuryDebt`, and future performance fees go to
depositors until it is repaid.

</details>

<details>

<summary>What does a non-zero `treasuryDebt` mean?</summary>

That a past loss exceeded what the treasury could absorb, and depositors are currently
receiving 100% of reported profit until the debt clears. The treasury earns nothing new
while it owes.

</details>

<details>

<summary>Can the fees change after I deposit?</summary>

Yes, and with no timelock. The exit fee cannot exceed 1% — that ceiling is enforced in the
contract. The performance fee cap can be raised to 100% of reported profit.

Check `fee()` and `maxFeePercentage()` before depositing, and watch `FeeSet` and
`MaxFeePercentage` for changes.

</details>

## Risk

<details>

<summary>Where are my funds actually held?</summary>

Not in the vault. Deposits are forwarded to the Manager contract immediately and then
deployed to an offchain counterparty. The vault holds an accounting record of what you are
owed.

</details>

<details>

<summary>Am I guaranteed to be able to withdraw eventually?</summary>

No. The protocol's own invariant documentation states that *"users can always eventually
withdraw"* **does not hold**. Withdrawal requires an operator to fund the vault, and an
admin pause blocks it entirely. Neither can be forced onchain.

</details>

<details>

<summary>Can the admin take my funds?</summary>

The admin can call `emergencyRecover`, which transfers any token out of the vault —
including assets already earmarked for pending redemptions. The admin can also whitelist a
destination and deploy capital to it in the same block, with no timelock.

This is why the admin should be a multisig, and why it is worth verifying that yourself
with `getOwners()` and `getThreshold()`. See [Roles](reference/roles.md).

</details>

<details>

<summary>Can the contracts change after I deposit?</summary>

Yes. All three are upgradeable, effective immediately, with no timelock. There is no window
in which to exit ahead of a change. An upgrade can override every limit described in this
documentation, including the 1% fee cap.

Watch the `Upgraded` event.

</details>

<details>

<summary>What is the single biggest risk?</summary>

Counterparty default. Once capital leaves for the offchain strategy, recovery depends on an
offchain agreement rather than on code. Everything before that point is verifiable onchain;
everything after is not.

Size your deposit as an allocation to an offchain trading counterparty with an onchain
accounting wrapper — not as a self-custodial DeFi position.

</details>

## Technical

<details>

<summary>Why do my shares have 18 decimals when USDC has 6?</summary>

The vault applies a decimals offset, so shares are always 18 decimals regardless of the
underlying asset. Never compare share amounts to asset amounts directly — convert with
`convertToAssets` or `convertToShares`.

</details>

<details>

<summary>Is this a standard ERC-4626 vault I can integrate against?</summary>

Not without changes. Three deviations will break a naive integration:

1. `withdraw`/`redeem` require a prior `requestRedeem` and an elapsed cooldown.
2. `maxWithdraw`/`maxRedeem` over-report.
3. Allowance-based withdrawal is disabled — `caller` must equal `owner`.

`totalAssets()` is also an accounting figure, not a token balance. See
[Function reference](reference/functions.md).

</details>

<details>

<summary>A transaction reverted with a raw selector. How do I decode it?</summary>

```bash
cast 4byte <selector>
```

Common ones are listed in [Events and errors](reference/events-and-errors.md).

</details>
