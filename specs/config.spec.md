CONFIG MODULE — SPECIFICATION
==============================

Module: `config`
Design reference: design-compact.md §6
Module map reference: module-map.spec.md §3
Depends on: `curve`


0. MODULE RESPONSIBILITY
------------------------

`config` owns the `IntegrationConfig` struct and its validated constructor.
It bundles all immutable integration parameters into a single value that is
embedded inside `RentalEscrow` at integration time and never mutated again.

**Owns:**

- `IntegrationConfig` — plain data struct (`store` only, no `key`, no `drop`).
  No UID. Not a shared object. Embedded field inside `RentalEscrow`.
- `new(...)` — the sole constructor. `public`. Validates all protocol
  invariants and aborts on any violation.
- One `public` getter per field. Return immutable references or copy values.

**Does not own:**

- `CurveShape` and `PriceFunction` construction or evaluation — those live in
  `curve`. `config::new` receives already-constructed values and does not
  re-validate their internal fields.
- Protocol state, fund movements, or capability objects.
- Any Sui framework object operations (no `object::new`, no `transfer`).

**Dependency direction:** `config` calls no `curve` module functions.
It stores `CurveShape` and `PriceFunction` values and pattern-matches on them
at runtime only to enforce the Logistic overflow constraint in `new`.
`rental_escrow` calls `config::new` and the getters.


1. ERROR CONSTANTS
------------------

All validation aborts originate in `new`. Constants are `public` so the SDK
can map abort codes to human-readable messages (same convention as `curve`).

    public const E_MIN_RENT_PRICE_ZERO:            u64 = 0;  // min_rent_price == 0
    public const E_TENURE_CEILING_ZERO:            u64 = 1;  // tenure_ceiling == 0
    public const E_HANDOVER_FLOOR_ZERO:            u64 = 2;  // handover_floor == 0
    public const E_HANDOVER_FLOOR_EXCEEDS_TENURE:  u64 = 3;  // handover_floor > tenure_ceiling
    public const E_DESCENT_CEILING_ZERO:           u64 = 4;  // descent_ceiling == 0
    public const E_TENURE_TOO_LARGE_FOR_LOGISTIC:  u64 = 5;  // Logistic credit_curve + tenure_ceiling > u64::MAX / 12
    public const E_DESCENT_TOO_LARGE_FOR_LOGISTIC: u64 = 6;  // Logistic descent_curve + descent_ceiling > u64::MAX / 12

`retire_floor >= 0` is trivially satisfied for `u64` — no error constant needed.


2. TYPE
-------

### IntegrationConfig — struct

Bundles all immutable parameters for one integration instance.

```move
struct IntegrationConfig has store {
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover_floor:  u64,
    descent_ceiling: u64,
    retire_floor:    u64,
    credit_curve:    CurveShape,
    descent_curve:   CurveShape,
    price_function:  PriceFunction,
}
```

**Abilities:** `store` only.
- No `key` — not an object; embedded inside `RentalEscrow`.
- No `drop` — must be explicitly destructured at retirement (via `claim_asset`).
- No `copy` — there is exactly one `IntegrationConfig` per escrow.

**Field semantics:**

| Field | Unit | Meaning |
|---|---|---|
| `min_rent_price` | payment token base denomination | Price floor. Idle entry price; Dutch Auction lower bound. |
| `tenure_ceiling` | milliseconds | Fixed duration of each rental block. |
| `handover_floor` | milliseconds | Minimum bidding window after a takeover bid. |
| `descent_ceiling` | milliseconds | Maximum Dutch Auction duration. |
| `retire_floor` | milliseconds | Minimum time since integration before `retire()` may execute. 0 = no restriction. |
| `credit_curve` | — | `CurveShape g` — shape of `f_credit_ascent`. |
| `descent_curve` | — | `CurveShape h` — shape of `f_price_descent`. |
| `price_function` | — | `PriceFunction` — shape of `f_next_rent_price`. |

All fields are private. Access via getters only.


3. CONSTRUCTOR
--------------

### Signature

    public fun new(
        min_rent_price:  u64,
        tenure_ceiling:  u64,
        handover_floor:  u64,
        descent_ceiling: u64,
        retire_floor:    u64,
        credit_curve:    CurveShape,
        descent_curve:   CurveShape,
        price_function:  PriceFunction,
    ): IntegrationConfig

### Visibility

`public` — callable from anywhere, including by `rental_escrow::integrate`.
Not directly callable from PTBs in practice: `CurveShape` and `PriceFunction`
values are constructed via `curve` constructors which are `public(package)`,
so callers outside the package cannot build the arguments.

### Validation (in order)

    assert!(min_rent_price > 0,                       E_MIN_RENT_PRICE_ZERO)
    assert!(tenure_ceiling > 0,                       E_TENURE_CEILING_ZERO)
    assert!(handover_floor > 0,                       E_HANDOVER_FLOOR_ZERO)
    assert!(handover_floor <= tenure_ceiling,          E_HANDOVER_FLOOR_EXCEEDS_TENURE)
    assert!(descent_ceiling > 0,                      E_DESCENT_CEILING_ZERO)

Logistic-specific upper-bound checks (cross-field, curve × time).
Expressed as pattern matches — the idiomatic Move 2024 form:

    match (&credit_curve) {
        CurveShape::Logistic =>
            assert!(tenure_ceiling <= u64::MAX / 12, E_TENURE_TOO_LARGE_FOR_LOGISTIC),
        _ => (),
    };
    match (&descent_curve) {
        CurveShape::Logistic =>
            assert!(descent_ceiling <= u64::MAX / 12, E_DESCENT_TOO_LARGE_FOR_LOGISTIC),
        _ => (),
    };

**Rationale for Logistic checks:** `eval_logistic` (curve §8) computes
`LOGISTIC_K * (two_t - t_max)` where `two_t = 2 * t` and `t_max` is
`tenure_ceiling` (or `descent_ceiling`). The binding overflow constraint is
`t_max ≤ u64::MAX / LOGISTIC_K = u64::MAX / 12`. This is the only case where
a curve type imposes a constraint on a time parameter — all other variants
impose no additional bounds beyond `> 0`.

No validation is performed on `credit_curve`, `descent_curve`, or
`price_function` field internals — those were validated by their constructors
in `curve`.

### Return

On success, returns an `IntegrationConfig` with all fields set to the provided
values. No implicit defaults.


4. GETTERS
----------

One `public` getter per field. All take `&IntegrationConfig`.

    public fun min_rent_price(cfg: &IntegrationConfig): u64
    public fun tenure_ceiling(cfg: &IntegrationConfig): u64
    public fun handover_floor(cfg: &IntegrationConfig): u64
    public fun descent_ceiling(cfg: &IntegrationConfig): u64
    public fun retire_floor(cfg: &IntegrationConfig): u64
    public fun credit_curve(cfg: &IntegrationConfig): &CurveShape
    public fun descent_curve(cfg: &IntegrationConfig): &CurveShape
    public fun price_function(cfg: &IntegrationConfig): &PriceFunction

Scalar fields (`u64`) are returned by value (copy). Curve and price function
fields are returned by immutable reference (no `copy` needed at call sites).

No setter exists. `IntegrationConfig` is write-once.


5. PROPERTIES
-------------

The following hold for any `IntegrationConfig` successfully constructed via
`new` — they are invariants the rest of the protocol may rely on without
re-checking.

**P1 — Price floor positive:**
    cfg.min_rent_price > 0

**P2 — Time parameters positive:**
    cfg.tenure_ceiling > 0
    cfg.handover_floor > 0
    cfg.descent_ceiling > 0

**P3 — Handover contained within tenure:**
    cfg.handover_floor <= cfg.tenure_ceiling

**P4 — Logistic overflow safety:**
    if cfg.credit_curve == CurveShape::Logistic  →  cfg.tenure_ceiling  <= u64::MAX / 12
    if cfg.descent_curve == CurveShape::Logistic →  cfg.descent_ceiling <= u64::MAX / 12

**P5 — retire_floor is unrestricted:**
    cfg.retire_floor can be 0 (no restriction) or any u64 value.
    0 means the owner may call `retire()` immediately after integration.

**P6 — Getters are consistent:**
    For all fields f: getter_f(new(..., f, ...)) == f
    (Constructors store values as-is; no normalization occurs in `config`.)


6. TEST CASES
-------------

Format: `new(min_rent_price, tenure_ceiling, handover_floor, descent_ceiling, retire_floor, credit_curve, descent_curve, price_function)`

Curve values use shorthand: `Lin` = `linear()`, `Smt` = `smoothstep()`,
`Pow(n,d)` = `power_law(n, d)`, `Exp(a,neg)` = `exponential(a, neg)`,
`Log` = `logistic()`.
Price function: `FD(d)` = `fixed_delta(d)`, `CD(bps,d)` = `compound_delta(bps, d)`.

### 6.1 Valid inputs (must not abort)

| # | min_rent_price | tenure_ceiling | handover_floor | descent_ceiling | retire_floor | credit_curve | descent_curve | price_function | Notes |
|---|---|---|---|---|---|---|---|---|---|
| V1 | 1 | 1 | 1 | 1 | 0 | Lin | Lin | FD(1) | Minimal valid config. handover_floor == tenure_ceiling. |
| V2 | 1_000_000 | 86_400_000 | 3_600_000 | 43_200_000 | 0 | Lin | Lin | FD(1) | Typical: 1h handover in 24h tenure, 12h auction. |
| V3 | 100 | 10_000 | 5_000 | 10_000 | 7_200_000 | Smt | Smt | FD(10) | retire_floor > 0. |
| V4 | 50 | 100_000 | 1 | 50_000 | 0 | Pow(1,2) | Lin | FD(1) | handover_floor = 1 (minimum). |
| V5 | 1 | u64::MAX / 12 | 1 | 1 | 0 | Log | Lin | FD(1) | Logistic credit_curve at exact upper bound for tenure_ceiling. |
| V6 | 1 | 1 | 1 | u64::MAX / 12 | 0 | Lin | Log | FD(1) | Logistic descent_curve at exact upper bound for descent_ceiling. |
| V7 | 1 | u64::MAX / 12 | 1 | u64::MAX / 12 | 0 | Log | Log | FD(1) | Both curves Logistic at upper bound. |
| V8 | u64::MAX | 1_000 | 500 | 1_000 | 0 | Exp(3,false) | Exp(3,true) | FD(1) | max min_rent_price, mixed Exp curves. |
| V9 | 1 | u64::MAX | 1 | u64::MAX | 0 | Lin | Lin | FD(1) | Non-Logistic curves have no upper bound on time parameters. |

### 6.2 Invalid inputs (must abort with stated error code)

| # | Input description | Expected abort |
|---|---|---|
| I1 | min_rent_price = 0 | E_MIN_RENT_PRICE_ZERO (0) |
| I2 | tenure_ceiling = 0 | E_TENURE_CEILING_ZERO (1) |
| I3 | handover_floor = 0 | E_HANDOVER_FLOOR_ZERO (2) |
| I4 | handover_floor > tenure_ceiling (e.g. floor=100, ceiling=50) | E_HANDOVER_FLOOR_EXCEEDS_TENURE (3) |
| I5 | descent_ceiling = 0 | E_DESCENT_CEILING_ZERO (4) |
| I6 | credit_curve = Logistic, tenure_ceiling = u64::MAX / 12 + 1 | E_TENURE_TOO_LARGE_FOR_LOGISTIC (5) |
| I7 | descent_curve = Logistic, descent_ceiling = u64::MAX / 12 + 1 | E_DESCENT_TOO_LARGE_FOR_LOGISTIC (6) |
| I8 | credit_curve = Logistic, tenure_ceiling = u64::MAX | E_TENURE_TOO_LARGE_FOR_LOGISTIC (5) |

### 6.3 Getter round-trip (must hold for all valid configs)

For any config `c` produced by `new(mrp, tc, hf, dsc, rf, g, h, pf)`:
    min_rent_price(&c)  == mrp
    tenure_ceiling(&c)  == tc
    handover_floor(&c)  == hf
    descent_ceiling(&c) == dsc
    retire_floor(&c)    == rf
    credit_curve(&c)    == &g
    descent_curve(&c)   == &h
    price_function(&c)  == &pf

### 6.4 Logistic boundary precision

The boundary `u64::MAX / 12` uses integer (floor) division.
`u64::MAX = 18_446_744_073_709_551_615`.
`u64::MAX / 12 = 1_537_228_672_809_129_301`.

- V5/V6/V7 use exactly `1_537_228_672_809_129_301` — must not abort.
- I6 uses `1_537_228_672_809_129_302` — must abort with E_TENURE_TOO_LARGE_FOR_LOGISTIC.


7. MODULE BOUNDARY
------------------

`config.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `E_MIN_RENT_PRICE_ZERO: u64 = 0` | `public` | SDK error handling. |
| `E_TENURE_CEILING_ZERO: u64 = 1` | `public` | SDK error handling. |
| `E_HANDOVER_FLOOR_ZERO: u64 = 2` | `public` | SDK error handling. |
| `E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 3` | `public` | SDK error handling. |
| `E_DESCENT_CEILING_ZERO: u64 = 4` | `public` | SDK error handling. |
| `E_TENURE_TOO_LARGE_FOR_LOGISTIC: u64 = 5` | `public` | SDK error handling. |
| `E_DESCENT_TOO_LARGE_FOR_LOGISTIC: u64 = 6` | `public` | SDK error handling. |
| `IntegrationConfig` (type) | `public` | Embedded in `RentalEscrow`. |
| `new(...)` | `public` | Validated constructor. |
| `min_rent_price(cfg)` | `public` | Getter — returns `u64`. |
| `tenure_ceiling(cfg)` | `public` | Getter — returns `u64`. |
| `handover_floor(cfg)` | `public` | Getter — returns `u64`. |
| `descent_ceiling(cfg)` | `public` | Getter — returns `u64`. |
| `retire_floor(cfg)` | `public` | Getter — returns `u64`. |
| `credit_curve(cfg)` | `public` | Getter — returns `&CurveShape`. |
| `descent_curve(cfg)` | `public` | Getter — returns `&CurveShape`. |
| `price_function(cfg)` | `public` | Getter — returns `&PriceFunction`. |

No private helpers. All logic is in `new`.

**SDK note:** `new` is `public` but not directly reachable from a PTB in
isolation — it requires `CurveShape` and `PriceFunction` arguments that are
only constructible via `curve` functions which are `public(package)`. The SDK
wraps the full integration flow into a single PTB via `rental_escrow::integrate`,
keeping `IntegrationConfig`, `CurveShape`, and `PriceFunction` as
implementation details invisible to the integrator. Error constants are `public`
so the SDK can map abort codes to human-readable messages.

**Depends on:** `curve` (type imports only — `CurveShape`, `PriceFunction`).
