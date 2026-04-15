CURVE MODULE — SPECIFICATION
=============================

Module: `curve`
Design reference: design-compact.md §5
Module map reference: module-map.spec.md §2


0. MODULE RESPONSIBILITY
------------------------

`curve` defines the shape and price function types and evaluates them.
It is the bridge between raw arithmetic (`math`) and protocol-level computations
(`rental_escrow`).

**Owns:**

- `CurveShape` — enumerated functional forms for `f_credit_ascent` and
  `f_price_descent`. All dispatch on this type lives here.
- `PriceFunction` — enumerated functional forms for `f_next_rent_price`.
- `evaluate_curve` — private dispatcher. Single entry point for evaluating
  any `CurveShape` at a given (t, t_max) pair. Returns a value in [0, SCALE].
- `evaluate_price_fn` — private dispatcher. Single entry point for evaluating
  any `PriceFunction` at a given `last_rent_price`.
- `LOGISTIC_K: u64 = 12` and `LOGISTIC_DENOM: u64` — module-level constants.
  Both are hardcoded literals. Move `const` does not support function calls, so
  `LOGISTIC_DENOM` cannot be derived from `exp_scaled` at compile time — its value
  is established by running the algorithm once during initial implementation (same
  approach as the golden vectors in `math.spec.md`), then fixed as a literal.
- `compute_used_credit`, `compute_price_descent`, `compute_next_rent_price` —
  `public(package)` protocol-level wrappers. Called by `rental_escrow` via
  `current_used_credit`, `current_price_descent`, `current_next_rent_price`.

**Does not own:**

- Assembly of integration parameters — lives in `config::new`.
  (`config::new` calls `curve` constructors; it does not re-validate fields.)
- Protocol state (`RentalEscrow`, phase anchors).
- Fund movements (`Balance`, `Coin`).
- Access control (`OwnerCap`, `TenantCap`).
- Raw arithmetic primitives (`mul_div`, `nth_root_u128`, `exp_scaled`) — those
  live in `math`.

**Dependency direction:** `curve` calls `math`. `config` and `rental_escrow`
call `curve`. `curve` calls nothing outside `math`.


1. PRECISION MODEL
------------------

All curve evaluations operate on a fixed-point representation with:

    SCALE: u64 = 1_000_000_000   (10^9)

A curve output value `v` in [0, SCALE] represents the rational g(x) = v / SCALE.

Intermediates use u128 to avoid overflow. Final results are cast back to u64.

Rounding: floor throughout (truncation), unless stated otherwise.


1.1 ERROR CONSTANTS
-------------------

All validation aborts originate in the constructors defined in §2.3.

    const E_ALPHA_NUM_RANGE:   u64 = 0;  // power_law: alpha_num ∉ [1, 8]
    const E_ALPHA_DEN_RANGE:   u64 = 1;  // power_law: alpha_den ∉ {1, 2, 3, 4}
    const E_DEGENERATE_LINEAR: u64 = 2;  // power_law: alpha_num == alpha_den (use Linear)
    const E_ALPHA_ABS_RANGE:   u64 = 3;  // exponential: alpha_abs ∉ [1, 8]
    const E_FIXED_DELTA_ZERO:  u64 = 4;  // fixed_delta / compound_delta: delta == 0
    const E_BPS_RANGE:         u64 = 5;  // compound_delta: bps ∉ [1, u64::MAX−10000]


2. TYPES
--------

### CurveShape — enum

Defines the functional form of `f_credit_ascent` or `f_price_descent`.

```move
enum CurveShape has copy, drop, store {
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

### PriceFunction — enum

Defines the functional form of `f_next_rent_price`.

```move
enum PriceFunction has copy, drop, store {
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
- `CompoundDelta`: `bps ∈ [1, u64::MAX - 10000]` so `10000 + bps` does not overflow u64; `delta > 0`

Both variants guarantee `f(x) > x` for all `x > 0` from field constraints alone — no
cross-field validation required. For `CompoundDelta`: `mul_div(x, 10000 + bps, 10000) >= x`
always (denominator ≤ numerator factor), so `+ delta > 0` ensures strict increase regardless
of floor rounding on the percentage component.

**Semantics:**

| Variant | Formula |
|---------|---------|
| `FixedDelta { delta }` | `f(x) = x + delta` |
| `CompoundDelta { bps, delta }` | `f(x) = mul_div(x, 10000 + bps, 10000) + delta` |

where `bps` is basis points (100 bps = 1%, 10000 bps = 100%).
`delta` is a raw amount in the payment token's base denomination — same unit as
`min_rent_price` and `last_rent_price`. It is not scaled by `SCALE` (10^9).
Pure percentage behavior: use `CompoundDelta { bps, delta: 1 }` (1 base unit).

**Floor threshold for the percentage component** — the bps contribution is zero when
`last_rent_price < 10000 / bps`. Below this threshold only `delta` contributes.

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

Enum fields are private to `curve.move`. All external callers must construct
`CurveShape` and `PriceFunction` values through these functions.

`Linear`, `Smoothstep`, and `Logistic` have no fields — they are returned
directly without validation.

### CurveShape constructors

    public fun linear(): CurveShape
    // Returns CurveShape::Linear. No validation.

    public fun smoothstep(): CurveShape
    // Returns CurveShape::Smoothstep. No validation.

    public fun logistic(): CurveShape
    // Returns CurveShape::Logistic. No validation.

    public fun power_law(alpha_num: u8, alpha_den: u8): CurveShape
    // Validates:
    //   assert!(alpha_num >= 1 && alpha_num <= 8, E_ALPHA_NUM_RANGE)
    //   assert!(alpha_den >= 1 && alpha_den <= 4, E_ALPHA_DEN_RANGE)
    //   assert!(alpha_num != alpha_den,            E_DEGENERATE_LINEAR)
    // Normalizes: divides both by gcd(alpha_num, alpha_den) before storing.
    // Returns CurveShape::PowerLaw { alpha_num: reduced, alpha_den: reduced }.

    public fun exponential(alpha_abs: u8, alpha_neg: bool): CurveShape
    // Validates:
    //   assert!(alpha_abs >= 1 && alpha_abs <= 8, E_ALPHA_ABS_RANGE)
    // Returns CurveShape::Exponential { alpha_abs, alpha_neg }.

### PriceFunction constructors

    public fun fixed_delta(delta: u64): PriceFunction
    // Validates:
    //   assert!(delta > 0, E_FIXED_DELTA_ZERO)
    // Returns PriceFunction::FixedDelta { delta }.

    public fun compound_delta(bps: u64, delta: u64): PriceFunction
    // Validates:
    //   assert!(bps >= 1 && bps <= u64::MAX - 10000, E_BPS_RANGE)
    //   assert!(delta > 0,                            E_FIXED_DELTA_ZERO)
    // Returns PriceFunction::CompoundDelta { bps, delta }.


3. EVALUATE_CURVE (private)
----------------------------

### Signature

    fun evaluate_curve(shape: &CurveShape, t: u64, t_max: u64): u64

### Semantics

Evaluates the normalized shape function g at x = t / t_max.
Returns g(x) * SCALE, in [0, SCALE].

`t_max > 0` is guaranteed by `IntegrationConfig` constraints.
Private — used only by `compute_used_credit` and `compute_price_descent`.

### Implementation

    fun evaluate_curve(shape: &CurveShape, t: u64, t_max: u64): u64 {
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

Each `eval_*` function is private to `curve.move` and defined in §4-§8 below.


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
    let s128  = SCALE as u128;
    let num   = x128 * x128 * (3 * s128 - 2 * x128);
    let den   = s128 * s128;
    (num / den) as u64

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
Guaranteed by `power_law()` constructor: stored alpha_num and alpha_den are always coprime.

### Algorithm

Let n = alpha_num, d = alpha_den.

Step 1 — compute x^n scaled:

    let mut acc: u64 = math::mul_div(t, SCALE, t_max);    // x * SCALE
    for _ in 1..n {
        acc = math::mul_div(acc, math::mul_div(t, SCALE, t_max), SCALE);
    }
    // acc = x^n * SCALE

Step 2 — take d-th root scaled:

We want R such that (R / SCALE)^d = x^n.
Equivalently: R = floor( nth_root(acc * SCALE^(d-1), d) )

    let scale_pow: u128 = match d {
        1 => 1,
        2 => SCALE as u128,
        3 => (SCALE as u128) * (SCALE as u128),
        _ => (SCALE as u128) * (SCALE as u128) * (SCALE as u128),  // d=4
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

    let a   = alpha_abs as u64;   // ∈ [1, 8]
    let neg = alpha_neg;

    // e^(α·x): y_num = a*t, y_den = t_max, sign = neg
    let exp_ax = math::exp_scaled(a * t, t_max, neg);

    // e^α: y_num = a, y_den = 1, sign = neg
    let exp_a  = math::exp_scaled(a, 1, neg);

    if !neg {
        // α > 0: both exp_ax > TS and exp_a > TS
        let num = exp_ax - TAYLOR_SCALE;
        let den = exp_a  - TAYLOR_SCALE;
        (num * SCALE as u128 / den) as u64
    } else {
        // α < 0: both exp_ax < TS and exp_a < TS
        // (e^(α·x) - 1) and (e^α - 1) are both negative — ratio is positive
        let num = TAYLOR_SCALE - exp_ax;   // magnitude of numerator
        let den = TAYLOR_SCALE - exp_a;    // magnitude of denominator
        (num * SCALE as u128 / den) as u64
    }

`TAYLOR_SCALE` is defined in `math` — see math.spec.md §1.

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

    const LOGISTIC_K: u64     = 12;
    const LOGISTIC_DENOM: u64 = /* algorithm-derived — establish during initial implementation */;

Move `const` only admits literals and simple arithmetic — function calls are not
allowed. `LOGISTIC_DENOM` must be hardcoded as a literal whose value is produced by
running the following derivation once and recording the output (K=32, floor rounding):

    let TS: u128  = TAYLOR_SCALE;
    let ek6: u128 = math::exp_scaled(6, 1, false);   // e^6 · TS  (K=32)
    // (σ(6) − σ(−6)) · SCALE  =  (ek6 − TS) · SCALE / (ek6 + TS)
    LOGISTIC_DENOM = ((ek6 - TS) * SCALE as u128 / (ek6 + TS)) as u64;

Mathematical reference: (σ(6) − σ(−6)) · SCALE ≈ 995_054_750. The exact
algorithm-derived value may differ by a few ULP due to floor rounding in
`exp_scaled` — use the algorithm output, not this approximation.

### Runtime algorithm

    let TS: u128 = TAYLOR_SCALE;
    let S:  u128 = SCALE as u128;

    // y = 12 · (x − 0.5) = 12 · (t − t_max/2) / t_max
    let two_t = 2 * t;
    let (y_num_abs, y_neg) = if two_t >= t_max {
        (LOGISTIC_K * (two_t - t_max), false)
    } else {
        (LOGISTIC_K * (t_max - two_t), true)
    };
    let y_den: u64 = 2 * t_max;

    let ey: u128 = math::exp_scaled(y_num_abs, y_den, y_neg);   // e^y * TS
    let sigma_y: u128 = ey * S / (ey + TS);                     // σ(y) * SCALE

    // σ(−6) * SCALE = (SCALE − LOGISTIC_DENOM) / 2
    let sigma_floor: u128 = (S - LOGISTIC_DENOM as u128) / 2;

    ((sigma_y - sigma_floor) * S / LOGISTIC_DENOM as u128) as u64


### Overflow analysis

    ey          ≤ e^6 · TS ≈ 403 · 10^18 ≈ 4×10^20   fits u128 ✓
    ey · S      ≤ 4×10^20 · 10^9 = 4×10^29            fits u128 ✓
    (σ_y − σ_floor) · S  ≤ S · S = 10^18              fits u128 ✓

### No integration-time constraint

`Logistic` has no fields — nothing to validate at construction time.


9. COMPUTE_USED_CREDIT
-----------------------

### Signature

    public(package) fun compute_used_credit(
        shape: &CurveShape,
        elapsed_ms: u64,
        tenure_ceiling: u64,
        last_rent_price: u64,
    ): u64

### Semantics

    used_credit = last_rent_price * g(elapsed_ms / tenure_ceiling)

### Algorithm

    let g_x = evaluate_curve(shape, elapsed_ms, tenure_ceiling);
    math::mul_div(last_rent_price, g_x, SCALE)

### Saturation

If `elapsed_ms >= tenure_ceiling`, `evaluate_curve` returns SCALE and
`used_credit = last_rent_price` (fully consumed).

Caller must ensure `elapsed_ms` is not derived from a future timestamp
relative to `phase_start_ms`.


10. COMPUTE_PRICE_DESCENT
--------------------------

### Signature

    public(package) fun compute_price_descent(
        shape: &CurveShape,
        elapsed_ms: u64,
        descent_ceiling: u64,
        last_rent_price: u64,
        min_rent_price: u64,
    ): u64

### Semantics

    price = last_rent_price - (last_rent_price - min_rent_price) * h(elapsed_ms / descent_ceiling)

### Algorithm

    let h_x = evaluate_curve(shape, elapsed_ms, descent_ceiling);
    let spread = last_rent_price - min_rent_price;
    let consumed = math::mul_div(spread, h_x, SCALE);
    last_rent_price - consumed

### Saturation

If `elapsed_ms >= descent_ceiling`, `evaluate_curve` returns SCALE and
`price = min_rent_price`.

### Precondition

Caller must ensure `last_rent_price >= min_rent_price`. The protocol
guarantees this invariant — the first rent sets
`last_rent_price = min_rent_price` and it only increases thereafter.
Violation would underflow the u64 subtraction `last_rent_price - min_rent_price`.


11. COMPUTE_NEXT_RENT_PRICE
----------------------------

### Signature

    public(package) fun compute_next_rent_price(
        price_fn: &PriceFunction,
        last_rent_price: u64,
    ): u64

### Semantics

    compute_next_rent_price(price_fn, last_rent_price)
        → evaluate_price_fn(price_fn, last_rent_price)

Thin wrapper. All logic lives in the private layer below.

---

### `evaluate_price_fn` (private dispatcher)

    fun evaluate_price_fn(price_fn: &PriceFunction, last_rent_price: u64): u64 {
        match price_fn {
            PriceFunction::FixedDelta   { delta }      => eval_fixed_delta(last_rent_price, *delta),
            PriceFunction::CompoundDelta { bps, delta } => eval_compound_delta(last_rent_price, *bps, *delta),
        }
    }

---

### `eval_fixed_delta` (private)

    fun eval_fixed_delta(last_rent_price: u64, delta: u64): u64

    last_rent_price + delta

### `eval_compound_delta` (private)

    fun eval_compound_delta(last_rent_price: u64, bps: u64, delta: u64): u64

    math::mul_div(last_rent_price, 10000 + bps, 10000) + delta

### Overflow

All additions use checked arithmetic — abort on u64 overflow.
Guaranteed result > last_rent_price by constructor field constraints (§2.3).


12. MODULE BOUNDARY
--------------------

`curve.move` exports:

| Symbol | Visibility | Notes |
|--------|-----------|-------|
| `E_ALPHA_NUM_RANGE: u64 = 0` | `public` | SDK error handling. |
| `E_ALPHA_DEN_RANGE: u64 = 1` | `public` | SDK error handling. |
| `E_DEGENERATE_LINEAR: u64 = 2` | `public` | SDK error handling. |
| `E_ALPHA_ABS_RANGE: u64 = 3` | `public` | SDK error handling. |
| `E_FIXED_DELTA_ZERO: u64 = 4` | `public` | SDK error handling. |
| `E_BPS_RANGE: u64 = 5` | `public` | SDK error handling. |
| `linear()` | `public` | Called by integrators to build `CurveShape`. |
| `smoothstep()` | `public` | Called by integrators to build `CurveShape`. |
| `logistic()` | `public` | Called by integrators to build `CurveShape`. |
| `power_law(alpha_num, alpha_den)` | `public` | Called by integrators. Validates + normalizes. |
| `exponential(alpha_abs, alpha_neg)` | `public` | Called by integrators. Validates. |
| `fixed_delta(delta)` | `public` | Called by integrators to build `PriceFunction`. |
| `compound_delta(bps, delta)` | `public` | Called by integrators. Validates. |
| `compute_used_credit(...)` | `public(package)` | Called by `rental_escrow`. |
| `compute_price_descent(...)` | `public(package)` | Called by `rental_escrow`. |
| `compute_next_rent_price(...)` | `public(package)` | Called by `rental_escrow`. |
| `evaluate_curve(...)` | private | Dispatcher — match on `CurveShape`. |
| `eval_linear(...)` | private | §4 |
| `eval_smoothstep(...)` | private | §5 |
| `eval_power_law(...)` | private | §6 |
| `eval_exponential(...)` | private | §7 |
| `eval_logistic(...)` | private | §8 |
| `evaluate_price_fn(...)` | private | Dispatcher — match on `PriceFunction`. |
| `eval_fixed_delta(...)` | private | §11 |
| `eval_compound_delta(...)` | private | §11 |

`CurveShape` and `PriceFunction` types are defined in this module and embedded
in `IntegrationConfig` (via `config.move`).

**Integration flow:** constructors are `public` — callable directly from PTBs.
An integrator builds `CurveShape` and `PriceFunction` values by calling these
constructors, then passes them to `config::new`, then to `rental_escrow::integrate`.
Error constants are `public` so the SDK can map abort codes to human-readable messages.

**Depends on:** `math` (for `mul_div`, `nth_root_u128`, `exp_scaled`).


13. TEST CASES
--------------

Tests follow the same convention as `math.spec.md`: exact values are given where
derivable from the algorithm by hand; algorithm-derived golden vectors are marked
and must be established by running the implementation once and fixing the output.

Three categories per function:
- **Edge cases** — boundary inputs with known exact output
- **Golden vectors** — specific input → exact output (hand-derived or algorithm-derived)
- **Properties** — invariants that must hold for all valid inputs in the stated domain


### 13.1 `evaluate_curve` — dispatcher edge cases

These apply regardless of the variant passed. Tested once per variant to confirm
the dispatcher short-circuits before reaching `eval_*`.

| `shape` | `t` | `t_max` | result |
|---------|-----|---------|--------|
| any | `0` | any `> 0` | `0` |
| any | `t_max` | `t_max` | `SCALE` |
| any | `t_max + 1` | `t_max` | `SCALE` |


### 13.2 `eval_linear`

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


### 13.3 `eval_smoothstep`

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


### 13.4 `eval_power_law`

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


### 13.5 `eval_exponential`

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


### 13.6 `eval_logistic`

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


### 13.7 `eval_fixed_delta`

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


### 13.8 `eval_compound_delta`

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
- **Percentage floor:** when `last_rent_price < 10_000 / bps`,
  `result = last_rent_price + delta` (percentage component lost to floor rounding)


### 13.9 `compute_used_credit`

#### Properties

- **Range:** `result ∈ [0, last_rent_price]`
- **Zero start:** `elapsed_ms = 0 → result = 0`
- **Saturation:** `elapsed_ms >= tenure_ceiling → result = last_rent_price`
- **Monotonicity:** `e1 < e2 → compute_used_credit(e1) ≤ compute_used_credit(e2)`
- **Complement:** `result + (last_rent_price - result) = last_rent_price` (confirms no overflow)


### 13.10 `compute_price_descent`

#### Properties

- **Range:** `result ∈ [min_rent_price, last_rent_price]`
- **Zero start:** `elapsed_ms = 0 → result = last_rent_price`
- **Saturation:** `elapsed_ms >= descent_ceiling → result = min_rent_price`
- **Monotone decreasing:** `e1 < e2 → compute_price_descent(e1) ≥ compute_price_descent(e2)`


### 13.11 `compute_next_rent_price`

#### Properties

- **Strict increase:** `result > last_rent_price` for all valid inputs
- **Determinism:** same `(price_fn, last_rent_price)` → same result always
