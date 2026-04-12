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
- Integration-time validation — lives in `config::new`.
- Protocol state, fund movements, access control, event emission.

**Dependency direction:** `math` calls nothing outside its own module.
`curve` calls into `math`.


1. PRECISION MODEL
------------------

    SCALE: u64        = 1_000_000_000          (10^9)
    TAYLOR_SCALE: u128 = 1_000_000_000_000_000_000  (10^18)
    TAYLOR_SCALE_SQ: u128 = TAYLOR_SCALE * TAYLOR_SCALE   (10^36, fits u128 ✓)

`SCALE` is used by `curve` for curve output values in [0, SCALE].
`TAYLOR_SCALE` and `TAYLOR_SCALE_SQ` are used internally by `exp_scaled`.

Rounding: floor throughout (truncation), unless stated otherwise.


2. MUL_DIV
----------

### Signature

    public fun mul_div(a: u64, b: u64, c: u64): u64

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


3. NTH_ROOT_U128
----------------

### Signature

    public fun nth_root_u128(n: u128, d: u32): u128

### Semantics

    Returns floor(n^(1/d))

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


4. EXP_SCALED / EXP_SCALED_POS
--------------------------------

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

    K = 20 terms — for |y| ≤ 8, yields relative error < 10^-9.

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
      Logistic:    y_num = k · |2t − t_max| ≤ 16 · tenure_ceiling
      For tenure_ceiling ≤ 10^13 ms (~317 years):
        term · y_num ≤ 4.2×10^20 · 16 · 10^13 = 6.7×10^34  fits u128 ✓
      u128 max ≈ 3.4×10^38 — safe margin of ~3 orders of magnitude.

### Usage

Called by `curve` for the Exponential and Logistic variants.


5. MODULE BOUNDARY
------------------

`math.move` exports:

| Function | Visibility | Notes |
|---|---|---|
| `mul_div(a, b, c): u64` | `public` | Used by `curve` and internally. |
| `nth_root_u128(n, d): u128` | `public` | Used by `curve` (PowerLaw). |
| `exp_scaled(y_num, y_den, neg): u128` | `public` | Used by `curve` (Exponential, Logistic). |
| `exp_scaled_pos(y_num, y_den): u128` | private | Inner Taylor series. |

**Depends on:** nothing.
