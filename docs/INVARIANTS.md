# Protocol Invariants

Properties that must hold for the protocol to be correct. Each is marked with its current
test status.

**No stateful (handler-based) invariant suite exists yet.** `test/` contains unit tests,
fork tests, characterisation PoCs, and one stateless fuzz test (I-05, in
`POC-TotalAssetsUnderflow.t.sol`) — but no `invariant_*` handler suite. Building one before
or during the audit is the highest-value testing work available: the accounting invariants
below (I-01 … I-04) are exactly the class of property stateful fuzzing finds violations in,
and they remain unenforced by any test.

Legend: ✅ covered by a test · ⚠️ partially covered · ❌ not covered

## Core Accounting

**I-01 — Share supply matches holder balances.** ❌
`sum(balanceOf(u) for all u) == totalSupply()`
No mint or burn path outside `_deposit`, `requestRedeem`, `mintVaultToken`, and
`burnVaultToken`. The latter two are restricted to the treasury address.

**I-02 — `virtualAssets` is fully accounted.** ❌
`virtualAssets == Σ(deposits) + Σ(profit distributed) − Σ(losses) − Σ(assets locked by redeem requests) ± Σ(manageAssetAndShares asset updates)`
`virtualAssets` is pure accounting and is never reconciled against a real token balance.
This is the invariant most worth fuzzing.

**I-03 — Pending redemptions are backed.** ❌ **← the critical one**
`totalRequestedAmount ≤ asset.balanceOf(townSqToken) + assets recoverable from Manager`
**This invariant is not enforced anywhere onchain.** The vault holds no assets by default;
funding pending redemptions is a manual operator step (`Manager.transferToVault`) or a
plain transfer. Nothing prevents `totalRequestedAmount` from exceeding what is available,
and nothing prevents `emergencyRecover` from removing assets that are already earmarked.
If one invariant should be stress-tested, it is this one.

**I-04 — `totalRequestedAmount` equals the sum of live requests.** ❌
`totalRequestedAmount == Σ(redemptionRequests[u].assets where exists)`
Incremented in `requestRedeem`, decremented in `_withdraw`. Note `_withdraw` does
`totalRequestedAmount -= assets` unchecked by any explicit guard — Solidity 0.8 will revert
on underflow, which is the desired failure mode but worth confirming is unreachable.

**I-05 — `virtualAssets >= getUnvestedAmount()` (i.e. `totalAssets()` never underflows).** ✅
Holds. Every path that subtracts from `virtualAssets` is bounded by a quantity that is
itself ≤ the current gap, so the gap converges toward zero without crossing it. Verified by
`test/POC-TotalAssetsUnderflow.t.sol` (4 tests incl. a 257-run fuzz over loss schedules);
reasoning and the one genuinely-exceeding path in `KNOWN_ISSUES.md` Q-03.

## Vesting

**I-06 — Unvested amount decreases monotonically between distributions.** ✅
`POC-VestingSemantics` covers the schedule shape and the roll-and-restart behaviour.

**I-07 — A new distribution rolls the remainder and restarts the clock.** ✅
`vestingAmount = new + getUnvestedAmount()`; `lastDistributionTimestamp = block.timestamp`.
Never two parallel schedules.

**I-08 — Losses bypass vesting entirely.** ✅ (by design; `POC-LossHandling`)

## Economic

**I-09 — Redemption amount is locked at request time.** ✅
Consequence: pending redeemers are insulated from loss and forgo profit during cooldown.
Intentional; documented in `KNOWN_ISSUES.md` (D-03).

**I-10 — Share price does not decrease except via a booked loss.** ⚠️
Fee minting to the treasury dilutes existing holders. Deposit fees are taken from the
depositor's own shares (neutral to existing holders), but `distributeYield`'s `feeAmount`
mints shares *and* adds `feeAmount` to assets, so it should be price-neutral. Worth
verifying the two move in lockstep given `convertToShares` rounding.

**I-11 — Fees are bounded.** ✅ (enforced onchain)
`fee ≤ 1e18` (1%, `setFee`); `maxYieldPercentage ≤ 10_000`; `maxFeePercentage ≤ 10_000`.
Note `maxFeePercentage` may be set to 100% of `amount`, and `setMaxFeePercentage` permits
`0` while `setMaxYieldPercentage` does not.

**I-12 — Yield per distribution is bounded.** ✅
`amount ≤ totalAssets() * maxYieldPercentage / 10_000` (default 0.5%). Enforced with a
bare `require()` with no error message — see `KNOWN_ISSUES.md` (Q-01).

**I-13 — Distributions are sequential and non-replayable.** ✅
`nonce == epoch + 1`, plus a `trxns[proofHash]` guard. Note `proofHash` does **not**
include `feeAmount`, so it is weaker than the nonce check it sits behind; the nonce is
doing the real work.

## Access Control

**I-14 — Only the Manager can move the vault's accounting.** ✅
`updateTotalAssets`, `mintVaultToken`, `burnVaultToken`, `redeemFor` all check
`msg.sender != manager`.

**I-15 — Only the Yield contract can distribute.** ✅
`transferInRewards` checks `msg.sender != IManager(manager).yield()`.
Note this reads through the Manager at call time, so `Manager.setManagerAndYield`
retargets vault authorisation without touching the vault.

**I-16 — Minting is restricted to the treasury.** ✅
Both `mintVaultToken` and `burnVaultToken` require `to == IManager(manager).treasury()`.

**I-17 — Users can only act on their own request.** ✅
`_withdraw` reverts unless `caller == owner`. This intentionally breaks ERC4626
allowance-based withdrawal (see `KNOWN_ISSUES.md` D-02).

**I-18 — `execute` can only reach whitelisted targets.** ✅
Whitelist cannot include `townSqToken` or `yield`. **Nothing else is excluded** —
in particular the underlying asset itself may be whitelisted, which would allow the
operator to `approve` or `transfer` deposits out via `execute`. Worth explicit auditor
attention.

## Upgrade Safety

**I-19 — Storage layout is append-only across upgrades.** ⚠️
Each contract reserves `uint256[50] private __gap`. `test/UpgradeTest.t.sol` exists.
`forge inspect <C> storage-layout` diffs are **not** currently captured in CI — recommend
adding before the first upgrade.

**I-20 — Implementations cannot be initialised directly.** ✅
All three call `_disableInitializers()` in the constructor.

**I-21 — Upgrade authorisation is gated.** ✅
`_authorizeUpgrade` is `onlyRole(DEFAULT_ADMIN_ROLE)` on all three contracts.

## Liveness

**I-22 — Users can always eventually withdraw.** ❌ **does not hold**
Three independent blockers:
1. `pause()` blocks `withdraw`, `redeem`, and `redeemFor` (`whenNotPaused`). Paused funds
   are inaccessible for the duration.
2. Redemption requires the vault to be funded — a manual step (I-03).
3. `emergencyRecover` (ADMIN_ROLE) can transfer out assets earmarked for pending
   redemptions; it does not respect `totalRequestedAmount`.

Documented as an accepted risk (`KNOWN_ISSUES.md` K-01) but auditors should confirm the
team intends this. Most vaults deliberately keep withdrawal live while paused.

**I-23 — One live request per user.** ✅ (by design)
`requestRedeem` reverts if a request already exists, so a user cannot queue a second
redemption until the first is executed. A user with a pending request cannot request more
even if they hold additional shares.
