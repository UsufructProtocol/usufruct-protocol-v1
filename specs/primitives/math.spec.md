MATH MODULE — SPECIFICATION
============================

Module: `math`
Design reference: design-compact.md §5
Module map reference: module-map.spec.md §1


0. MODULE RESPONSIBILITY
------------------------

`math` is the pure arithmetic layer of the protocol. It owns every numeric
primitive shared across modules — no protocol types, no objects, no fund
movements, no Sui framework dependencies.

**Owns:**

- `mul_div` — overflow-safe integer multiplication and division via u128.
- `nth_root_u128` — integer d-th root via Newton-Raphson. Used by `curve`
  for the PowerLaw variant.
- `exp_scaled` / `exp_scaled_pos` — scaled exponential via Taylor series.
  Used by `curve` for the Exponential and Logistic variants.

**Does not own:**

- `CurveShape` — lives in `curve_shape`. `PriceFunction` — lives in `price_function`.
- `evaluate_curve` — lives in `curve_shape`.
- `evaluate_price_fn` — lives in `price_function`.
- Protocol-level scaling of curve outputs (by `tenant_stake`, spread) — lives in `rental_escrow`.
- Integration-time validation — lives in the primitive modules' constructors (`config::new` assembles, does not re-validate).
- Protocol state, fund movements, access control, event emission.

**Dependency direction:** `math` calls nothing outside its own module.
`curve` calls into `math`.


1. PRECISION MODEL
------------------

    TAYLOR_SCALE: u128    = 1_000_000_000_000_000_000  (10^18)
    TAYLOR_SCALE_SQ: u128 = TAYLOR_SCALE * TAYLOR_SCALE   (10^36, fits u128 ✓)

`TAYLOR_SCALE` and `TAYLOR_SCALE_SQ` are internal to `exp_scaled` and exported
as public constants so `curve` can interpret the results.

`SCALE` (10^9) is defined in `curve` — it is the fixed-point denominator for
curve output values and has no role in `math`.

Rounding: floor throughout (truncation), unless stated otherwise.


1.1 ERROR CONSTANTS
-------------------

    const E_MUL_DIV_OVERFLOW: u64 = 0;  // mul_div: result exceeds u64 range

Division by zero in `mul_div` (c = 0) triggers Move's built-in arithmetic
abort — no user-defined constant is needed for that path.


2. `mul_div`
-----------

### Signature

    public fun mul_div(a: u64, b: u64, c: u64): u64

### Semantics

    result = floor(a * b / c)

### Algorithm

    let num: u128 = (a as u128) * (b as u128);
    let res: u128 = num / (c as u128);
    assert!(res <= u64::MAX as u128, E_MUL_DIV_OVERFLOW);
    res as u64

### Constraints

- `c > 0` — aborts (arithmetic error) if zero
- Result fits u64 — `assert!(res <= u64::MAX as u128, E_MUL_DIV_OVERFLOW)`


### Test cases

Exact (no approximation):

| `a` | `b` | `c` | result | note |
|-----|-----|-----|--------|------|
| 0 | 5 | 3 | 0 | zero multiplicand |
| 5 | 0 | 3 | 0 | zero multiplicand |
| 6 | 7 | 3 | 14 | exact |
| 1 | 1 | 3 | 0 | floor: 1/3 |
| 2 | 1 | 3 | 0 | floor: 2/3 |
| 3 | 1 | 3 | 1 | boundary |
| 5 | 1 | 3 | 1 | floor: 5/3 |
| 6 | 1 | 3 | 2 | floor: 6/3 |
| 1_000_000_000 | 1_000_000_000 | 1_000_000_000 | 1_000_000_000 | curve::SCALE identity |
| 5_000_000_000 | 5_000_000_000 | 5_000_000_000 | 5_000_000_000 | a·b = 25×10¹⁸ > u64::MAX but result fits — intermediate exceeds u64 range, final does not |
| `u64::MAX` | 1 | 1 | `u64::MAX` | identity |
| `u64::MAX` | `u64::MAX` | `u64::MAX` | `u64::MAX` | max exact |
| `u64::MAX` | 1 | 2 | `u64::MAX / 2` | **[new]** floor of odd/2; exercises non-trivial divisor |
| 2⁶³ | 2 | 2 | 2⁶³ | **[new]** intermediate = 2⁶⁴ > u64::MAX; final fits exactly (u64::MAX+1 would not) — guards the `res <= u64::MAX` check against off-by-one |

Abort cases:

| `a` | `b` | `c` | abort | reason |
|-----|-----|-----|-------|--------|
| 1 | 1 | 0 | arithmetic | c = 0 |
| 0 | 0 | 0 | arithmetic | **[new]** c = 0 with zero multiplicands — assert that the `c = 0` check fires regardless of a/b |
| `u64::MAX` | 2 | 1 | `E_MUL_DIV_OVERFLOW` | result = 2·u64::MAX overflows |
| 2³² | 2³² | 1 | `E_MUL_DIV_OVERFLOW` | **[new]** result = 2⁶⁴ = u64::MAX + 1 — exact overflow boundary |
| `u64::MAX` | `u64::MAX` | 1 | `E_MUL_DIV_OVERFLOW` | **[new]** max intermediate ≈ 2¹²⁸ − 2⁶⁵ + 1 (fits u128), final = intermediate overflows u64 |


3. `nth_root_u128`
------------------

### Signature

    public fun nth_root_u128(n: u128, d: u32): u128

### Semantics

    Returns floor(n^(1/d))

### Valid inputs

`d ∈ {2, 3, 4}` — the only degrees used by `curve` (PowerLaw variant).
Behaviour outside this range is undefined. Validation is the caller's
responsibility (`curve`'s `power_law` constructor).

### Algorithm

Newton-Raphson integer root:

    if n == 0: return 0
    if n == 1: return 1

    // Initial guess: bit-shift based on bit-length of n
    let bits = 128u32 - n.leading_zeros();
    let shift = (bits + d - 1) / d;        // ceil(bits / d)
    let mut x: u128 = 1 << shift;          // guaranteed x0 >= n^(1/d)

    // Hoist loop-invariant casts: d is a function parameter, never reassigned.
    let d_128: u128 = d as u128;
    let d_minus_one: u128 = d_128 - 1;

    loop:
        // dispatch on d — .pow() does not exist in Move
        let x_pow: u128 = match d {
            2 => x,
            3 => x * x,
            _ => x * x * x,   // d=4
        };
        let x_new = (d_minus_one * x + n / x_pow) / d_128;
        if x_new >= x: return x   // converged — x is the floor
        x = x_new

### Convergence

Quadratic. For u128 inputs and d ≤ 4, at most ~13 iterations.
Gas cost: bounded and low (~100–200 operations).

### Overflow analysis for x_pow in loop body

x converges toward n^(1/d). At worst x0 = 1 << ceil(128/d).

    d=2: x0 ≤ 2^64, x0^1 = x0 fits u128 ✓
    d=3: x0 ≤ 2^43, x0^2 ≤ 2^86 fits u128 ✓
    d=4: x0 ≤ 2^32, x0^3 ≤ 2^96 fits u128 ✓

### Usage

Called by `curve` for the PowerLaw variant (d ∈ {2, 3, 4}).


### Test cases

Exact (floor root by definition):

| `n` | `d` | result | note |
|-----|-----|--------|------|
| 0 | 2 | 0 | n = 0 special case |
| 1 | 2 | 1 | n = 1 special case |
| 2 | 2 | 1 | **[new]** smallest non-trivial n; floor √2 ≈ 1.414 — guards Newton-Raphson initial-guess path for tiny n |
| 3 | 2 | 1 | **[new]** floor √3 ≈ 1.732 — adjacent to the (result+1)² = 4 boundary |
| 4 | 2 | 2 | perfect square |
| 9 | 2 | 3 | perfect square |
| 10 | 2 | 3 | floor: √10 ≈ 3.162 |
| 15 | 2 | 3 | floor: √15 ≈ 3.873 |
| 16 | 2 | 4 | perfect square |
| 2⁶⁴ | 2 | 2³² | **[new]** exact square at mid-u128 range — exercises d=2 Newton for n that does not hit the x0 upper bound |
| 2⁶⁴ − 1 | 2 | 2³² − 1 | **[new]** floor just below exact square — (2³²)² = 2⁶⁴ > 2⁶⁴−1 ≥ (2³²−1)² |
| 0 | 3 | 0 | n = 0 special case |
| 1 | 3 | 1 | n = 1 special case |
| 7 | 3 | 1 | **[new]** floor: ∛7 ≈ 1.913 — adjacent to (result+1)³ = 8 boundary |
| 8 | 3 | 2 | perfect cube |
| 26 | 3 | 2 | floor: ∛26 ≈ 2.962 |
| 27 | 3 | 3 | perfect cube |
| 0 | 4 | 0 | n = 0 special case |
| 1 | 4 | 1 | n = 1 special case |
| 15 | 4 | 1 | **[new]** floor: ⁴√15 ≈ 1.968 — adjacent to (result+1)⁴ = 16 boundary |
| 16 | 4 | 2 | perfect 4th power |
| 80 | 4 | 2 | floor: ⁴√80 ≈ 2.990 |
| 81 | 4 | 3 | perfect 4th power |
| 2¹²⁸ − 1 | 2 | 2⁶⁴ − 1 | max u128; (2⁶⁴−1)² ≤ 2¹²⁸−1 < (2⁶⁴)² |
| 2⁹⁶ | 3 | 2³² | exact cube: (2³²)³ = 2⁹⁶ — tests d=3 convergence for large n |
| 2⁹⁶ − 1 | 3 | 2³² − 1 | floor near boundary: (2³²)³ > 2⁹⁶−1 ≥ (2³²−1)³ |
| 2⁹⁶ | 4 | 2²⁴ | exact 4th power: (2²⁴)⁴ = 2⁹⁶ — tests d=4 convergence for large n |
| 2⁹⁶ − 1 | 4 | 2²⁴ − 1 | **[new]** floor near d=4 overflow bound — (2²⁴)⁴ = 2⁹⁶ > 2⁹⁶−1 ≥ (2²⁴−1)⁴ |

Invariant (for all valid inputs): `result^d ≤ n < (result + 1)^d`.

**[new] [property]** Parametric row — encode the invariant as a predicate
over every `(n, d, result)` triple above: assert `result^d ≤ n` and
`n < (result + 1)^d`, computed in u128 (use `math::mul_div` or raw u128
multiplication since the `(result+1)^d` product is bounded by the same
overflow analysis as §3). This row executes inside the same parametric
loop as the table and guards against future algorithm changes that
reproduce the listed outputs by coincidence but violate the floor
contract on an unlisted input.


4. `exp_scaled` / `exp_scaled_pos`
-----------------------------------

### Signatures

    public fun exp_scaled(y_num: u64, y_den: u64, neg: bool): u128
    fun exp_scaled_pos(y_num: u64, y_den: u64): u128   // private

### Semantics

    exp_scaled:     returns floor(e^(y_num/y_den) * TAYLOR_SCALE)  with sign via neg
    exp_scaled_pos: returns floor(e^(y_num/y_den) * TAYLOR_SCALE)  for y > 0 only

### Sign handling

    exp_scaled:
        if !neg { exp_scaled_pos(y_num, y_den) }
        else    { TAYLOR_SCALE_SQ / exp_scaled_pos(y_num, y_den) }

Reciprocal identity: e^(-y) = 1/e^y, so:
    floor(e^(-y) · TS) = floor(TS² / floor(e^y · TS))

This avoids alternating-sign Taylor series entirely (which would underflow u128).
Error introduced by the integer division is at most 1 ULP — within the 10^-9 budget.

### Taylor series algorithm for exp_scaled_pos

    K = 32 terms — for |y| ≤ 8, yields relative error < 10^-9.
    Early exit fires well before k=32 for small y — gas cost increase
    is only realized near the upper bound (|y| → 8).

    // Hoist loop-invariant casts out of the body.
    let y_num_128: u128 = y_num as u128
    let y_den_128: u128 = y_den as u128

    acc: u128 = TAYLOR_SCALE   // term_0 = 1 * TS
    term: u128 = TAYLOR_SCALE  // running term

    for k in 1..=K:
        term = term * y_num_128 / (k as u128 * y_den_128)
        if term == 0: break    // early exit — once term is 0, all subsequent terms are 0
        acc = acc + term

    return acc

Note: divisor `k * y_den_128` computed in u128 to avoid u64 overflow for large y_den.

### Overflow analysis

    acc     ≤ e^8 · TS ≈ 2981 · 10^18 ≈ 3×10^21          fits u128 ✓
    term    ≤ peak ≈ e^8 · TS / √(2π·8) ≈ 4.2×10^20      fits u128 ✓
    term · y_num:
      Exponential: y_num = alpha_abs · t ≤ 8 · tenure_ceiling
      Logistic:    y_num = k · |2t − t_max| ≤ 12 · tenure_ceiling
      For tenure_ceiling ≤ 10^13 ms (~317 years):
        term · y_num ≤ 4.2×10^20 · 12 · 10^13 = 5.0×10^34  fits u128 ✓
      u128 max ≈ 3.4×10^38 — safe margin of ~3 orders of magnitude.

### Usage

Called by `curve` for the Exponential and Logistic variants.


### Test cases

#### Exact case (y = 0)

The Taylor series exits after k=1 (term becomes 0). Result is exact regardless
of `neg`.

| `y_num` | `y_den` | `neg` | result |
|---------|---------|-------|--------|
| 0 | 1 | false | `TAYLOR_SCALE` |
| 0 | 1 | true | `TAYLOR_SCALE` |
| 0 | 7 | false | `TAYLOR_SCALE` |

#### Algorithm-derived golden vectors

These values are produced by the spec algorithm (K = 32 terms, floor rounding
at every step). They are not the mathematical floor of eʸ · TS — they are
what the specific integer-arithmetic algorithm produces.

**How to establish:** run the algorithm once; record the output; fix those
values as constants in the test file. All future changes must reproduce them
exactly.

Expected values for K = 32 terms. For y = 1, these are algorithm-derived
and must be verified during initial implementation:

| `y_num` | `y_den` | `neg` | expected result | note |
|---------|---------|-------|-----------------|------|
| 1 | 1 | false | 2_718_281_828_459_045_226 | **[algorithm-derived]** reference true floor(e¹ · TS) = ..._235 (delta = 9 ULP, within < 10⁻⁹ budget) |
| 1 | 1 | true  | 367_879_441_171_442_322  | **[algorithm-derived]** mathematical floor is 321; +1 ULP from reciprocal-identity rounding |
| 1 | 2 | false | **TBD (algorithm-derived)** | **[new]** fractional y = 0.5; exercises `y_den > 1` path of the divisor |
| 1 | 2 | true  | **TBD (algorithm-derived)** | **[new]** fractional y = 0.5 negative; exercises reciprocal on non-integer exponent |
| 2 | 1 | false | **TBD (algorithm-derived)** | **[new]** y = 2 — e² ≈ 7.389 · TS |
| 4 | 1 | false | **TBD (algorithm-derived)** | **[new]** y = 4 — e⁴ ≈ 54.598 · TS |
| 8 | 1 | false | **TBD (algorithm-derived)** | **[new]** y = 8 — upper bound of §4 overflow analysis; guards the claimed `acc ≤ e⁸ · TS ≈ 3×10²¹` budget |
| 8 | 1 | true  | **TBD (algorithm-derived)** | **[new]** y = 8 negative — deepest reciprocal division; guards `TAYLOR_SCALE_SQ / exp_scaled_pos(...)` precision at smallest positive result |

The seven `TBD` cells above are established during initial implementation
by running the K=32 Taylor algorithm once, pasting the resulting `u128`
literal back into this table, and committing it as the golden vector for
all future runs. See §5 "Golden-vector convention".

#### Properties

These hold for all valid inputs and can be tested without knowing exact values.
Each property below translates to one `#[test]` function that loops over the
**seed set** listed — the seeds are small on purpose (each exp_scaled call is
up to 32 Taylor iterations of u128 arithmetic, and Move tests run in-VM).

**Seed set S:** `[(1,2), (1,1), (2,1), (3,1), (4,1), (6,1), (8,1), (7,2), (15,2)]`
— nine rationals spanning (0, 8], deliberately including both integer and
fractional `y_den` values and the `y = 8` upper bound.

1. **Monotone (pos) [property].** For every adjacent pair `(yᵢ, yᵢ₊₁)` in S
   after sorting by `y_num / y_den` ascending, assert
   `exp_scaled_pos_for_testing(yᵢ) < exp_scaled_pos_for_testing(yᵢ₊₁)`.
   Targets the private Taylor kernel via the `#[test_only]` wrapper declared
   in §5. Zero-argument branch (`y = 0`) is covered by the y=0 exact rows
   above; this property does not include it.

2. **Reciprocal identity (within 1 ULP) [property].** For every `y ∈ S`,
   assert `pos × neg ∈ [TAYLOR_SCALE_SQ − TAYLOR_SCALE, TAYLOR_SCALE_SQ]`
   where `pos = exp_scaled(y_num, y_den, false)` and
   `neg = exp_scaled(y_num, y_den, true)`. Goes through the public
   `exp_scaled` entry — exercises both sign paths together. The 1-ULP slack
   matches the reciprocal-identity error budget stated in §4 "Sign handling".

3. **Precision bound [property].** Not directly testable in Move without a
   reference `floor(eʸ · TS)` oracle. Deferred to an off-chain check:
   the initial-implementation trace (which also establishes the
   `TBD (algorithm-derived)` cells) compares each produced value against a
   high-precision reference and records the relative error. If any seed in S
   exceeds `10⁻⁹` relative error, the Taylor-series parameter `K = 32` is
   insufficient and §4 must be re-budgeted. Document the trace output in a
   comment alongside the golden vectors when pasting them back.

4. **[new] [property] Boundary at y = 8.** Assert
   `exp_scaled_pos_for_testing(8, 1) > 0` and the raw product
   `exp_scaled_pos_for_testing(8, 1) * 8` (both sides cast `u128`) does not
   exceed `u128::MAX`. Guards the §4 overflow analysis claim `term · y_num ≤
   4.2×10²⁰ · 12 · 10¹³ = 5.0×10³⁴ fits u128`.

5. **[new] y = 0 sign-invariance.** Assert
   `exp_scaled(0, 1, false) == exp_scaled(0, 1, true) == TAYLOR_SCALE` and
   `exp_scaled(0, 7, false) == TAYLOR_SCALE`. Covered structurally by the
   "Exact case (y = 0)" table above; listed here to make the property
   explicit alongside the others.

#### Input validity note

No abort is defined for out-of-range y. The overflow analysis (§4) guarantees
correctness only for `y_num/y_den ≤ 8` with `tenure_ceiling ≤ 10¹³ ms`. Inputs
outside this range are the caller's responsibility (`curve` enforces them at
integration time via `alpha_abs ∈ [1, 8]`).


5. TESTS — STRATEGY
-------------------

Per-function test vectors live inline in §2, §3, §4. This section
declares the conventions the test writer applies when translating those
rows into Move code. `math` is a pure-arithmetic module: no objects, no
Sui framework dependencies, no events, no clock, no scenario.

**Test module.** `#[test_only] module liquid_renting::math_tests`.
Test functions named by what they assert (e.g. `mul_div_floor_two_thirds`,
`mul_div_overflow_aborts`). No `test_` prefix.

**Idioms.**

- Success rows translate as **one parametric loop** per function over a
  `vector<Case>`, where `Case` is a `#[test_only]` struct with the input
  columns and the `expected` column from the table. Rows flagged
  `[property]` expand into the same loop when they can be encoded as a
  per-row predicate (e.g. `nth_root_u128` invariant `result^d ≤ n <
  (result+1)^d`).
- Abort rows translate as **one `#[test, expected_failure(abort_code =
  math::E_MUL_DIV_OVERFLOW)]` function each** — parametric loops stop at
  the first abort, so success and abort rows never share a loop. The
  built-in arithmetic abort for `c = 0` is asserted via
  `#[expected_failure(arithmetic_error, location = liquid_renting::math)]`.
- Property rows that are not per-row predicates (Monotone pair,
  Reciprocal identity, Precision bound) translate as dedicated
  `#[test]` functions that loop over a small `vector<(y_num, y_den)>`
  seed set documented in §4.

**Fixtures.** None. Functions are pure u64/u128 → u128, no `TxContext`.
Assertions use `use std::unit_test::assert_eq;` under `#[test_only]`.

**Golden-vector convention.** Rows marked `[algorithm-derived]` hold
values produced by running the spec algorithm once and fixing the
output. These are not the mathematical floor of the target function —
they are what the integer-arithmetic spec produces at `K = 32` terms
with floor rounding. All future changes must reproduce them exactly.
For `exp_scaled`, the initial implementation establishes the
`[algorithm-derived]` cells marked `TBD` in §4 by running the K=32
Taylor algorithm and pasting the resulting `u128` literal back into
this spec before the first test run.

**Private-symbol access.** The "Monotone (pos)" and "Precision bound"
properties in §4 target `exp_scaled_pos` directly. The test module
obtains visibility via a `#[test_only] public fun exp_scaled_pos_for_testing(
y_num: u64, y_den: u64): u128` wrapper declared alongside the private
function — not by exposing `exp_scaled_pos` itself. The "Reciprocal
identity" property goes through the public `exp_scaled` entry.

**Open-question markers.** Cells reading `TBD (algorithm-derived)` are
intentional placeholders: they tell the test writer the row must exist
but the value is established at first implementation and pasted back
into this spec.


### Open questions

- **Precision bound oracle (property 3, §4).** Move has no high-precision
  real-number type, so the `|result − floor(eʸ · TS)| ≤ floor(eʸ · TS) ×
  10⁻⁹` check cannot execute in-VM. The audit has deferred it to an
  off-chain trace at initial implementation. If a future change introduces
  a cross-language harness (e.g. a `check_precision.py` that re-runs the
  algorithm in Python `decimal` and compares), this row can be promoted to
  a CI-level check. Until then it lives as documentation, not as `#[test]`
  code.
- **`exp_scaled_pos_for_testing` wrapper location.** The `#[test_only]`
  wrapper that exposes the private `exp_scaled_pos` to the test module
  lives inside `math.move` (same file), not in `math_tests.move` — Move's
  visibility rules require the wrapper to be in the declaring module. The
  test module then calls it directly. Flag if implementation convention
  prefers a different shape (e.g. `#[test_only] public(package)` on the
  private function itself), in which case update this spec.
- **Abort-attribute shape for `c = 0`.** Move's `arithmetic_error` abort
  has no user-defined code. The strategy above uses
  `#[expected_failure(arithmetic_error, location = liquid_renting::math)]`
  — verify this attribute form at implementation time against the target
  Sui framework version. If the form differs, update §5 accordingly.


6. MODULE BOUNDARY
------------------

`math.move` exports:

| Symbol | Visibility | Notes |
|--------|-----------|-------|
| `TAYLOR_SCALE: u128` | `public` | Used by `curve` to interpret `exp_scaled` results. |
| `TAYLOR_SCALE_SQ: u128` | `public` | Used by `curve` (Exponential neg path). |
| `E_MUL_DIV_OVERFLOW: u64 = 0` | `public` | Abort code for mul_div result overflow. |
| `mul_div(a, b, c): u64` | `public` | Used by `curve` and internally. |
| `nth_root_u128(n, d): u128` | `public` | Used by `curve` (PowerLaw). |
| `exp_scaled(y_num, y_den, neg): u128` | `public` | Used by `curve` (Exponential, Logistic). |
| `exp_scaled_pos(y_num, y_den): u128` | private | Inner Taylor series. |

**Depends on:** nothing.
