# test/legacy — vendored predecessor implementations

## What this is

Verbatim copies of the implementations that were live **before** the fee-split upgrade, kept so
[`test/UpgradeFeeSplit.t.sol`](../UpgradeFeeSplit.t.sol) can test the real old→new proxy swap:
deploy the old logic, build genuine mid-vesting state on it, upgrade, and assert nothing moved.

A `forge inspect storage-layout` diff proves the slots match. It cannot prove that an upgrade
lands cleanly on a half-complete vesting schedule, that the share price is continuous across
the swap, or that the upgrade *order* is right. That is what these files buy.

## Provenance

| File | Source |
| --- | --- |
| `TownSqTokenV1.sol` | `src/TownSqToken.sol` at `b6e5b5c` |
| `YieldV1.sol` | `src/Yield.sol` at `b6e5b5c` |
| `ItownSqUSDV1.sol` | `src/Interface/ItownSqUSD.sol` at `b6e5b5c` |

Commit `b6e5b5c` — *"fix(yield): price fee shares against the fully vested asset base"*, 2026-08-19.

Only mechanical edits were applied to each: a `VENDORED TEST FIXTURE` header block was inserted
after the pragma, the contract/interface was renamed with a `V1` suffix so it can coexist with
its successor, imports were repointed at `../../src/`, and `ItownSqUSD` is aliased from the
vendored `ItownSqUSDV1`. **No logic was changed.** Verify with:

```bash
git show b6e5b5c:src/TownSqToken.sol | diff - test/legacy/TownSqTokenV1.sol
```

The only hunks that should appear are the inserted header, the three `import` lines, and the
`contract ... is` line. Anything else in that diff means the fixture has been tampered with and
the upgrade test is no longer testing the deployed code.

## THESE FILES GO STALE THE MOMENT YOU DEPLOY

They are *not* "the old version" in the abstract — they are **whatever is currently live on
chain**. Once the fee-split upgrade is executed, the new `src/` becomes live and these files
describe the previous deployment. At that point `UpgradeFeeSplit.t.sol` is testing a swap that
has already happened, and it will keep passing while telling you nothing about your next one.

**Before testing any future upgrade, re-vendor from the live commit:**

```bash
LIVE=<commit tag of the deployed implementation>
git show $LIVE:src/TownSqToken.sol        > test/legacy/TownSqTokenV1.sol
git show $LIVE:src/Yield.sol              > test/legacy/YieldV1.sol
git show $LIVE:src/Interface/ItownSqUSD.sol > test/legacy/ItownSqUSDV1.sol
# then reapply the three mechanical edits above and update this table
```

Tag each deployed implementation (`git tag deployed-vault-YYYY-MM-DD <sha>`) so `$LIVE` is
something you can look up rather than reconstruct from memory.

## Rules

- Never import anything here from `src/`. Production code must not depend on a test fixture.
- Never fix a bug here. These files are a historical record; if the old code was wrong, that
  wrongness is the point — it is what the upgrade is being tested against.
- If a test in `UpgradeFeeSplit.t.sol` starts failing after `src/` changes, the question is
  whether the *new* upgrade is safe, not whether to edit these files to make it pass.
