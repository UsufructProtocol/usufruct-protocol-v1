MATH MODULE — SPECIFICATION
============================

Module: `math`
Design reference: design-compact.md §5
Inventory reference: inventory-impl.md §4


0. MODULE RESPONSIBILITY
------------------------

`math` is the pure computational layer of the protocol. It owns every
numeric operation and type definition that is shared across modules — no
protocol state, no object model, no fund movements.

**Owns:**

- `CurveShape` and `PriceFunction` — the enumerated functional forms used
  in `IntegrationConfig`. All dispatch on these types lives here.
- Fixed-point arithmetic primitives (`mul_div`, `nth_root_u128`,
  `exp_scaled`, `exp_scaled_pos`) used exclusively by this module.
- `evaluate_curve` — single entry point for evaluating any `CurveShape`
  at a given (t, t_max) pair. Returns a value in [0, SCALE].
- `compute_used_credit`, `compute_price_descent`,
  `compute_next_rent_price` — protocol-level wrappers that apply the
  relevant curve or price function to raw protocol inputs.
- `new_logistic` — the only valid constructor for the `Logistic` variant
  (precomputes `denom` at construction time).
- `validate_config` — integration-time validation called by `integrate()`.
  Aborts on any constraint violation; normalises `PowerLaw` to lowest
  terms in-place.

**Does not own:**

- Protocol state (`RentalEscrow`, `AssetState`, phase anchors).
- Fund movements (`Balance`, `Coin`).
- Access control (`OwnerCap`, `TenantCap`).
- Event emission.

**Dependency direction:** `rental_escrow` and `curve` call into `math`;
`math` calls nothing outside its own module boundary.


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
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num` | `∈ [1, 8]` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_den` | `∈ {1, 2, 3, 4}` |
| `PowerLaw` | `g(x) = x^(alpha_num/alpha_den)` | `alpha_num, alpha_den` | `alpha_num != alpha_den` (degenerate linear — use `Linear` instead) |
| `Exponential` | `g(x) = (e^(α·x) - 1) / (e^α - 1)` | `alpha_abs` | `∈ [1, 8]` |
| `Exponential` | `g(x) = (e^(α·x) - 1) / (e^α - 1)` | `alpha_neg` | `false` → convex (α > 0), `true` → concave (α < 0) |
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

    alpha_num: u8   — numerator of exponent,   ∈ [1, 8]
    alpha_den: u8   — denominator of exponent, >= 1, in {1, 2, 3, 4}

### Constraint at integration time

    alpha_num >= 1, alpha_den >= 1
    alpha_num in {1, 2, 3, 4, 5, 6, 7, 8}
    alpha_den in {1, 2, 3, 4}       — restricts to square, cube, 4th root
    alpha_num / alpha_den > 0       — always satisfied by above

### Shape by alpha value

    alpha < 1  (e.g. 1/2, 2/3, 3/4)  →  purely concave
    alpha = 1                          →  linear (degenerate; use Linear instead)
    alpha > 1  (e.g. 2, 3, 3/2)       →  purely convex

### Algorithm

Let n = alpha_num, d = alpha_den.

Step 0 — reduce n/d to lowest terms (done once at integration time, stored):

    let g = gcd(n, d);
    n = n / g;
    d = d / g;

This minimizes loop iterations in Step 1 and may eliminate Step 2 entirely
(e.g., 6/2 → 3/1: x^3 with no root vs x^6 + square root).
Guaranteed by §13: stored alpha_num and alpha_den are always coprime.

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
    // .pow() does not exist in Move — dispatch on d explicitly:
    let scale_pow: u128 = match d {
        1 => 1,
        2 => SCALE as u128,
        3 => (SCALE as u128) * (SCALE as u128),
        _ => (SCALE as u128) * (SCALE as u128) * (SCALE as u128),  // d=4
    };
    let target: u128 = (acc as u128) * scale_pow;
    let R: u64 = nth_root_u128(target, d) as u64;

### nth_root_u128(N, d) — Newton-Raphson

    // Returns floor(N^(1/d))
    if N == 0: return 0
    if N == 1: return 1

    // Initial guess: bit-shift based on bit-length of N
    // bits(N) = 128 - N.leading_zeros()
    // x0 = 1 << ceil(bits(N) / d)
    let bits = 128u32 - (N.leading_zeros() as u32);
    let shift = (bits + d - 1) / d;        // ceil(bits / d)
    let mut x: u128 = 1 << shift;          // guaranteed x0 >= N^(1/d)

    loop:
        // .pow() does not exist in Move — dispatch on d explicitly:
        let x_pow: u128 = match d {
            2 => x,
            3 => x * x,
            _ => x * x * x,   // d=4
        };
        let x_new = ((d as u128 - 1) * x + N / x_pow) / (d as u128);
        if x_new >= x: return x            // converged — x is the floor
        x = x_new

Convergence: quadratic. For u128 inputs and d ≤ 4, at most ~13 iterations.
Gas cost: bounded and low (~100-200 operations).

### Overflow note for x.pow(d-1)

x converges toward N^(1/d). At worst x0 = 1 << ceil(128/d).
For d=2: x0 ≤ 2^64, x0^1 = x0 fits u128 ✓
For d=3: x0 ≤ 2^43, x0^2 ≤ 2^86 fits u128 ✓
For d=4: x0 ≤ 2^32, x0^3 ≤ 2^96 fits u128 ✓

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

    alpha_abs: u8   — magnitude of exponent, ∈ [1, 8]
    alpha_neg: bool — sign: false → α > 0 (convex), true → α < 0 (concave)

Move has no native signed integer types. Sign is represented as magnitude + flag.

### Sign and shape

    alpha_neg = false  →  convex  (e.g. α = 2: slow start, fast finish)
    alpha_neg = true   →  concave (e.g. α = -2: fast start, slow finish)

### Representation of e^y via Taylor series

    e^y = Σ(k=0..K) y^k / k!

For |y| ≤ 8 and x ∈ [0, 1], K = 20 terms yields relative error < 10^-9.

### Scaling approach

Work in a scaled integer domain with precision TAYLOR_SCALE = 10^18 (fits u128):

    TAYLOR_SCALE: u128 = 1_000_000_000_000_000_000   (10^18)
    TAYLOR_SCALE_SQ: u128 = TAYLOR_SCALE * TAYLOR_SCALE  (10^36, fits u128 ✓)

Two functions:

    // Public entry point — handles sign via reciprocal identity
    fn exp_scaled(y_num: u64, y_den: u64, neg: bool) -> u128
        if !neg { exp_scaled_pos(y_num, y_den) }
        else    { TAYLOR_SCALE_SQ / exp_scaled_pos(y_num, y_den) }

    // Inner — Taylor series for e^y, y = y_num/y_den > 0
    fn exp_scaled_pos(y_num: u64, y_den: u64) -> u128
        // returns floor(e^(y_num/y_den) * TAYLOR_SCALE)

Reciprocal identity: e^(-y) = 1/e^y, so:
    floor(e^(-y) · TS) = floor(TS² / floor(e^y · TS))

This avoids alternating-sign Taylor series entirely (which would underflow u128).
Error introduced by the integer division is at most 1 ULP — within the 10^-9 budget.

Taylor series algorithm for exp_scaled_pos:

    acc: u128 = TAYLOR_SCALE   // term_0 = 1 * TS
    term: u128 = TAYLOR_SCALE  // running term

    for k in 1..=K:            // K = 20
        term = term * (y_num as u128) / (k as u128 * y_den as u128)
        acc  = acc + term
        if term == 0: break    // early exit

    return acc

Note: divisor `k * y_den` computed in u128 to avoid u64 overflow for large y_den.

### Overflow analysis for exp_scaled_pos

    acc     ≤ e^8 · TS ≈ 2981 · 10^18 ≈ 3×10^21          fits u128 ✓
    term    ≤ peak ≈ e^8 · TS / √(2π·8) ≈ 4.2×10^20      fits u128 ✓
    term · y_num:
      Exponential: y_num = alpha_abs · t ≤ 8 · tenure_ceiling
      Logistic:    y_num = k · |2t - t_max| ≤ 16 · tenure_ceiling
      For tenure_ceiling ≤ 10^13 ms (~317 years):
        term · y_num ≤ 4.2×10^20 · 16 · 10^13 = 6.7×10^34  fits u128 ✓
      u128 max ≈ 3.4×10^38 — safe margin of ~3 orders of magnitude.

### Full algorithm for Exponential variant

    let a  = shape.alpha_abs as u64;   // ∈ [1, 8]
    let neg = shape.alpha_neg;

    // e^(α·x): y_num = a*t, y_den = t_max, sign = neg
    let exp_ax = exp_scaled(a * t, t_max, neg);

    // e^α: y_num = a, y_den = 1, sign = neg
    let exp_a  = exp_scaled(a, 1, neg);

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

### Constraints at integration time

    alpha_abs ∈ [1, 8]     (0 is rejected: denominator would be zero)
    alpha_neg ∈ {true, false}

alpha_abs = 0 is rejected because e^0 - 1 = 0 makes the denominator zero
(the limit at α → 0 is linear — use Linear variant instead).


9. LOGISTIC VARIANT
--------------------

    g(x) = (σ(k·(x − 0.5)) − σ(−k/2)) / denom

    where σ(y) = e^y / (e^y + 1)
    and   denom = (σ(k/2) − σ(−k/2)) * SCALE   [precomputed at integration time]

    k: u8      — steepness, ∈ [10, 16]. Inflection fixed at x = 0.5.
    denom: u64 — precomputed normalization constant. Never set manually.

**Construction:** always use `math::new_logistic(k)` — never construct `Logistic { k, denom }` directly.
`new_logistic` validates k ∈ [10, 16], computes denom via `exp_scaled`, and returns the variant.

### Shape by k value

    k ∈ [10, 12]  →  pronounced S-curve, distinctly steeper than Smoothstep
    k ∈ [13, 16]  →  steep cliff near x = 0.5

k < 10 produces curves indistinguishable from Linear or Smoothstep — use those
variants instead (exact computation, negligible gas cost).
Use `Logistic` only when a steep, parameterizable sigmoid is required.

### Precomputing denom (at integration time, stored in variant)

    let TS: u128 = TAYLOR_SCALE;                      // 10^18
    let ek2: u128 = exp_scaled(k as u64, 2, false);   // e^(k/2) * TS  (always positive)
    // σ(k/2)  = ek2 / (ek2 + TS)
    // σ(−k/2) = TS  / (ek2 + TS)
    // σ(k/2) − σ(−k/2) = (ek2 − TS) / (ek2 + TS)
    denom = ((ek2 - TS) * SCALE as u128 / (ek2 + TS)) as u64;

### Runtime algorithm

    let TS: u128 = TAYLOR_SCALE;
    let S:  u128 = SCALE as u128;

    // y = k · (x − 0.5) = k · (t − t_max/2) / t_max
    // y_num_abs = k · |2t − t_max|,  y_den = 2 · t_max,  y_neg = (t < t_max/2)
    let two_t = 2 * t;
    let (y_num_abs, y_neg) = if two_t >= t_max {
        (k as u64 * (two_t - t_max), false)
    } else {
        (k as u64 * (t_max - two_t), true)
    };
    let y_den: u64 = 2 * t_max;
    // two_t and y_den require tenure_ceiling ≤ u64::MAX / 2 ≈ 9.2×10^18 ms (~292 million years)
    // Enforced by §13 note — no protocol use case approaches this.

    let ey: u128 = exp_scaled(y_num_abs, y_den, y_neg);  // e^y * TS
    let sigma_y: u128 = ey * S / (ey + TS);   // σ(y) * SCALE

    // σ(−k/2) * SCALE = (SCALE − denom) / 2   [derived from stored denom]
    let sigma_floor: u128 = (S - denom as u128) / 2;

    ((sigma_y - sigma_floor) * S / denom as u128) as u64

### Overflow analysis

    ey          ≤ e^8 · TS ≈ 2981 · 10^18 ≈ 3×10^21   fits u128 ✓
    ey · S      ≤ 3×10^21 · 10^9 = 3×10^30             fits u128 ✓
    (σ_y − σ_floor) · S  ≤ S · S = 10^18               fits u128 ✓

### Constraint at integration time

    k ∈ [10, 16]
    denom > 0   (guaranteed: k ≥ 10 ensures σ(k/2) > σ(−k/2))


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
Two phases: first validate (abort on failure), then normalize (mutate stored values).

### Phase 1 — Validation (abort on failure)

| Check                                        | Abort reason                   |
|----------------------------------------------|--------------------------------|
| `min_rent_price > 0`                         | zero floor price               |
| `tenure_ceiling > 0`                         | zero tenure                    |
| `handover_floor > 0`                         | zero handover floor            |
| `handover_floor <= handover_ceiling`         | floor exceeds ceiling          |
| `handover_ceiling <= tenure_ceiling`         | handover exceeds tenure        |
| `descent_ceiling > 0`                        | zero descent period            |
| `tenure_ceiling <= u64::MAX / 2`             | prevents overflow in Logistic (`2 * t`) |
| `tenure_ceiling <= u64::MAX / 8`             | prevents overflow in Exponential (`alpha_abs * t`, alpha_abs ≤ 8) |
| PowerLaw: `alpha_den in {1,2,3,4}`           | unsupported root               |
| PowerLaw: `alpha_num in [1, 8]`              | zero or out-of-range exponent  |
| PowerLaw: `alpha_num != alpha_den`           | degenerate linear — use `Linear` |
| Exponential: `alpha_abs in [1, 8]`           | zero or out-of-range alpha_abs |
| Logistic: `k in [10, 16]`                    | out-of-range k                 |
| Percentage/CompoundDelta: `bps <= u64::MAX - 10000` | `10000 + bps` overflow  |
| `compute_next_rent_price(fn, min_rent_price) > min_rent_price` | price fn non-increasing |

### Phase 2 — Normalization (mutate, never aborts)

| Mutation                                                        | Purpose                  |
|-----------------------------------------------------------------|--------------------------|
| PowerLaw: `let g = gcd(alpha_num, alpha_den); alpha_num /= g; alpha_den /= g` | reduce to lowest terms |


14. MODULE BOUNDARY
--------------------

`math.move` exports:
  - `evaluate_curve` (public)
  - `compute_used_credit` (public)
  - `compute_price_descent` (public)
  - `compute_next_rent_price` (public)
  - `new_logistic(k: u8): CurveShape` (public) — only valid constructor for `Logistic`
  - `validate_config` (public, called by integrate())
  - `mul_div` (public, usable by other modules)
  - `nth_root_u128`, `exp_scaled`, `exp_scaled_pos` (private)

`CurveShape` and `PriceFunction` types are defined in this module
and re-exported as part of `IntegrationConfig`.
