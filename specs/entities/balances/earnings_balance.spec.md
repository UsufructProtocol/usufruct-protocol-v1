# earnings_balance

## § OVERVIEW

A typed wrapper around `Balance<CoinType>` holding the governor's share of settlement proceeds — the income-side analogue of `FeeShare`. At settlement an `EarningsBalance` is split from the departing usufructuary's stake (`usufructuary_seat::take_earnings`) and routed to the governor's `EarningsInbox` as an `EarningsMessage` (`earnings_message::post`). It is **never accumulated in a seat and never withdrawn directly** — it is a short-lived value produced at settlement and consumed into a message. The typed wrapper prevents the balance from being misrouted (to the fee inbox or the usufructuary refund) without an explicit conversion.

## § TYPES

```
EarningsBalance<CoinType: phantom> { balance: Balance<CoinType> }   has store
```
The governor's settled share for a given coin type. No `copy` or `drop` — must be explicitly consumed (posted, joined, or destroyed-zero).

## § API

**Constructors** (package)
- `earnings_balance::new<C>(balance: Balance<C>): EarningsBalance<C>` — wraps a raw balance (the split-off governor share).
- `earnings_balance::zero<C>(): EarningsBalance<C>` — an empty earnings balance.

**Accessors** (package)
- `earnings_balance::proj_value<C>(&EarningsBalance<C>): Stake` — current amount as a `Stake`.

**Mutations** (package)
- `earnings_balance::join<C>(&mut EarningsBalance<C>, EarningsBalance<C>)` — merges two earnings balances into one.
- `earnings_balance::drain_all<C>(&mut EarningsBalance<C>): Balance<C>` — extracts the full balance, leaving zero.

**Conversion** (package)
- `earnings_balance::into_balance<C>(EarningsBalance<C>): Balance<C>` — consumes the wrapper, returning the raw balance; used by `earnings_message::post` to form the message payload.

**Destruction** (package)
- `earnings_balance::destroy_zero<C>(EarningsBalance<C>)` — asserts balance is zero before dropping.

## § INVARIANTS

- No direct access to the inner `Balance`; all flows go through typed ops (`new` / `join` / `drain_all` / `into_balance`).
- `destroy_zero` aborts if the balance is non-zero, preventing silent loss of funds.
- Produced at settlement, consumed into an `EarningsMessage` — it does not persist as accumulated governor state.

## § EVENTS

None.
