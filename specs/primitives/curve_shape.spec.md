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
- `TAYLOR_SCALE: u128 = 10^18` and `TAYLOR_SCALE_SQ: u128 = 10^36` — precision
  constants for the Taylor series kernel. Defined here because `exp_scaled` and
  `exp_scaled_pos` have no caller outside this module.
- `exp_scaled` / `exp_scaled_pos` — scaled exponential via Taylor series (K=32).
  Private helpers used by `eval_exponential` (§8) and `eval_logistic` (§9).
- `LOGISTIC_K: u64 = 12` and `LOGISTIC_DENOM: u64` — module-level constants.
  Both are hardcoded literals. Move `const` does not support function calls, so
  `LOGISTIC_DENOM` cannot be derived from `exp_scaled` at compile time — its value
  is established by running the algorithm once during initial implementation (same
  approach as the `EXP_A_NORM_*` constants below), then fixed as a literal.
- `EXP_A_NORM_{1..8}_{POS,NEG}` — 16 module-level `const` declarations of
  algorithm-derived u128 values for the Exponential variant (§8). Same pinning
  pattern as `LOGISTIC_DENOM`: each depends on `exp_scaled_pos` (§7), which Move
  `const` cannot invoke, so the values are produced once during initial
  implementation and fixed as named module-level literals. The private
  `exp_a_norm(alpha_abs, alpha_neg)` function is a pure dispatcher over these
  16 constants.

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
- Raw arithmetic primitives (`mul_div`, `nth_root_u128`) — those live in `math`.

**Dependency direction:** `curve_shape` calls `math`. `config` and `rental_escrow`
call `curve_shape`. `curve_shape` calls nothing outside `math`.


1. PRECISION MODEL
------------------

All curve evaluations operate on a fixed-point representation with:

    TAYLOR_SCALE:    u128 = 1_000_000_000_000_000_000  (10^18)
    TAYLOR_SCALE_SQ: u128 = TAYLOR_SCALE * TAYLOR_SCALE   (10^36, fits u128 ✓)

    SCALE:      u64  = 1_000_000_000                (10^9)
    SCALE_U128: u128 = SCALE as u128                 (10^9)
    SCALE_SQ:   u128 = SCALE_U128 * SCALE_U128       (10^18, fits u128 ✓)
    SCALE_CB:   u128 = SCALE_SQ   * SCALE_U128       (10^27, fits u128 ✓)

`TAYLOR_SCALE` and `TAYLOR_SCALE_SQ` are internal to the Taylor series kernel
(§7) and used by `eval_exponential` (§8) and `eval_logistic` (§9) to interpret
results.

A curve output value `v` in [0, SCALE] represents the rational g(x) = v / SCALE.

The u128 variants are precomputed at module scope to avoid re-materializing
the cast / multiplication on every `eval_*` call. Used by `eval_smoothstep`
(§5), `eval_power_law` Step 2 (§6), `eval_exponential` (§8), and
`eval_logistic` (§9).

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

Each `eval_*` function is private to `curve_shape.move` and defined in §4-§9 below.


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


7. TAYLOR SERIES KERNEL
-----------------------

`exp_scaled` and `exp_scaled_pos` implement the scaled exponential via Taylor
series. They live in `curve_shape` because `TAYLOR_SCALE` / `TAYLOR_SCALE_SQ`
are defined here and they have no caller outside this module. Both functions
are private — `eval_exponential` (§8) and `eval_logistic` (§9) are the only
consumers.

### Signatures

    fun exp_scaled(y_num: u64, y_den: u64, neg: bool): u128      // private
    fun exp_scaled_pos(y_num: u64, y_den: u64): u128             // private

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

Called by `eval_exponential` (§8) and `eval_logistic` (§9) within this module.


8. EXPONENTIAL VARIANT
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
    let exp_ax = exp_scaled(a * t, t_max, alpha_neg);

    // |e^(α·x) · TS − TS| — magnitude of numerator.
    let num = if alpha_neg {
        TAYLOR_SCALE - exp_ax   // α < 0: exp_ax < TS
    } else {
        exp_ax - TAYLOR_SCALE   // α > 0: exp_ax > TS
    };

    // |e^α · TS − TS| — pinned algorithm-derived constant, module-level lookup.
    let den = exp_a_norm(alpha_abs, alpha_neg);

    (num * SCALE_U128 / den) as u64

`TAYLOR_SCALE` is defined in this module (§1).

### Module-level constants

`|e^α · TS − TS|` depends only on `(alpha_abs, alpha_neg)` — both are fixed
at construction. The domain is finite: `alpha_abs ∈ [1, 8]`, `alpha_neg ∈
{true, false}` → 16 pairs total. Following the `LOGISTIC_DENOM` precedent
(§9), algorithm-derived values that Move `const` cannot compute are pinned
as named `const` declarations at module scope instead of recomputed per call.

Naming convention: `EXP_A_NORM_{alpha_abs}_{POS|NEG}`, where `POS` corresponds
to `alpha_neg = false` (α > 0) and `NEG` to `alpha_neg = true` (α < 0).

    // α > 0  (alpha_neg = false)  →  convex
    const EXP_A_NORM_1_POS: u128 =     1_718_281_828_459_045_226;  // e¹·TS − TS
    const EXP_A_NORM_2_POS: u128 =     6_389_056_098_930_650_216;  // e²·TS − TS
    const EXP_A_NORM_3_POS: u128 =    19_085_536_923_187_667_729;
    const EXP_A_NORM_4_POS: u128 =    53_598_150_033_144_239_050;
    const EXP_A_NORM_5_POS: u128 =   147_413_159_102_576_587_697;
    const EXP_A_NORM_6_POS: u128 =   402_428_793_492_728_453_424;
    const EXP_A_NORM_7_POS: u128 = 1_095_633_158_427_339_529_377;
    const EXP_A_NORM_8_POS: u128 = 2_979_957_986_946_523_322_343;

    // α < 0  (alpha_neg = true)   →  concave
    const EXP_A_NORM_1_NEG: u128 = 632_120_558_828_557_678;  // TS − e⁻¹·TS
    const EXP_A_NORM_2_NEG: u128 = 864_664_716_763_387_308;  // TS − e⁻²·TS
    const EXP_A_NORM_3_NEG: u128 = 950_212_931_632_136_057;
    const EXP_A_NORM_4_NEG: u128 = 981_684_361_111_265_820;
    const EXP_A_NORM_5_NEG: u128 = 993_262_053_000_914_533;
    const EXP_A_NORM_6_NEG: u128 = 997_521_247_823_333_601;
    const EXP_A_NORM_7_NEG: u128 = 999_088_118_034_444_554;
    const EXP_A_NORM_8_NEG: u128 = 999_664_537_372_086_775;

Move `const` cannot invoke `exp_scaled_pos`, so each literal is produced by
running the following derivation once per `(alpha_abs, alpha_neg)` pair and
recording the output (same methodology as `LOGISTIC_DENOM` in §9 and the
golden vectors in §11.5):

    let a = alpha_abs as u64;
    let exp_a = exp_scaled(a, 1, alpha_neg);
    let norm  = if alpha_neg { TAYLOR_SCALE - exp_a } else { exp_a - TAYLOR_SCALE };
    // record `norm` as the literal for EXP_A_NORM_{alpha_abs}_{POS|NEG}

### Lookup dispatcher

`exp_a_norm` reduces to a pure dispatcher over the 16 constants above:

    fun exp_a_norm(alpha_abs: u8, alpha_neg: bool): u128 {
        match (alpha_abs, alpha_neg) {
            // α > 0 (convex)
            (1, false) => EXP_A_NORM_1_POS,
            (2, false) => EXP_A_NORM_2_POS,
            (3, false) => EXP_A_NORM_3_POS,
            (4, false) => EXP_A_NORM_4_POS,
            (5, false) => EXP_A_NORM_5_POS,
            (6, false) => EXP_A_NORM_6_POS,
            (7, false) => EXP_A_NORM_7_POS,
            (8, false) => EXP_A_NORM_8_POS,
            // α < 0 (concave)
            (1, true)  => EXP_A_NORM_1_NEG,
            (2, true)  => EXP_A_NORM_2_NEG,
            (3, true)  => EXP_A_NORM_3_NEG,
            (4, true)  => EXP_A_NORM_4_NEG,
            (5, true)  => EXP_A_NORM_5_NEG,
            (6, true)  => EXP_A_NORM_6_NEG,
            (7, true)  => EXP_A_NORM_7_NEG,
            (8, true)  => EXP_A_NORM_8_NEG,
        }
    }

**Why module scope, not a variant field:** storing `exp_a_norm` as a
`CurveShape::Exponential` field would cost 16 bytes per escrow in
persistent Sui object storage. The 16 module-level constants cost 16
literals once in bytecode, with O(1) lookup via match, and preserve the
variant posture that fields carry only definition inputs — derived values
live alongside `LOGISTIC_DENOM` and `LOGISTIC_SIGMA_FLOOR`.

**Eliminating the per-call Taylor series:** the original formulation called
`exp_scaled(a, 1, neg)` on every evaluation — up to 32 u128
multiplications and divisions per call. With the table, `eval_exponential`
runs exactly one Taylor series per call (`exp_ax`), halving the curve's
evaluation cost on the hot path walked by every lazy-price read.

### Constraints validated by constructor

    alpha_abs ∈ [1, 8]     (0 rejected: denominator would be zero)
    alpha_neg ∈ {true, false}   (not validated — any bool accepted)

alpha_abs = 0 is rejected because e^0 - 1 = 0 makes the denominator zero
(the limit at α → 0 is linear — use Linear variant instead).


9. LOGISTIC VARIANT
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
    const LOGISTIC_DENOM:       u64  = 995_054_753;
    const LOGISTIC_SIGMA_FLOOR: u128 = (SCALE_U128 - (LOGISTIC_DENOM as u128)) / 2;   // σ(−6) · SCALE

Move `const` only admits literals and simple arithmetic — function calls are not
allowed. `LOGISTIC_DENOM` must be hardcoded as a literal whose value is produced by
running the following derivation once and recording the output (K=32, floor rounding):

    let TS: u128  = TAYLOR_SCALE;
    let ek6: u128 = exp_scaled_pos(6, 1);   // e^6 · TS  (K=32)
    // (σ(6) − σ(−6)) · SCALE  =  (ek6 − TS) · SCALE / (ek6 + TS)
    LOGISTIC_DENOM = ((ek6 - TS) * SCALE_U128 / (ek6 + TS)) as u64;

`LOGISTIC_SIGMA_FLOOR` is derived from `LOGISTIC_DENOM` via cast + arithmetic
(admitted by Move `const`), so it evaluates at compile time once
`LOGISTIC_DENOM` has been pinned.

Mathematical reference: (σ(6) − σ(−6)) · SCALE ≈ 995_054_750. The pinned
algorithm-derived value is `995_054_753` (+3 ULP from floor rounding in
`exp_scaled`). Treat the literal above as authoritative; the reference is
only for sanity checks.

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

    let ey: u128 = exp_scaled(y_num_abs, y_den, y_neg);        // e^y · TS
    let sigma_y: u128 = ey * SCALE_U128 / (ey + TS);           // σ(y) · SCALE

    ((sigma_y - LOGISTIC_SIGMA_FLOOR) * SCALE_U128 / LOGISTIC_DENOM as u128) as u64


### Overflow analysis

    ey          ≤ e^6 · TS ≈ 403 · 10^18 ≈ 4×10^20   fits u128 ✓
    ey · S      ≤ 4×10^20 · 10^9 = 4×10^29            fits u128 ✓
    (σ_y − σ_floor) · S  ≤ S · S = 10^18              fits u128 ✓

### No integration-time constraint

`Logistic` has no fields — nothing to validate at construction time.


10. MODULE BOUNDARY
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
| `exp_scaled(y_num, y_den, neg)` | private | §7 — Taylor kernel with sign dispatch |
| `exp_scaled_pos(y_num, y_den)` | private | §7 — Taylor series for positive exponent |
| `eval_exponential(...)` | private | §8 |
| `exp_a_norm(alpha_abs, alpha_neg)` | private | §8 — dispatcher over the 16 `EXP_A_NORM_*` module constants |
| `eval_logistic(...)` | private | §9 |

`CurveShape` is defined in this module and embedded in `IntegrationConfig`
(via `config.move`).

**Integration flow:** constructors are `public` — callable directly from PTBs.
An integrator builds `CurveShape` values by calling these constructors, then
passes them to `config::new`, then to `rental_escrow::integrate`.
Error constants are `public` so the SDK can map abort codes to human-readable messages.

**Depends on:** `math` (for `mul_div`, `nth_root_u128`).


11. TEST CASES
--------------

Tests follow the convention in §11.0: exact values are given where derivable
from the algorithm by hand; algorithm-derived golden vectors are marked
`TBD (algorithm-derived)` and must be established by running the implementation
once and pasting the output back into this spec.

Three categories per function:
- **Edge cases** — boundary inputs with known exact output
- **Golden vectors** — specific input → exact output (hand-derived or algorithm-derived)
- **Properties** — invariants that must hold for all valid inputs in the stated domain


### 11.0 Test strategy

**Test module.** `#[test_only] module usufruct::curve_shape_tests`.
Function names describe the asserted behaviour (e.g.
`eval_linear_floor_third`, `new_power_law_rejects_alpha_num_zero`).

**Idioms.**

- Constructor success rows and `eval_*` golden-vector rows translate as
  **one parametric loop** per function over a `vector<Case>`.
- Constructor abort rows translate as **one
  `#[test, expected_failure(abort_code = curve_shape::E_<NAME>)]` function
  each** — never mixed with success rows in one loop.
- Dispatcher `evaluate_curve` edge rows in §11.1 run **once per variant**
  (Linear, Smoothstep, Logistic, plus one PowerLaw and one Exponential
  seed). The short-circuit (`t == 0`, `t >= t_max`) fires before reaching
  `eval_*`, so the variant identity does not change the result — the loop
  asserts this explicitly.

**Fixtures.** None beyond `tx_context::dummy()` where constructors take no
ctx (they don't — all `new_*` are pure). Assertions use
`use std::unit_test::assert_eq;` under `#[test_only]`.

**Private-symbol access.** The `#[test_only]` wrappers declared alongside
the private helpers expose:

```
#[test_only] public fun eval_linear_for_testing(t: u64, t_max: u64): u64
#[test_only] public fun eval_smoothstep_for_testing(t: u64, t_max: u64): u64
#[test_only] public fun eval_power_law_for_testing(
    t: u64, t_max: u64, alpha_num: u8, alpha_den: u8): u64
#[test_only] public fun exp_scaled_for_testing(y_num: u64, y_den: u64, neg: bool): u128
#[test_only] public fun exp_scaled_pos_for_testing(y_num: u64, y_den: u64): u128
#[test_only] public fun taylor_scale_for_testing(): u128
#[test_only] public fun taylor_scale_sq_for_testing(): u128
#[test_only] public fun eval_exponential_for_testing(
    t: u64, t_max: u64, alpha_abs: u8, alpha_neg: bool): u64
#[test_only] public fun eval_logistic_for_testing(t: u64, t_max: u64): u64
#[test_only] public fun exp_a_norm_for_testing(alpha_abs: u8, alpha_neg: bool): u128
#[test_only] public fun logistic_sigma_floor_for_testing(): u128
#[test_only] public fun logistic_denom_for_testing(): u64
```

These route through the same private functions `evaluate_curve` dispatches
to, so a test against `eval_power_law_for_testing(t, t_max, 2, 1)` and a
test against `evaluate_curve(&new_power_law(2, 1), t, t_max)` with
`t ∈ (0, t_max)` must produce the same value (asserted by property P-D1
below).

**Golden-vector convention.** Rows marked `TBD (algorithm-derived)` hold
values produced by running the spec algorithm once at K=32 with floor
rounding, then committing the literal. Constructor tests for `new_exponential`
do not include the cached value (`exp_a_norm` lives at module scope, not in
the variant field) — see §11.6 for the `exp_a_norm_for_testing` lookup tests.

**Constructor-destructure convention.** For `new_power_law` success rows,
tests read the stored `(alpha_num, alpha_den)` via a `#[test_only]`
destructure helper `power_law_fields_for_testing(shape: &CurveShape):
(u8, u8)` that matches on `CurveShape::PowerLaw` (aborts on other
variants). The helper is the only way to verify gcd normalization
post-construction without leaking enum fields publicly.


### 11.0.1 Constructor success

| `new_*` call | stored variant | note |
|---|---|---|
| **[new]** `new_linear()` | `Linear` | no fields |
| **[new]** `new_smoothstep()` | `Smoothstep` | no fields |
| **[new]** `new_logistic()` | `Logistic` | no fields |
| **[new]** `new_power_law(2, 1)` | `PowerLaw { 2, 1 }` | already coprime; no reduction |
| **[new]** `new_power_law(1, 2)` | `PowerLaw { 1, 2 }` | already coprime |
| **[new]** `new_power_law(6, 4)` | `PowerLaw { 3, 2 }` | gcd=2 reduction |
| **[new]** `new_power_law(6, 3)` | `PowerLaw { 2, 1 }` | gcd=3 reduction to d=1 |
| **[new]** `new_power_law(8, 4)` | `PowerLaw { 2, 1 }` | gcd=4 reduction; boundary `alpha_num=8` |
| **[new]** `new_power_law(1, 3)` | `PowerLaw { 1, 3 }` | smallest d=3 variant |
| **[new]** `new_power_law(1, 4)` | `PowerLaw { 1, 4 }` | smallest d=4 variant; boundary `alpha_den=4` |
| **[new]** `new_exponential(1, false)` | `Exponential { 1, false }` | lower bound `alpha_abs=1`, convex |
| **[new]** `new_exponential(8, true)` | `Exponential { 8, true }` | upper bound `alpha_abs=8`, concave |

**Property [new] [property] — coprimality:** for every success row of
`new_power_law`, `gcd(stored.alpha_num, stored.alpha_den) == 1`. Encoded
as a predicate over the parametric loop using a Euclid-gcd test helper.


### 11.0.2 Constructor abort

Each row below translates to one dedicated
`#[test, expected_failure(abort_code = curve_shape::E_<NAME>)]` function.

| Call | Abort code | Reason |
|---|---|---|
| **[new]** `new_power_law(0, 2)` | `E_ALPHA_NUM_RANGE` | `alpha_num = 0` below `[1, 8]` |
| **[new]** `new_power_law(9, 2)` | `E_ALPHA_NUM_RANGE` | `alpha_num = 9` above `[1, 8]` |
| **[new]** `new_power_law(3, 0)` | `E_ALPHA_DEN_RANGE` | `alpha_den = 0` below `{1..4}` |
| **[new]** `new_power_law(3, 5)` | `E_ALPHA_DEN_RANGE` | `alpha_den = 5` above `{1..4}` |
| **[new]** `new_power_law(2, 2)` | `E_DEGENERATE_LINEAR` | `alpha_num == alpha_den` at raw input |
| **[new]** `new_power_law(4, 4)` | `E_DEGENERATE_LINEAR` | `alpha_num == alpha_den` at raw input (pre-gcd check fires) |
| **[new]** `new_exponential(0, false)` | `E_ALPHA_ABS_RANGE` | `alpha_abs = 0` below `[1, 8]` |
| **[new]** `new_exponential(9, true)` | `E_ALPHA_ABS_RANGE` | `alpha_abs = 9` above `[1, 8]` |

**Abort-check order note:** `new_power_law(0, 0)` aborts with
`E_ALPHA_NUM_RANGE` because the `alpha_num` assert runs first; this is
only interesting if the implementation reorders the asserts. Flag in Open
questions, not a test row.


### 11.1 `evaluate_curve` — dispatcher edge cases

These apply regardless of the variant passed. The parametric loop runs the
full cross-product of (variant seed × edge row), i.e. **each row below is
executed once per variant seed**. Variant seeds: `Linear`, `Smoothstep`,
`Logistic`, `PowerLaw(2, 1)`, `Exponential(2, false)`.

| `shape` | `t` | `t_max` | result | note |
|---------|-----|---------|--------|------|
| any seed | `0` | `1_000_000_000` | `0` | short-circuit on `t == 0` before `eval_*` |
| any seed | `0` | `1` | `0` | **[new]** `t_max = 1` boundary — smallest non-zero denominator |
| any seed | `1` | `1` | `SCALE` | **[new]** `t == t_max` at smallest denominator |
| any seed | `t_max` | `t_max` | `SCALE` | short-circuit on `t >= t_max` before `eval_*` |
| any seed | `t_max + 1` | `t_max` | `SCALE` | short-circuit on `t >= t_max` — clamped |
| any seed | `u64::MAX` | `1_000_000_000` | `SCALE` | **[new]** saturated `t` — confirms clamp to `SCALE` on extreme overshoots |

**[new] [property] P-D1 — dispatch equivalence.** For every variant seed
above and every interior `t ∈ (0, t_max)` in the seed set
`[(1, 4), (1, 3), (3, 4), (1_000_000_000, 4_000_000_000)]`, assert
`evaluate_curve(&shape, t, t_max)` equals the corresponding
`eval_<variant>_for_testing(t, t_max [, fields…])`. Guards against
dispatcher drift (wrong arm, wrong field forwarding) that would not
surface in any single-variant row.


### 11.2 `eval_linear`

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


### 11.3 `eval_smoothstep`

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


### 11.4 `eval_power_law`

#### Golden vectors — exact (hand-derivable)

`d = 1` rows skip Step 2 (the root step). Exact, no algorithm-derived
placeholder required.

| `t` | `t_max` | `alpha_num` | `alpha_den` | result | note |
|-----|---------|-------------|-------------|--------|------|
| **[new]** `1_000_000_000` | `2_000_000_000` | `2` | `1` | `250_000_000` | g(0.5) = 0.25 exact — d=1 arm, no `nth_root` |
| **[new]** `1_000_000_000` | `2_000_000_000` | `3` | `1` | `125_000_000` | g(0.5) = 0.125 exact — d=1 arm |
| **[new]** `2` | `4` | `2` | `1` | `250_000_000` | small-t path; same result, different scaling |
| **[new]** `3` | `4` | `2` | `1` | `562_500_000` | g(0.75) = 0.5625 exact |
| **[new]** `4_000_000_000` | `4_000_000_000` | `8` | `1` | `SCALE` | `t == t_max` short-circuit, confirms dispatcher clamp applies for `d=1` too |

#### Golden vectors — algorithm-derived (root step involved)

Roots introduce `math::nth_root_u128` floor rounding; values established by
emitting `eval_power_law_for_testing(...)` outputs via `std::debug::print` in
a one-shot `#[test]`, then pinning the captured literals here and in the
`eval_power_law_root_golden_vectors` regression check (same procedure as
§11.5).

Four of the five inputs land on perfect d-th powers, so `nth_root_u128`
returns an exact integer and the algorithm output equals the mathematical
reference; the (3, 4, 1, 2) row exercises floor rounding on the irrational
`√0.75`.

| `t` | `t_max` | `alpha_num` | `alpha_den` | result | note |
|-----|---------|-------------|-------------|--------|------|
| **[new]** `1`  | `4`  | `1` | `2` | `500_000_000` | α = 1/2 concave; √0.25 · SCALE = 5·10⁸ exactly |
| **[new]** `1`  | `4`  | `3` | `2` | `125_000_000` | α = 3/2 convex; 0.25^1.5 · SCALE = 1.25·10⁸ exactly |
| **[new]** `1`  | `8`  | `1` | `3` | `500_000_000` | α = 1/3 concave; d=3 path; ∛(1/8) · SCALE = 5·10⁸ exactly |
| **[new]** `1`  | `16` | `1` | `4` | `500_000_000` | α = 1/4 concave; d=4 path (`SCALE_CB` branch); (1/16)^(1/4) · SCALE = 5·10⁸ exactly |
| **[new]** `3`  | `4`  | `1` | `2` | `866_025_403` | α = 1/2 at `t = 0.75·t_max`; floor(√0.75 · SCALE), √0.75 ≈ 0.866025403784… |

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


### 11.5 `exp_scaled` / `exp_scaled_pos`

Tests for the Taylor series kernel (§7). These exercise `exp_scaled` and the
private `exp_scaled_pos` directly, outside the context of any curve evaluation.

**Test wrappers.** `exp_scaled` and `exp_scaled_pos` are private. Access via
`exp_scaled_for_testing` and `exp_scaled_pos_for_testing` declared in
`curve_shape.move` (see §11.0 Private-symbol access). `TAYLOR_SCALE` is
accessed via `taylor_scale_for_testing()` or the literal
`1_000_000_000_000_000_000`.

#### Exact case (y = 0)

The Taylor series exits after k=1 (term becomes 0). Result is exact
regardless of `neg`.

| `y_num` | `y_den` | `neg` | result |
|---------|---------|-------|--------|
| 0 | 1 | false | `TAYLOR_SCALE` |
| 0 | 1 | true | `TAYLOR_SCALE` |
| 0 | 7 | false | `TAYLOR_SCALE` |

#### Algorithm-derived golden vectors

These values are produced by the §7 algorithm (K = 32 terms, floor rounding
at every step). They are not the mathematical floor of eʸ · TS — they are
what the specific integer-arithmetic algorithm produces.

**How to establish:** emit each output via `std::debug::print(&actual)` from
a one-shot `#[test]` function, capture the printed literals, paste them back
as the `expected` column here and as `assert_eq!` constants in the test
file. The same single run pins `EXP_A_NORM_*` (§8) and `LOGISTIC_DENOM`
(§9). The regression check (`bootstrap_constants_match_pinned`) then guards
the values forever — any future §7 change that perturbs outputs flags here.

| `y_num` | `y_den` | `neg` | expected result | note |
|---------|---------|-------|-----------------|------|
| 1 | 1 | false | 2_718_281_828_459_045_226     | **[algorithm-derived]** reference true floor(e¹ · TS) = ..._235 (delta = 9 ULP, within < 10⁻⁹ budget) |
| 1 | 1 | true  | 367_879_441_171_442_322       | **[algorithm-derived]** mathematical floor is 321; +1 ULP from reciprocal-identity rounding |
| 1 | 2 | false | 1_648_721_270_700_128_139     | **[algorithm-derived]** fractional y = 0.5; reference e^0.5 · TS ≈ 1.6487 · 10¹⁸ |
| 1 | 2 | true  | 606_530_659_712_633_426       | **[algorithm-derived]** fractional y = 0.5 negative; exercises reciprocal on non-integer exponent |
| 2 | 1 | false | 7_389_056_098_930_650_216     | **[algorithm-derived]** y = 2; reference e² · TS ≈ 7.389 · 10¹⁸ |
| 4 | 1 | false | 54_598_150_033_144_239_050    | **[algorithm-derived]** y = 4; reference e⁴ · TS ≈ 54.598 · 10¹⁸ |
| 8 | 1 | false | 2_980_957_986_946_523_322_343 | **[algorithm-derived]** y = 8 — upper bound of §7 overflow analysis; guards the claimed `acc ≤ e⁸ · TS ≈ 3×10²¹` budget |
| 8 | 1 | true  | 335_462_627_913_225           | **[algorithm-derived]** y = 8 negative — deepest reciprocal division; guards `TAYLOR_SCALE_SQ / exp_scaled_pos(...)` precision at smallest positive result |

All eight rows are pinned. Re-derive whenever §7 (Taylor K, rounding) changes;
the `bootstrap_constants_match_pinned` regression test in `curve_shape_tests`
flags any drift.

#### Properties

**Seed set S:** `[(1,2), (1,1), (2,1), (3,1), (4,1), (6,1), (8,1), (7,2), (15,2)]`
— nine rationals spanning (0, 8], deliberately including both integer and
fractional `y_den` values and the `y = 8` upper bound.

1. **Monotone (pos) [property].** For every adjacent pair `(yᵢ, yᵢ₊₁)` in S
   after sorting by `y_num / y_den` ascending, assert
   `exp_scaled_pos_for_testing(yᵢ) < exp_scaled_pos_for_testing(yᵢ₊₁)`.
   Zero-argument branch (`y = 0`) is covered by the y=0 exact rows above;
   this property does not include it.

2. **Reciprocal identity [property].** For every `y ∈ S`, assert
   `pos × neg ∈ [TAYLOR_SCALE_SQ − pos, TAYLOR_SCALE_SQ]`
   where `pos = exp_scaled_for_testing(y_num, y_den, false)` and
   `neg = exp_scaled_for_testing(y_num, y_den, true)`. Since
   `neg = floor(TS² / pos)`, the integer-division floor introduces an error
   of at most 1 in `neg`, which projects to an error of at most `pos` in the
   product. For `y ∈ S`, `pos` is bounded by `e⁸ · TS ≈ 3·10²¹`. The earlier
   "1 ULP = TAYLOR_SCALE" bound only holds for `y ≈ 0` where `pos ≈ TS`.

3. **Precision bound [property].** Not directly testable in Move without a
   reference `floor(eʸ · TS)` oracle. Deferred to an off-chain check:
   the initial-implementation trace compares each produced value against a
   high-precision reference and records the relative error. If any seed in S
   exceeds `10⁻⁹` relative error, the Taylor-series parameter `K = 32` is
   insufficient and §7 must be re-budgeted.

4. **[new] [property] Boundary at y = 8.** Assert
   `exp_scaled_pos_for_testing(8, 1) > 0` and the raw product
   `exp_scaled_pos_for_testing(8, 1) * 8` (both sides cast `u128`) does not
   exceed `u128::MAX`. Guards the §7 overflow analysis claim `term · y_num ≤
   4.2×10²⁰ · 12 · 10¹³ = 5.0×10³⁴ fits u128`.

5. **[new] y = 0 sign-invariance.** Assert
   `exp_scaled_for_testing(0, 1, false) == exp_scaled_for_testing(0, 1, true) == TAYLOR_SCALE`
   and `exp_scaled_for_testing(0, 7, false) == TAYLOR_SCALE`. Covered
   structurally by the "Exact case (y = 0)" table above; listed here to make
   the property explicit.

#### Input validity note

No abort is defined for out-of-range y. The overflow analysis (§7) guarantees
correctness only for `y_num/y_den ≤ 8` with `tenure_ceiling ≤ 10¹³ ms`. Inputs
outside this range are the caller's responsibility (`eval_exponential` and
`eval_logistic` enforce them via `alpha_abs ∈ [1, 8]` at construction time).


### 11.6 `eval_exponential`

#### Precomputed `EXP_A_NORM_*` constants — lookup dispatcher

The 16 module-level `EXP_A_NORM_{1..8}_{POS,NEG}` constants (§8) are
algorithm-derived — establish all 16 during initial implementation using the
procedure documented in §8. Correct `EXP_A_NORM_*` values are a precondition
for the golden vectors below to reproduce.

`exp_a_norm(alpha_abs, alpha_neg)` is a pure dispatcher over these 16
constants (§8). The test surface has three layers:

| `alpha_abs` | `alpha_neg` | result | note |
|---|---|---|---|
| **[new]** 1..8 (eight rows) | `false` | `EXP_A_NORM_{abs}_POS` | **[property]** per-pair: `exp_a_norm_for_testing(a, false)` equals the POS constant by direct reference |
| **[new]** 1..8 (eight rows) | `true`  | `EXP_A_NORM_{abs}_NEG` | **[property]** per-pair: `exp_a_norm_for_testing(a, true)` equals the NEG constant |

The parametric loop above asserts the dispatcher wiring is correct (no
swapped arms, no missing coverage of a pair). It does not verify the
numerical value of the constants themselves — those are validated by the
golden-vector rows below (which depend on the constants for correctness)
and by the two monotonicity rows:

- **[new] [property] POS strictly increasing in α:** for all pairs
  `(a, a+1)` with `a ∈ {1..7}`, `EXP_A_NORM_{a}_POS < EXP_A_NORM_{a+1}_POS`
  (since `e^a − 1` is strictly increasing for `a > 0`).
- **[new] [property] NEG strictly increasing in α:** for all pairs
  `(a, a+1)` with `a ∈ {1..7}`, `EXP_A_NORM_{a}_NEG < EXP_A_NORM_{a+1}_NEG`
  (since `1 − e^{−a}` is strictly increasing for `a > 0`).

These two rows catch copy-paste mistakes at pinning time (e.g. swapped
`EXP_A_NORM_3_POS` and `EXP_A_NORM_4_POS`) that would not surface in a
single-α golden vector.

#### Golden vectors

Algorithm-derived — established by emitting `eval_exponential_for_testing(...)`
outputs via `std::debug::print` in a one-shot `#[test]`, then pinning the
captured literals here and in the `eval_exponential_golden_vectors`
regression check (same procedure as §11.5).

| `t` | `t_max` | `alpha_abs` | `alpha_neg` | result | note |
|-----|---------|-------------|-------------|--------|------|
| **[new]** `1` | `4` | `2` | `false` | `101_536_324` | α=+2 convex |
| **[new]** `1` | `4` | `2` | `true`  | `455_054_233` | α=−2 concave; complementary to row above |
| **[new]** `1` | `4` | `4` | `false` |  `32_058_603` | mid-range α |
| **[new]** `1` | `4` | `8` | `false` |   `2_144_008` | **upper bound** α=+8 — guards §8 math overflow analysis at boundary |
| **[new]** `1` | `4` | `8` | `true`  | `864_954_876` | **upper bound** α=−8 — reciprocal path at depth |
| **[new]** `1` | `4` | `1` | `true`  | `349_932_008` | minimum concave |
| **[new]** `2` | `4` | `2` | `false` | `268_941_421` | midpoint `t = t_max/2` — used in complementarity property pair |
| **[new]** `2` | `4` | `2` | `true`  | `731_058_578` | midpoint concave — sum with row above is 999_999_999 (1 ULP from SCALE) |

#### Properties

- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_exponential(t1) ≤ eval_exponential(t2)`
- **Below linear** when `alpha_neg=false`:
  `eval_exponential(t, t_max, a, false) < eval_linear(t, t_max)` for `t ∈ (0, t_max)`
- **Above linear** when `alpha_neg=true`:
  `eval_exponential(t, t_max, a, true) > eval_linear(t, t_max)` for `t ∈ (0, t_max)`
- **Complementarity** (mathematically exact, small rounding deviation from integer arithmetic):
  `eval_exponential(t, t_max, a, false) + eval_exponential(t_max-t, t_max, a, true) ≈ SCALE`
  Proof: `f_α(x) + f_{-α}(1-x) = 1` for all x (see §8). Maximum deviation: a few ULP.

  **[new] [property] Complementarity — seed set C.** Seeds:
  `(t, t_max, alpha_abs) ∈ {(1, 4, 2), (2, 4, 2), (3, 4, 2), (1, 4, 8), (3, 8, 4)}`.
  For each seed, assert
  `|eval_exponential_for_testing(t, t_max, a, false) +
    eval_exponential_for_testing(t_max − t, t_max, a, true) − SCALE| ≤ 4`
  (4 ULP tolerance; tighten at implementation time if empirical deviation
  is smaller). Midpoint seed `(2, 4, 2)` exercises the `t == t_max − t`
  self-complementary case where the sum must be exactly `2 · eval_mid`.


### 11.7 `eval_logistic`

#### Golden vectors

Algorithm-derived rows established by emitting `eval_logistic_for_testing(...)`
outputs via `std::debug::print` in a one-shot `#[test]`, then pinning the
captured literals here and in the `eval_logistic_golden_vectors` regression
check (same procedure as §11.5).

| `t` | `t_max` | result | note |
|-----|---------|--------|------|
| **[new]** `2_000_000_000` | `4_000_000_000` | `500_000_000` | exact midpoint `SCALE/2` — by construction (σ is symmetric around y=0; at x=0.5 the numerator equals half the denominator). No algorithm placeholder. |
| **[new]** `1_000_000_000` | `4_000_000_000` |  `45_176_659` | `t = t_max/4` — below linear |
| **[new]** `3_000_000_000` | `4_000_000_000` | `954_823_340` | `t = 3·t_max/4` — above linear; sum with row above is 999_999_999 (1 ULP from SCALE) |
| **[new]** `1` | `4` |  `45_176_659` | small-integer inputs — same `x = 0.25` ratio as the SCALE-aligned row above; integer rounding cancels at this granularity |

#### Constant derivation tests — `LOGISTIC_DENOM`, `LOGISTIC_SIGMA_FLOOR`

These guard the relationship declared in §9 between the two constants
and prevent a pinned literal for one from drifting out of sync with the
other.

| Assertion | Note |
|---|---|
| **[new] [property]** `2 · logistic_sigma_floor_for_testing() + (logistic_denom_for_testing() as u128) ∈ [SCALE_U128 − 1, SCALE_U128]` | Algebraic identity from the definition `SIGMA_FLOOR = floor((SCALE − DENOM) / 2)`. The integer-floor allows a 1-ULP slack when `(SCALE − DENOM)` is odd; for the pinned `DENOM = 995_054_753` the difference is `4_945_247` (odd), so the value is `SCALE − 1`. Fails if either literal drifts against a different `exp_scaled` output than the other. |
| **[new]** `(logistic_denom_for_testing() as i128 − 995_054_750).abs() <= 100` | Reference check: `(σ(6) − σ(−6)) · SCALE ≈ 995_054_750` (§9). 100-ULP tolerance covers floor rounding in `exp_scaled`; tighten at implementation if actual delta is known. Fails if `LOGISTIC_DENOM` is pinned against a wrong exponent (e.g. `k=6` vs `k=12`). |

#### Properties

- **Range:** result `∈ [0, SCALE]`
- **Monotonicity:** `t1 < t2 → eval_logistic(t1) ≤ eval_logistic(t2)`
- **Exact midpoint:** `eval_logistic(t_max/2, t_max) = SCALE/2` — covered
  by the golden-vector row above.
- **Approximate symmetry [property]:** for seed set
  `S_L = [(1, 4), (1, 8), (3, 8), (1_000_000_000, 4_000_000_000)]`,
  `|eval_logistic_for_testing(t, t_max) +
    eval_logistic_for_testing(t_max − t, t_max) − SCALE| ≤ 2`.
- **Below linear:** `eval_logistic(t) < eval_linear(t)` for `t ∈ (0, t_max/2)`
- **Above linear:** `eval_logistic(t) > eval_linear(t)` for `t ∈ (t_max/2, t_max)`


### 11.8 Open questions

- **`exp_scaled` parameter drift risk.** If the Taylor series parameters (K,
  rounding) in §7 are changed, every pinned constant in this module
  (`EXP_A_NORM_*`, `LOGISTIC_DENOM`) must be re-derived. No in-VM test detects
  the drift — the only guard is the reference-value tolerance check on
  `LOGISTIC_DENOM`. Flag as a module-level invariant when changing §7.
- **Destructure helper visibility.** `power_law_fields_for_testing` needs
  to match on `CurveShape::PowerLaw { .. }`, which requires either
  `#[test_only]` public access to the enum fields or a helper inside
  `curve_shape.move` that exposes them. The strategy above assumes the
  latter. Confirm implementation convention at first use.
- **Abort-ordering assumption.** The table in §11.0.2 assumes the
  `new_power_law` asserts fire in the order `alpha_num → alpha_den →
  degenerate`. If the implementation chooses a different order, the
  `(0, 0)` / `(0, 5)` style rows would surface a different error code
  than listed. Keep a single assert per precondition and document the
  order in §2.3; adjust rows if order changes.
- **Complementarity tolerance bound.** Rows use 4 ULP for Exponential
  and 2 ULP for Logistic as working tolerances. Empirical deviation from
  the initial-implementation trace should let us tighten these. Record
  the observed max deviation in a comment when pasting the golden
  vectors back, and reduce the tolerance to that value + 1 ULP.
- **Abort-attribute shape for arithmetic errors.** Move's `arithmetic_error`
  attribute form — verify against the target Sui framework version at
  implementation time if any `eval_*` function triggers arithmetic aborts.
