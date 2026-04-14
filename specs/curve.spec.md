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
- `LOGISTIC_K: u64 = 12` and `LOGISTIC_DENOM: u64` — module-level constants.
  `denom` is precomputed from k=12 at compile time, never set by the integrator.
- `compute_used_credit`, `compute_price_descent`, `compute_next_rent_price` —
  `public(package)` protocol-level wrappers. Called by `rental_escrow` via
  `current_used_credit`, `current_price_descent`, `current_next_rent_price`.

**Does not own:**

- Integration-time validation — lives in `config::new`.
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


2. TYPES
--------

### CurveShape — enum

Defines the functional form of `f_credit_ascent` or `f_price_descent`.

```move
enum CurveShape {
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

    const LOGISTIC_K: u64 = 12;
    const LOGISTIC_DENOM: u64 = /* precomputed: (σ(6) − σ(−6)) · SCALE ≈ 995_054_754 */;

**Abilities:** `copy, drop, store`

**Constraints (validated at integration time by `config::new`):**

| Variant | Function | Field | Constraint |
|---------|----------|-------|------------|
| `Linear` | `g(x) = x` | — | N/A |
| `Smoothstep` | `g(x) = 3x² - 2x³` | — | N/A |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num` | `∈ [1, 8]` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_den` | `∈ {1, 2, 3, 4}` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num, alpha_den` | `alpha_num != alpha_den` (degenerate linear — use `Linear` instead) |
| `Exponential` | `g(x) = (e^(α·x) - 1) / (e^α - 1)` | `alpha_abs` | `∈ [1, 8]` |
| `Exponential` | `g(x) = (e^(α·x) - 1) / (e^α - 1)` | `alpha_neg` | `false` → convex (α > 0), `true` → concave (α < 0) |
| `Logistic` | `g(x) = (σ(12·(x−0.5)) − σ(−6)) / LOGISTIC_DENOM` | — | No fields. k=12 fixed. |

### PriceFunction — enum

Defines the functional form of `f_next_rent_price`.

```move
enum PriceFunction {
    FixedDelta {
        delta: u64,
    },
    Percentage {
        bps: u64,
    },
    CompoundDelta {
        bps: u64,
        delta: u64,
    },
}
```

**Abilities:** `copy, drop, store`

**Constraints (validated at integration time by `config::new`):**

All variants must satisfy:
- `compute_next_rent_price(fn, min_rent_price) > min_rent_price`
- No u64 overflow on computation

Per-variant overflow constraints:
- `FixedDelta`:  `delta > 0` (enforced by the > check above)
- `Percentage`:  `bps ∈ [1, u64::MAX - 10000]` so `10000 + bps` does not overflow u64
- `CompoundDelta`: same `bps` bound as Percentage; `delta` unconstrained (> check handles it)

**Semantics:**

| Variant | Formula |
|---------|---------|
| `FixedDelta { delta }` | `f(x) = x + delta` |
| `Percentage { bps }` | `f(x) = mul_div(x, 10000 + bps, 10000)` |
| `CompoundDelta { bps, delta }` | `f(x) = mul_div(x, 10000 + bps, 10000) + delta` |

where `bps` is basis points (100 bps = 1%, 10000 bps = 100%).


3. EVALUATE_CURVE (private)
----------------------------

### Signature

    fun evaluate_curve(shape: &CurveShape, t: u64, t_max: u64): u64

### Semantics

Evaluates the normalized shape function g at x = t / t_max.
Returns g(x) * SCALE, in [0, SCALE].

### Edge cases (apply before dispatch, regardless of shape)

| Condition    | Return  |
|--------------|---------|
| `t == 0`     | `0`     |
| `t >= t_max` | `SCALE` |

### Dispatch

Delegates to the variant-specific function below.
`t_max > 0` is guaranteed by `IntegrationConfig` constraints.

Private — used only by `compute_used_credit` and `compute_price_descent`.


4. LINEAR VARIANT
-----------------

    g(x) = x

### Algorithm

    math::mul_div(t, SCALE, t_max)

Exact. No approximation.


5. SMOOTHSTEP VARIANT
---------------------

    g(x) = 3x² - 2x³

### Derivation in integers

Let `x = t * SCALE / t_max` (x in [0, SCALE]).

    g(x/SCALE) = 3(x/SCALE)² - 2(x/SCALE)³
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

### Shape by alpha value

    alpha < 1  (e.g. 1/2, 2/3, 3/4)  →  purely concave
    alpha = 1                          →  linear (degenerate; use Linear instead)
    alpha > 1  (e.g. 2, 3, 3/2)       →  purely convex

### Normalization at integration time

    let g = gcd(alpha_num, alpha_den);
    alpha_num /= g;
    alpha_den /= g;

Reduces to lowest terms once at integration time (stored in variant).
Minimizes loop iterations in Step 1 and may eliminate Step 2 entirely
(e.g., 6/2 → 3/1: x^3 with no root vs x^6 + square root).
Guaranteed by `config::new`: stored alpha_num and alpha_den are always coprime.

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
    alpha_neg: bool — sign: false → α > 0 (convex), true → α < 0 (concave)

Move has no native signed integer types. Sign is represented as magnitude + flag.

### Sign and shape

    alpha_neg = false  →  convex  (e.g. α = 2: slow start, fast finish)
    alpha_neg = true   →  concave (e.g. α = -2: fast start, slow finish)

### Algorithm

    let a   = shape.alpha_abs as u64;   // ∈ [1, 8]
    let neg = shape.alpha_neg;

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

### Constraints at integration time

    alpha_abs ∈ [1, 8]     (0 rejected: denominator would be zero)
    alpha_neg ∈ {true, false}

alpha_abs = 0 is rejected because e^0 - 1 = 0 makes the denominator zero
(the limit at α → 0 is linear — use Linear variant instead).


8. LOGISTIC VARIANT
--------------------

    g(x) = (σ(12·(x − 0.5)) − σ(−6)) / LOGISTIC_DENOM

    where σ(y) = e^y / (e^y + 1)

No fields. `k = 12` and `LOGISTIC_DENOM` are module-level constants.
Produces a pronounced S-curve with inflection fixed at x = 0.5 — clearly
distinguishable from `Smoothstep` without being extreme.

### Module-level constants

    const LOGISTIC_K: u64    = 12;
    const LOGISTIC_DENOM: u64 = /* (σ(6) − σ(−6)) · SCALE ≈ 997_524_148 */;

`LOGISTIC_DENOM` is derived once:

    let TS: u128 = TAYLOR_SCALE;
    let ek2: u128 = math::exp_scaled(6, 1, false);   // e^6 * TS
    // σ(6) − σ(−6) = (ek2 − TS) / (ek2 + TS)
    LOGISTIC_DENOM = ((ek2 - TS) * SCALE as u128 / (ek2 + TS)) as u64;

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

Note: `two_t` and `y_den` require `tenure_ceiling ≤ u64::MAX / 2`.
Enforced by `config::new`.

### Overflow analysis

    ey          ≤ e^6 · TS ≈ 403 · 10^18 ≈ 4×10^20   fits u128 ✓
    ey · S      ≤ 4×10^20 · 10^9 = 4×10^29            fits u128 ✓
    (σ_y − σ_floor) · S  ≤ S · S = 10^18              fits u128 ✓

### No integration-time constraint

`Logistic` has no fields — nothing to validate at integration time.


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


11. COMPUTE_NEXT_RENT_PRICE
----------------------------

### Signature

    public(package) fun compute_next_rent_price(
        price_fn: &PriceFunction,
        last_rent_price: u64,
    ): u64

### Dispatch

| Variant                        | Computation |
|--------------------------------|-------------|
| `FixedDelta { delta }`         | `last_rent_price + delta` |
| `Percentage { bps }`           | `math::mul_div(last_rent_price, 10000 + bps, 10000)` |
| `CompoundDelta { bps, delta }` | `math::mul_div(last_rent_price, 10000 + bps, 10000) + delta` |

### Overflow

All additions use checked arithmetic — abort on u64 overflow.
Guaranteed result > last_rent_price by integration-time constraint validation
in `config::new`.


12. MODULE BOUNDARY
--------------------

`curve.move` exports:

| Function | Visibility | Notes |
|---|---|---|
| `compute_used_credit(...)` | `public(package)` | Called by `rental_escrow::current_used_credit`. |
| `compute_price_descent(...)` | `public(package)` | Called by `rental_escrow::current_price_descent`. |
| `compute_next_rent_price(...)` | `public(package)` | Called by `rental_escrow::current_next_rent_price`. |
| `evaluate_curve(...)` | private | Internal dispatcher. |

`CurveShape` and `PriceFunction` types are defined in this module and embedded
in `IntegrationConfig` (via `config.move`).

**Depends on:** `math` (for `mul_div`, `nth_root_u128`, `exp_scaled`).
