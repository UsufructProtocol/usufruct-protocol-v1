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

- `IntegrationConfig` — plain data struct (`copy + drop + store`, no `key`).
  No UID. Not a shared object. Embedded field inside `RentalEscrow`.
- `new_config(...)` — the sole constructor. `public`. Validates all protocol
  invariants and aborts on any violation.
- One `public(package)` getter per field. Return immutable references or copy values.

**Does not own:**

- `CurveShape` and `PriceFunction` construction or evaluation — those live in
  `curve`. `config::new_config` receives already-constructed values and does not
  re-validate their internal fields.
- Protocol state, fund movements, or capability objects.
- Any Sui framework object operations (no `object::new`, no `transfer`).

**Dependency direction:** `config` calls no `curve` module functions.
It stores `CurveShape` and `PriceFunction` values.
`rental_escrow` calls `config::new_config` and the getters.


1. ERROR CONSTANTS
------------------

All validation aborts originate in `new_config`. Constants are `public` so the SDK
can map abort codes to human-readable messages (same convention as `curve`).

    public const E_MIN_RENT_PRICE_ZERO:           u64 = 0;  // min_rent_price == 0
    public const E_TENURE_CEILING_ZERO:           u64 = 1;  // tenure_ceiling == 0
    public const E_HANDOVER_FLOOR_ZERO:           u64 = 2;  // handover_floor == 0
    public const E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 3;  // handover_floor > tenure_ceiling
    public const E_DESCENT_CEILING_ZERO:          u64 = 4;  // descent_ceiling == 0

`retire_floor >= 0` is trivially satisfied for `u64` — no error constant needed.


2. TYPE
-------

### IntegrationConfig — struct

Bundles all immutable parameters for one integration instance.

```move
public struct IntegrationConfig has copy, drop, store {
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

**Abilities:** `copy + drop + store`.
- No `key` — not an object; embedded inside `RentalEscrow`.
- `drop` — all fields have `drop` (u64, CurveShape, PriceFunction). No assets to
  protect; omitting `drop` would add boilerplate with no safety benefit.
- `copy` — config is immutable data; all fields have `copy`. Enables reading a
  config from one escrow to construct another with identical parameters.

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

    public fun new_config(
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

`public` — callable from PTBs. Integrators build `CurveShape` and `PriceFunction`
values via `curve` constructors (also `public`), then pass them to `new_config`.

### Validation (in order)

    assert!(min_rent_price > 0,              E_MIN_RENT_PRICE_ZERO)
    assert!(tenure_ceiling > 0,              E_TENURE_CEILING_ZERO)
    assert!(handover_floor > 0,              E_HANDOVER_FLOOR_ZERO)
    assert!(handover_floor <= tenure_ceiling, E_HANDOVER_FLOOR_EXCEEDS_TENURE)
    assert!(descent_ceiling > 0,             E_DESCENT_CEILING_ZERO)

No validation is performed on `credit_curve`, `descent_curve`, or
`price_function` field internals — those were validated by their constructors
in `curve`.

### Return

On success, returns an `IntegrationConfig` with all fields set to the provided
values. No implicit defaults.


4. GETTERS
----------

One `public(package)` getter per field. All take `&IntegrationConfig`.
External observers read field values on-chain directly; only `rental_escrow`
needs these in Move code.

    public(package) fun min_rent_price(cfg: &IntegrationConfig): u64
    public(package) fun tenure_ceiling(cfg: &IntegrationConfig): u64
    public(package) fun handover_floor(cfg: &IntegrationConfig): u64
    public(package) fun descent_ceiling(cfg: &IntegrationConfig): u64
    public(package) fun retire_floor(cfg: &IntegrationConfig): u64
    public(package) fun credit_curve(cfg: &IntegrationConfig): &CurveShape
    public(package) fun descent_curve(cfg: &IntegrationConfig): &CurveShape
    public(package) fun price_function(cfg: &IntegrationConfig): &PriceFunction

Scalar fields (`u64`) are returned by value (copy). Curve and price function
fields are returned by immutable reference (no `copy` needed at call sites).

No setter exists. `IntegrationConfig` is write-once.


5. PROPERTIES
-------------

The following hold for any `IntegrationConfig` successfully constructed via
`new_config` — they are invariants the rest of the protocol may rely on without
re-checking.

**P1 — Price floor positive:**
    cfg.min_rent_price > 0

**P2 — Time parameters positive:**
    cfg.tenure_ceiling > 0
    cfg.handover_floor > 0
    cfg.descent_ceiling > 0

**P3 — Handover contained within tenure:**
    cfg.handover_floor <= cfg.tenure_ceiling

**P4 — retire_floor is unrestricted:**
    cfg.retire_floor can be 0 (no restriction) or any u64 value.
    0 means the owner may call `retire()` immediately after integration.

**P5 — Getters are consistent:**
    For all fields f: getter_f(new_config(..., f, ...)) == f
    (Constructor stores values as-is; no normalization occurs in `config`.)


6. TEST CASES
-------------

Format: `new_config(min_rent_price, tenure_ceiling, handover_floor, descent_ceiling, retire_floor, credit_curve, descent_curve, price_function)`

Curve values use shorthand: `Lin` = `new_linear()`, `Smt` = `new_smoothstep()`,
`Pow(n,d)` = `new_power_law(n, d)`, `Exp(a,neg)` = `new_exponential(a, neg)`,
`Log` = `new_logistic()`.
Price function: `FD(d)` = `new_fixed_delta(d)`, `CD(bps,d)` = `new_compound_delta(bps, d)`.

### 6.1 Valid inputs (must not abort)

| # | min_rent_price | tenure_ceiling | handover_floor | descent_ceiling | retire_floor | credit_curve | descent_curve | price_function | Notes |
|---|---|---|---|---|---|---|---|---|---|
| V1 | 1 | 1 | 1 | 1 | 0 | Lin | Lin | FD(1) | Minimal valid config. handover_floor == tenure_ceiling. |
| V2 | 1_000_000 | 86_400_000 | 3_600_000 | 43_200_000 | 0 | Lin | Lin | FD(1) | Typical: 1h handover in 24h tenure, 12h auction. |
| V3 | 100 | 10_000 | 5_000 | 10_000 | 7_200_000 | Smt | Smt | FD(10) | retire_floor > 0. |
| V4 | 50 | 100_000 | 1 | 50_000 | 0 | Pow(1,2) | Lin | FD(1) | handover_floor = 1 (minimum). |
| V5 | u64::MAX | 1_000 | 500 | 1_000 | 0 | Exp(3,false) | Exp(3,true) | FD(1) | max min_rent_price, mixed Exp curves. |
| V6 | 1 | u64::MAX | 1 | u64::MAX | 0 | Log | Log | FD(1) | No upper bound on time parameters — including Logistic. |

### 6.2 Invalid inputs (must abort with stated error code)

| # | Input description | Expected abort |
|---|---|---|
| I1 | min_rent_price = 0 | E_MIN_RENT_PRICE_ZERO (0) |
| I2 | tenure_ceiling = 0 | E_TENURE_CEILING_ZERO (1) |
| I3 | handover_floor = 0 | E_HANDOVER_FLOOR_ZERO (2) |
| I4 | handover_floor > tenure_ceiling (e.g. floor=100, ceiling=50) | E_HANDOVER_FLOOR_EXCEEDS_TENURE (3) |
| I5 | descent_ceiling = 0 | E_DESCENT_CEILING_ZERO (4) |

### 6.3 Getter round-trip (must hold for all valid configs)

Verifies that every value passed to `new_config` is returned unchanged by its
getter — the constructor does not transform, normalize, or discard any field.

For any config `c` produced by `new_config(mrp, tc, hf, dsc, rf, g, h, pf)`:
    min_rent_price(&c)  == mrp
    tenure_ceiling(&c)  == tc
    handover_floor(&c)  == hf
    descent_ceiling(&c) == dsc
    retire_floor(&c)    == rf
    credit_curve(&c)    == &g
    descent_curve(&c)   == &h
    price_function(&c)  == &pf

Note on `CurveShape`: `new_power_law` normalizes by gcd before storing, so the
round-trip holds against the reduced value, not the raw arguments:

    g = new_power_law(2, 4)          // stored as PowerLaw { alpha_num: 1, alpha_den: 2 }
    credit_curve(&c) == &g           // &PowerLaw { 1, 2 } — correct
    credit_curve(&c) == &PowerLaw { alpha_num: 2, alpha_den: 4 }  // WRONG


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
| `IntegrationConfig` (type) | `public` | `copy + drop + store`. Embedded in `RentalEscrow`. |
| `new_config(...)` | `public` | Validated constructor. |
| `min_rent_price(cfg)` | `public(package)` | Getter — returns `u64`. |
| `tenure_ceiling(cfg)` | `public(package)` | Getter — returns `u64`. |
| `handover_floor(cfg)` | `public(package)` | Getter — returns `u64`. |
| `descent_ceiling(cfg)` | `public(package)` | Getter — returns `u64`. |
| `retire_floor(cfg)` | `public(package)` | Getter — returns `u64`. |
| `credit_curve(cfg)` | `public(package)` | Getter — returns `&CurveShape`. |
| `descent_curve(cfg)` | `public(package)` | Getter — returns `&CurveShape`. |
| `price_function(cfg)` | `public(package)` | Getter — returns `&PriceFunction`. |

No private helpers. All logic is in `new_config`.

**Integration flow:** an integrator calls `curve` constructors to build
`CurveShape` and `PriceFunction` values, then calls `new_config` to get an
`IntegrationConfig`, then passes it to `rental_escrow::integrate`. All three
layers are `public` and composable from a PTB. Error constants are `public`
so the SDK can map abort codes to human-readable messages.

**Depends on:** `curve` (type imports only — `CurveShape`, `PriceFunction`).
