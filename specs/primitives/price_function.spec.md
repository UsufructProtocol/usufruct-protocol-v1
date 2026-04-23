PRICE_FUNCTION MODULE — SPECIFICATION
======================================

Module: `price_function`
Design reference: design-compact.md §5
Module map reference: module-map.spec.md §2


0. MODULE RESPONSIBILITY
------------------------

`price_function` defines the `PriceFunction` type and evaluates it.
It encapsulates the logic for `f_next_rent_price` — how the rent price
escalates between consecutive rental periods.

**Owns:**

- `PriceFunction` — enumerated functional forms for `f_next_rent_price`.
  All dispatch on this type lives here.
- `evaluate_price_fn` — `public(package)` dispatcher. Single entry point for
  evaluating any `PriceFunction` at a given `last_rent_price`. Called directly
  by `rental_escrow::compute_next_rent_price`; the escrow layer owns all
  state validation (e.g. `E_NOT_RENTED`) around the call.

**Does not own:**

- `CurveShape` type or any credit/price-descent logic — lives in `curve_shape`.
- Assembly of integration parameters — lives in `config::new`.
  (`config::new` calls constructors; it does not re-validate fields.)
- Protocol state (`RentalEscrow`, phase anchors).
- Fund movements (`Balance`, `Coin`).
- Access control (`OwnerCap`, `TenantCap`).
- Raw arithmetic primitives (`mul_div`) — those live in `math`.

**Dependency direction:** `price_function` calls `math`. `config` and
`rental_escrow` call `price_function`. `price_function` calls nothing outside
`math`.


1. ERROR CONSTANTS
------------------

All validation aborts originate in the constructors defined in §2.3.

    const E_DELTA_ZERO: u64 = 0;  // new_fixed_delta, new_compound_delta: delta == 0
    const E_BPS_RANGE:  u64 = 1;  // new_compound_delta: bps ∉ [1, u64::MAX − BPS_PER_UNIT]

**Module constants:**

    const BPS_PER_UNIT: u64 = 10_000;  // basis points per one whole unit (100% = 10_000 bps)


2. TYPE
-------

### PriceFunction — enum

Defines the functional form of `f_next_rent_price`.

```move
public enum PriceFunction has copy, drop, store {
    FixedDelta {
        delta: u64,
    },
    CompoundDelta {
        bps: u64,
        delta: u64,
    },
}
```

**Field-level constraints (validated by constructors in §2.3):**

- `FixedDelta`:    `delta > 0`
- `CompoundDelta`: `bps ∈ [1, u64::MAX - BPS_PER_UNIT]` so `BPS_PER_UNIT + bps` does not overflow u64; `delta > 0`

Both variants guarantee `f(x) > x` for all `x > 0` from field constraints alone — no
cross-field validation required. For `CompoundDelta`: `mul_div(x, BPS_PER_UNIT + bps, BPS_PER_UNIT) >= x`
always (denominator ≤ numerator factor), so `+ delta > 0` ensures strict increase regardless
of floor rounding on the percentage component.

**Semantics:**

| Variant | Formula |
|---------|---------|
| `FixedDelta { delta }` | `f(x) = x + delta` |
| `CompoundDelta { bps, delta }` | `f(x) = mul_div(x, BPS_PER_UNIT + bps, BPS_PER_UNIT) + delta` |

where `bps` is basis points (100 bps = 1%, `BPS_PER_UNIT` = 10_000 bps = 100%).
`delta` is a raw amount in the payment token's base denomination — same unit as
`min_rent_price` and `last_rent_price`. It is not scaled by `SCALE` (10^9).
Pure percentage behavior: use `CompoundDelta { bps, delta: 1 }` (1 base unit).

**Floor threshold for the percentage component** — the bps contribution is zero when
`last_rent_price < BPS_PER_UNIT / bps`. Below this threshold only `delta` contributes.

| bps | % | Min price for bps to contribute |
|-----|---|---------------------------------|
| 1 | 0.01% | 10_000 base units |
| 10 | 0.1% | 1_000 base units |
| 50 | 0.5% | 200 base units |
| 100 | 1% | 100 base units |
| 500 | 5% | 20 base units |
| 1_000 | 10% | 10 base units |

For highly fractioned tokens, prefer larger `bps` or a meaningful `delta` to ensure
the percentage component is not silently swallowed by floor rounding.


2.3 CONSTRUCTORS
----------------

Enum fields are private to `price_function.move`. All external callers must
construct `PriceFunction` values through these functions.

    public fun new_fixed_delta(delta: u64): PriceFunction
    // Validates:
    //   assert!(delta > 0, E_DELTA_ZERO)
    // Returns PriceFunction::FixedDelta { delta }.

    public fun new_compound_delta(bps: u64, delta: u64): PriceFunction
    // Validates:
    //   assert!(bps >= 1 && bps <= u64::MAX - BPS_PER_UNIT, E_BPS_RANGE)
    //   assert!(delta > 0,                                  E_DELTA_ZERO)
    // Returns PriceFunction::CompoundDelta { bps, delta }.


3. EVALUATE_PRICE_FN
--------------------

### Signature

    public(package) fun evaluate_price_fn(
        price_fn:        &PriceFunction,
        last_rent_price: u64,
    ): u64

### Semantics

Single protocol-level entry point. Dispatches on `PriceFunction` and returns
the next rent price.

    fun evaluate_price_fn(price_fn: &PriceFunction, last_rent_price: u64): u64 {
        match price_fn {
            PriceFunction::FixedDelta    { delta }      => eval_fixed_delta(last_rent_price, *delta),
            PriceFunction::CompoundDelta { bps, delta } => eval_compound_delta(last_rent_price, *bps, *delta),
        }
    }

This module does not own state-level validation: callers that need to gate
the evaluation by protocol state (e.g. assert `state == Rented`) do so at
their own layer. `rental_escrow::compute_next_rent_price` is the external
call site and performs the `E_NOT_RENTED` guard before invoking
`evaluate_price_fn`.

---

### `eval_fixed_delta` (private)

    fun eval_fixed_delta(last_rent_price: u64, delta: u64): u64

    last_rent_price + delta

### `eval_compound_delta` (private)

    fun eval_compound_delta(last_rent_price: u64, bps: u64, delta: u64): u64

    math::mul_div(last_rent_price, BPS_PER_UNIT + bps, BPS_PER_UNIT) + delta

### Overflow

All additions use checked arithmetic — abort on u64 overflow.
Guaranteed result > last_rent_price by constructor field constraints (§2.3).


4. MODULE BOUNDARY
-------------------

`price_function.move` exports:

| Symbol | Visibility | Notes |
|--------|-----------|-------|
| `E_DELTA_ZERO: u64 = 0` | `public` | SDK error handling. |
| `E_BPS_RANGE: u64 = 1` | `public` | SDK error handling. |
| `new_fixed_delta(delta)` | `public` | Called by integrators to build `PriceFunction`. |
| `new_compound_delta(bps, delta)` | `public` | Called by integrators. Validates. |
| `evaluate_price_fn(...)` | `public(package)` | Dispatcher — match on `PriceFunction`. Called by `rental_escrow::compute_next_rent_price`. |
| `eval_fixed_delta(...)` | private | §3 |
| `eval_compound_delta(...)` | private | §3 |

`PriceFunction` is defined in this module and embedded in `IntegrationConfig`
(via `config.move`).

**Integration flow:** constructors are `public` — callable directly from PTBs.
An integrator builds `PriceFunction` values by calling these constructors, then
passes them to `config::new`, then to `rental_escrow::integrate`.
Error constants are `public` so the SDK can map abort codes to human-readable messages.

**Depends on:** `math` (for `mul_div`).


5. TEST CASES
-------------

Tests follow the same convention as `math.spec.md`: exact values are given where
derivable from the algorithm by hand.

Three categories per function:
- **Edge cases** — boundary inputs with known exact output
- **Golden vectors** — specific input → exact output (hand-derived)
- **Properties** — invariants that must hold for all valid inputs in the stated domain


### 5.1 `eval_fixed_delta`

#### Golden vectors

| `last_rent_price` | `delta` | result | note |
|-------------------|---------|--------|------|
| `100` | `50` | `150` | exact |
| `1_000_000_000` | `1` | `1_000_000_001` | minimum delta |
| `1_000_000_000` | `1_000_000_000` | `2_000_000_000` | delta equals price |

#### Properties

- **Exactness:** `result = last_rent_price + delta`
- **Strict increase:** `result > last_rent_price`
- **Exact increment:** `result - last_rent_price = delta`


### 5.2 `eval_compound_delta`

#### Golden vectors

| `last_rent_price` | `bps` | `delta` | result | note |
|-------------------|-------|---------|--------|------|
| `10_000` | `500` | `1` | `10_501` | 5% = +500, +delta |
| `1` | `500` | `1` | `2` | percentage floors to 0, only delta contributes |
| `200` | `50` | `1` | `201` | bps=50 at exact threshold (x=200): +1 from pct, +1 from delta |
| `199` | `50` | `1` | `200` | below threshold: pct floors to 0 |
| `1_000_000_000` | `10_000` | `1` | `2_000_000_001` | 100% + delta |

#### Properties

- **Strict increase:** `result > last_rent_price` for all valid inputs
- **Minimum increase:** `result >= last_rent_price + delta`
- **Percentage floor:** when `last_rent_price < BPS_PER_UNIT / bps`,
  `result = last_rent_price + delta` (percentage component lost to floor rounding)


### 5.3 `evaluate_price_fn`

#### Properties

- **Strict increase:** `result > last_rent_price` for all valid inputs
- **Determinism:** same `(price_fn, last_rent_price)` → same result always
- **Dispatch correctness:** result matches the branch-specific formula
  (§5.1 for `FixedDelta`, §5.2 for `CompoundDelta`) — the dispatcher adds
  no transformation beyond the `match`.
