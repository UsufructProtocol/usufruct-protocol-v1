# monetary

## § OVERVIEW

Defines the two monetary units the protocol operates with: `Price` — the per-tenure floor amount quoted by policy — and `Stake` — the collateral a tenant commits at rent time. The distinction is semantic, not structural; separate types prevent accidental substitution (e.g., passing a stake where a price is expected). All values are denominated in MIST (1 SUI = 10⁹ MIST).

## § TYPES

```
Price { mist: u64 }   has copy, drop, store
```
A quoted amount per tenure. Produced by policy functions; consumed by settlement and price escalation.

```
Stake { mist: u64 }   has copy, drop, store
```
Tenant collateral locked at rent time. Converted to a reference price via `as_reference_price` when used as the base for next-tenure escalation.

## § API

**Constructors**
- `monetary::price(mist: u64): Price`
- `monetary::stake(mist: u64): Stake`

**Accessors**
- `monetary::price_mist(Price): u64`
- `monetary::stake_mist(Stake): u64`

**Conversions**
- `monetary::as_reference_price(Stake): Price` — reinterprets the mist value of a Stake as a Price; the bridge between what a tenant paid and what the next tenant must pay.

**Arithmetic**
- `monetary::compute_price_add(Price, Price): Price` — checked addition; aborts on overflow
- `monetary::compute_price_sub(Price, Price): Price`
- `monetary::compute_stake_sub(Stake, Stake): Stake`

## § INVARIANTS

- `Price` and `Stake` are distinct types; no implicit coercion exists between them.
- `compute_price_add` aborts if the result would exceed `u64::MAX`.
- Subtraction operations are caller-ordered; the module does not check for underflow.

## § EVENTS

None.
