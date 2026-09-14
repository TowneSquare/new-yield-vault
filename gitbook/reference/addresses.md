# Contract addresses

{% hint style="danger" %}
**Verify every address before sending funds.** Confirm on a block explorer and by reading
the contract onchain. A wrong address means permanent loss. Never take an address from a
screenshot, a direct message, or a search result.
{% endhint %}

## Deployment status

{% hint style="warning" %}
**This table needs to be completed and verified before publication.** The repository
currently contains conflicting deployment information — the README names Monad, Base, and
BNB Smart Chain as targets, while the deployment scripts reference X Layer (chain 196) and
chain 4663. Do not publish this page until the canonical live deployments are confirmed.
{% endhint %}

| Contract | Network | Address |
|---|---|---|
| Vault (`townSqUSD`) | _to be confirmed_ | `0x…` |
| Manager | _to be confirmed_ | `0x…` |
| Yield | _to be confirmed_ | `0x…` |
| Underlying asset | _to be confirmed_ | `0x…` |

All three contracts sit behind ERC-1967 proxies. **The proxy addresses are what you
interact with**, and they do not change when the implementation is upgraded.

## Verifying an address

Before your first deposit, confirm the vault is what it claims to be:

```bash
VAULT=<address>; RPC=<rpc>

# Has code at all
cast code $VAULT --rpc-url $RPC | head -c 20

# Identity
cast call $VAULT "name()(string)" --rpc-url $RPC
cast call $VAULT "symbol()(string)" --rpc-url $RPC

# The underlying asset it accepts
cast call $VAULT "asset()(address)" --rpc-url $RPC

# Cross-check: the Manager it points at, and that the Manager points back
cast call $VAULT "manager()(address)" --rpc-url $RPC
cast call <manager> "townSqToken()(address)" --rpc-url $RPC
```

The last check matters. The vault and Manager must reference each other. If they do not,
you are looking at a misconfigured or fake deployment.

Confirm the implementation behind the proxy:

```bash
cast storage $VAULT \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $RPC
```

That is the ERC-1967 implementation slot. The value should match a verified contract on the
explorer.

## Verifying the asset

```bash
ASSET=$(cast call $VAULT "asset()(address)" --rpc-url $RPC)
cast call $ASSET "symbol()(string)" --rpc-url $RPC
cast call $ASSET "decimals()(uint8)" --rpc-url $RPC
```

{% hint style="info" %}
If the asset is USDC, expect **6 decimals** — while your vault shares will have 18. Confirm
you are looking at native USDC for that chain and not a bridged variant.
{% endhint %}

## Checking who controls the deployment

```bash
# Is the admin a multisig or a single key?
cast call <manager> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "ADMIN_ROLE") <address> --rpc-url $RPC

# If it is a Safe, this tells you the real signing requirement
cast call <admin> "getThreshold()(uint256)" --rpc-url $RPC
cast call <admin> "getOwners()(address[])" --rpc-url $RPC
```

A single-key admin on a live vault is a materially different risk profile from a multisig.
This is worth checking yourself rather than taking on trust.

## Where capital can be sent

The whitelist is the destination set for deposited capital. Its authoritative history is
the event log:

```bash
cast logs --address <manager> "WhitelistUpdated(address,address,bool)" \
  --from-block <deployment block> --rpc-url $RPC

# Check a single address
cast call <manager> "whitelistedAddresses(address)(bool)" <address> --rpc-url $RPC
```
