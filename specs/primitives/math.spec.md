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

- `CurveShape`, `PriceFunction` — live in `curve`.
- `evaluate_curve`, `compute_used_credit`, `compute_price_descent`,
  `compute_next_rent_price` — live in `curve`.
- Integration-time validation — lives in `curve` constructors (`config::new` assembles, does not re-validate).
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

Abort cases:

| `a` | `b` | `c` | abort | reason |
|-----|-----|-----|-------|--------|
| 1 | 1 | 0 | arithmetic | c = 0 |
| `u64::MAX` | 2 | 1 | `E_MUL_DIV_OVERFLOW` | result = 2·u64::MAX overflows |


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

    loop:
        // dispatch on d — .pow() does not exist in Move
        let x_pow: u128 = match d {
            2 => x,
            3 => x * x,
            _ => x * x * x,   // d=4
        };
        let x_new = ((d as u128 - 1) * x + n / x_pow) / (d as u128);
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
| 4 | 2 | 2 | perfect square |
| 9 | 2 | 3 | perfect square |
| 10 | 2 | 3 | floor: √10 ≈ 3.162 |
| 15 | 2 | 3 | floor: √15 ≈ 3.873 |
| 16 | 2 | 4 | perfect square |
| 0 | 3 | 0 | n = 0 special case |
| 1 | 3 | 1 | n = 1 special case |
| 8 | 3 | 2 | perfect cube |
| 26 | 3 | 2 | floor: ∛26 ≈ 2.962 |
| 27 | 3 | 3 | perfect cube |
| 0 | 4 | 0 | n = 0 special case |
| 1 | 4 | 1 | n = 1 special case |
| 16 | 4 | 2 | perfect 4th power |
| 80 | 4 | 2 | floor: ⁴√80 ≈ 2.990 |
| 81 | 4 | 3 | perfect 4th power |
| 2¹²⁸ − 1 | 2 | 2⁶⁴ − 1 | max u128; (2⁶⁴−1)² ≤ 2¹²⁸−1 < (2⁶⁴)² |
| 2⁹⁶ | 3 | 2³² | exact cube: (2³²)³ = 2⁹⁶ — tests d=3 convergence for large n |
| 2⁹⁶ − 1 | 3 | 2³² − 1 | floor near boundary: (2³²)³ > 2⁹⁶−1 ≥ (2³²−1)³ |
| 2⁹⁶ | 4 | 2²⁴ | exact 4th power: (2²⁴)⁴ = 2⁹⁶ — tests d=4 convergence for large n |

Invariant (for all valid inputs): `result^d ≤ n < (result + 1)^d`.


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

    acc: u128 = TAYLOR_SCALE   // term_0 = 1 * TS
    term: u128 = TAYLOR_SCALE  // running term

    for k in 1..=K:
        term = term * (y_num as u128) / (k as u128 * y_den as u128)
        acc  = acc + term
        if term == 0: break    // early exit

    return acc

Note: divisor `k * y_den` computed in u128 to avoid u64 overflow for large y_den.

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

| `y_num` | `y_den` | `neg` | expected result |
|---------|---------|-------|-----------------|
| 1 | 1 | false | 2_718_281_828_459_045_226 |
| 1 | 1 | true  | 367_879_441_171_442_322  |

Reference: true floor(e¹ · TS) = 2_718_281_828_459_045_235 (delta = 9 ULP —
within the < 10⁻⁹ relative error budget). The `neg=true` result of 322 exceeds
the mathematical floor (321) by 1 ULP — the expected upper-bound rounding from
the reciprocal identity.

For y ∈ {2, 4, 8} and fractional y, establish during initial implementation
using the same trace method.

#### Properties

These hold for all valid inputs and can be tested without knowing exact values:

1. **Monotone (pos):** for rational 0 < y₁ < y₂ ≤ 8,
   `exp_scaled(y1_num, y1_den, false) < exp_scaled(y2_num, y2_den, false)`

2. **Reciprocal identity (within 1 ULP):** for any y > 0,
   `exp_scaled(y, neg=false) × exp_scaled(y, neg=true)` ∈ `[TS² − TS, TS²]`

3. **Precision bound:** for all y = y_num/y_den with 0 < y ≤ 8,
   `|result − floor(eʸ · TS)| ≤ floor(eʸ · TS) × 10⁻⁹`

#### Input validity note

No abort is defined for out-of-range y. The overflow analysis (§4) guarantees
correctness only for `y_num/y_den ≤ 8` with `tenure_ceiling ≤ 10¹³ ms`. Inputs
outside this range are the caller's responsibility (`curve` enforces them at
integration time via `alpha_abs ∈ [1, 8]`).


5. MODULE BOUNDARY
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
