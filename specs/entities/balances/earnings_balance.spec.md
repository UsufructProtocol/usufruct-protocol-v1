# earnings_balance

## § OVERVIEW

A typed wrapper around `Balance<CoinType>` that accumulates the governor's share of settlement proceeds. Separating governor earnings from the raw Sui `Balance` type prevents the balance from being routed to the wrong destination (e.g., fee inbox, usufructuary refund) without an explicit conversion. Earnings are accumulated inside `GovernorSeat` and drained to a `Coin` when the governor calls `withdraw_earnings`.

## § TYPES

```
EarningsBalance<CoinType: phantom> { balance: Balance<CoinType> }   has store
```
Accumulated governor proceeds for a given coin type. No `copy` or `drop` — must be explicitly consumed or joined.

## § API

**Constructors** (package)
- `earnings_balance::new<C>(balance: Balance<C>): EarningsBalance<C>`
- `earnings_balance::zero<C>(): EarningsBalance<C>` — empty balance; used when initialising a fresh `GovernorSeat`.

**Accessors** (package)
- `earnings_balance::proj_value<C>(&EarningsBalance<C>): Stake` — current balance as a `Stake` value.

**Mutations** (package)
- `earnings_balance::join<C>(&mut EarningsBalance<C>, EarningsBalance<C>)` — merges incoming earnings into the accumulator.
- `earnings_balance::drain_all<C>(&mut EarningsBalance<C>): Balance<C>` — extracts the full balance, leaving zero; used at withdrawal time.

**Destruction** (package)
- `earnings_balance::destroy_zero<C>(EarningsBalance<C>)` — asserts balance is zero before dropping.

## § INVARIANTS

- No direct access to the inner `Balance`; all reads and writes go through typed operations.
- `destroy_zero` aborts if the balance is non-zero, preventing silent loss of funds.

## § EVENTS

None.
