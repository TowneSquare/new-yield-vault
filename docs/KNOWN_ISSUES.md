# Known Issues, Design Decisions & Open Questions

Three sections: **K** = known risks the team accepts, **D** = intentional design
decisions auditors should not report as bugs, **Q** = observations surfaced during
audit preparation that the team has **not** yet triaged.

> The Q items were found by reading the code during audit prep, not by a security review.
> They are recorded here so auditors are not spending time re-discovering things the team
> already knows about — **not** as a claim that they are safe. Each needs a decision before
> the engagement starts.

---

## K — Accepted Risks

### K-01: Withdrawals are blocked while paused
**Severity**: Medium · **Status**: Accepted
`withdraw`, `redeem`, and `redeemFor` all carry `whenNotPaused`. An admin pause makes user
funds inaccessible for the duration. Most vaults deliberately keep the exit path live while
pausing entry. Accepted on the basis that pause is a short-lived emergency measure
controlled by a multisig.

### K-02: Offchain yield engine is fully trusted
**Severity**: High · **Status**: Accepted (architectural)
`distributeYield` takes `amount` and `feeAmount` as unverifiable trusted inputs. The vault
cannot see strategy balances, so overstated yield permanently inflates `totalAssets()`
against assets that do not exist. Mitigations: `maxYieldPercentage` (default 0.5% of
`totalAssets` per distribution), `maxFeePercentage`, `minDistributionInterval` (~22h),
sequential nonce. These bound the *rate* of divergence, not its existence.

### K-03: Redemption funding is a manual operator step
**Severity**: Medium · **Status**: Accepted with monitoring
The vault holds no assets by default. A user whose cooldown has elapsed cannot redeem until
assets are pushed in via `Manager.transferToVault` (OPERATOR_ROLE) or a plain transfer.
Liveness depends on offchain monitoring unwinding strategies in time. Characterised in
`test/POC-RedeemFunding.t.sol`.

### K-04: OPERATOR_ROLE can make arbitrary calls from the asset-custody address
**Severity**: High · **Status**: Accepted (architectural)
`Manager.execute` performs arbitrary `call`s with arbitrary calldata to any whitelisted
target, from the address holding every deposited asset. The whitelist is the only
constraint. Mitigation is operational: multisig-controlled whitelist, narrow entries, key
hygiene. See Q-01 for a specific gap in the whitelist guard.

### K-05: No timelock on upgrades or parameter changes
**Severity**: Medium · **Status**: Accepted for v1
`DEFAULT_ADMIN_ROLE` can upgrade all three contracts with immediate effect. No timelock
contract is in scope. Mitigation is multisig custody only; users have no exit window ahead
of a malicious or mistaken upgrade.

---

## D — Intentional Design Decisions

**D-01: Not fully ERC4626-conformant — `withdraw`/`redeem` require a prior request.**
Both revert with `NoRedemptionRequest` unless the caller has an existing request past
cooldown, and require the amount to match the recorded request *exactly* (`assets !=
request.assets` / `shares != request.shares` revert). `maxWithdraw`/`maxRedeem` are **not**
overridden, so they still report the inherited ERC4626 values and will over-report what is
actually withdrawable. Integrators treating this as a drop-in ERC4626 will break. This is
a deliberate async-redemption design (ERC-7540-like) but is not declared as such.

**D-02: `caller == owner` enforced — no allowance-based withdrawal.** `_withdraw` reverts
if `caller != owner`, so the ERC4626 pattern of an approved spender withdrawing on a
holder's behalf does not work. The only third-party path is `Manager.redeemFor`
(OPERATOR_ROLE, and it skips cooldown entirely).

**D-03: Redemption asset amount is locked at request time.** Pending redeemers are fully
insulated from losses booked during their cooldown, and forgo profit. Remaining holders
absorb the loss. Characterised in `POC-LossHandling`.

**D-04: `vestingPeriod` is not a per-user lockup.** It smooths recognition of distributed
yield vault-wide. New depositors accrue immediately; a mid-schedule depositor shares in the
unvested remainder of yield earned before they arrived. Characterised in
`POC-VestingSemantics`.

**D-05: Losses apply instantly, profits vest.** Asymmetric by design.

**D-06: `redeemFor` bypasses the cooldown.** Manager/OPERATOR_ROLE only. Documented inline.

**D-07: Fee-on-transfer and rebasing tokens are not supported.** `_deposit` credits the
requested `assets`, not the delta actually received.

**D-08: Assets with more than 18 decimals are not supported.** `_decimalsOffset()` and
`exchangeRateScaled()` compute `18 - asset.decimals()` and revert on underflow.

---

## Q — Open Questions (not yet triaged)

### Q-01: `execute` whitelist does not exclude the underlying asset
`setWhitelistedAddresses` blocks only `townSqToken` and `yield`. If the underlying asset is
ever whitelisted, `Manager.execute` can call `transfer`/`approve` on it directly, moving
deposits out of custody in a single operator transaction with no protocol interaction
involved. Consider blocking the asset address explicitly, or constraining `execute` by
function selector rather than target alone.

### Q-02: `emergencyRecover` can drain assets earmarked for pending redemptions
`townSqToken.emergencyRecover` (ADMIN_ROLE) transfers any token, including the underlying
asset, without consulting `totalRequestedAmount`. Consider requiring
`balance - amount >= totalRequestedAmount` when `token == asset()`.

### Q-03: `totalAssets()` underflow — investigated, NOT reachable ✅
**Resolved.** The concern was that `totalAssets()` (`virtualAssets - getUnvestedAmount()`)
could underflow, since losses reduce `virtualAssets` but never reduce `vestingAmount`. A
revert there would brick `previewDeposit`, `previewRedeem`, and `distributeYield` together.

`test/POC-TotalAssetsUnderflow.t.sol` attempts it four ways — all four confirm the
invariant `virtualAssets >= getUnvestedAmount()` holds, including a 257-run fuzz over loss
schedules. The reason it holds: **every path that subtracts from `virtualAssets` is bounded
by a quantity that is itself ≤ the current gap**, so the gap converges toward zero without
crossing it.

| Attempted path | Why it cannot underflow |
| --- | --- |
| Repeated maximum losses | `amount ≤ totalAssets * maxYieldPercentage / 10_000` — bounded by the gap itself, so it shrinks geometrically. Self-limiting even at `maxYieldPercentage = 10_000`. |
| Loss + loss-fee (subtracts `amount + feeAmount`, so **can** exceed the gap) | To underflow, `feeAmount` must exceed the post-`amount` gap. Burning that many treasury shares requires the treasury to hold more than `totalSupply + 10**offset` — impossible, since the treasury's balance is a subset of `totalSupply`. The distribution reverts on the burn first. |
| Full `requestRedeem` of the entire supply | The subtracted amount comes from `previewRedeem`, which is proportional to the gap. |

Note this was the one path where a **combined** subtraction genuinely can exceed the gap —
the treasury-share requirement is what blocks it, not the caps. Worth an auditor
independently confirming that reasoning rather than taking the PoC's word for it, since it
is the load-bearing argument.

Residual observation, not a bug: if the underflow *were* ever reachable, recovery would be
`setVestingPeriod` to a short value (its `_updateVestingAmount(0)` call reads
`getUnvestedAmount()`, not `totalAssets()`, so it stays callable), or simply waiting for
the schedule to vest out.

### Q-04: `Manager.initialize` does not validate its arguments
`initialize(admin, _yield, _executor)` performs no zero-address checks, unlike
`townSqToken.initialize` and the setters. `treasury` and `townSqToken` are left unset and
must be configured in a follow-up transaction — a deployment that forgets leaves
`treasury == address(0)`, and `_deposit` would then mint fee shares to the zero address
(OZ v5 `_mint` reverts on zero, so deposits with a non-zero fee would fail closed).

### Q-05: `Yield.distributeYield` uses bare `require()` with no message
Lines 165–166 use `require(cond)` with no error string or custom error. Both are
user-visible bounds (`maxYieldPercentage`, `maxFeePercentage`); a failed distribution
reverts with no indication which bound was hit. The codebase otherwise uses `Errors.*`
custom errors throughout. Fix is mechanical and should land before the audit.

### Q-06: `proofHash` omits `feeAmount`
`keccak256(abi.encode(vaultToken, amount, nonce, isProfit))` excludes `feeAmount`, so the
replay guard is weaker than it appears. The `nonce == epoch + 1` check makes this
unexploitable today; the concern is that the hash gives a false impression of independent
protection and would silently stop protecting anything if the nonce check were relaxed.

### Q-07: Floating pragmas and unpinned compiler
`^0.8.19` / `^0.8.20`, no `solc_version` in `foundry.toml`. The audited bytecode is not
reproducible from the repo. Pin before the engagement.

### Q-08: Vault authorisation is indirect through the Manager
`transferInRewards` authorises `msg.sender == IManager(manager).yield()`, resolved at call
time. `Manager.setManagerAndYield` therefore changes who may distribute yield into the
vault without any transaction touching the vault. Consider whether the vault should hold
its own `yield` address.

### Q-09: `setMaxFeePercentage` permits 0 but `setMaxYieldPercentage` does not
Asymmetric validation (`Yield.sol:112` vs `:118`). Likely intentional (a zero fee cap is
meaningful, a zero yield cap would disable distribution) but worth confirming.

### Q-10: No stateful invariant test suite
`test/` has unit, fork, and characterisation tests but no `invariant_*` handler suite. The
accounting invariants (I-01 … I-05) are unenforced by tests. See `INVARIANTS.md`.

### Q-11: Live Alchemy API key committed to git history ⚠️ **act before pushing anywhere**

`test/forkTest.t.sol:26` contains a plaintext Alchemy RPC key, committed in `d2dcfd2`:

```solidity
vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/sKww…", 23198600);
```

Not a contract vulnerability — a credential leak. Two consequences:

1. **Rotate the key.** It is in git history, so deleting the line does not un-leak it.
   Rotation at Alchemy is the only real remediation.
2. **This propagates on push.** Anyone with repo read access has the key. If this repo is
   pushed to another organisation or made public, the key travels with it — and stripping
   history does not help, because the key is also in the current working tree.

Fix: rotate at Alchemy, then replace all three hardcoded fork URLs
(`forkTest.t.sol:26`, `testCrossChain.t.sol:28`, `:61`) with `vm.envString("...")` reads
and document the required env vars in the README. See `audit/static-analysis.md` for the
related unpinned-fork-block issue.
