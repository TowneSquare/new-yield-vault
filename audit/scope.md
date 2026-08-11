# Audit Scope — townSqUSD

**Commit hash**: `b708b3044d1e31e9afc190880c5f71cb043ffe0c`
**Repository**: townSqUSD (TownSquare Yield Vault)
**Compiler**: solc `0.8.x` via pragma `^0.8.19` / `^0.8.20` — see Note 1
**Optimizer**: enabled, 200 runs, `via_ir = true`

## In Scope

| File | LOC | Description |
|------|----:|-------------|
| `src/townSqToken.sol` | 544 | ERC4626 vault: deposits, request/execute redemption, yield vesting, fees, UUPS |
| `src/Yield.sol` | 217 | Epoch-based profit/loss distribution, rate limiting, fee accounting |
| `src/Manager.sol` | 197 | Asset custody, whitelisted protocol execution, asset/share coordination |
| `src/Errors.sol` | 57 | Custom error definitions |
| `src/Interface/IManager.sol` | 49 | Manager interface + `ManageAssetAndShares` struct |
| `src/Interface/ItownSqUSD.sol` | 45 | Vault interface |
| `src/Proxy.sol` | 14 | ERC1967 proxy wrapper (no added logic) |
| **Total** | **1123** | |

LOC is raw line count including comments and blank lines (`wc -l`). No SLOC tool was
run; auditors sizing the engagement should treat these as upper bounds — the files are
heavily commented.

## Out of Scope

- `lib/openzeppelin-contracts` and `lib/openzeppelin-contracts-upgradeable` — both v5.7.0, audited upstream
- `lib/forge-std` v1.16.2 — test-only
- `test/` and `script/` — provided for auditor reference, not for review
- The offchain yield engine that computes and submits `distributeYield` parameters
- Cross-chain exchange-rate reconciliation (offchain; see README "Cross-Chain Yield Distribution")

## Trust Boundary

**The offchain engine is fully trusted and is not constrained onchain.** The vault has no
view of the balances held in external strategies. `distributeYield(amount, feeAmount,
nonce, isProfit)` is trusted input, bounded only by `maxYieldPercentage` and
`maxFeePercentage`. See `docs/ARCHITECTURE.md` for the full trust model — this is the
single most important thing for an auditor to internalise before reading the code.

## Deployment Targets

 Monad mainnet, base, Binance. The exact chain
list and addresses are **not yet pinned** — see `docs/DEPLOYMENT.md`.

## Notes

**Note 1 — floating pragmas.** All contracts use floating pragmas (`^0.8.19` in
`townSqToken.sol`, `^0.8.20` elsewhere) rather than a pinned version, and `foundry.toml`
sets no `solc_version`. The exact compiler used for the audited build is therefore not
reproducible from the repo alone. Recommend pinning before the engagement starts.

**Note 2 — `via_ir = true`.** Enabled. Auditors should be aware the deployed bytecode
goes through the IR pipeline; if any inline assembly is reviewed for gas or aliasing
behaviour (`Manager.execute` uses an assembly revert-bubble), the IR codegen path is the
relevant one.

**Note 3 — asset decimals.** The vault assumes the underlying asset has **≤ 18
decimals**; `_decimalsOffset()` and `exchangeRateScaled()` both compute
`18 - asset.decimals()` and will revert on underflow for any asset with more than 18
decimals. USDC (6) is the intended asset. Not a finding, but it constrains which assets
may ever be listed.
