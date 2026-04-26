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
- `nth_root_u128` — integer d-th root via Newton-Raphson. Used by `curve_shape`
  for the PowerLaw variant.

**Does not own:**

- `CurveShape` — lives in `curve_shape`. `PriceFunction` — lives in `price_function`.
- `evaluate_curve` — lives in `curve_shape`.
- `evaluate_price_fn` — lives in `price_function`.
- `exp_scaled` / `exp_scaled_pos` / `TAYLOR_SCALE` / `TAYLOR_SCALE_SQ` — the
  Taylor series kernel and its precision constants live in `curve_shape`, the
  sole consumer.
- Protocol-level scaling of curve outputs (by `tenant_stake`, spread) — lives in `rental_escrow`.
- Integration-time validation — lives in the primitive modules' constructors
  (`config::new` assembles, does not re-validate).
- Protocol state, fund movements, access control, event emission.

**Dependency direction:** `math` calls nothing outside its own module.
`curve_shape` calls into `math`.


1. PRECISION MODEL
------------------

Intermediates use u128 to avoid overflow. Final results are cast back to u64.
No module-level precision constants.

Rounding: floor throughout (truncation), unless stated otherwise.


1.1 ERROR CONSTANTS
-------------------

    const EMulDivOverflow:   u64 = 0;  // mul_div: result exceeds u64 range
    const ENthRootBadDegree: u64 = 1;  // nth_root_u128: d ∉ {2, 3, 4}

Division by zero in `mul_div` (c = 0) triggers Move's built-in arithmetic
abort — no user-defined constant is needed for that path.


2. `mul_div`
-----------

### Signature

    public(package) fun mul_div(a: u64, b: u64, c: u64): u64

### Semantics

    result = floor(a * b / c)

### Algorithm

    let num: u128 = (a as u128) * (b as u128);
    let res: u128 = num / (c as u128);
    assert!(res <= u64::MAX as u128, EMulDivOverflow);
    res as u64

### Constraints

- `c > 0` — aborts (arithmetic error) if zero
- Result fits u64 — `assert!(res <= u64::MAX as u128, EMulDivOverflow)`


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
| 1_000_000_000 | 1_000_000_000 | 1_000_000_000 | 1_000_000_000 | curve_shape::SCALE identity |
| 5_000_000_000 | 5_000_000_000 | 5_000_000_000 | 5_000_000_000 | a·b = 25×10¹⁸ > u64::MAX but result fits — intermediate exceeds u64 range, final does not |
| `u64::MAX` | 1 | 1 | `u64::MAX` | identity |
| `u64::MAX` | `u64::MAX` | `u64::MAX` | `u64::MAX` | max exact |
| `u64::MAX` | 1 | 2 | `u64::MAX / 2` | **[new]** floor of odd/2; exercises non-trivial divisor |
| 2⁶³ | 2 | 2 | 2⁶³ | **[new]** intermediate = 2⁶⁴ > u64::MAX; final fits exactly (u64::MAX+1 would not) — guards the `res <= u64::MAX` check against off-by-one |

**[property]** Parametric row — encode the floor invariant as a predicate
over every `(a, b, c, result)` tuple above: assert
`result*c ≤ a*b < (result+1)*c`, computed in u128. For u64 inputs,
`(result+1)*c ≤ 2⁶⁴ · (2⁶⁴ − 1) < u128::MAX` — no overflow guard needed.
Encoded inline in the same parametric loop as the table; guards against
algorithm changes that reproduce the listed outputs by coincidence but
violate the floor contract on an unlisted input. Same role as the
`nth_root_u128` `[property]` row in §3.

Abort cases:

| `a` | `b` | `c` | abort | reason |
|-----|-----|-----|-------|--------|
| 1 | 1 | 0 | arithmetic | c = 0 |
| 0 | 0 | 0 | arithmetic | **[new]** c = 0 with zero multiplicands — assert that the `c = 0` check fires regardless of a/b |
| `u64::MAX` | 2 | 1 | `EMulDivOverflow` | result = 2·u64::MAX overflows |
| 2³² | 2³² | 1 | `EMulDivOverflow` | **[new]** result = 2⁶⁴ = u64::MAX + 1 — exact overflow boundary |
| `u64::MAX` | `u64::MAX` | 1 | `EMulDivOverflow` | **[new]** max intermediate ≈ 2¹²⁸ − 2⁶⁵ + 1 (fits u128), final = intermediate overflows u64 |


3. `nth_root_u128`
------------------

### Signature

    public(package) fun nth_root_u128(n: u128, d: u32): u128

### Semantics

    Returns floor(n^(1/d))

### Valid inputs

`d ∈ {2, 3, 4}` — required by the overflow analysis below (x_pow ≤ 2⁹⁶ at
d=4). Enforced at function entry:

    assert!(d >= 2 && d <= 4, ENthRootBadDegree)

The constraint is intrinsic to this algorithm, not inherited from
`curve_shape`. Without the assert, d ≥ 5 silently returns
`floor(n^(1/4))` because the d-dispatch in the loop body falls through
to the d=4 arm — a worse failure mode than abort.

### Algorithm

Newton-Raphson integer root:

    if n == 0: return 0
    if n == 1: return 1

    // Initial guess: bit-shift based on bit-length of n.
    // Sui Move u128 has no `leading_zeros()`; bit_length is a private helper
    // (see §3.1) returning floor(log2(n)) + 1 for n >= 1.
    let bits = bit_length(n);
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

Called by `curve_shape` for the PowerLaw variant (d ∈ {2, 3, 4}).


### 3.1 `bit_length` helper

    fun bit_length(x: u128): u32   // private

Returns `floor(log2(x)) + 1` for x ≥ 1. Implemented via a binary cascade
of right-shifts (O(log₂ 128) = 7 conditionals). Only called from
`nth_root_u128` after the `n == 0` and `n == 1` early returns, so the
x = 0 input is never exercised.


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
overflow analysis as §3). For the d=2, n=2¹²⁸−1, result=2⁶⁴−1 row, the
upper bound `(result+1)² = 2¹²⁸` overflows u128 and is treated as
trivially satisfied (test-only saturating check). This row executes
inside the same parametric loop as the table and guards against future
algorithm changes that reproduce the listed outputs by coincidence but
violate the floor contract on an unlisted input.

Largest perfect d-th powers fitting u128 (boundary cases not covered by
the table, which uses 2^k bases for d=3,4 and a non-power for d=2):

| `n`                       | `d` | result          | note |
|---------------------------|-----|-----------------|------|
| `(2⁶⁴ − 1)²`              | 2   | `2⁶⁴ − 1`       | **[new]** largest representable square; Newton must hit u64::MAX without `(k+1)²` fitting u128 |
| `(2⁶⁴ − 1)² − 1`          | 2   | `2⁶⁴ − 2`       | **[new]** floor neighbour below |
| `(2⁶⁴ − 1)² + 1`          | 2   | `2⁶⁴ − 1`       | **[new]** floor neighbour above (still ≤ u128::MAX) |
| `(2⁴²)³ = 2¹²⁶`           | 3   | `2⁴²`           | **[new]** largest d=3 cube near u128 ceiling |
| `(2⁴²)³ − 1`              | 3   | `2⁴² − 1`       | **[new]** floor neighbour below |
| `(2³¹)⁴ = 2¹²⁴`           | 4   | `2³¹`           | **[new]** largest d=4 4-th power tested |
| `(2³¹)⁴ − 1`              | 4   | `2³¹ − 1`       | **[new]** floor neighbour below |

**[new]** Non-power-of-2 roundtrip — for every `(k, d)` in the cross
product `k ∈ {7, 13, 100, 1000} × d ∈ {2, 3, 4}`, assert
`nth_root_u128(k^d, d) == k` and `nth_root_u128(k^d − 1, d) == k − 1`.
All `k^d` fit u128. Guards against Newton convergence bugs masked by
the 2^k alignment of the boundary rows above.

Abort cases:

| `n` | `d` | abort | reason |
|-----|-----|-------|--------|
| any | 0   | `ENthRootBadDegree` | d below {2, 3, 4} |
| any | 1   | `ENthRootBadDegree` | d below {2, 3, 4} |
| any | 5   | `ENthRootBadDegree` | d above {2, 3, 4} (silent-wrong path before the assert) |


4. TESTS — STRATEGY
-------------------

Per-function test vectors live inline in §2 and §3. This section declares
the conventions the test writer applies when translating those rows into
Move code. `math` is a pure-arithmetic module: no objects, no Sui framework
dependencies, no events, no clock, no scenario.

**Test module.** `#[test_only] module usufruct::math_tests`.
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
  math::E<NAME>)]` function each** (`EMulDivOverflow` for §2,
  `ENthRootBadDegree` for §3) — parametric loops stop at the first
  abort, so success and abort rows never share a loop. The built-in
  arithmetic abort for `c = 0` is asserted via
  `#[expected_failure(arithmetic_error, location = usufruct::math)]`.

**Fixtures.** None. Functions are pure u64/u128 → u64/u128, no `TxContext`.
Assertions use `use std::unit_test::assert_eq;` under `#[test_only]`.


### Open questions

(none currently)


5. MODULE BOUNDARY
------------------

`math.move` exports:

| Symbol | Visibility | Notes |
|--------|-----------|-------|
| `EMulDivOverflow:   u64 = 0` | module-private const¹ | Abort code for `mul_div` result overflow. |
| `ENthRootBadDegree: u64 = 1` | module-private const¹ | Abort code for `nth_root_u128` invalid degree. |
| `mul_div(a, b, c): u64` | `public(package)` | Used by `curve_shape` and internally. |
| `nth_root_u128(n, d): u128` | `public(package)` | Used by `curve_shape` (PowerLaw). |
| `bit_length(n): u32` | private | §3.1 — initial-guess helper for `nth_root_u128`. |

¹ Move `const` has no public visibility modifier. Constants are
module-internal but referenceable from `#[expected_failure(abort_code =
math::E<NAME>)]` test attributes (Move compiler convenience for tests).

**Functions are `public(package)`, not `public`.** `math` is an internal
utility for the `usufruct` package, not a standalone arithmetic library.
External callers have no business reaching past `curve_shape` /
`rental_escrow` to invoke these primitives. This matches the package-wide
policy of using `public(package)` whenever a spec marks a function
`public` in a pure-utility module with no external consumers.

**Depends on:** nothing.
