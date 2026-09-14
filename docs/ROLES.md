# Roles & Permissions

Companion to `ARCHITECTURE.md`, written for auditors and counterparty diligence. This
document enumerates every privileged role across the three proxies, every function each
role can call, and what each role can and cannot cause to happen.

Every entry is sourced from the code. Where a capability is operational policy rather than
an onchain constraint, it is marked as such.

## Summary

Four roles exist across three contracts on the **current live deployment**. There is no
`CURATOR_ROLE`, no timelock, and no role that is restricted to risk parameters alone.

> **Pending change.** A 48-hour `TimelockController` and a fifth role, `GUARDIAN_ROLE`, are
> implemented in `src/` and covered by `test/Timelock.t.sol` and
> `test/TimelockHandover.fork.t.sol`, but are **not deployed**. After the handover,
> `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` move to the timelock and every governance action
> takes 48 hours; `GUARDIAN_ROLE` retains instant `pause()` and instant whitelist removal.
> See the [Post-timelock model](#post-timelock-model-pending) section below. Everything
> before that section describes live state today.

| Role | Contracts | Intended holder | Can move assets | Can move share price |
|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | all three | Governance multisig | **Yes** (via upgrade, `emergencyRecover`) | **Yes** (via upgrade) |
| `ADMIN_ROLE` | all three | Governance multisig | **Yes** (`emergencyRecover`, whitelist) | Indirectly (parameters) |
| `OPERATOR_ROLE` | Manager | Executor (bot/Safe) | **Yes** (`execute`) | No |
| `REBALANCER_ROLE` | Yield | Offchain yield engine | No | **Yes** (entirely) |

Role constants:

| Role | Value |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x00` |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` |
| `OPERATOR_ROLE` | `keccak256("OPERATOR_ROLE")` |
| `REBALANCER_ROLE` | `keccak256("REBALANCER_ROLE")` |

All three contracts use OpenZeppelin `AccessControlUpgradeable`. `DEFAULT_ADMIN_ROLE` is the
admin of every other role, so it can grant and revoke `ADMIN_ROLE`, `OPERATOR_ROLE` and
`REBALANCER_ROLE` at will, on any of the three proxies, with no delay.

## Assignment at deployment

From `script/Deploy.s.sol` and the three `initialize` functions:

| Contract | `DEFAULT_ADMIN_ROLE` | `ADMIN_ROLE` | Other |
|---|---|---|---|
| `TownSqToken` | `_admin` | `_admin` | — |
| `Manager` | `admin` | `admin` | `OPERATOR_ROLE` → `_executor` |
| `Yield` | `_admin` | `_admin` | `REBALANCER_ROLE` → `_rebalancer` |

`Manager.initialize` grants `OPERATOR_ROLE` to `_executor` but **does not** set `treasury`
or `townSqToken`; those are configured afterwards via `setTreasury` and
`setManagerAndYield`. No addresses are whitelisted at deploy time — the live allowlist must
be read onchain (see *Reading live state* below).

---

## `DEFAULT_ADMIN_ROLE`

Highest privilege. Holds two distinct powers.

### Upgrade authority

`_authorizeUpgrade(address)` — `TownSqToken.sol:115`, `Manager.sol:68`, `Yield.sol:93`

All three contracts are UUPS. `DEFAULT_ADMIN_ROLE` can replace the implementation of any of
them with arbitrary code, with no timelock and no upgrade-safety check enforced onchain.
This subsumes every other capability in this document: a malicious upgrade can mint shares,
rewrite accounting, or transfer custodied assets.

### Role administration

`grantRole` / `revokeRole` on all four roles, across all three proxies. Immediate effect.

**Consequence:** `DEFAULT_ADMIN_ROLE` is the root of trust for the entire protocol. It must
be a multisig; a timelock in front of it is the single highest-value control improvement
available.

---

## `ADMIN_ROLE`

Governance parameters plus two custody-adjacent powers. Note the mix — this role is not
separable into "risk only" as currently written.

### TownSqToken

| Function | Line | Effect | Bound |
|---|---|---|---|
| `setFee` | `L322` | Exit fee charged on redemption | `<= ONE_PERCENT` (1%), hard-coded |
| `setCooldownPeriod` | `L209` | Delay between request and withdrawal | `<= 7 days`, hard-coded |
| `setVestingPeriod` | `L332` | Linear profit vesting window | `<= 30 days`, hard-coded |
| `setManager` | `L343` | Repoints the Manager address | non-zero only |
| `pause` / `unpause` | `L218`, `L226` | Halts deposit, withdraw, redeem, redeemFor, requestRedeem | none |
| `emergencyRecover` | `L355` | Transfers any ERC-20 or native balance out of the vault | balance only |

Two of these are not risk parameters:

- **`emergencyRecover`** can withdraw assets already earmarked for pending redemptions.
  `totalRequestedAmount` is not consulted. See `KNOWN_ISSUES.md`.
- **`setManager`** repoints the address authorised to call `updateTotalAssets`,
  `mintVaultToken` and `burnVaultToken`. A hostile Manager can forge vault accounting.
- **`pause`** blocks the exit path, not just entry (`KNOWN_ISSUES.md` K-01), so it is a
  fund-freezing power rather than a purely defensive one.

### Manager

| Function | Line | Effect | Bound |
|---|---|---|---|
| `setWhitelistedAddresses` | `L100` | **The strategy/destination allowlist** | cannot whitelist `townSqToken` or `yield` (`L107`) |
| `setTreasury` | `L75` | Destination for all fee accrual | non-zero only |
| `setManagerAndYield` | `L86` | Repoints Yield and TownSqToken | non-zero only |
| `setMaxRedeemCap` | `L168` | Max assets per redemption request | none; `0` == uncapped |
| `setMinSharesInVaultToken` | `L157` | Minimum shares per deposit | must be non-zero |

`setWhitelistedAddresses` is the most consequential `ADMIN_ROLE` function. The whitelist is
the *only* constraint on where custodied assets can be sent by `OPERATOR_ROLE`. There is no
timelock: an address can be whitelisted and drained to in the same block.

The guard at `L107` is load-bearing — it prevents whitelisting `townSqToken` or `yield`,
which would otherwise let `OPERATOR_ROLE` reach `mintVaultToken` and `updateTotalAssets`
through `execute` and forge share supply.

### Yield

| Function | Line | Effect | Bound |
|---|---|---|---|
| `setMaxYieldPercentage` | `L122` | Cap on reported P&L per epoch | `1..10_000` bps of `totalAssets()`; default `50` = 0.5% |
| `setMaxFeePercentage` | `L128` | Performance fee share of profit | `<= 10_000` bps; default `5000` = 50% |
| `setMinDistributionInterval` | `L116` | Minimum spacing between epochs | none |
| `setManager` | `L138` | Repoints the Manager address | — |

`setMaxFeePercentage` accepts up to `10_000` — **100% of reported profit assignable to the
treasury**, with no timelock. Unlike the exit fee's hard-coded 1% ceiling, there is no
structural bound here.

`setMinDistributionInterval` rejects `0` (`L117`) but accepts `1`, so the rate limit
protecting against a compromised rebalancer can be reduced to a single second. There is
also **no maximum** interval and no staleness check anywhere: nothing obliges the
rebalancer to report at all, and if reporting stops the share price simply freezes at its
last value.

---

## `OPERATOR_ROLE`

Manager only. Three functions. This role controls **where the assets physically are**.

### `execute(address[] targets, bytes[] data)` — `Manager.sol:119-140`

```solidity
if (!whitelistedAddresses[targets[i]]) revert Errors.NotWhitelisted();
(bool success, bytes memory result) = targets[i].call(data[i]);
```

Arbitrary calldata to any whitelisted target, batched, executed from the address custodying
100% of deposited assets. Within the whitelist the operator can:

- transfer any amount of any asset to any whitelisted address
- grant unlimited ERC-20 approvals to whitelisted targets
- call any function with any arguments on any whitelisted contract
- batch all of the above atomically

**No amount cap, no per-target cap, no rate limit, no reentrancy guard.** The whitelist and
the `L107` guard are the only constraints. This is the function through which capital leaves
onchain infrastructure for the offchain trading book.

### `transferToVault(address token, uint256 amount)` — `Manager.sol:194-196`

Pushes assets from Manager custody into the vault so pending redemptions can settle. The
return leg of the flow.

This function is what makes withdrawal liveness an offchain dependency: per
`INVARIANTS.md` I-22, *"users can always eventually withdraw"* **does not hold**. A user
past cooldown cannot exit until an operator calls this, or until any address sends a plain
ERC-20 transfer to the vault.

No zero-amount check, no event emitted, no NatSpec — the only function in `Manager` lacking
all three.

### `redeemFor(address _townSqUSD, address _user)` — `Manager.sol:147-150`

Executes a matured redemption on a user's behalf. Fully bounded: requires an existing
request, cooldown elapsed, and pays the quoted amount to that user only
(`TownSqToken.sol:492-500`). Cannot redirect funds or alter amounts. A UX convenience.

### What `OPERATOR_ROLE` cannot do

Change the whitelist, grant roles, upgrade, pause, set parameters, set the treasury, report
yield, or mint/burn shares.

---

## `REBALANCER_ROLE`

Yield only. One function. This role controls **what the books say the assets are worth**.

### `distributeYield(uint256 amount, uint256 feeAmount, uint256 nonce, bool isProfit)` — `Yield.sol:171-281`

There is no oracle in this system. `totalAssets()` moves only through deposits,
redemptions, and this call. The rebalancer asserts P&L; the vault books it.

Effects:

- **On profit:** `amount` enters the linear vesting schedule for shareholders; `feeAmount`
  is minted to the treasury as shares, split into `recognisedFee` (credited immediately)
  and `vestingFee` (rides the same schedule) so the recognised share price does not step up.
- **On loss:** `amount` is debited instantly with no vesting; treasury shares are burned to
  absorb `feeAmount`, clamped to the treasury's actual balance, with any uncovered remainder
  booked to `treasuryDebt`.
- **Debt settlement:** outstanding `treasuryDebt` is repaid out of future `feeAmount` and
  routed to shareholders before the treasury earns anything new (`L201-207`).

Constraints, in full:

| Guard | Line | Effect |
|---|---|---|
| `amount <= totalAssets * maxYieldPercentage / 10_000` | `L176` | Default 0.5% of TVL per epoch |
| `feeAmount <= amount * maxFeePercentage / 10_000` | `L177` | Default 50% of profit |
| `nonce == epoch + 1` | `L180` | Strictly sequential; primary replay defence |
| `trxns[proofHash]` | `L182-184` | Duplicate rejection |
| `lastDistributionTime + minDistributionInterval` | `L186-188` | Default 79200s (22h) |

Two notes on these guards:

- `proofHash` hashes `(vaultToken, amount, nonce, isProfit)` — **`feeAmount` is excluded**
  from the replay identity. The `nonce` check is what actually prevents replay.
- The two `require`s at `L176-177` carry no message and no custom error, unlike every other
  check in the file. A distribution rejected by a cap reverts with no reason string.

### Trust assumption

`amount` and `feeAmount` are unverifiable onchain. From the code comment at `L151-153`:

> Nothing onchain can verify this: the vault has no view of strategy balances, so the split
> is trusted input from the offchain engine.

Recorded as `KNOWN_ISSUES.md` K-02. The rate limit bounds damage per epoch but not
cumulatively: at 0.5% per 22h, a compromised rebalancer can report roughly 5.5% of loss per
week indefinitely, with no floor.

### What `REBALANCER_ROLE` cannot do

Move any asset, change the whitelist, grant roles, upgrade, pause, or set parameters. Its
entire surface is the accounting.

---

## Separation of duties

The intended split:

> **`OPERATOR_ROLE` controls where the money is. `REBALANCER_ROLE` controls what the books
> say it is worth. `ADMIN_ROLE` decides the rules. `DEFAULT_ADMIN_ROLE` decides the code.**

Compromise analysis:

| Compromised role | Consequence | Bounded by |
|---|---|---|
| `REBALANCER_ROLE` | Mispriced redemptions; value leaks gradually | 0.5%/epoch, 22h interval |
| `OPERATOR_ROLE` | Assets sent to whitelisted destinations | The whitelist |
| `ADMIN_ROLE` | Whitelist any address, then `emergencyRecover`; 100% fee | Nothing |
| `DEFAULT_ADMIN_ROLE` | Total; can grant itself every other role or upgrade | Nothing |

Known weaknesses in the current separation:

1. **No timelock anywhere.** Whitelisting and withdrawal can occur in the same block;
   upgrades and role rotations take effect immediately.
2. **`ADMIN_ROLE` mixes risk parameters with custody powers.** `setFee` and
   `emergencyRecover` sit behind the same role, so delegating parameter management is
   impossible without delegating fund extraction. This is the gap a `CURATOR_ROLE` would
   fill.
3. **`ADMIN_ROLE` and `OPERATOR_ROLE` may be the same key.** The whitelist setter and the
   fund mover must be distinct for the whitelist to function as a control.
4. **`setMaxFeePercentage` and `setMinDistributionInterval` are unbounded** in the
   directions that matter (100% fee; a 1-second interval, and no maximum interval or
   staleness check at all).

---

## Post-timelock model (pending)

Implemented in `src/`, **not deployed**. Everything above describes live state today.

### What changes

`DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` move from the Safe to an OpenZeppelin
`TimelockController` with a 48-hour `minDelay`, deployed with `admin == address(0)` so no
standing bypass exists. There is **no code coupling** — no contract imports or stores the
timelock address. The vault sees a call from an address holding `ADMIN_ROLE` and has no
idea a delay occurred.

Upgrades inherit the delay at no cost: `_authorizeUpgrade` was already
`onlyRole(DEFAULT_ADMIN_ROLE)`, so the role move is sufficient.

### The fifth role

`GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE")`, declared on `TownSqToken` and `Manager`. It
exists only because `TimelockController` applies one uniform delay and two actions cannot
tolerate it.

| Can | Cannot |
|---|---|
| `pause()` (`TownSqToken.sol`) | `unpause()` |
| `removeWhitelistedAddresses()` (`Manager.sol`) | `setWhitelistedAddresses()` |
| | Any parameter, upgrade, or role grant |

The asymmetry is the point: a compromised guardian can only cause a denial of service that
`ADMIN_ROLE` can undo. It can never open a path for funds to leave, and it can never lift a
halt it caused. Pause-fast/resume-slow is deliberate — pause blocks user withdrawals
(K-01), so lifting it should carry the delay and the visibility.

### Storage safety

Adding role constants costs **no storage slots** — `AccessControlUpgradeable` keys roles by
`bytes32` in an existing mapping. `forge inspect storage-layout` before and after is
identical on all three contracts (10 / 7 / 11 slots, matching label, slot, offset and type;
only `astId` values differ, which are AST node ids, not storage positions).

`Yield` is unchanged — it has no emergency surface.

### Roles after the handover

| Role | Holder | Delay |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController | 48h |
| `ADMIN_ROLE` | TimelockController | 48h |
| `GUARDIAN_ROLE` | Safe | none — pause, whitelist removal only |
| `OPERATOR_ROLE` | Executor | none — unchanged |
| `REBALANCER_ROLE` | Offchain engine | none — unchanged |

The operational roles are deliberately untouched. A 48-hour delay on `execute` or
`distributeYield` would break normal operation, and neither can change the rules.
`script/TimelockRoleChange.s.sol` asserts at runtime that its batch never touches either.

### Deployment

1. Deploy guardian-aware `TownSqToken` and `Manager` implementations.
2. `forge script script/DeployTimelock.s.sol --broadcast`
3. `forge script script/TimelockRoleChange.s.sol` → `safe/timelock-handover.json`, a
   16-transaction batch. **Order is load-bearing**: guardian granted before any admin
   revoke (otherwise there is a window with no working pause), and `DEFAULT_ADMIN` revoked
   last on each proxy (it authorises the revokes).
4. Verify onchain that the Safe holds `GUARDIAN_ROLE` and *not* `ADMIN_ROLE`.

Simulate against live state first:

```bash
forge test --match-path test/TimelockHandover.fork.t.sol -vv
```

That forks the chain, deploys the implementations and timelock, runs the exact batch as the
Safe, and asserts live storage survives — fee, cooldown, vesting, `virtualAssets`,
`totalAssets`, supply, `totalRequestedAmount`, treasury, epoch and whitelist entries.

### Which weaknesses this closes

Of the four listed above: (1) no timelock is resolved for governance actions; (2)
`ADMIN_ROLE` mixing risk parameters with custody powers is *mitigated*, not fixed — both
now carry a 48h delay, but they remain the same role, so a `CURATOR_ROLE` split is still
the cleaner answer; (3) and (4) are unaffected.

## Reading live state

Role holders and the whitelist are onchain state, not repo state. Do not quote either from
source — read them.

X Layer (chain 196), per `script/SafeRoleChange.s.sol`:

| Contract | Proxy |
|---|---|
| `TownSqToken` | `0x5B8dC679EDAE1Ad507c433EF55d5B4bA620F1919` |
| `Yield` | `0xa437BD29AB51BF43C686FE1561B97cF9DeBFB524` |
| `Manager` | `0xF14d5567f85c73FD309738374D5a69EB17b8387c` |

```bash
# Role holders
cast call <proxy> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ADMIN_ROLE") <address> --rpc-url $RPC_URL

cast call <proxy> "getRoleMemberCount(bytes32)(uint256)" \
  $(cast keccak "OPERATOR_ROLE") --rpc-url $RPC_URL

# Whitelist — authoritative history is the event stream
cast logs --address 0xF14d5567f85c73FD309738374D5a69EB17b8387c \
  "WhitelistUpdated(address,address,bool)" --from-block <deploy> --rpc-url $RPC_URL

# Single-address check
cast call 0xF14d5567f85c73FD309738374D5a69EB17b8387c \
  "whitelistedAddresses(address)(bool)" <address> --rpc-url $RPC_URL

# Live parameters
cast call 0x5B8dC679EDAE1Ad507c433EF55d5B4bA620F1919 "fee()(uint256)" --rpc-url $RPC_URL
cast call 0xa437BD29AB51BF43C686FE1561B97cF9DeBFB524 "maxFeePercentage()(uint256)" --rpc-url $RPC_URL
```

If a role holder is a Safe, `getOwners()` and `getThreshold()` give the real signing
requirement. `ARCHITECTURE.md:72` describes `OPERATOR_ROLE` as an "Executor (EOA/bot)"
while `script/SafeRoleChange.s.sol` rotates it to a Safe — these descriptions conflict and
the onchain state is authoritative.

## Events

Every privileged action emits. Useful for monitoring and for diligence evidence.

| Event | Contract | Signals |
|---|---|---|
| `WhitelistUpdated` | Manager | Destination allowlist change |
| `BatchExecuted` | Manager | `execute` call, with full targets and calldata |
| `TreasurySet` | Manager | Fee destination change |
| `MaxRedeemCapSet`, `MinSharesInVaultTokenSet` | Manager | Capacity parameter change |
| `DistributeYield` | Yield | Epoch P&L report |
| `TreasuryDebtAccrued`, `TreasuryDebtRepaid` | Yield | Unabsorbed loss / settlement |
| `MaxYieldPercentageSet`, `MaxFeePercentage`, `MinDistributionIntervalSet` | Yield | Yield parameter change |
| `FeeSet`, `CooldownPeriodUpdated`, `VestingPeriodUpdated` | TownSqToken | Vault parameter change |
| `EmergencyRecovery` | TownSqToken | Asset extraction |
| `Paused`, `Unpaused` | TownSqToken | Pause state (OZ Pausable) |
| `RoleGranted`, `RoleRevoked` | all three | Role rotation (OZ AccessControl) |
| `Upgraded` | all three | Implementation change (OZ ERC1967) |

Two monitoring gaps:

- **`Manager.transferToVault` emits nothing.** Redemption funding — the step withdrawal
  liveness depends on — is observable only via the underlying ERC-20 `Transfer`.
- **`AssetsWithdrawn` is declared in `IManager` but never emitted** anywhere in `src/`.
  Do not build monitoring against it.

Note also that `Yield`'s fee-cap event is named `MaxFeePercentage`, not
`MaxFeePercentageSet` — it breaks the naming convention every other setter event follows.
