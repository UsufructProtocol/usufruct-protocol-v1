# stake_balance

## § OVERVIEW

A typed wrapper around `Balance<CoinType>` that holds a usufructuary's locked collateral. The wrapper enforces that stake can only leave via two sanctioned paths: partial extraction (fee and earnings splits during settlement) and full liquidation back to the usufructuary's refund address. No raw balance handle is ever exposed outside the module.

## § TYPES

```
StakeBalance<CoinType: phantom> { balance: Balance<CoinType> }   has store
```
Locked collateral for a single usufructuary slot. No `copy` or `drop` — must be explicitly consumed.

## § API

**Constructors** (package)
- `stake_balance::new<C>(balance: Balance<C>): StakeBalance<C>`

**Accessors** (package)
- `stake_balance::proj_value<C>(&StakeBalance<C>): Stake` — current locked amount.

**Mutations** (package)
- `stake_balance::split<C>(&mut StakeBalance<C>, amount: Stake): Balance<C>` — withdraws exactly `amount` mist from the stake; used to extract fee share and governor earnings during settlement.

**Liquidation** (package)
- `stake_balance::liquidate<C>(StakeBalance<C>, to: address, ctx: &mut TxContext)` — converts the full remaining balance to a `Coin<C>` and transfers it to `to`; the canonical end-of-life path for usufructuary collateral.

**Destruction** (package)
- `stake_balance::destroy_zero<C>(StakeBalance<C>)` — asserts balance is zero before dropping.

## § INVARIANTS

- The raw `Balance` is never exposed; all outflows go through `split` (partial) or `liquidate` (full).
- `destroy_zero` aborts if any balance remains, preventing silent fund loss.
- `split` does not check for underflow; callers must ensure `amount ≤ proj_value`.

## § EVENTS

None.
