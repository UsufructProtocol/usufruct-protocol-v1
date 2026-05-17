# owner_earning

## § OVERVIEW

A typed wrapper around `Balance<CoinType>` that accumulates the owner's share of settlement proceeds. Separating owner earnings from the raw Sui `Balance` type prevents the balance from being routed to the wrong destination (e.g., fee inbox, tenant refund) without an explicit conversion. Earnings are accumulated inside `OwnerSeat` and drained to a `Coin` when the owner calls `withdraw_earnings`.

## § TYPES

```
OwnerEarnings<CoinType: phantom> { balance: Balance<CoinType> }   has store
```
Accumulated owner proceeds for a given coin type. No `copy` or `drop` — must be explicitly consumed or joined.

## § API

**Constructors** (package)
- `owner_earning::new<C>(balance: Balance<C>): OwnerEarnings<C>`
- `owner_earning::zero<C>(): OwnerEarnings<C>` — empty balance; used when initialising a fresh `OwnerSeat`.

**Accessors** (package)
- `owner_earning::proj_value<C>(&OwnerEarnings<C>): Stake` — current balance as a `Stake` value.

**Mutations** (package)
- `owner_earning::join<C>(&mut OwnerEarnings<C>, OwnerEarnings<C>)` — merges incoming earnings into the accumulator.
- `owner_earning::drain_all<C>(&mut OwnerEarnings<C>): Balance<C>` — extracts the full balance, leaving zero; used at withdrawal time.

**Destruction** (package)
- `owner_earning::destroy_zero<C>(OwnerEarnings<C>)` — asserts balance is zero before dropping.

## § INVARIANTS

- No direct access to the inner `Balance`; all reads and writes go through typed operations.
- `destroy_zero` aborts if the balance is non-zero, preventing silent loss of funds.

## § EVENTS

None.
