# tenant_stake

## § OVERVIEW

A typed wrapper around `Balance<CoinType>` that holds a tenant's locked collateral. The wrapper enforces that stake can only leave via two sanctioned paths: partial extraction (fee and earnings splits during settlement) and full liquidation back to the tenant's refund address. No raw balance handle is ever exposed outside the module.

## § TYPES

```
TenantStake<CoinType: phantom> { balance: Balance<CoinType> }   has store
```
Locked collateral for a single tenant slot. No `copy` or `drop` — must be explicitly consumed.

## § API

**Constructors** (package)
- `tenant_stake::new<C>(balance: Balance<C>): TenantStake<C>`

**Accessors** (package)
- `tenant_stake::proj_value<C>(&TenantStake<C>): Stake` — current locked amount.

**Mutations** (package)
- `tenant_stake::split<C>(&mut TenantStake<C>, amount: Stake): Balance<C>` — withdraws exactly `amount` mist from the stake; used to extract fee share and owner earnings during settlement.

**Liquidation** (package)
- `tenant_stake::liquidate<C>(TenantStake<C>, to: address, ctx: &mut TxContext)` — converts the full remaining balance to a `Coin<C>` and transfers it to `to`; the canonical end-of-life path for tenant collateral.

**Destruction** (package)
- `tenant_stake::destroy_zero<C>(TenantStake<C>)` — asserts balance is zero before dropping.

## § INVARIANTS

- The raw `Balance` is never exposed; all outflows go through `split` (partial) or `liquidate` (full).
- `destroy_zero` aborts if any balance remains, preventing silent fund loss.
- `split` does not check for underflow; callers must ensure `amount ≤ proj_value`.

## § EVENTS

None.
