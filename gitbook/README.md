---
description: A yield-bearing ERC-4626 vault with offchain-driven yield and a cooldown-based withdrawal flow.
---

# Introduction

townSqUSD is a yield-bearing vault. You deposit a stablecoin and receive `townSqUSD`
shares. Yield is produced by a trading strategy operated offchain, and realised profit or
loss is reported back onchain each epoch. Your shares change in value; the number of shares
you hold does not.

{% hint style="warning" %}
**This is not a drop-in ERC-4626 vault.** Withdrawals require a request followed by a
cooldown, allowance-based withdrawal is disabled, and `maxWithdraw` / `maxRedeem` are
unreliable. If you are integrating programmatically, read
[Withdrawing](guides/withdrawing.md) and [Function reference](reference/functions.md)
first.
{% endhint %}

## The short version

| | |
|---|---|
| **Deposit** | Free. No entry fee. Assets are forwarded to the Manager contract immediately. |
| **Yield** | Reported offchain each epoch. Profit vests linearly; losses apply instantly. |
| **Withdraw** | Two steps — `requestRedeem`, wait out the cooldown, then `redeem`. |
| **Exit fee** | Charged on redemption. Hard-capped at 1%. |
| **Custody** | The vault holds no assets. The Manager contract does, and deploys them offchain. |

## Four things to understand before depositing

**1. The vault holds no assets.** Your deposit is forwarded to the `Manager` contract, which
custodies everything and deploys it into the strategy. `totalAssets()` is an accounting
figure, not a token balance.

**2. Withdrawals must be funded before they can execute.** There is no liquidity buffer. When
your cooldown ends, an operator must push assets back onchain before you can collect. This
is an offchain-triggered step, not an automatic one.

**3. Yield is trusted input.** The vault cannot see strategy balances. An offchain engine
reports profit and loss, and the vault books what it is told — bounded by percentage caps
and a rate limit, but not verified.

**4. Your redemption amount is locked when you request it.** You stop earning yield the
moment you call `requestRedeem`, and you are also insulated from losses from that point.

{% hint style="info" %}
These are covered in full, with the reasoning behind each, in
[Risks and trust assumptions](risks/README.md). Read that page before depositing.
{% endhint %}

## Where to go next

{% content-ref url="overview/how-it-works.md" %}
[how-it-works.md](overview/how-it-works.md)
{% endcontent-ref %}

{% content-ref url="guides/depositing.md" %}
[depositing.md](guides/depositing.md)
{% endcontent-ref %}

{% content-ref url="risks/README.md" %}
[README.md](risks/README.md)
{% endcontent-ref %}

## For auditors and integrators

This documentation is written for users. The technical documentation lives in the
repository:

- `docs/ARCHITECTURE.md` — what the code does and where the trust boundaries sit
- `docs/ROLES.md` — every privileged role, enumerated
- `docs/INVARIANTS.md` — properties the protocol does and does not guarantee
- `docs/KNOWN_ISSUES.md` — accepted risks and intentional design decisions
