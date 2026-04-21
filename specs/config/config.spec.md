CONFIG MODULE — SPECIFICATION
==============================

Module: `config`
Design reference: design-compact.md §6
Module map reference: module-map.spec.md §3
Depends on: `curve_shape`, `price_function`


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
- `IntegrationConfigRegistered` — event struct capturing the full parameter
  snapshot at integration time, keyed by `escrow_id`.
- `emit_registration(cfg, escrow_id)` — `public(package)` emitter called from
  `rental_escrow::integrate` once the escrow ID is known. Split from
  `new_config` because the config is built in the PTB before the escrow
  exists, so the ID cannot be captured inside the constructor.

**Does not own:**

- `CurveShape` and `PriceFunction` construction or evaluation — those live in
  `curve_shape` / `price_function`. `config::new_config` receives already-constructed
  values and does not re-validate their internal fields.
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
    public const E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2;  // handover_floor > tenure_ceiling
    public const E_DESCENT_CEILING_ZERO:          u64 = 3;  // descent_ceiling == 0


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
  Consequence: at retirement, `claim_asset` destroys `RentalEscrow` and
  `IntegrationConfig` is discarded implicitly — no explicit destructuring required.
- `copy` — config is immutable data; all fields have `copy`. Enables reading a
  config from one escrow to construct another with identical parameters.

**Field semantics:**

| Field | Unit | Meaning |
|---|---|---|
| `min_rent_price` | payment token base denomination | Price floor. Idle entry price; Dutch Auction lower bound. |
| `tenure_ceiling` | milliseconds | Fixed duration of each rental block. |
| `handover_floor` | milliseconds | Bidding window after a takeover bid. `0` = handover fires immediately — no competitive bidding window. |
| `descent_ceiling` | milliseconds | Maximum Dutch Auction duration. |
| `retire_floor` | milliseconds | Minimum time since integration before `retire()` may execute. `0` = no restriction — owner may retire immediately. An on-chain commitment to tenants: the asset cannot exit during this window regardless of state. |
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
    assert!(handover_floor <= tenure_ceiling, E_HANDOVER_FLOOR_EXCEEDS_TENURE)
    assert!(descent_ceiling > 0,             E_DESCENT_CEILING_ZERO)
    // retire_floor >= 0 is trivially satisfied for u64 — no error constant needed.

No validation is performed on `credit_curve`, `descent_curve`, or
`price_function` field internals — those were validated by their constructors
in `curve_shape` / `price_function`.

### Return

On success, returns an `IntegrationConfig` with all fields set to the provided
values. No implicit defaults.


### `retire_floor` — design rationale

At first glance, `retire_floor` is counter-incentivized: the owner who sets it is
the same actor who pays the cost — a self-imposed restriction on their own exit
flexibility — with no direct benefit to themselves. An owner acting purely in
self-interest would set `retire_floor = 0`.

The value of `retire_floor` is not for the owner; it is a credible commitment to
potential tenants. For most assets, the rental price is market-driven and tenant
trust in the owner's continuity of participation is not a prerequisite for
engagement. But certain categories of asset derive a material fraction of their
rental value from the guarantee that the owner will not withdraw arbitrarily:

- **Protocol admin caps** — a tenant considering renting an `adminCap` needs
  assurance that the rental market will remain active for a meaningful period.
  Without `retire_floor`, the owner could retire immediately from `Idle` or
  `AtDutchAuction` between tenures, collapsing the market arbitrarily. A
  `retire_floor` commitment gives prospective tenants confidence that the
  opportunity to acquire the cap will persist for a minimum horizon.
- **Yield-bearing rights** — assets representing ongoing revenue streams (e.g. a
  claim on protocol fees or staking rewards) are worth more to a tenant when the
  owner commits to keeping the yield source active inside the protocol for a
  minimum horizon.
- **Time-sensitive or expiring assets** — assets whose value decays or terminates
  at a known future date (e.g. a governance vote right, an option-like position)
  benefit from an owner commitment that prevents early withdrawal before the value
  event occurs, making the rental market viable for tenants who need certainty over
  that window.

In these cases, an owner who sets a meaningful `retire_floor` signals verifiable
on-chain commitment — not reputation, not terms-of-service, but an immutable
parameter in the shared object that any participant can read. This can increase
asset valorization by expanding the pool of tenants willing to engage.

`retire_floor = 0` remains valid and is the correct default for owners who do not
need to signal this commitment.


### `handover_floor` — design rationale

`handover_floor` serves two simultaneous functions:

**1. Time guarantee for the displaced tenant.** When a new tenant displaces the
current one, the current tenant retains full access to the asset for exactly
`handover_floor` (bounded by remaining tenure time). This window is known and
fixed at integration time — the current tenant entered their position knowing
how much time they are guaranteed before any handover can execute. It makes
rational entry possible at any point in the rental cycle: a tenant never faces
instant, unannounced displacement.

**2. Competitive bidding window.** During the `handover_floor` window, any actor
may supersede the pending bid by paying at least `next_rent_price`. The
`handover_countdown_expiry` does not reset with each supersede — it runs to
completion regardless. Access transfers to the **last** valid bidder when it
expires. This creates a price discovery window where future tenants compete
against each other, driving the price upward before the handover settles.

These two functions are inseparable: the same window that protects the displaced
tenant is the window that enables competitive price discovery.

**Special cases:**

- **`handover_floor = 0`** — the handover fires immediately on bid. No time
  guarantee for the displaced tenant; no competitive bidding window. The first
  bidder at `next_rent_price` wins instantly. Suitable for integrators who do not
  need either guarantee and want fully frictionless displacement.

- **`handover_floor > 0`** — the standard configuration. Both guarantees are
  active. The size of `handover_floor` controls the trade-off between tenant
  stability (larger = more protection for the current tenant) and market
  responsiveness (smaller = faster rotation).

- **`handover_floor = tenure_ceiling`** — the current tenant is guaranteed their
  full block before any handover can execute. A new tenant pays `next_rent_price`
  and waits for the entire remaining tenure before gaining access. This replicates
  traditional fixed-term renting — a sequential queue of full blocks — while
  retaining all liquid renting mechanics: price escalation, fee distribution,
  and the Dutch Auction on tenure expiry. `remain_credit` is always zero at
  handover in this configuration — the full block is consumed before access transfers. The protocol
  does not special-case this; it emerges naturally from the parameter choice.


4. EVENT AND EMITTER
--------------------

### `IntegrationConfigRegistered` — event

Emitted exactly once per integration, at `rental_escrow::integrate` time,
after the escrow is constructed and before it is shared. Carries a full
snapshot of the immutable parameters the integrator committed to, keyed
by `escrow_id`.

```move
public struct IntegrationConfigRegistered has copy, drop {
    escrow_id:       ID,
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

**Abilities:** `copy + drop` — required by `event::emit`. `CurveShape` and
`PriceFunction` both have `copy + drop`, so the whole struct satisfies the
Sui event verifier.

**Field semantics:** each scalar and curve field mirrors the corresponding
`IntegrationConfig` field by value (see §2 for units and meaning).
`escrow_id` is the root FK that ties this row to every other event for the
same escrow; it is the protocol's uniform schema anchor (see
`rental_escrow.spec.md §3` — "Star schema").

**Star-schema role.** `IntegrationConfigRegistered` is a **1:1 satellite
dimension** of the `escrows` fact table, emitted exactly once per escrow at
integration and never again (configs are immutable; no burn / update event
exists). It carries no child PK of its own — the config has no UID — so the
only key is `escrow_id`.

**Why emit all parameters at once.** The off-chain indexer needs to know
*which parameter combinations produce good liquid-renting mechanics*. A
single event carrying the full snapshot lets analytical queries group
escrows by any parameter (e.g. `WHERE tenure_ceiling > X`) without reading
the on-chain object. Splitting the snapshot across multiple events would
force envelope-timing joins — disallowed by star-schema invariant (d).

### `emit_registration` — function

```move
public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID)
```

**Visibility:** `public(package)` — only `rental_escrow::integrate` is
expected to call it. Not exposed to PTBs: an integrator cannot emit a
registration event decoupled from an actual escrow construction.

**Behavior:** reads every field of `cfg` and emits a single
`IntegrationConfigRegistered` event with those values plus `escrow_id`. No
validation (inputs were already validated by `new_config`; `escrow_id` is
authoritative — it comes from `object::uid_to_inner` inside `integrate`).
No state mutation.

**Why split from `new_config`.** `new_config` runs in the PTB *before*
`rental_escrow::integrate` — there is no `escrow_id` yet. The only other
option would be to fold construction + emission into a single
escrow-scoped call, which would break PTB composability (integrators could
no longer build `CurveShape` / `PriceFunction` / `IntegrationConfig`
independently). The split follows the same pattern as
`fee_message::new(...)` + `send_message(msg, tenant)`: pure builder,
separate emitter called at the point the contextual data becomes known.

**Emit-last compliance.** Called from `rental_escrow::integrate` *after*
the escrow has been constructed with `config` embedded (so the config↔
escrow_id binding is a realized semantic fact) and *before* `share_object`
consumes the escrow value. Placing the call any earlier would emit before
the semantic operation the event describes.


5. GETTERS
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
fields are returned by immutable reference. Rationale: if `CurveShape` or
`PriceFunction` lost `copy` in the future, `IntegrationConfig` would also lose
`copy` (a struct cannot have abilities its fields lack) — but reference-returning
getters would remain valid without signature changes.

No setter exists. `IntegrationConfig` is write-once.


6. PROPERTIES
-------------

The following hold for any `IntegrationConfig` successfully constructed via
`new_config` — they are invariants the rest of the protocol may rely on without
re-checking.

**P1 — Price floor positive:**
    cfg.min_rent_price > 0

**P2 — Time parameters positive (except handover_floor):**
    cfg.tenure_ceiling > 0
    cfg.handover_floor >= 0   (0 = no bidding window — handover fires immediately)
    cfg.descent_ceiling > 0

**P3 — Handover contained within tenure:**
    cfg.handover_floor <= cfg.tenure_ceiling

**P4 — retire_floor is unrestricted:**
    cfg.retire_floor can be 0 (no restriction) or any u64 value.
    0 means the owner may call `retire()` immediately after integration.

**P5 — Getters are consistent:**
    For all fields f: getter_f(new_config(..., f, ...)) == f
    (Constructor stores values as-is; no normalization occurs in `config`.)


7. TEST CASES
-------------

Format: `new_config(min_rent_price, tenure_ceiling, handover_floor, descent_ceiling, retire_floor, credit_curve, descent_curve, price_function)`

Curve values use shorthand: `Lin` = `new_linear()`, `Smt` = `new_smoothstep()`,
`Pow(n,d)` = `new_power_law(n, d)`, `Exp(a,neg)` = `new_exponential(a, neg)`,
`Log` = `new_logistic()`.
Price function: `FD(d)` = `new_fixed_delta(d)`, `CD(bps,d)` = `new_compound_delta(bps, d)`.

### 6.1 Valid inputs (must not abort)

| # | min_rent_price | tenure_ceiling | handover_floor | descent_ceiling | retire_floor | credit_curve | descent_curve | price_function | Notes |
|---|---|---|---|---|---|---|---|---|---|
| V1 | 1 | 1 | 0 | 1 | 0 | Lin | Lin | FD(1) | Minimal valid config. handover_floor = 0 (immediate handover). |
| V2 | 1_000_000 | 86_400_000 | 3_600_000 | 43_200_000 | 0 | Lin | Lin | FD(1) | Typical: 1h handover in 24h tenure, 12h auction, no retire floor. |
| V3 | 100 | 10_000 | 5_000 | 10_000 | 7_200_000 | Smt | Smt | FD(10) | retire_floor = 2h — owner commits to keeping asset in escrow for 2h. |
| V4 | 50 | 100_000 | 0 | 50_000 | 0 | Pow(1,2) | Lin | FD(1) | handover_floor = 0 (no bidding window). |
| V5 | u64::MAX | 1_000 | 500 | 1_000 | 0 | Exp(3,false) | Exp(3,true) | FD(1) | max min_rent_price, mixed Exp curves. |
| V6 | 1 | u64::MAX | 1 | u64::MAX | u64::MAX | Log | Log | FD(1) | No upper bound on time parameters — including retire_floor. |
| V7 | 1_000 | 86_400_000 | 3_600_000 | 43_200_000 | 0 | Lin | Lin | CD(500,100) | CompoundDelta price function: 5% + 100 base units per cycle. |

**Note — unconstrained free variables:** `tenure_ceiling`, `descent_ceiling`,
and `retire_floor` have no upper bound. Absurd values (e.g. `u64::MAX`) are
accepted by `new_config`; any resulting arithmetic overflow surfaces at runtime
inside `curve` or `rental_escrow` via Move's checked arithmetic. Adding upper
bounds here would be the same mistake as the removed Logistic constraint —
validation noise for inputs that never occur in practice.

### 6.2 Invalid inputs (must abort with stated error code)

| # | Input description | Expected abort |
|---|---|---|
| I1 | min_rent_price = 0 | E_MIN_RENT_PRICE_ZERO (0) |
| I2 | tenure_ceiling = 0 | E_TENURE_CEILING_ZERO (1) |
| I3 | handover_floor > tenure_ceiling (e.g. floor=100, ceiling=50) | E_HANDOVER_FLOOR_EXCEEDS_TENURE (2) |
| I4 | descent_ceiling = 0 | E_DESCENT_CEILING_ZERO (3) |

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


8. MODULE BOUNDARY
------------------

`config.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `E_MIN_RENT_PRICE_ZERO: u64 = 0` | `public` | SDK error handling. |
| `E_TENURE_CEILING_ZERO: u64 = 1` | `public` | SDK error handling. |
| `E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2` | `public` | SDK error handling. |
| `E_DESCENT_CEILING_ZERO: u64 = 3` | `public` | SDK error handling. |
| `IntegrationConfig` (type) | `public` | `copy + drop + store`. Embedded in `RentalEscrow`. |
| `IntegrationConfigRegistered` (type) | `public` | Event. `copy + drop`. Emitted once at integration time. |
| `new_config(...)` | `public` | Validated constructor. |
| `emit_registration(cfg, escrow_id)` | `public(package)` | Emits `IntegrationConfigRegistered`. Called from `rental_escrow::integrate` after escrow construction. |
| `min_rent_price(cfg)` | `public(package)` | Getter — returns `u64`. |
| `tenure_ceiling(cfg)` | `public(package)` | Getter — returns `u64`. |
| `handover_floor(cfg)` | `public(package)` | Getter — returns `u64`. |
| `descent_ceiling(cfg)` | `public(package)` | Getter — returns `u64`. |
| `retire_floor(cfg)` | `public(package)` | Getter — returns `u64`. |
| `credit_curve(cfg)` | `public(package)` | Getter — returns `&CurveShape`. |
| `descent_curve(cfg)` | `public(package)` | Getter — returns `&CurveShape`. |
| `price_function(cfg)` | `public(package)` | Getter — returns `&PriceFunction`. |

No private helpers. All logic is in `new_config` and `emit_registration`.

**Integration flow:** an integrator calls `curve_shape` and `price_function` constructors
to build `CurveShape` and `PriceFunction` values, then calls `new_config` to get an
`IntegrationConfig`, then passes it to `rental_escrow::integrate`. All three
layers are `public` and composable from a PTB. Error constants are `public`
so the SDK can map abort codes to human-readable messages.

**Depends on:** `curve_shape`, `price_function` (type imports only — `CurveShape`, `PriceFunction`).
