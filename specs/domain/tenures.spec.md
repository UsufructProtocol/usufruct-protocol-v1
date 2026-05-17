# tenures

## § OVERVIEW

Defines `Tenures` — the count of consecutive rental cycles a tenant commits to in a single `rent` call. A tenant renting multiple tenures pays total stake upfront and receives proportionally longer occupancy. All scaled arithmetic delegates to `math::compute_mul_div` to avoid intermediate overflow. `Tenures` is always ≥ 1; the zero case is invalid by construction.

## § TYPES

```
Tenures { count: u64 }   has copy, drop, store
```
Number of consecutive tenure cycles purchased in a single rental. A single-cycle rental has `count = 1`.

## § API

**Constructors** (public)
- `tenures::tenures(n: u64): Tenures` — asserts `n > 0`.
- `tenures::tenures_count(Tenures): u64`

**Projections** (package)
- `tenures::proj_is_single(Tenures): bool` — true iff `count == 1`.

**Computations** (package)
- `tenures::compute_total_price(floor: Price, t: Tenures): Price` — `floor × count`; total amount owed at rent time.
- `tenures::compute_per_tenure_stake(stake: Stake, t: Tenures): Stake` — `stake / count`; collateral apportioned per cycle for credit accrual purposes.
- `tenures::compute_total_duration(d: Duration, t: Tenures): Duration` — `d × count`; total occupancy span.
- `tenures::compute_rescaled_duration(d: Duration, from: Tenures, to: Tenures): Duration` — `d × to / from`; adjusts a total duration when the committed tenure count changes.

## § INVARIANTS

- `count > 0` is enforced at construction; no zero-tenure rental is representable.
- All scaled arithmetic routes through `math::compute_mul_div`; intermediate u128 overflow aborts.

## § EVENTS

None.
