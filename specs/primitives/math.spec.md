# math

## § OVERVIEW

Low-level numeric utilities shared across all layers. Provides `BasisPoints` — a typed wrapper for fractional rates expressed in hundredths of a percent — along with the three arithmetic kernels the protocol depends on: overflow-checked fixed-point multiplication (`compute_mul_div`), basis-point application, and integer nth-root via Newton's method. All operations are pure functions with no side effects.

## § TYPES

```
BasisPoints { bps: u64 }   has copy, drop, store
```
A fractional rate in basis points (1 bp = 0.01%). The denominator is always 10 000. Used by `price_escalation_policy` for compound price growth and by `asset_state` for the protocol fee split.

## § API

**Constructors** (package)
- `math::bps(bps: u64): BasisPoints`
- `math::bps_value(BasisPoints): u64`
- `math::bps_denominator(): u64` — returns the constant `10_000`

**Computations** (package)
- `math::compute_apply_bps(amount: u64, rate: BasisPoints): u64` — `amount × bps / 10_000`; routed through `compute_mul_div`.
- `math::compute_mul_div(a: u64, b: u64, c: u64): u64` — computes `a × b / c` using u128 intermediate to avoid overflow; aborts if the result exceeds `u64::MAX`.
- `math::compute_nth_root_u128(n: u128, d: u32): u128` — integer nth root of `n` for degree `d ∈ {2, 3, 4}`; computed via Newton's method. Used by `curve_shape_policy` for power-law curve evaluation.

## § INVARIANTS

- `compute_mul_div` aborts if `a × b / c > u64::MAX`.
- `compute_nth_root_u128` is defined only for degrees 2, 3, and 4; other degrees abort.
- `bps_denominator()` is a named constant accessor, not a magic number; callers should use it rather than embedding `10_000` directly.

## § EVENTS

None.
