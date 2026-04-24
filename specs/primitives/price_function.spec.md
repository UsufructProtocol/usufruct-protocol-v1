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

Tests follow the same convention as `math.spec.md` §5: exact values are
given where derivable from the algorithm by hand. `price_function` has no
algorithm-derived golden vectors — both variants are closed-form u64
arithmetic.

Three categories per function:
- **Edge cases** — boundary inputs with known exact output
- **Golden vectors** — specific input → exact output (hand-derived)
- **Properties** — invariants that must hold for all valid inputs in the stated domain


### 5.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::price_function_tests`.
Function names describe the asserted behaviour (e.g.
`eval_compound_delta_rounds_pct_to_zero_below_threshold`,
`new_compound_delta_rejects_bps_zero`).

**Idioms.**

- Constructor success rows and `eval_*` golden-vector rows translate as
  **one parametric loop** per function over a `vector<Case>`.
- Constructor abort rows and evaluator-overflow rows translate as **one
  `#[test, expected_failure(abort_code = price_function::E_<NAME>)]`
  function each**. The `math::E_MUL_DIV_OVERFLOW` cross-module abort is
  referenced by its fully-qualified name; the built-in `arithmetic_error`
  for `u64` add-overflow is asserted via
  `#[expected_failure(arithmetic_error, location = liquid_renting::price_function)]`.

**Fixtures.** None. All functions are pure u64 → u64, no `TxContext`.

**Private-symbol access.** The `#[test_only]` wrappers declared alongside
the private helpers expose:

```
#[test_only] public fun eval_fixed_delta_for_testing(
    last_rent_price: u64, delta: u64): u64
#[test_only] public fun eval_compound_delta_for_testing(
    last_rent_price: u64, bps: u64, delta: u64): u64
#[test_only] public fun bps_per_unit_for_testing(): u64
#[test_only] public fun fixed_delta_fields_for_testing(
    price_fn: &PriceFunction): u64
#[test_only] public fun compound_delta_fields_for_testing(
    price_fn: &PriceFunction): (u64, u64)
```

The `*_fields_for_testing` destructure helpers match on the corresponding
variant (abort on mismatch) so constructor tests can verify stored
field values without leaking enum fields publicly. Dispatcher-equivalence
tests (§5.3) call `evaluate_price_fn(&shape, x)` and
`eval_<variant>_for_testing(x, …)` and assert equality.

**Golden-vector convention.** All vectors below are hand-derived (closed
form). No `TBD (algorithm-derived)` placeholders in this module.


### 5.0.1 Constructor success

| `new_*` call | stored variant | note |
|---|---|---|
| **[new]** `new_fixed_delta(1)` | `FixedDelta { 1 }` | minimum valid delta |
| **[new]** `new_fixed_delta(u64::MAX)` | `FixedDelta { u64::MAX }` | maximum delta; construction succeeds (overflow only fires at evaluation) |
| **[new]** `new_compound_delta(1, 1)` | `CompoundDelta { 1, 1 }` | minimum valid `bps` and `delta` |
| **[new]** `new_compound_delta(BPS_PER_UNIT, 1)` | `CompoundDelta { BPS_PER_UNIT, 1 }` | 100% bps — inside bounds |
| **[new]** `new_compound_delta(u64::MAX - BPS_PER_UNIT, 1)` | `CompoundDelta { u64::MAX − BPS_PER_UNIT, 1 }` | **upper boundary** of §1 `bps` range; construction succeeds — evaluation at non-trivial `last_rent_price` may abort via `math::E_MUL_DIV_OVERFLOW` (see §5.2 abort rows) |


### 5.0.2 Constructor abort

Each row translates to one dedicated
`#[test, expected_failure(abort_code = price_function::E_<NAME>)]` function.

| Call | Abort code | Reason |
|---|---|---|
| **[new]** `new_fixed_delta(0)` | `E_DELTA_ZERO` | `delta == 0` |
| **[new]** `new_compound_delta(500, 0)` | `E_DELTA_ZERO` | `delta == 0` — same constant reused from the `CompoundDelta` site (renamed from `E_FIXED_DELTA_ZERO`) |
| **[new]** `new_compound_delta(0, 1)` | `E_BPS_RANGE` | `bps == 0` below range |
| **[new]** `new_compound_delta(u64::MAX - BPS_PER_UNIT + 1, 1)` | `E_BPS_RANGE` | `bps` one above upper bound — smallest value that would overflow `BPS_PER_UNIT + bps` in u64 |
| **[new]** `new_compound_delta(u64::MAX, 1)` | `E_BPS_RANGE` | saturated `bps` — confirms upper bound fires, not any arithmetic path |

**Abort-check order assumption.** Rows for `new_compound_delta(0, 0)`
and `new_compound_delta(u64::MAX, 0)` are omitted: the expected abort
depends on whether the `bps` check or the `delta` check fires first. The
§2.3 listing shows `bps` first; document this order in code and keep
single-violation rows to avoid coupling tests to assert ordering. Flagged
in Open questions.


### 5.1 `eval_fixed_delta`

#### Golden vectors

| `last_rent_price` | `delta` | result | note |
|-------------------|---------|--------|------|
| `100` | `50` | `150` | exact |
| `1_000_000_000` | `1` | `1_000_000_001` | minimum delta |
| `1_000_000_000` | `1_000_000_000` | `2_000_000_000` | delta equals price |
| **[new]** `0` | `1` | `1` | zero `last_rent_price` — valid input at this layer (escrow layer rejects `last_rent_price = 0` separately) |
| **[new]** `u64::MAX - 1` | `1` | `u64::MAX` | saturated boundary without overflow |

#### Abort rows

| `last_rent_price` | `delta` | abort | reason |
|-------------------|---------|-------|--------|
| **[new]** `u64::MAX` | `1` | `arithmetic_error` | u64 add overflow — §3 states "checked arithmetic — abort on u64 overflow" |
| **[new]** `u64::MAX / 2 + 1` | `u64::MAX / 2 + 1` | `arithmetic_error` | **[new]** sum equals u64::MAX + 1 — exact overflow boundary |

#### Properties

- **Exactness:** `result = last_rent_price + delta`
- **Strict increase:** `result > last_rent_price` (since `delta > 0` by §2.3)
- **Exact increment:** `result - last_rent_price = delta`

**[new] [property] Strict-increase seed set F:** for every
`(last_rent_price, delta) ∈ {(0, 1), (100, 50), (u64::MAX - 2, 1), (10⁹, 10⁹)}`,
assert `result > last_rent_price`. Encoded as a predicate over the
parametric loop.


### 5.2 `eval_compound_delta`

#### Golden vectors

| `last_rent_price` | `bps` | `delta` | result | note |
|-------------------|-------|---------|--------|------|
| `10_000` | `500` | `1` | `10_501` | 5% = +500, +delta |
| `1` | `500` | `1` | `2` | percentage floors to 0, only delta contributes |
| `200` | `50` | `1` | `202` | **[corrected]** bps=50 at exact threshold (x=200): `mul_div(200, 10_050, 10_000) = 201` (pct contribution +1), then `+ delta = 202`. Prior spec row stated `201` — did not add `delta` to the pct result. |
| `199` | `50` | `1` | `200` | below threshold: pct floors to 0 |
| `1_000_000_000` | `10_000` | `1` | `2_000_000_001` | 100% + delta |
| **[new]** `0` | `500` | `1` | `1` | zero `last_rent_price`: pct component = 0 mechanically (mul_div(0, …) = 0); only delta contributes |
| **[new]** `9_999` | `1` | `1` | `10_000` | just below the `bps=1` threshold (§2 table): `mul_div(9_999, 10_001, 10_000) = floor(99_999_999 / 10_000) = 9_999`; +delta = 10_000 — pct floors to 0 |
| **[new]** `10_000` | `1` | `1` | `10_002` | **minimum `bps`** (`bps = 1` = 0.01%) at the §2-table threshold: `mul_div(10_000, 10_001, 10_000) = 10_001` (pct contribution +1), +delta = 10_002 — first `last_rent_price` at which the pct contributes |
| **[new]** `20_000` | `1` | `1` | `20_003` | higher up: `mul_div(20_000, 10_001, 10_000) = 20_002`; +delta = 20_003 — confirms pct contributes +2 once well above threshold |
| **[new]** `1_000_000_000` | `1` | `1` | `1_000_100_001` | `mul_div(10⁹, 10_001, 10_000) = 1_000_100_000`; +delta = 1_000_100_001 — full 0.01% contribution (+100_000) |

#### Abort rows

| `last_rent_price` | `bps` | `delta` | abort | reason |
|-------------------|-------|---------|-------|--------|
| **[new]** `u64::MAX` | `1` | `1` | `math::E_MUL_DIV_OVERFLOW` | `mul_div(u64::MAX, 10_001, 10_000) > u64::MAX` — math layer aborts before the `+ delta` add |
| **[new]** `u64::MAX - 1` | `BPS_PER_UNIT` | `1` | `math::E_MUL_DIV_OVERFLOW` | `mul_div(u64::MAX − 1, 20_000, 10_000) = 2·(u64::MAX − 1)` overflows u64 — fires at the math layer |
| **[new]** `u64::MAX / 2` | `1` | `u64::MAX` | `arithmetic_error` | **pct result** `≈ u64::MAX/2` fits u64; `+ delta = u64::MAX` fits too — but `u64::MAX/2` is even, `mul_div` returns `mul_div(u64::MAX/2, 10_001, 10_000) = (u64::MAX/2) + (u64::MAX/2)/10_000` — add-overflow fires on `+ delta` when the pct result plus delta exceeds u64. Row documents the checked-add behavior at the price_function layer vs the mul_div layer above. |

#### Properties

- **Strict increase:** `result > last_rent_price` for all valid inputs (when
  `mul_div` does not abort)
- **Minimum increase:** `result >= last_rent_price + delta`
- **Percentage floor:** when `last_rent_price < BPS_PER_UNIT / bps`,
  `result = last_rent_price + delta` (percentage component lost to floor rounding)
- **[new] [property] Percentage-floor threshold (seed set C).** For each
  `(bps, threshold)` pair from the §2 table
  `{(1, 10_000), (10, 1_000), (50, 200), (100, 100), (500, 20), (1_000, 10)}`,
  assert the pair of claims:
  1. `eval_compound_delta_for_testing(threshold − 1, bps, 1) = threshold − 1 + 1 = threshold`
     (pct still floors to 0 at `last_rent_price = threshold − 1`).
  2. `eval_compound_delta_for_testing(threshold, bps, 1) >= threshold + 1`
     (pct begins to contribute at or before `last_rent_price = threshold`;
     the exact unit where contribution starts can vary by 1 ULP — see
     corrected `200, 50, 1` row above, where `threshold = 200` is the
     first contributing price).
- **[new] [property] Strict increase on compound seed C':** for every
  `(x, bps, delta) ∈ {(1, 1, 1), (200, 50, 1), (10⁹, 500, 1), (10⁹, 1, 10⁹), (0, 500, 1)}`,
  assert `eval_compound_delta_for_testing(x, bps, delta) > x`.


### 5.3 `evaluate_price_fn`

#### Golden vectors

Each row builds the `PriceFunction` via the constructor, passes it to the
dispatcher, and asserts equality with the corresponding private helper
output (i.e. both the constructor and the dispatch arm are exercised).

| `price_fn` | `last_rent_price` | result | note |
|---|---|---|---|
| **[new]** `new_fixed_delta(50)` | `100` | `150` | dispatcher reaches `FixedDelta` arm |
| **[new]** `new_compound_delta(500, 1)` | `10_000` | `10_501` | dispatcher reaches `CompoundDelta` arm — matches §5.2 first row |
| **[new]** `new_compound_delta(50, 1)` | `200` | `202` | dispatcher + corrected-vector cross-check |

#### Dispatch equivalence

**[new] [property] P-DE — dispatch equivalence.** For every
`(price_fn, last_rent_price)` pair in the seed set
`{(new_fixed_delta(50), 100), (new_fixed_delta(1), 0),
  (new_compound_delta(500, 1), 10_000),
  (new_compound_delta(50, 1), 200),
  (new_compound_delta(1, 1), 9_999),
  (new_compound_delta(1, 1), 10_000)}`,
assert `evaluate_price_fn(&price_fn, last_rent_price) ==
eval_<variant>_for_testing(last_rent_price [, fields…])`. Guards
against dispatcher drift (wrong arm, wrong field forwarding) that
would not surface in any single-variant row.

#### Properties

- **Strict increase:** `result > last_rent_price` for all valid inputs
  (when neither `math::E_MUL_DIV_OVERFLOW` nor `arithmetic_error` fires)
- **Determinism:** same `(price_fn, last_rent_price)` → same result always
- **Dispatch correctness:** result matches the branch-specific formula
  (§5.1 for `FixedDelta`, §5.2 for `CompoundDelta`) — the dispatcher adds
  no transformation beyond the `match`. Operationalized by property P-DE
  above.


### 5.4 Open questions

- **Constructor abort-ordering assumption.** §5.0.2 assumes
  `new_compound_delta` checks `bps` before `delta`. If the implementation
  chooses the reverse order, `new_compound_delta(0, 0)` would abort with
  `E_DELTA_ZERO` instead of `E_BPS_RANGE`. The test table avoids
  dual-violation inputs specifically so rows remain insensitive to this
  choice; document the chosen order in §2.3 once implementation lands
  and reconcile.
- **Checked-arithmetic location for `eval_compound_delta` add-overflow.**
  §5.2 abort row `u64::MAX / 2, 1, u64::MAX` asserts an
  `arithmetic_error` from the `+ delta` step. In Move 2024 the add is
  implicitly checked, so the abort surfaces at the `+` operator inside
  `eval_compound_delta`. If a future refactor wraps the add in a
  named-error helper (e.g. `math::checked_add`), update this row and the
  attribute form (`location = ...`).
- **§2 threshold-table interpretation.** The corrected `200, 50, 1 → 202`
  row and the new `10_000, 1, 1 → 10_002` row together confirm that the
  §2 table's "Min price for bps to contribute" column marks the first
  `last_rent_price` at which the pct contribution is exactly `+1` (not
  the last price at which it floors to 0). Preserve the §2 column
  semantics as-is; flagged here only in case a future edit rewrites §2
  prose.
- **Prior test-spec bug.** The row `200, 50, 1 → 201` in the pre-audit
  `§5.2` table was internally inconsistent (its note described +1 pct,
  +1 delta → 202, but the result column said 201). Corrected in-place
  this pass. No code-side issue — the test vector itself was wrong.
