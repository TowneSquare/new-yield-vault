# Static Analysis & Test Results

**Run date**: 2026-08-11 · **Commit**: `b708b3044d1e31e9afc190880c5f71cb043ffe0c`
**Slither**: 0.11.4 · **Aderyn**: not run (not installed)

## Test Suite

```text
forge test  →  68 passed, 2 failed   (70 total, 11 suites)
```

Both failures are **environmental, not code defects** — the two mainnet-fork entry points
now fail loudly with `environment variable ETH_RPC_URL not found`:

| Test | Location | Resolution |
| --- | --- | --- |
| `setUp()` | `test/forkTest.t.sol` | Set `ETH_RPC_URL` in `.env` |
| `testDeploymentETH()` | `test/testCrossChain.t.sol` | Set `ETH_RPC_URL` in `.env` |

Excluding fork tests: **66 passed, 0 failed**.

### Fork-test hygiene — fixed during prep

- **Hardcoded RPC URLs removed.** All three call sites now resolve through
  `[rpc_endpoints]` in `foundry.toml` (`vm.rpcUrl("mainnet")` / `("monad")`), which reads
  `${ETH_RPC_URL}` / `${MONAD_RPC_URL}` from the environment. No URL or key remains in
  `.sol` source. `.env.example` documents every variable.
- **Fork blocks pinnable.** `ETH_FORK_BLOCK` defaults to the known-good `23198600`.
  `MONAD_FORK_BLOCK` is unset and defaults to chain head — **still not reproducible**; pin
  it once a known-good block is chosen.
- **`testDeploymentKatana` → `testDeploymentMonad`.** Retargeted to an actual deployment
  chain; Katana was dropped from `rpc_endpoints`.

⚠️ **Q-11 is not resolved by any of this.** The Alchemy key is still in git history
(`d2dcfd2`) and must be rotated at the provider.

### Still not run

- **`forge coverage`** — no coverage figures exist. Checklist target is 90%+ branch coverage on `src/`.
- **Stateful (handler-based) invariant suite** — still does not exist (`docs/KNOWN_ISSUES.md`
  Q-10). `POC-TotalAssetsUnderflow.t.sol` adds a stateless fuzz test covering I-05 only.
- **`forge inspect <C> storage-layout`** — no upgrade baseline captured (I-19).
- **Aderyn** — not installed.

## Slither

```bash
slither . --filter-paths "test|script|lib" \
          --exclude naming-convention,solc-version \
          --json audit/slither-output.json
```

Raw output: `audit/slither-output.json`. 40 contracts, 98 detectors, **29 findings**.

| Impact | Count | Genuine after triage |
| --- | ---: | ---: |
| High | 5 | **0** — all false positives |
| Low | 8 | 1 (already tracked as Q-04) |
| Informational | 11 | 0 |
| Optimization | 5 | 0 |

**No new genuine issues.** Slither did not surface anything beyond what manual review had
already recorded in `docs/KNOWN_ISSUES.md`. In particular it did **not** flag Q-01
(whitelist scope), Q-02 (`emergencyRecover` vs pending redemptions), or Q-03
(`totalAssets()` underflow) — the three items most worth an auditor's time. Treat this
clean result as evidence about Slither's reach, not about the code.

### High (5) — all false positives

All five are `uninitialized-state` on `townSqToken` storage: `manager`, `cooldownPeriod`,
`vestingPeriod`, `fee`, `redemptionRequests`.

Slither did not resolve the UUPS initializer pattern. `initialize()` assigns `manager`
([`townSqToken.sol:104`](../src/townSqToken.sol#L104)), `cooldownPeriod` (`:105`), and
`vestingPeriod` (`:106`). `fee` is intentionally left at `0` and set via `setFee`.
`redemptionRequests` is a mapping, populated by `requestRedeem`.

The same root cause produces the `constable-states` optimization findings (`manager`, `fee`,
`cooldownPeriod`, `vestingPeriod`, `totalRequestedAmount` "should be constant" — all have
setters or are mutated at runtime) and the three `dead-code` findings
(`_updateTotalAssets`, `_updateVestingAmount`, `_withdraw` are all reachable).

**Do not suppress these.** A reader who sees them suppressed loses the signal that Slither
is mis-modelling this contract's initialization — which is also why its reentrancy and
state-tracking conclusions here deserve less weight than usual.

### Low (8) — triage

| Finding | Location | Disposition |
| --- | --- | --- |
| `missing-zero-check` on `_yield` | `Manager.sol:56` | **Genuine** — already tracked as **Q-04**. Fix: add zero-checks to `Manager.initialize` for all three args. |
| `calls-loop` | `Manager.sol:130` | Accepted — batch execution is the intended design (K-04). Targets are whitelisted. |
| `reentrancy-events` ×4 | `Yield.sol:160-208`, `Manager.sol:119-140`, `:147-150`, `:178-192` | Accepted — event-ordering only, no state written after the external call. Both `Manager` functions are role- or caller-gated; the vault side is `nonReentrant`. |
| `timestamp` ×2 | `Yield.sol:175`, `townSqToken.sol:156` | Accepted — cooldown/vesting granularity is hours-to-days; validator drift is immaterial. |

### Informational / Optimization (16) — accepted

- `assembly` + `low-level-calls` in `Manager.execute` — intended (K-04); the assembly
  revert-bubble at `Manager.sol:132-134` is deliberate.
- `unused-state` on `__gap` ×3 — that is what a storage gap is.
- `unindexed-event-address` ×3 — all in OpenZeppelin (`IERC1967`, `PausableUpgradeable`), out of scope.
- `constable-states` ×5 and `dead-code` ×3 — false positives, same root cause as the Highs.

## Reproducing

Slither installed to `~/Library/Python/3.9/bin` (not on `PATH` by default):

```bash
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
slither --version   # 0.11.4
```

Note the local Python is 3.9.6; `pipx` is not installed, so `pip3 install --user` was used.
The install exits non-zero on a urllib3/LibreSSL warning but the tool works.
