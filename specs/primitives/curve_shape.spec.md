CURVE_SHAPE MODULE — SPECIFICATION
====================================

Module: `curve_shape`
Design reference: design-compact.md §5
Module map reference: module-map.spec.md §2


0. MODULE RESPONSIBILITY
------------------------

`curve_shape` defines the `CurveShape` type and evaluates normalized shape
functions. It is pure math over a fixed-point representation — no protocol
concepts, no state, no scaling by principals.

**Owns:**

- `CurveShape` — enumerated functional forms for `f_credit_ascent` and
  `f_price_descent`. All dispatch on this type lives here.
- `evaluate_curve` — `public(package)` dispatcher. Single entry point for
  evaluating any `CurveShape` at a given (t, t_max) pair. Returns a value in
  [0, SCALE].
- `LOGISTIC_K: u64 = 12` and `LOGISTIC_DENOM: u64` — module-level constants.
  Both are hardcoded literals. Move `const` does not support function calls, so
  `LOGISTIC_DENOM` cannot be derived from `exp_scaled` at compile time — its value
  is established by running the algorithm once during initial implementation (same
  approach as the golden vectors in `math.spec.md`), then fixed as a literal.
- `exp_a_norm(alpha_abs, alpha_neg)` — 16-arm lookup table of algorithm-derived
  u128 literals for the Exponential variant (§7). Same pinning pattern as
  `LOGISTIC_DENOM`: each of the 16 values depends on `math::exp_scaled`, which
  Move `const` cannot invoke, so the values are produced once during initial
  implementation and fixed as match-arm literals.

**Does not own:**

- `PriceFunction` type or any next-rent-price logic — lives in `price_function`.
- Assembly of integration parameters — lives in `config::new`.
  (`config::new` calls constructors; it does not re-validate fields.)
- Protocol state (`RentalEscrow`, phase anchors).
- Fund movements (`Balance`, `Coin`).
- Access control (`OwnerCap`, `TenantCap`).
- Protocol-level scaling (mapping a normalized curve output to `last_rent_price`,
  `tenant_stake`, or a spread) — lives in `rental_escrow`. The protocol layer
  validates inputs (state, clamps, `elapsed_ms`) and applies the single
  `mul_div` that scales `evaluate_curve`'s output to a price or credit.
- Raw arithmetic primitives (`mul_div`, `nth_root_u128`, `exp_scaled`) — those
  live in `math`.

**Dependency direction:** `curve_shape` calls `math`. `config` and `rental_escrow`
call `curve_shape`. `curve_shape` calls nothing outside `math`.


1. PRECISION MODEL
------------------

All curve evaluations operate on a fixed-point representation with:

    SCALE:      u64  = 1_000_000_000                (10^9)
    SCALE_U128: u128 = SCALE as u128                 (10^9)
    SCALE_SQ:   u128 = SCALE_U128 * SCALE_U128       (10^18, fits u128 ✓)
    SCALE_CB:   u128 = SCALE_SQ   * SCALE_U128       (10^27, fits u128 ✓)

A curve output value `v` in [0, SCALE] represents the rational g(x) = v / SCALE.

The u128 variants are precomputed at module scope to avoid re-materializing
the cast / multiplication on every `eval_*` call. Used by `eval_smoothstep`
(§5), `eval_power_law` Step 2 (§6), `eval_exponential` (§7), and
`eval_logistic` (§8).

Intermediates use u128 to avoid overflow. Final results are cast back to u64.

Rounding: floor throughout (truncation), unless stated otherwise.


1.1 ERROR CONSTANTS
-------------------

All validation aborts originate in the constructors defined in §2.3.

    const E_ALPHA_NUM_RANGE:   u64 = 0;  // power_law: alpha_num ∉ [1, 8]
    const E_ALPHA_DEN_RANGE:   u64 = 1;  // power_law: alpha_den ∉ {1, 2, 3, 4}
    const E_DEGENERATE_LINEAR: u64 = 2;  // power_law: alpha_num == alpha_den (use Linear)
    const E_ALPHA_ABS_RANGE:   u64 = 3;  // exponential: alpha_abs ∉ [1, 8]


2. TYPE
-------

### CurveShape — enum

Defines the functional form of `f_credit_ascent` or `f_price_descent`.

```move
public enum CurveShape has copy, drop, store {
    Linear,
    Smoothstep,
    PowerLaw {
        alpha_num: u8,
        alpha_den: u8,
    },
    Exponential {
        alpha_abs: u8,
        alpha_neg: bool,
    },
    Logistic,
}
```

`Logistic` has no fields. `k = 12` and `denom` are module-level constants:

    const LOGISTIC_K: u64     = 12;
    const LOGISTIC_DENOM: u64 = /* algorithm-derived — establish during initial implementation */;

**Constraints (validated by constructors in §2.3):**

| Variant | Function | Field | Constraint |
|---------|----------|-------|------------|
| `Linear` | `g(x) = x` | — | N/A |
| `Smoothstep` | `g(x) = 3x² - 2x³` | — | N/A |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num` | `∈ [1, 8]` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_den` | `∈ {1, 2, 3, 4}` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num, alpha_den` | `alpha_num != alpha_den` (degenerate linear — use `Linear` instead) |
| `Exponential` | `g(x) = (e^(α·x) - 1) / (e^α - 1)` | `alpha_abs` | `∈ [1, 8]` |
| `Logistic` | `g(x) = (σ(12·(x−0.5)) − σ(−6)) / LOGISTIC_DENOM` | — | No fields. k=12 fixed. |


2.3 CONSTRUCTORS
----------------

Enum fields are private to `curve_shape.move`. All external callers must construct
`CurveShape` values through these functions.

`Linear`, `Smoothstep`, and `Logistic` have no fields — they are returned
directly without validation.

    public fun new_linear(): CurveShape
    // Returns CurveShape::Linear. No validation.

    public fun new_smoothstep(): CurveShape
    // Returns CurveShape::Smoothstep. No validation.

    public fun new_logistic(): CurveShape
    // Returns CurveShape::Logistic. No validation.

    public fun new_power_law(alpha_num: u8, alpha_den: u8): CurveShape
    // Validates:
    //   assert!(alpha_num >= 1 && alpha_num <= 8, E_ALPHA_NUM_RANGE)
    //   assert!(alpha_den >= 1 && alpha_den <= 4, E_ALPHA_DEN_RANGE)
    //   assert!(alpha_num != alpha_den,            E_DEGENERATE_LINEAR)
    // Normalizes: divides both by gcd(alpha_num, alpha_den) before storing.
    // Returns CurveShape::PowerLaw { alpha_num: reduced, alpha_den: reduced }.

    public fun new_exponential(alpha_abs: u8, alpha_neg: bool): CurveShape
    // Validates:
    //   assert!(alpha_abs >= 1 && alpha_abs <= 8, E_ALPHA_ABS_RANGE)
    // Returns CurveShape::Exponential { alpha_abs, alpha_neg }.


3. EVALUATE_CURVE
-----------------

### Signature

    public(package) fun evaluate_curve(shape: &CurveShape, t: u64, t_max: u64): u64

### Semantics

Evaluates the normalized shape function g at x = t / t_max.
Returns g(x) * SCALE, in [0, SCALE].

`t_max > 0` is guaranteed by `IntegrationConfig` constraints.
Called by `rental_escrow` (from `compute_used_credit` and
`compute_price_descent`) with protocol-level inputs already validated and
normalized at the escrow layer. This module does not validate state, phase
timing, or principals — it only evaluates the curve.

### Implementation

    public(package) fun evaluate_curve(shape: &CurveShape, t: u64, t_max: u64): u64 {
        if t == 0      { return 0 };
        if t >= t_max  { return SCALE };

        match shape {
            CurveShape::Linear                                => eval_linear(t, t_max),
            CurveShape::Smoothstep                            => eval_smoothstep(t, t_max),
            CurveShape::PowerLaw { alpha_num, alpha_den }     => eval_power_law(t, t_max, *alpha_num, *alpha_den),
            CurveShape::Exponential { alpha_abs, alpha_neg }  => eval_exponential(t, t_max, *alpha_abs, *alpha_neg),
            CurveShape::Logistic                              => eval_logistic(t, t_max),
        }
    }

Each `eval_*` function is private to `curve_shape.move` and defined in §4-§8 below.


4. LINEAR VARIANT
-----------------

    g(x) = x

### Signature

    fun eval_linear(t: u64, t_max: u64): u64

### Algorithm

    math::mul_div(t, SCALE, t_max)

Exact. No approximation.


5. SMOOTHSTEP VARIANT
---------------------

    g(x) = 3x² - 2x³

### Signature

    fun eval_smoothstep(t: u64, t_max: u64): u64

### Derivation in integers

Let `x = t * SCALE / t_max` (x in [0, SCALE]).

    g(x/SCALE) · SCALE = 3(x/SCALE)² - 2(x/SCALE)³
                      = x² * (3*SCALE - 2*x) / SCALE²

### Algorithm

    let x: u64 = math::mul_div(t, SCALE, t_max);    // x in [0, SCALE]
    let x128  = x as u128;
    let num   = x128 * x128 * (3 * SCALE_U128 - 2 * x128);
    (num / SCALE_SQ) as u64

### Overflow analysis

    x       ≤ 10^9
    x²      ≤ 10^18                         fits u128
    3S-2x   ≤ 3 * 10^9                      fits u128
    x²*(3S-2x) ≤ 3 * 10^27                  fits u128 (max ~3.4×10^38)  ✓
    S²      = 10^18                          fits u128  ✓

Exact. No approximation.

### Shape properties

Sigmoidal (S-shaped). Inflection at x = 0.5.
g''(x) > 0 for x < 0.5 (convex), g''(x) < 0 for x > 0.5 (concave).
Not a substitute for pure concavity or convexity — distinct incentive profile.


6. POWERLAW VARIANT
-------------------

    g(x) = x^(alpha_num / alpha_den)

    alpha_num: u8   — numerator of exponent,   ∈ [1, 8]
    alpha_den: u8   — denominator of exponent, ∈ {1, 2, 3, 4}

### Signature

    fun eval_power_law(t: u64, t_max: u64, alpha_num: u8, alpha_den: u8): u64

### Shape by alpha value

    alpha < 1  (e.g. 1/2, 2/3, 3/4)  →  purely concave
    alpha = 1                          →  linear (degenerate; use Linear instead)
    alpha > 1  (e.g. 2, 3, 3/2)       →  purely convex

### Normalization at construction time

    let g = gcd(alpha_num, alpha_den);
    alpha_num /= g;
    alpha_den /= g;

Reduces to lowest terms once at construction time (stored in variant).
Minimizes loop iterations in Step 1 and may eliminate Step 2 entirely
(e.g., 6/2 → 3/1: x^3 with no root vs x^6 + square root).
Guaranteed by `new_power_law()` constructor: stored alpha_num and alpha_den are always coprime.

### Algorithm

Let n = alpha_num, d = alpha_den.

Step 1 — compute x^n scaled:

    // x · SCALE is loop-invariant — compute once, reuse across iterations.
    let x_scaled: u64 = math::mul_div(t, SCALE, t_max);
    let mut acc:  u64 = x_scaled;
    for _ in 1..n {
        acc = math::mul_div(acc, x_scaled, SCALE);
    }
    // acc = x^n * SCALE

Step 2 — take d-th root scaled:

We want R such that (R / SCALE)^d = x^n.
Equivalently: R = floor( nth_root(acc * SCALE^(d-1), d) )

    let scale_pow: u128 = match d {
        1 => 1,
        2 => SCALE_U128,
        3 => SCALE_SQ,
        _ => SCALE_CB,  // d=4
    };
    let target: u128 = (acc as u128) * scale_pow;
    let R: u64 = math::nth_root_u128(target, d) as u64;

### Special case: d = 1

    g(x) = x^n   (integer exponent, no root needed)
    Step 2 is skipped. Return acc directly.

### Overflow analysis for Step 2

    acc      ≤ SCALE = 10^9
    SCALE^(d-1):
      d=1 → 1          no scale needed, result = acc directly
      d=2 → 10^9       acc * 10^9  ≤ 10^18   fits u128  ✓
      d=3 → 10^18      acc * 10^18 ≤ 10^27   fits u128  ✓
      d=4 → 10^27      acc * 10^27 ≤ 10^36   fits u128  ✓

Maximum u128 ≈ 3.4×10^38 — all cases within bounds. ✓
This is why alpha_den is restricted to {1, 2, 3, 4}.


7. EXPONENTIAL VARIANT
----------------------

    g(x) = (e^(α·x) - 1) / (e^α - 1)

    alpha_abs: u8   — magnitude of exponent, ∈ [1, 8]
    alpha_neg: bool — sign of α (Move has no native signed integers)

### Signature

    fun eval_exponential(t: u64, t_max: u64, alpha_abs: u8, alpha_neg: bool): u64

### Sign and shape

`alpha_neg` is not validated — any bool is accepted. It determines the sign of α
and therefore the curve shape:

    alpha_neg = false  →  α = +alpha_abs  →  convex  (slow start, fast finish)
    alpha_neg = true   →  α = −alpha_abs  →  concave (fast start, slow finish)

### Algorithm

    let a = alpha_abs as u64;   // ∈ [1, 8]

    // e^(α·x) · TS — varies per call (depends on t, t_max).
    let exp_ax = math::exp_scaled(a * t, t_max, alpha_neg);

    // |e^(α·x) · TS − TS| — magnitude of numerator.
    let num = if alpha_neg {
        TAYLOR_SCALE - exp_ax   // α < 0: exp_ax < TS
    } else {
        exp_ax - TAYLOR_SCALE   // α > 0: exp_ax > TS
    };

    // |e^α · TS − TS| — pinned algorithm-derived constant, module-level lookup.
    let den = exp_a_norm(alpha_abs, alpha_neg);

    (num * SCALE_U128 / den) as u64

`TAYLOR_SCALE` is defined in `math` — see math.spec.md §1.

### Precomputed `exp_a_norm` table

`|e^α · TS − TS|` depends only on `(alpha_abs, alpha_neg)` — both are fixed
at construction. The domain is finite: `alpha_abs ∈ [1, 8]`, `alpha_neg ∈
{true, false}` → 16 pairs total. Following the `LOGISTIC_DENOM` precedent
(§8), algorithm-derived values that Move `const` cannot compute are pinned
as literals at module scope instead of recomputed per call.

    fun exp_a_norm(alpha_abs: u8, alpha_neg: bool): u128 {
        match (alpha_abs, alpha_neg) {
            (1, false) => /* e^1·TS − TS, algorithm-derived literal */,
            (1, true)  => /* TS − e^−1·TS, algorithm-derived literal */,
            (2, false) => /* algorithm-derived literal */,
            (2, true)  => /* algorithm-derived literal */,
            (3, false) => /* algorithm-derived literal */,
            (3, true)  => /* algorithm-derived literal */,
            (4, false) => /* algorithm-derived literal */,
            (4, true)  => /* algorithm-derived literal */,
            (5, false) => /* algorithm-derived literal */,
            (5, true)  => /* algorithm-derived literal */,
            (6, false) => /* algorithm-derived literal */,
            (6, true)  => /* algorithm-derived literal */,
            (7, false) => /* algorithm-derived literal */,
            (7, true)  => /* algorithm-derived literal */,
            (8, false) => /* algorithm-derived literal */,
            (8, true)  => /* algorithm-derived literal */,
        }
    }

**Establishing values:** during initial implementation, for each of the 16
pairs run the following derivation and record the output as the match arm's
literal (same methodology as the golden vectors in `math.spec.md` §4 and
`LOGISTIC_DENOM` in §8):

    let a = alpha_abs as u64;
    let exp_a = math::exp_scaled(a, 1, alpha_neg);
    let norm  = if alpha_neg { TAYLOR_SCALE - exp_a } else { exp_a - TAYLOR_SCALE };
    // record `norm` as the `(alpha_abs, alpha_neg)` arm's literal

**Why module scope, not a variant field:** storing `exp_a_norm` as a
`CurveShape::Exponential` field would cost 16 bytes per escrow in
persistent Sui object storage (BCS does not pad to max-variant size, but
the field is paid once per `Exponential` instance). The module-level table
costs 16 literals once in bytecode, with O(1) lookup via match, and
preserves the variant posture that fields carry only definition inputs —
derived values live alongside `LOGISTIC_DENOM`.

**Eliminating the per-call Taylor series:** the original formulation called
`math::exp_scaled(a, 1, neg)` on every evaluation — up to 32 u128
multiplications and divisions per call. With the table, `eval_exponential`
runs exactly one Taylor series per call (`exp_ax`), halving the curve's
evaluation cost on the hot path walked by every lazy-price read.

### Constraints validated by constructor

    alpha_abs ∈ [1, 8]     (0 rejected: denominator would be zero)
    alpha_neg ∈ {true, false}   (not validated — any bool accepted)

alpha_abs = 0 is rejected because e^0 - 1 = 0 makes the denominator zero
(the limit at α → 0 is linear — use Linear variant instead).


8. LOGISTIC VARIANT
--------------------

    g(x) = (σ(12·(x − 0.5)) − σ(−6)) / LOGISTIC_DENOM

    where σ(y) = e^y / (e^y + 1)

No fields. `k = 12` and `LOGISTIC_DENOM` are module-level constants.
Produces a pronounced S-curve with inflection fixed at x = 0.5 — clearly
distinguishable from `Smoothstep` without being extreme.

### Signature

    fun eval_logistic(t: u64, t_max: u64): u64

### Module-level constants

    const LOGISTIC_K:           u64  = 12;
    const LOGISTIC_DENOM:       u64  = /* algorithm-derived — establish during initial implementation */;
    const LOGISTIC_SIGMA_FLOOR: u128 = (SCALE_U128 - (LOGISTIC_DENOM as u128)) / 2;   // σ(−6) · SCALE

Move `const` only admits literals and simple arithmetic — function calls are not
allowed. `LOGISTIC_DENOM` must be hardcoded as a literal whose value is produced by
running the following derivation once and recording the output (K=32, floor rounding):

    let TS: u128  = TAYLOR_SCALE;
    let ek6: u128 = math::exp_scaled(6, 1, false);   // e^6 · TS  (K=32)
    // (σ(6) − σ(−6)) · SCALE  =  (ek6 − TS) · SCALE / (ek6 + TS)
    LOGISTIC_DENOM = ((ek6 - TS) * SCALE_U128 / (ek6 + TS)) as u64;

`LOGISTIC_SIGMA_FLOOR` is derived from `LOGISTIC_DENOM` via cast + arithmetic
(admitted by Move `const`), so it evaluates at compile time once
`LOGISTIC_DENOM` has been pinned.

Mathematical reference: (σ(6) − σ(−6)) · SCALE ≈ 995_054_750. The exact
algorithm-derived value may differ by a few ULP due to floor rounding in
`exp_scaled` — use the algorithm output, not this approximation.

### Runtime algorithm

    let TS: u128 = TAYLOR_SCALE;

    // y = 12 · (x − 0.5) = 12 · (t − t_max/2) / t_max
    let two_t = 2 * t;
    let (y_num_abs, y_neg) = if two_t >= t_max {
        (LOGISTIC_K * (two_t - t_max), false)
    } else {
        (LOGISTIC_K * (t_max - two_t), true)
    };
    let y_den: u64 = 2 * t_max;

    let ey: u128 = math::exp_scaled(y_num_abs, y_den, y_neg);        // e^y · TS
    let sigma_y: u128 = ey * SCALE_U128 / (ey + TS);                  // σ(y) · SCALE

    ((sigma_y - LOGISTIC_SIGMA_FLOOR) * SCALE_U128 / LOGISTIC_DENOM as u128) as u64


### Overflow analysis

    ey          ≤ e^6 · TS ≈ 403 · 10^18 ≈ 4×10^20   fits u128 ✓
    ey · S      ≤ 4×10^20 · 10^9 = 4×10^29            fits u128 ✓
    (σ_y − σ_floor) · S  ≤ S · S = 10^18              fits u128 ✓

### No integration-time constraint

`Logistic` has no fields — nothing to validate at construction time.


9. MODULE BOUNDARY
-------------------

`curve_shape.move` exports:

| Symbol | Visibility | Notes |
|--------|-----------|-------|
| `E_ALPHA_NUM_RANGE: u64 = 0` | `public` | SDK error handling. |
| `E_ALPHA_DEN_RANGE: u64 = 1` | `public` | SDK error handling. |
| `E_DEGENERATE_LINEAR: u64 = 2` | `public` | SDK error handling. |
| `E_ALPHA_ABS_RANGE: u64 = 3` | `public` | SDK error handling. |
| `new_linear()` | `public` | Called by integrators to build `CurveShape`. |
| `new_smoothstep()` | `public` | Called by integrators to build `CurveShape`. |
| `new_logistic()` | `public` | Called by integrators to build `CurveShape`. |
| `new_power_law(alpha_num, alpha_den)` | `public` | Called by integrators. Validates + normalizes. |
| `new_exponential(alpha_abs, alpha_neg)` | `public` | Called by integrators. Validates. |
| `evaluate_curve(...)` | `public(package)` | Called by `rental_escrow`. Dispatcher — match on `CurveShape`. |
| `eval_linear(...)` | private | §4 |
| `eval_smoothstep(...)` | private | §5 |
| `eval_power_law(...)` | private | §6 |
| `eval_exponential(...)` | private | §7 |
| `exp_a_norm(alpha_abs, alpha_neg)` | private | §7 — 16-arm lookup, algorithm-derived literals |
| `eval_logistic(...)` | private | §8 |

`CurveShape` is defined in this module and embedded in `IntegrationConfig`
(via `config.move`).

**Integration flow:** constructors are `public` — callable directly from PTBs.
An integrator builds `CurveShape` values by calling these constructors, then
passes them to `config::new`, then to `rental_escrow::integrate`.
Error constants are `public` so the SDK can map abort codes to human-readable messages.

**Depends on:** `math` (for `mul_div`, `nth_root_u128`, `exp_scaled`).


10. TEST CASES
--------------

Tests follow the same convention as `math.spec.md`: exact values are given where
derivable from the algorithm by hand; algorithm-derived golden vectors are marked
and must be established by running the implementation once and fixing the output.

Three categories per function:
- **Edge cases** — boundary inputs with known exact output
- **Golden vectors** — specific input → exact output (hand-derived or algorithm-derived)
- **Properties** — invariants that must hold for all valid inputs in the stated domain


### 10.1 `evaluate_curve` — dispatcher edge cases

These apply regardless of the variant passed. Tested once per variant to confirm
the dispatcher short-circuits before reaching `eval_*`.

| `shape` | `t` | `t_max` | result |
|---------|-----|---------|--------|
| any | `0` | any `> 0` | `0` |
| any | `t_max` | `t_max` | `SCALE` |
| any | `t_max + 1` | `t_max` | `SCALE` |


### 10.2 `eval_linear`

#### Golden vectors

| `t` | `t_max` | result | note |
|-----|---------|--------|------|
| `1` | `4` | `250_000_000` | floor(SCALE/4) |
| `3` | `4` | `750_000_000` | floor(3·SCALE/4) |
| `1` | `3` | `333_333_333` | floor: 1/3 |
| `2` | `3` | `666_666_666` | floor: 2/3 |
| `1` | `1_000_000_000` | `1` | minimum nonzero output |

#### Properties

- **Exactness:** `eval_linear(t, t_max) = floor(t * SCALE / t_max)`
- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_linear(t1, t_max) ≤ eval_linear(t2, t_max)`
- **Midpoint:** `eval_linear(t_max/2, t_max) = SCALE/2` when `t_max` is even


### 10.3 `eval_smoothstep`

#### Golden vectors

| `t` | `t_max` | result | note |
|-----|---------|--------|------|
| `1_000_000_000` | `4_000_000_000` | `156_250_000` | x=0.25: g(0.25)=0.15625 |
| `2_000_000_000` | `4_000_000_000` | `500_000_000` | midpoint exact: g(0.5)=0.5 |
| `3_000_000_000` | `4_000_000_000` | `843_750_000` | x=0.75: g(0.75)=0.84375 |

#### Properties

- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_smoothstep(t1) ≤ eval_smoothstep(t2)`
- **Approximate symmetry (within 1-2 ULP):** `eval_smoothstep(t, t_max) + eval_smoothstep(t_max-t, t_max) ∈ [SCALE-2, SCALE]`
- **Exact midpoint:** `eval_smoothstep(t_max/2, t_max) = SCALE/2` when `t_max` even
- **Below linear:** `eval_smoothstep(t) < eval_linear(t)` for `t ∈ (0, t_max/2)`
- **Above linear:** `eval_smoothstep(t) > eval_linear(t)` for `t ∈ (t_max/2, t_max)`


### 10.4 `eval_power_law`

#### Golden vectors

Algorithm-derived — establish during initial implementation (same approach as
`exp_scaled` golden vectors in `math.spec.md`).

Representative inputs to cover:
- `alpha = 1/2` (d=2, concave): `t=1, t_max=4`
- `alpha = 2`   (d=1, convex):  `t=1, t_max=4`
- `alpha = 3/2` (d=2, convex):  `t=1, t_max=4`
- `alpha = 1/3` (d=3, concave): `t=1, t_max=8`
- `alpha = 1/4` (d=4, concave): `t=1, t_max=16`

#### Properties

- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_power_law(t1) ≤ eval_power_law(t2)`
- **Below linear** when `alpha > 1`:
  `eval_power_law(t, t_max, n, d) < eval_linear(t, t_max)` for `t ∈ (0, t_max)`
- **Above linear** when `alpha < 1`:
  `eval_power_law(t, t_max, n, d) > eval_linear(t, t_max)` for `t ∈ (0, t_max)`
- **Special case d=1:** no root step — result equals `acc` directly (Step 2 skipped)
- **Normalization:** `eval_power_law(t, t_max, 2, 4)` = `eval_power_law(t, t_max, 1, 2)`
  (constructor reduces 2/4 → 1/2 via gcd)


### 10.5 `eval_exponential`

#### Precomputed `exp_a_norm` table

The 16 literals of `exp_a_norm(alpha_abs, alpha_neg)` (§7) are also
algorithm-derived — establish all 16 during initial implementation using the
procedure documented in §7. They are not a separate test surface: correct
`exp_a_norm` literals are a precondition for the golden vectors below to
reproduce.

#### Golden vectors

Algorithm-derived — establish during initial implementation.

Representative inputs to cover:
- `alpha_abs=2, alpha_neg=false` (convex):  `t=1, t_max=4`
- `alpha_abs=2, alpha_neg=true`  (concave): `t=1, t_max=4`
- `alpha_abs=4, alpha_neg=false`:            `t=1, t_max=4`
- `alpha_abs=8, alpha_neg=false`:            `t=1, t_max=4` (upper bound)
- `alpha_abs=1, alpha_neg=true`:             `t=1, t_max=4` (minimum concave)

#### Properties

- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_exponential(t1) ≤ eval_exponential(t2)`
- **Below linear** when `alpha_neg=false`:
  `eval_exponential(t, t_max, a, false) < eval_linear(t, t_max)` for `t ∈ (0, t_max)`
- **Above linear** when `alpha_neg=true`:
  `eval_exponential(t, t_max, a, true) > eval_linear(t, t_max)` for `t ∈ (0, t_max)`
- **Complementarity** (mathematically exact, small rounding deviation from integer arithmetic):
  `eval_exponential(t, t_max, a, false) + eval_exponential(t_max-t, t_max, a, true) ≈ SCALE`
  Proof: `f_α(x) + f_{-α}(1-x) = 1` for all x (see §7). Maximum deviation: a few ULP.


### 10.6 `eval_logistic`

#### Golden vectors

Algorithm-derived — establish during initial implementation.

Representative inputs to cover:
- `t = t_max/4`: below linear
- `t = t_max/2`: exact midpoint = `SCALE/2`
- `t = 3*t_max/4`: above linear

#### Properties

- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_logistic(t1) ≤ eval_logistic(t2)`
- **Exact midpoint:** `eval_logistic(t_max/2, t_max) = SCALE/2`
- **Approximate symmetry:** `eval_logistic(t, t_max) + eval_logistic(t_max-t, t_max) ≈ SCALE`
  (deviation ≤ 2 ULP from accumulated rounding in `exp_scaled`)
- **Below linear:** `eval_logistic(t) < eval_linear(t)` for `t ∈ (0, t_max/2)`
- **Above linear:** `eval_logistic(t) > eval_linear(t)` for `t ∈ (t_max/2, t_max)`


