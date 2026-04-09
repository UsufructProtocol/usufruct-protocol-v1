MATH MODULE — SPECIFICATION
============================

Module: `math`
Design reference: design-compact.md §5
Inventory reference: inventory-impl.md §4


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
        alpha: i8,
    },
    Logistic {
        k: u8,
        denom: u64,
    },
}
```

**Constraints (validated at integration time, §13):**

| Variant | Function | Field | Constraint |
|---------|----------|-------|------------|
| `Linear` | `g(x) = x` | — | N/A |
| `Smoothstep` | `g(x) = 3x² - 2x³` | — | N/A |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num` | `∈ [1, 16]` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_den` | `∈ {1, 2, 3, 4}` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num, alpha_den` | `alpha_num != alpha_den` (degenerate linear — use `Linear` instead) |
| `Exponential` | `g(x) = (e^(alpha·x) - 1) / (e^alpha - 1)` | `alpha` | `∈ [-8, -1] ∪ [1, 8]` (nonzero) |
| `Logistic` | `g(x) = (σ(k·(x−0.5)) − σ(−k/2)) / denom` | `k` | `∈ [10, 16]` |

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

**Constraints (validated at integration time, §13):**

All variants must satisfy:
- `compute_next_rent_price(fn, min_rent_price) > min_rent_price`
- No u64 overflow on computation

**Semantics:**

| Variant | Formula |
|---------|---------|
| `FixedDelta { delta }` | `f(x) = x + delta` |
| `Percentage { bps }` | `f(x) = mul_div(x, 10000 + bps, 10000)` |
| `CompoundDelta { bps, delta }` | `f(x) = mul_div(x, 10000 + bps, 10000) + delta` |

where `bps` is basis points (100 bps = 1%, 10000 bps = 100%).

### How CurveShape is used

All `CurveShape` variants are evaluated via a single dispatcher function:

```move
fun evaluate_curve(shape: &CurveShape, t: u64, t_max: u64) -> u64
```

**Semantics:** Given a curve shape, a time point `t`, and max duration `t_max`, 
returns the normalized curve value `g(t/t_max) * SCALE` in [0, SCALE].

Each variant has its own implementation logic (§5–§9); the caller does not need 
to know which variant is stored — the function handles the dispatch.

**Example usage:**

```move
let config = IntegrationConfig { 
    credit_curve: CurveShape::PowerLaw { alpha_num: 1, alpha_den: 2 },
    // ... other fields ...
};

let g_x = evaluate_curve(&config.credit_curve, elapsed_ms, config.tenure_ceiling);
// Returns g(elapsed/tenure) * SCALE where g(x) = sqrt(x)
```


3. MUL_DIV
----------

### Signature

    mul_div(a: u64, b: u64, c: u64) -> u64

### Semantics

    result = floor(a * b / c)

### Algorithm

    let num: u128 = (a as u128) * (b as u128);
    let res: u128 = num / (c as u128);
    assert!(res <= u64::MAX as u128);   // abort on overflow
    res as u64

### Constraints

- `c > 0` — aborts if zero
- Result fits u64 — aborts otherwise
- Used as the primitive for all other computations in this module


4. EVALUATE_CURVE
-----------------

### Signature

    evaluate_curve(shape: &CurveShape, t: u64, t_max: u64) -> u64

### Semantics

Evaluates the normalized shape function g at x = t / t_max.
Returns g(x) * SCALE, in [0, SCALE].

### Edge cases (apply before dispatch, regardless of shape)

| Condition       | Return  |
|-----------------|---------|
| `t == 0`        | `0`     |
| `t >= t_max`    | `SCALE` |

### Dispatch

Delegates to the variant-specific function below.
`t_max > 0` is guaranteed by `IntegrationConfig` constraints.


5. LINEAR VARIANT
-----------------

    g(x) = x

### Algorithm

    mul_div(t, SCALE, t_max)

Exact. No approximation.


6. SMOOTHSTEP VARIANT
---------------------

    g(x) = 3x² - 2x³

### Derivation in integers

Let `x = t * SCALE / t_max` (x in [0, SCALE]).

    g(x/SCALE) = 3(x/SCALE)² - 2(x/SCALE)³
               = x² * (3*SCALE - 2*x) / SCALE²

### Algorithm

    let x: u64 = mul_div(t, SCALE, t_max);          // x in [0, SCALE]
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


7. POWERLAW VARIANT
-------------------

    g(x) = x^(alpha_num / alpha_den)

    alpha_num: u8   — numerator of exponent,   >= 1
    alpha_den: u8   — denominator of exponent, >= 1, in {1, 2, 3, 4}

### Constraint at integration time

    alpha_num >= 1, alpha_den >= 1
    alpha_den in {1, 2, 3, 4}       — restricts to square, cube, 4th root
    alpha_num / alpha_den > 0       — always satisfied by above

### Shape by alpha value

    alpha < 1  (e.g. 1/2, 2/3, 3/4)  →  purely concave
    alpha = 1                          →  linear (degenerate; use Linear instead)
    alpha > 1  (e.g. 2, 3, 3/2)       →  purely convex

### Algorithm

Let n = alpha_num, d = alpha_den.

Step 1 — compute x^n scaled:

    // Start with x = t/t_max scaled by SCALE
    let mut acc: u64 = mul_div(t, SCALE, t_max);    // x * SCALE
    for _ in 1..n {
        acc = mul_div(acc, mul_div(t, SCALE, t_max), SCALE);
    }
    // acc = x^n * SCALE

Step 2 — take d-th root scaled:

We want R such that (R / SCALE)^d = x^n.
Equivalently: R = floor( nth_root(acc * SCALE^(d-1), d) )

    // target = acc * SCALE^(d-1), in u128
    let target: u128 = (acc as u128) * SCALE.pow(d - 1);
    let R: u64 = nth_root_u128(target, d) as u64;

### nth_root_u128(N, d) — Newton-Raphson

    // Returns floor(N^(1/d))
    if N == 0: return 0
    initial guess: x = N >> ((N.leading_zeros() as u32 / d) ... )  // shift-based
    loop:
        x_new = ((d-1)*x + N / x^(d-1)) / d
        if x_new >= x: return x
        x = x_new

Convergence: quadratic. For u128 inputs and d ≤ 4, at most ~13 iterations.
Gas cost: bounded and low (~100-200 operations).

### Overflow analysis for Step 2

    acc      ≤ SCALE = 10^9
    SCALE^(d-1):
      d=1 → 1          no scale needed, result = acc directly
      d=2 → 10^9       acc * 10^9  ≤ 10^18   fits u128  ✓
      d=3 → 10^18      acc * 10^18 ≤ 10^27   fits u128  ✓
      d=4 → 10^27      acc * 10^27 ≤ 10^36   fits u128  ✓

Maximum u128 ≈ 3.4×10^38 — all cases within bounds. ✓
This is why alpha_den is restricted to {1, 2, 3, 4}.

### Special case: d = 1

    g(x) = x^n   (integer exponent, no root needed)
    Step 2 is skipped. Return acc directly.


8. EXPONENTIAL VARIANT
----------------------

    g(x) = (e^(α·x) - 1) / (e^α - 1)

    alpha: i8   — signed integer, range [-8, 8], ≠ 0

`alpha` is stored as a plain signed integer (no fractional part in v1).

### Sign and shape

    alpha < 0  →  concave
    alpha > 0  →  convex

### Representation of e^y via Taylor series

    e^y = Σ(k=0..K) y^k / k!

For y = α·x with α ∈ [-8, 8] and x ∈ [0, 1], |y| ≤ 8.
K = 20 terms yields relative error < 10^-9 for all |y| ≤ 8.

### Scaling approach

Work in a scaled integer domain with precision TAYLOR_SCALE = 10^18 (fits u128):

    // Compute e^y * TAYLOR_SCALE using Taylor series
    fn exp_scaled(y_num: i64, y_den: u64) -> u128
        // y = y_num / y_den, represents the exponent
        // returns floor(e^y * TAYLOR_SCALE)

    Each term: term_k = term_{k-1} * y / k  (iterative, avoids factorial)
    Accumulate into u128. Stop when term < 1 or after K=20 terms.

### Full algorithm for Exponential variant

    let alpha = shape.alpha as i64;      // ∈ [-8, 8]

    // Compute numerator: e^(alpha * x) - 1
    // x = t / t_max, so alpha*x = alpha*t / t_max
    let num_raw = exp_scaled(alpha * t as i64, t_max) - TAYLOR_SCALE;

    // Compute denominator: e^alpha - 1
    let den_raw = exp_scaled(alpha, 1) - TAYLOR_SCALE;

    // Result: (num_raw / den_raw) * SCALE
    // = num_raw * SCALE / den_raw
    let result_u128 = (num_raw as u128) * (SCALE as u128) / (den_raw as u128);
    result_u128 as u64

### Sign handling

When alpha < 0, both num_raw and den_raw are negative (e^y < 1 for y < 0).
Their ratio is positive. Implementation uses signed i128 or absolute values with
explicit sign tracking. TBD at implementation time.

### Constraints at integration time

    alpha ∈ [-8, -1] ∪ [1, 8]      (i8, but 0 is rejected)

Alpha = 0 is rejected because it makes the denominator zero (limit is linear,
use Linear variant instead).


9. LOGISTIC VARIANT
--------------------

    g(x) = (σ(k·(x − 0.5)) − σ(−k/2)) / denom

    where σ(y) = e^y / (e^y + 1)
    and   denom = (σ(k/2) − σ(−k/2)) * SCALE   [precomputed at integration time]

    k: u8      — steepness, ∈ [10, 16]. Inflection fixed at x = 0.5.
    denom: u64 — stored in the variant, computed once in integrate().

### Shape by k value

    k ∈ [10, 12]  →  pronounced S-curve, distinctly steeper than Smoothstep
    k ∈ [13, 16]  →  steep cliff near x = 0.5

k < 10 produces curves indistinguishable from Linear or Smoothstep — use those
variants instead (exact computation, negligible gas cost).
Use `Logistic` only when a steep, parameterizable sigmoid is required.

### Precomputing denom (at integration time, stored in variant)

    let TS: u128 = TAYLOR_SCALE;             // 10^18
    let ek2: u128 = exp_scaled(k as i64, 2); // e^(k/2) * TS
    // σ(k/2)  = ek2 / (ek2 + TS)
    // σ(−k/2) = TS  / (ek2 + TS)
    // σ(k/2) − σ(−k/2) = (ek2 − TS) / (ek2 + TS)
    denom = ((ek2 - TS) * SCALE as u128 / (ek2 + TS)) as u64;

### Runtime algorithm

    let TS: u128 = TAYLOR_SCALE;
    let S:  u128 = SCALE as u128;

    // y = k · (x − 0.5) = k · (t − t_max/2) / t_max
    // Rational form: y_num = k · (2t − t_max),  y_den = 2 · t_max
    let y_num: i64 = (k as i64) * (2 * t as i64 - t_max as i64);
    let y_den: u64 = 2 * t_max;   // safe for practical tenure values (≤ centuries)

    let ey: u128 = exp_scaled(y_num, y_den);  // e^y * TS
    let sigma_y: u128 = ey * S / (ey + TS);   // σ(y) * SCALE

    // σ(−k/2) * SCALE = (SCALE − denom) / 2   [derived from stored denom]
    let sigma_floor: u128 = (S - denom as u128) / 2;

    ((sigma_y - sigma_floor) * S / denom as u128) as u64

### Overflow analysis

    ey          ≤ e^8 · TS ≈ 2981 · 10^18 ≈ 3×10^21   fits u128 ✓
    ey · S      ≤ 3×10^21 · 10^9 = 3×10^30             fits u128 ✓
    (σ_y − σ_floor) · S  ≤ S · S = 10^18               fits u128 ✓

### Constraint at integration time

    k ∈ [1, 16]
    denom > 0   (guaranteed: k ≥ 1 ensures σ(k/2) > σ(−k/2))


10. COMPUTE_USED_CREDIT
-----------------------

### Signature

    compute_used_credit(
        config: &IntegrationConfig,
        phase_start_ms: u64,
        now_ms: u64,
        last_rent_price: u64,
    ) -> u64

### Semantics

    elapsed = now_ms - phase_start_ms
    x = elapsed / tenure_ceiling
    used_credit = last_rent_price * g(x)

### Algorithm

    let elapsed = now_ms - phase_start_ms;
    let g_x = evaluate_curve(&config.credit_curve, elapsed, config.tenure_ceiling);
    mul_div(last_rent_price, g_x, SCALE)

### Saturation

If `now_ms >= phase_start_ms + tenure_ceiling`, evaluate_curve returns SCALE
and used_credit = last_rent_price (fully consumed).

If `now_ms < phase_start_ms` (clock skew): elapsed underflows — caller must
ensure now_ms >= phase_start_ms before calling. Abort otherwise.


11. COMPUTE_PRICE_DESCENT
-------------------------

### Signature

    compute_price_descent(
        config: &IntegrationConfig,
        phase_start_ms: u64,
        now_ms: u64,
        last_rent_price: u64,
    ) -> u64

### Semantics

    elapsed = now_ms - phase_start_ms
    x = elapsed / descent_ceiling
    price = last_rent_price - (last_rent_price - min_rent_price) * h(x)

### Algorithm

    let elapsed = now_ms - phase_start_ms;
    let h_x = evaluate_curve(&config.descent_curve, elapsed, config.descent_ceiling);
    let spread = last_rent_price - config.min_rent_price;
    let consumed = mul_div(spread, h_x, SCALE);
    last_rent_price - consumed

### Saturation

If `now_ms >= phase_start_ms + descent_ceiling`, evaluate_curve returns SCALE
and price = min_rent_price.


12. COMPUTE_NEXT_RENT_PRICE
----------------------------

### Signature

    compute_next_rent_price(price_fn: &PriceFunction, last_rent_price: u64) -> u64

### Dispatch

| Variant                       | Computation                                |
|-------------------------------|--------------------------------------------|
| `FixedDelta { delta }`        | `last_rent_price + delta`                  |
| `Percentage { bps }`          | `mul_div(last_rent_price, 10000 + bps, 10000)` |
| `CompoundDelta { bps, delta }`| `mul_div(last_rent_price, 10000 + bps, 10000) + delta` |

### Overflow

All additions use checked arithmetic — abort on u64 overflow.
Guaranteed result > last_rent_price by integration-time constraint validation.


13. INTEGRATION-TIME VALIDATION
--------------------------------

Called inside `integrate()` to reject invalid configs before creating the escrow.

| Check                                        | Abort reason                   |
|----------------------------------------------|--------------------------------|
| `min_rent_price > 0`                         | zero floor price               |
| `tenure_ceiling > 0`                         | zero tenure                    |
| `handover_floor > 0`                         | zero handover floor            |
| `handover_floor <= handover_ceiling`         | floor exceeds ceiling          |
| `handover_ceiling <= tenure_ceiling`         | handover exceeds tenure        |
| `descent_ceiling > 0`                        | zero descent period            |
| PowerLaw: `alpha_den in {1,2,3,4}`           | unsupported root               |
| PowerLaw: `alpha_num in [1, 16]`             | zero or out-of-range exponent  |
| PowerLaw: `alpha_num != alpha_den`           | degenerate linear — use `Linear` |
| Exponential: `alpha in [-8,-1] ∪ [1,8]`     | zero or out-of-range alpha     |
| Logistic: `k in [10, 16]`                    | out-of-range k (use Linear or Smoothstep for k < 10) |
| `compute_next_rent_price(fn, min_rent_price) > min_rent_price` | price fn non-increasing |


14. MODULE BOUNDARY
--------------------

`math.move` exports:
  - `evaluate_curve` (public)
  - `compute_used_credit` (public)
  - `compute_price_descent` (public)
  - `compute_next_rent_price` (public)
  - `validate_config` (public, called by integrate())
  - `mul_div` (public, usable by other modules)
  - `nth_root_u128`, `exp_scaled` (private)

`CurveShape` and `PriceFunction` types are defined in this module
and re-exported as part of `IntegrationConfig`.
