CONFIG MODULE — SPECIFICATION
==============================

Module: `config`
Design reference: design-compact.md §6
Module map reference: module-map.spec.md §3
Depends on: `curve_shape`, `price_function`


0. MODULE RESPONSIBILITY
------------------------

`config` owns the `IntegrationConfig` struct, the three policy enums that
parameterize its behavioral modes, their validated constructors, and the
dispatch helpers that turn policy variants into the timestamps and
durations the rest of the protocol consumes. It bundles all immutable
integration parameters into a single value that is embedded inside
`RentalEscrow` at integration time and never mutated again.

**Owns:**

- `IntegrationConfig` — plain data struct (`copy + drop + store`, no
  `key`). No UID. Not a shared object. Embedded field inside
  `RentalEscrow`.
- `HandoverPolicy`, `DescentPolicy`, `RetirePolicy` — three behavioral
  enums whose variants name the protocol modes the spec identifies as
  orthogonal axes (see `rental_escrow.spec.md §10.0` corpus subsection).
  All `copy + drop + store`.
- `new_config(...)` — the bundle constructor. `public`. Validates all
  protocol invariants and aborts on any violation.
- Variant constructors: `new_handover_instant`, `new_handover_countdown`,
  `new_handover_fixed_time`, `new_descent_skipped`, `new_descent_window`,
  `new_retire_immediate`, `new_retire_deferred`. All `public`. Each
  enforces the per-variant invariant required for the variant to be
  meaningful (e.g., `Countdown::new(0)` is rejected — the zero-countdown
  mode is `Instant`).
- One `public(package)` getter per field (scalar fields return by value;
  policy and curve fields return immutable references).
- Dispatch helpers — `public(package)` functions that consume a
  `&IntegrationConfig` plus a transient timestamp and return the
  protocol-relevant boundary or unlock value: `tenure_boundary`,
  `handover_expiry`, `descent_boundary`, `descent_window_ceiling`,
  `retire_unlock`. They encapsulate the saturation/dispatch rules that
  used to live inline at every call site in `rental_escrow`.
- `IntegrationConfigRegistered` — event struct capturing the full
  parameter snapshot at integration time, keyed by `escrow_id`.
- `emit_registration(cfg, escrow_id)` — `public(package)` emitter called
  from `rental_escrow::integrate` once the escrow ID is known. Split
  from `new_config` because the config is built in the PTB before the
  escrow exists, so the ID cannot be captured inside the constructor.

**Does not own:**

- `CurveShape` and `PriceFunction` construction or evaluation — those
  live in `curve_shape` / `price_function`. `config::new_config`
  receives already-constructed values and does not re-validate their
  internal fields.
- Protocol state, fund movements, or capability objects.
- Any Sui framework object operations (no `object::new`, no `transfer`).

**Dependency direction:** `config` calls no `curve` module functions.
It stores `CurveShape` and `PriceFunction` values. `rental_escrow` calls
`config::new_config`, the getters, and the dispatch helpers.


1. ERROR CONSTANTS
------------------

All validation aborts originate in `new_config` or the variant
constructors. Constants are `public` so the SDK can map abort codes to
human-readable messages.

    public const E_MIN_RENT_PRICE_ZERO:           u64 = 0;  // min_rent_price == 0
    public const E_TENURE_CEILING_ZERO:           u64 = 1;  // tenure_ceiling == 0
    public const E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2;  // Countdown.floor_ms >= tenure_ceiling
    public const E_HANDOVER_FLOOR_ZERO:           u64 = 3;  // new_handover_countdown(0) — use Instant
    public const E_DESCENT_CEILING_ZERO:          u64 = 4;  // new_descent_window(0)     — use Skipped
    public const E_RETIRE_FLOOR_ZERO:             u64 = 5;  // new_retire_deferred(0)    — use Immediate
    public const E_DESCENT_SKIPPED_NO_WINDOW:     u64 = 6;  // descent_window_ceiling on Skipped

`E_HANDOVER_FLOOR_EXCEEDS_TENURE` is now strict (`>=`, not `>`):
equality with `tenure_ceiling` is `HandoverPolicy::FixedTime`, a
separate variant — not the upper edge of `Countdown`. The variants are
disjoint: `Countdown { floor_ms }` requires `0 < floor_ms <
tenure_ceiling`; `Instant` is the `0` mode; `FixedTime` is the
`= tenure_ceiling` mode.


2. TYPES
--------

### HandoverPolicy — enum

Names the three modes of the bidding window.

```move
public enum HandoverPolicy has copy, drop, store {
    Instant,                          // no countdown — handover fires on bid
    Countdown { floor_ms: u64 },      // standard countdown; 0 < floor_ms < tenure_ceiling
    FixedTime,                        // saturated — countdown clamps to tenure boundary
}
```

**Variant semantics.** `Instant` collapses the bidding window to zero —
the first bidder at `next_rent_price` wins immediately, no competitive
phase. `Countdown { floor_ms }` is the standard configuration: the
window has duration `floor_ms`, bounded above by the remaining tenure
time. `FixedTime` is the saturation case where the countdown always
clamps to the tenure boundary — equivalent to traditional fixed-term
renting: the current tenant always finishes their full block before
any handover can execute. The three are qualitatively distinct
behavioral modes, not just different values of one parameter.

### DescentPolicy — enum

Names the two modes of the Dutch Auction window.

```move
public enum DescentPolicy has copy, drop, store {
    Skipped,                          // AtDutchAuction structurally unobservable
    Window { ceiling_ms: u64 },       // standard descent window; ceiling_ms > 0
}
```

**Variant semantics.** `Skipped` makes `AtDutchAuction` structurally
unobservable: `do_tenure_expiry` and `do_auction_expiry` co-emit at
identical timestamps in the same `apply_pending_transitions` call,
collapsing the cascade `HandoverOpen → Idle` (see
`rental_escrow.spec.md` Q11 / M6b). `Window { ceiling_ms }` is the
standard configuration with a real auction window of duration
`ceiling_ms`.

### RetirePolicy — enum

Names the two modes of the `retire()` time guard.

```move
public enum RetirePolicy has copy, drop, store {
    Immediate,                        // no time guard — retire() may execute any time
    Deferred { floor_ms: u64 },       // floor_ms > 0; retire blocked until that elapses
}
```

**Variant semantics.** `Immediate` removes the time guard entirely —
the owner may call `retire()` at any clock value. `Deferred { floor_ms
}` blocks `retire()` until `clock >= integrated_at_ms + floor_ms`,
producing an on-chain commitment to tenants that the asset cannot exit
the protocol within the deferred window.

### IntegrationConfig — struct

Bundles all immutable parameters for one integration instance.

```move
public struct IntegrationConfig has copy, drop, store {
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover:        HandoverPolicy,
    descent:         DescentPolicy,
    retire:          RetirePolicy,
    credit_curve:    CurveShape,
    descent_curve:   CurveShape,
    price_function:  PriceFunction,
}
```

**Abilities:** `copy + drop + store`.
- No `key` — not an object; embedded inside `RentalEscrow`.
- `drop` — all fields have `drop` (u64, the three policy enums,
  `CurveShape`, `PriceFunction`). No assets to protect.
- `copy` — config is immutable data; all fields have `copy`.

**Field semantics:**

| Field | Unit | Meaning |
|---|---|---|
| `min_rent_price` | payment token base denomination | Price floor. Idle entry price; Dutch Auction lower bound. |
| `tenure_ceiling` | milliseconds | Fixed duration of each rental block. |
| `handover` | `HandoverPolicy` | Mode of the bidding window after a takeover bid. See §2 enum semantics. |
| `descent` | `DescentPolicy` | Mode of the Dutch Auction window. See §2. |
| `retire` | `RetirePolicy` | Mode of the `retire()` time guard. See §2. |
| `credit_curve` | — | `CurveShape g` — shape of `f_credit_ascent`. |
| `descent_curve` | — | `CurveShape h` — shape of `f_price_descent`. |
| `price_function` | — | `PriceFunction` — shape of `f_next_rent_price`. |

All fields are private. Access via getters only.


3. CONSTRUCTORS
---------------

`config` exposes eight public constructors: seven variant constructors
for the three policy enums, and one bundle constructor `new_config`
that validates and assembles the `IntegrationConfig`.

### 3.1 Variant constructors

All `public` — callable from PTBs. Each enforces the per-variant
invariant required for the variant to be meaningful.

```move
public fun new_handover_instant():      HandoverPolicy
public fun new_handover_countdown(
    floor_ms: u64
): HandoverPolicy                                 // asserts floor_ms > 0
public fun new_handover_fixed_time():   HandoverPolicy

public fun new_descent_skipped():       DescentPolicy
public fun new_descent_window(
    ceiling_ms: u64
): DescentPolicy                                  // asserts ceiling_ms > 0

public fun new_retire_immediate():      RetirePolicy
public fun new_retire_deferred(
    floor_ms: u64
): RetirePolicy                                   // asserts floor_ms > 0
```

**Per-variant validation:**
- `new_handover_countdown(0)` aborts `E_HANDOVER_FLOOR_ZERO`. The
  zero-countdown mode is `Instant` — caller must use that variant.
- `new_descent_window(0)` aborts `E_DESCENT_CEILING_ZERO`. The
  zero-ceiling mode is `Skipped`.
- `new_retire_deferred(0)` aborts `E_RETIRE_FLOOR_ZERO`. The zero-floor
  mode is `Immediate`.

These keep the variants **disjoint** at construction time. A caller
cannot accidentally produce `Countdown { floor_ms: 0 }` and have it be
treated as "Instant" — the three modes are structurally distinct.

### 3.2 `new_config` — bundle constructor

#### Signature

    public fun new_config(
        min_rent_price: u64,
        tenure_ceiling: u64,
        handover:       HandoverPolicy,
        descent:        DescentPolicy,
        retire:         RetirePolicy,
        credit_curve:   CurveShape,
        descent_curve:  CurveShape,
        price_function: PriceFunction,
    ): IntegrationConfig

#### Visibility

`public` — callable from PTBs. Integrators build `CurveShape`,
`PriceFunction`, and the three policy values via their `public`
constructors, then pass them to `new_config`.

#### Validation (in order)

```
assert!(min_rent_price > 0, E_MIN_RENT_PRICE_ZERO);
assert!(tenure_ceiling > 0, E_TENURE_CEILING_ZERO);

// Re-validation of the variants — defense in depth, since direct enum
// construction (`Countdown { floor_ms: 0 }`) bypasses the convenience
// constructor's assertion. Cross-field constraint also enforced here.
match (&handover) {
    Countdown { floor_ms } => {
        assert!(*floor_ms > 0,              E_HANDOVER_FLOOR_ZERO);
        assert!(*floor_ms < tenure_ceiling, E_HANDOVER_FLOOR_EXCEEDS_TENURE);
    },
    Instant | FixedTime => (),
};
match (&descent) {
    Window { ceiling_ms } => assert!(*ceiling_ms > 0, E_DESCENT_CEILING_ZERO),
    Skipped              => (),
};
match (&retire) {
    Deferred { floor_ms } => assert!(*floor_ms > 0, E_RETIRE_FLOOR_ZERO),
    Immediate             => (),
};
```

Notes:
- The cross-field `Countdown.floor_ms < tenure_ceiling` is a strict
  inequality. Equality is `FixedTime`, not the upper edge of
  `Countdown`. The variants are disjoint by design.
- `descent_ceiling > tenure_ceiling` is allowed: no asserted ordering
  between the two — the protocol does not branch on the sign of
  `(descent_ceiling − tenure_ceiling)`.
- `retire = Deferred { floor_ms }` has no upper bound. Owners can
  signal arbitrarily long commitments.

No validation is performed on `credit_curve`, `descent_curve`, or
`price_function` field internals — those were validated by their
constructors in `curve_shape` / `price_function`.

#### Return

On success, returns an `IntegrationConfig` with all fields set to the
provided values. No implicit defaults.


### `RetirePolicy` — design rationale

At first glance, a `Deferred` policy is counter-incentivized: the owner
who sets it is the same actor who pays the cost — a self-imposed
restriction on their own exit flexibility — with no direct benefit to
themselves. An owner acting purely in self-interest would choose
`Immediate`.

The value of `Deferred` is not for the owner; it is a credible
commitment to potential tenants. For most assets, the rental price is
market-driven and tenant trust in the owner's continuity of
participation is not a prerequisite for engagement. But certain
categories of asset derive a material fraction of their rental value
from the guarantee that the owner will not withdraw arbitrarily:

- **Protocol admin caps** — a tenant considering renting an `adminCap`
  needs assurance that the rental market will remain active for a
  meaningful period. With `Immediate`, the owner could retire instantly
  from `Idle` or `AtDutchAuction` between tenures, collapsing the
  market arbitrarily. A `Deferred` commitment gives prospective tenants
  confidence that the opportunity to acquire the cap will persist for a
  minimum horizon.
- **Yield-bearing rights** — assets representing ongoing revenue
  streams (e.g. a claim on protocol fees or staking rewards) are worth
  more to a tenant when the owner commits to keeping the yield source
  active inside the protocol for a minimum horizon.
- **Time-sensitive or expiring assets** — assets whose value decays or
  terminates at a known future date (e.g. a governance vote right, an
  option-like position) benefit from an owner commitment that prevents
  early withdrawal before the value event occurs, making the rental
  market viable for tenants who need certainty over that window.

In these cases, an owner who chooses `Deferred { floor_ms }` signals
verifiable on-chain commitment — not reputation, not terms-of-service,
but an immutable parameter in the shared object that any participant
can read. This can increase asset valorization by expanding the pool of
tenants willing to engage.

`Immediate` remains valid and is the correct default for owners who do
not need to signal this commitment.


### `HandoverPolicy` — design rationale

`HandoverPolicy` serves two simultaneous functions:

**1. Time guarantee for the displaced tenant.** When a new tenant
displaces the current one, the current tenant retains full access to
the asset for exactly the handover countdown duration (bounded by
remaining tenure time). This window is known and fixed at integration
time — the current tenant entered their position knowing how much time
they are guaranteed before any handover can execute. It makes rational
entry possible at any point in the rental cycle: a tenant never faces
instant, unannounced displacement.

**2. Competitive bidding window.** During the handover countdown, any
actor may supersede the pending bid by paying at least
`next_rent_price`. The `handover_countdown_expiry` does not reset with
each supersede — it runs to completion regardless. Access transfers to
the **last** valid bidder when it expires. This creates a price
discovery window where future tenants compete against each other,
driving the price upward before the handover settles.

These two functions are inseparable: the same window that protects the
displaced tenant is the window that enables competitive price
discovery.

**Variants:**

- **`Instant`** — the handover fires immediately on bid. No time
  guarantee for the displaced tenant; no competitive bidding window.
  The first bidder at `next_rent_price` wins instantly. Suitable for
  integrators who do not need either guarantee and want fully
  frictionless displacement.

- **`Countdown { floor_ms }`** — the standard configuration. Both
  guarantees are active. The size of `floor_ms` controls the trade-off
  between tenant stability (larger = more protection for the current
  tenant) and market responsiveness (smaller = faster rotation).
  Constructor enforces `0 < floor_ms < tenure_ceiling` (as a
  cross-field check inside `new_config`).

- **`FixedTime`** — the current tenant is guaranteed their full block
  before any handover can execute. A new tenant pays `next_rent_price`
  and waits for the entire remaining tenure before gaining access.
  This replicates traditional fixed-term renting — a sequential queue
  of full blocks — while retaining all liquid renting mechanics: price
  escalation, fee distribution, and the Dutch Auction on tenure
  expiry. `remain_credit` is always zero at handover in this
  configuration — the full block is consumed before access transfers.
  The protocol does not special-case this; it emerges naturally from
  the policy choice.


4. EVENT AND EMITTER
--------------------

### `IntegrationConfigRegistered` — event

Emitted exactly once per integration, at `rental_escrow::integrate`
time, after the escrow is constructed and before it is shared. Carries
a full snapshot of the immutable parameters the integrator committed
to, keyed by `escrow_id`.

```move
public struct IntegrationConfigRegistered has copy, drop {
    escrow_id: ID,
    config:    IntegrationConfig,
}
```

**Abilities:** `copy + drop` — required by `event::emit`.
`IntegrationConfig` has `copy + drop + store`, so the nested form
satisfies the Sui event verifier.

**Field semantics:**
- `escrow_id` is the root FK that ties this row to every other event
  for the same escrow; it is the protocol's uniform schema anchor (see
  `rental_escrow.spec.md §3` — "Star schema").
- `config` carries the full immutable parameter snapshot by value.
  Field units and meanings are defined in §2 and not restated here —
  the single struct is the source of truth.

**Star-schema role.** `IntegrationConfigRegistered` is a **1:1
satellite dimension** of the `escrows` fact table, emitted exactly
once per escrow at integration and never again (configs are immutable;
no burn / update event exists). It carries no child PK of its own —
the config has no UID — so the only key is `escrow_id`.

**Why emit the full snapshot at once.** The off-chain indexer needs to
know *which parameter combinations produce good liquid-renting
mechanics*. A single event carrying the full `IntegrationConfig` lets
analytical queries group escrows by any parameter (e.g. `WHERE
config.handover = FixedTime` or `WHERE config.tenure_ceiling > X`)
without reading the on-chain object. Splitting the snapshot across
multiple events would force envelope-timing joins — disallowed by
star-schema invariant (d). Nesting the struct inside the event (rather
than mirroring its fields flat) keeps `IntegrationConfig` as the
single source of truth: new config fields propagate to the event
automatically, with no triplicated mirror to keep in sync.

### `emit_registration` — function

```move
public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID)
```

**Visibility:** `public(package)` — only `rental_escrow::integrate` is
expected to call it. Not exposed to PTBs: an integrator cannot emit a
registration event decoupled from an actual escrow construction.

**Behavior:** emits a single `IntegrationConfigRegistered { escrow_id,
config: *cfg }`. `*cfg` is a cheap `copy` (all fields have `copy`).
No validation (inputs were already validated by `new_config`;
`escrow_id` is authoritative — it comes from `object::uid_to_inner`
inside `integrate`). No state mutation.

**Why split from `new_config`.** `new_config` runs in the PTB *before*
`rental_escrow::integrate` — there is no `escrow_id` yet. Folding
construction + emission into a single escrow-scoped call would break
PTB composability: integrators could no longer build `CurveShape` /
`PriceFunction` / policy values / `IntegrationConfig` as independent
PTB steps. The split keeps `new_config` as a pure builder and adds a
separate emitter invoked at the point the contextual data (the
`escrow_id`) becomes known.

**Emit-last compliance.** Called from `rental_escrow::integrate`
*after* the escrow has been constructed with `config` embedded (so the
config↔escrow_id binding is a realized semantic fact) and *before*
`share_object` consumes the escrow value. Placing the call any earlier
would emit before the semantic operation the event describes.


5. GETTERS
----------

One `public(package)` getter per field. All take `&IntegrationConfig`.
External observers read field values on-chain directly; only
`rental_escrow` (and tests) needs these in Move code.

```move
public(package) fun min_rent_price(cfg: &IntegrationConfig): u64
public(package) fun tenure_ceiling(cfg: &IntegrationConfig): u64
public(package) fun handover(cfg: &IntegrationConfig):       &HandoverPolicy
public(package) fun descent(cfg: &IntegrationConfig):        &DescentPolicy
public(package) fun retire(cfg: &IntegrationConfig):         &RetirePolicy
public(package) fun credit_curve(cfg: &IntegrationConfig):   &CurveShape
public(package) fun descent_curve(cfg: &IntegrationConfig):  &CurveShape
public(package) fun price_function(cfg: &IntegrationConfig): &PriceFunction
```

Scalar fields (`u64`) are returned by value (copy). Policy enum, curve,
and price-function fields are returned by immutable reference.

Rationale for the by-reference return on enums: if any of these types
lost `copy` in the future (currently all have it), `IntegrationConfig`
would also lose `copy` (a struct cannot have abilities its fields
lack) — but reference-returning getters would remain valid without
signature changes.

No setter exists. `IntegrationConfig` is write-once.


6. DISPATCH HELPERS
-------------------

The dispatch helpers are `public(package)` functions that consume a
`&IntegrationConfig` plus a transient timestamp and return the
protocol-relevant boundary or unlock value. They live in `config`
(not in `rental_escrow`) for the same reason `curve_shape::evaluate_curve`
lives in `curve_shape`: the dispatch is over types defined in the
module, and lives next to the type.

The signature convention is: each helper takes `&IntegrationConfig` as
its primary argument, **not** a sub-component reference (`&HandoverPolicy`,
etc.). This matches the precedent of `curve_shape::evaluate_curve(&CurveShape, ...)`
and `price_function::evaluate_price_fn(&PriceFunction, ...)` — each
module's dispatch takes the module's primary type. For `config`, the
primary type is `IntegrationConfig`; the policy enums are
sub-components.

### 6.1 Tenure phase

```move
public(package) fun tenure_boundary(
    cfg:            &IntegrationConfig,
    phase_start_ms: u64,
): u64
```

Boundary timestamp at which `do_tenure_expiry` fires for an escrow in
`HandoverOpen` whose phase started at `phase_start_ms`. Returns
`phase_start_ms + cfg.tenure_ceiling`. No policy to dispatch over —
the helper exists for symmetry with `descent_boundary` /
`handover_expiry` so that `apply_pending_transitions` reads uniformly
through `config::*` for every phase, regardless of whether the
parameterization is a scalar or a policy enum.

```move
public(package) fun handover_expiry(
    cfg:            &IntegrationConfig,
    now:            u64,
    phase_start_ms: u64,
): u64
```

Timestamp at which the handover countdown expires. Encapsulates the
saturation rule of `rental_escrow.spec.md §5.1`:

| `cfg.handover` variant | Returned value |
|---|---|
| `Instant` | `now` |
| `Countdown { floor_ms }` | `min(now + floor_ms, phase_start_ms + cfg.tenure_ceiling)` |
| `FixedTime` | `phase_start_ms + cfg.tenure_ceiling` |

Consumers never replicate the saturation formula — they call this
helper.

### 6.2 Descent phase

```move
public(package) fun descent_boundary(
    cfg:            &IntegrationConfig,
    phase_start_ms: u64,
): u64
```

Boundary timestamp at which `do_auction_expiry` fires for an escrow
in `AtDutchAuction` whose phase started at `phase_start_ms`.

| `cfg.descent` variant | Returned value |
|---|---|
| `Skipped` | `phase_start_ms` (boundary == phase start; the comparison `now >= boundary` is then trivially satisfied at the same instant `do_tenure_expiry` produces the variant — collapsing the cascade to `Idle` in one APT step; see `rental_escrow.spec.md` M6b/Q11) |
| `Window { ceiling_ms }` | `phase_start_ms + ceiling_ms` |

```move
public(package) fun descent_window_ceiling(cfg: &IntegrationConfig): u64
```

Width of the descent window, used as the `t_max` of `evaluate_curve`
in `compute_price_descent`.

| `cfg.descent` variant | Returned value |
|---|---|
| `Window { ceiling_ms }` | `ceiling_ms` |
| `Skipped` | aborts `E_DESCENT_SKIPPED_NO_WINDOW` |

The abort is structurally unreachable from the protocol's normal call
graph: `compute_price_descent` is only called from `AtDutchAuction`,
and `AtDutchAuction` is unobservable under `Skipped`. The abort
exists as a defensive landmine: a developer who calls this helper
from a path that fails this invariant gets an explicit error rather
than a silently-wrong zero.

### 6.3 Retire guard

```move
public(package) fun retire_unlock(
    cfg:              &IntegrationConfig,
    integrated_at_ms: u64,
): u64
```

Earliest clock timestamp at which `retire()` may proceed.

| `cfg.retire` variant | Returned value |
|---|---|
| `Immediate` | `0` (any clock value passes the guard `clock >= retire_unlock(...)`) |
| `Deferred { floor_ms }` | `integrated_at_ms + floor_ms` |


7. PROPERTIES
-------------

The following hold for any `IntegrationConfig` successfully constructed
via `new_config` — they are invariants the rest of the protocol may
rely on without re-checking.

**P1 — Price floor positive:**
    cfg.min_rent_price > 0

**P2 — Time scale positive:**
    cfg.tenure_ceiling > 0

**P3 — Handover policy contained within tenure (Countdown only):**
    For all cfg.handover == Countdown { floor_ms }:
        0 < floor_ms < cfg.tenure_ceiling
    Instant and FixedTime variants are unconstrained at this layer
    (they encode "0" and "= tenure_ceiling" implicitly via variant
    identity, not via the field).

**P4 — Descent policy positive (Window only):**
    For all cfg.descent == Window { ceiling_ms }:
        ceiling_ms > 0
    Skipped is the structurally distinct "no auction" mode.

**P5 — Retire policy positive (Deferred only):**
    For all cfg.retire == Deferred { floor_ms }:
        floor_ms > 0
    Immediate is the structurally distinct "no guard" mode.

**P6 — Variants are disjoint:**
    HandoverPolicy / DescentPolicy / RetirePolicy variants are
    mutually exclusive by construction. A config never has two
    co-existing modes for the same policy field.

**P7 — Getters and dispatch helpers are consistent:**
    For all fields f: getter_f(new_config(..., f, ...)) == f
    For all dispatch helpers d: the variant match in d covers the
    full enum (compiler-enforced exhaustivity).

**P8 — Dispatch helper invariants:**
    P8.a — handover_expiry under Countdown saturates at the tenure
        boundary: handover_expiry(cfg, now, phase_start) <=
        phase_start + cfg.tenure_ceiling, for all now and phase_start.
    P8.b — descent_boundary under Skipped collapses to phase_start
        (boundary == phase start), enabling the cascade in
        apply_pending_transitions to fire in the same call.
    P8.c — retire_unlock under Immediate returns 0, making the guard
        `clock >= retire_unlock(...)` trivially satisfied.


8. TEST CASES
-------------

Format for `new_config(...)`:
`new_config(min_rent_price, tenure_ceiling, handover, descent, retire, credit_curve, descent_curve, price_function)`.

Curve shorthand: `Lin` = `new_linear()`, `Smt` = `new_smoothstep()`,
`Pow(n,d)` = `new_power_law(n, d)`, `Exp(a,neg)` = `new_exponential(a, neg)`,
`Log` = `new_logistic()`.
Price function: `FD(d)` = `new_fixed_delta(d)`, `CD(bps,d)` = `new_compound_delta(bps, d)`.
Policy shorthand: `H_INST` = `new_handover_instant()`, `H_CD(x)` =
`new_handover_countdown(x)`, `H_FIX` = `new_handover_fixed_time()`,
`D_SKP` = `new_descent_skipped()`, `D_W(x)` = `new_descent_window(x)`,
`R_IMM` = `new_retire_immediate()`, `R_DEF(x)` = `new_retire_deferred(x)`.


### 8.0 Test strategy

**Test module.** `#[test_only] module usufruct::config_tests`.
Function names describe the asserted behaviour (e.g.
`new_config_rejects_min_rent_price_zero`,
`emit_registration_e1_full_snapshot`).

**Idioms.**

- `new_config` success rows (§8.1) translate as **one parametric loop**
  over a `vector<Case>` where each `Case` carries the eight inputs
  including the three policy enum values directly. The loop runs
  `new_config(...)`, then the §8.3 round-trip predicate.
- `new_config` and variant-constructor abort rows (§8.2) translate as
  **one `#[test, expected_failure(abort_code = config::E_<NAME>)]`
  function each** — never mixed with success rows.
- `emit_registration` rows (§8.4) require `sui::test_scenario` because
  `event::emit` records into transaction effects.

**Fixtures.** A canonical V2 config is exposed via `v2_config()`.
Per-policy helpers `v2_handover()`, `v2_descent()`, `v2_retire()`
return canonical V2 variants for use as constants in single-field-
variation rows.


### 8.1 Valid inputs (must not abort)

| # | min_rent_price | tenure_ceiling | handover | descent | retire | credit | descent | price | Notes |
|---|---|---|---|---|---|---|---|---|---|
| V1 | 1 | 1 | H_INST | D_W(1) | R_IMM | Lin | Lin | FD(1) | Minimal valid config; handover_instant. |
| V2 | 1_000_000 | 86_400_000 | H_CD(3_600_000) | D_W(43_200_000) | R_IMM | Lin | Lin | FD(1) | Typical: 1h countdown in 24h tenure, 12h auction. |
| V3 | 100 | 10_000 | H_CD(5_000) | D_W(10_000) | R_DEF(7_200_000) | Smt | Smt | FD(10) | retire_deferred = 2h. |
| V4 | 50 | 100_000 | H_INST | D_W(50_000) | R_IMM | Pow(1,2) | Lin | FD(1) | handover_instant. |
| V5 | u64::MAX | 1_000 | H_CD(500) | D_W(1_000) | R_IMM | Exp(3,false) | Exp(3,true) | FD(1) | max min_rent_price; mixed Exp curves. |
| V6 | 1 | u64::MAX | H_CD(1) | D_W(u64::MAX) | R_DEF(u64::MAX) | Log | Log | FD(1) | No upper bound on time params. |
| V7 | 1_000 | 86_400_000 | H_CD(3_600_000) | D_W(43_200_000) | R_IMM | Lin | Lin | CD(500,100) | CompoundDelta price function. |
| V8 | 1 | 1_000 | H_FIX | D_W(1) | R_IMM | Lin | Lin | FD(1) | `handover_fixed_time` — replicates traditional fixed-term renting (§3 rationale). |
| V9 | 1 | u64::MAX | H_FIX | D_W(1) | R_IMM | Lin | Lin | FD(1) | FixedTime at u64-extreme tenure_ceiling. |
| V10 | 1 | 1_000 | H_INST | D_W(1) | R_IMM | Pow(2,4) | Pow(6,3) | FD(1) | PowerLaw inputs requiring gcd normalization. |
| V11 | 1 | 1_000 | H_CD(500) | D_W(1) | R_IMM | Exp(1,false) | Exp(8,true) | CD(1,1) | Extreme α values + minimum CompoundDelta. |
| V12 | 1 | 1_000 | H_INST | D_SKP | R_IMM | Lin | Lin | FD(1) | `descent_skipped` — AtDutchAuction unobservable (M6b). |

**Note — unconstrained free variables:** `tenure_ceiling`, the
`Window.ceiling_ms` payload of `DescentPolicy`, and the
`Deferred.floor_ms` payload of `RetirePolicy` have no upper bound.
Absurd values (e.g. `u64::MAX`) are accepted; any resulting arithmetic
overflow surfaces at runtime inside `curve` or `rental_escrow` via
Move's checked arithmetic.


### 8.2 Invalid inputs (must abort with stated error code)

| # | Input description | Expected abort |
|---|---|---|
| I1 | min_rent_price = 0 | `E_MIN_RENT_PRICE_ZERO` |
| I2 | tenure_ceiling = 0 | `E_TENURE_CEILING_ZERO` |
| I3 | `H_CD(100)` paired with `tenure_ceiling = 50` | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` |
| I4 | `H_CD(1_001)` paired with `tenure_ceiling = 1_000` | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — guards off-by-one on the strict `<` check |
| I5 | `H_CD(u64::MAX)` paired with `tenure_ceiling = u64::MAX − 1` | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — u64-saturated boundary |
| I6 | `H_CD(t)` paired with `tenure_ceiling = t` (e.g. both `1_000`) | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — equality is `FixedTime`, not the upper edge of `Countdown` |
| I7 | `new_handover_countdown(0)` (variant constructor) | `E_HANDOVER_FLOOR_ZERO` — zero is `Instant`, not `Countdown(0)` |
| I8 | `new_descent_window(0)` (variant constructor) | `E_DESCENT_CEILING_ZERO` — zero is `Skipped`, not `Window(0)` |
| I9 | `new_retire_deferred(0)` (variant constructor) | `E_RETIRE_FLOOR_ZERO` — zero is `Immediate`, not `Deferred(0)` |

**Abort-ordering note.** The validation sequence in §3.2 is:
`min_rent_price` → `tenure_ceiling` → handover variant → descent
variant → retire variant. Rows I1–I9 each set exactly one field to an
invalid value so the expected abort code is unambiguous.
Multi-violation inputs are omitted on purpose — they would couple the
test to the order above.


### 8.3 Getter round-trip (must hold for all valid configs)

Verifies that every value passed to `new_config` is returned unchanged
by its getter — the constructor does not transform, normalize, or
discard any field. **[property P7]** Translates as one predicate
applied inside the §8.1 parametric loop:

```move
let c = new_config(mrp, tc, h, d, r, &g, &h_curve, &pf);
assert_eq!(min_rent_price(&c),  mrp);
assert_eq!(tenure_ceiling(&c),  tc);
assert_eq!(*handover(&c),       h);
assert_eq!(*descent(&c),        d);
assert_eq!(*retire(&c),         r);
assert_eq!(*credit_curve(&c),   g);
assert_eq!(*descent_curve(&c),  h_curve);
assert_eq!(*price_function(&c), pf);
```

**Explicit round-trip rows — pin each field individually:**

| # | Field varied | Input value | Expected getter output |
|---|---|---|---|
| R1 | `min_rent_price` | `u64::MAX` | `u64::MAX` |
| R2 | `tenure_ceiling` | `86_400_000` | `86_400_000` |
| R3  | `handover` | `H_INST` | `&Instant` |
| R3b | `handover` | `H_FIX`  | `&FixedTime` (companion variant) |
| R4  | `descent`  | `D_W(1)` | `&Window { ceiling_ms: 1 }` |
| R4b | `descent`  | `D_SKP`  | `&Skipped` (companion variant) |
| R5 | `retire` | `R_DEF(u64::MAX)` | `&Deferred { floor_ms: u64::MAX }` |
| R6 | `credit_curve` | `new_power_law(2, 4)` (raw) | `&PowerLaw { 1, 2 }` (gcd-reduced) |
| R7 | `descent_curve` | `new_logistic()` | `&Logistic` |
| R8 | `price_function` | `new_compound_delta(500, 100)` | `&CompoundDelta { 500, 100 }` |

Each row holds all other fields to the V2 canonical values so the
varied field is the only independent variable.


### 8.4 `emit_registration` — event emission

Tests run in `sui::test_scenario` because `event::emit` is observable
only through transaction effects.

| # | Setup | Assertion |
|---|---|---|
| E1 | Build V2 config; pick literal `escrow_id` | `num_user_events == 1`; `events[0].escrow_id == escrow_id`; `events[0].config == cfg` (struct equality, all eight fields match by value). |
| E2 | Build V10 config (PowerLaw gcd-normalized curves); emit | Event payload's `config.credit_curve == &PowerLaw { 1, 2 }` (reduced form — what was stored, not what was passed to `new_power_law`). |
| E3 | Build V2 config; call `emit_registration` twice in the same tx | `num_user_events == 2`; both payloads identical. Documents that `emit_registration` is not idempotent at the event-count level — the single-emit contract is a *caller* contract (`rental_escrow::integrate` calls it once), not a module-side guard. |


### 8.5 Open questions

- **Cross-module re-validation.** `new_config` does not re-validate
  `CurveShape` / `PriceFunction` internals. A test that passes an
  *unvalidated* `CurveShape` is impossible to construct — the enum
  fields are private, constructors are the only path. Document that
  §8.1 rows exercise only already-validated curves; there is no
  "invalid curve bypasses `new_config`" row because the type system
  prevents it.


9. MODULE BOUNDARY
------------------

`config.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `E_MIN_RENT_PRICE_ZERO: u64 = 0` | `public` | SDK error handling. |
| `E_TENURE_CEILING_ZERO: u64 = 1` | `public` | SDK error handling. |
| `E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2` | `public` | SDK error handling. |
| `E_HANDOVER_FLOOR_ZERO: u64 = 3` | `public` | SDK error handling. |
| `E_DESCENT_CEILING_ZERO: u64 = 4` | `public` | SDK error handling. |
| `E_RETIRE_FLOOR_ZERO: u64 = 5` | `public` | SDK error handling. |
| `E_DESCENT_SKIPPED_NO_WINDOW: u64 = 6` | `public` | Internal invariant; would surface only if `compute_price_descent` is reached under `Skipped` (structurally unreachable). |
| `HandoverPolicy` (type) | `public` | `copy + drop + store`. Three variants. |
| `DescentPolicy` (type) | `public` | `copy + drop + store`. Two variants. |
| `RetirePolicy` (type) | `public` | `copy + drop + store`. Two variants. |
| `IntegrationConfig` (type) | `public` | `copy + drop + store`. Embedded in `RentalEscrow`. |
| `IntegrationConfigRegistered` (type) | `public` | Event. `copy + drop`. Emitted once at integration time. |
| `new_handover_instant() / _countdown(floor_ms) / _fixed_time()` | `public` | Variant constructors. PTB-callable. |
| `new_descent_skipped() / _window(ceiling_ms)` | `public` | Variant constructors. PTB-callable. |
| `new_retire_immediate() / _deferred(floor_ms)` | `public` | Variant constructors. PTB-callable. |
| `new_config(...)` | `public` | Validated bundle constructor. PTB-callable. |
| `emit_registration(cfg, escrow_id)` | `public(package)` | Emits `IntegrationConfigRegistered`. Called from `rental_escrow::integrate`. |
| `min_rent_price(cfg)` | `public(package)` | Getter — returns `u64`. |
| `tenure_ceiling(cfg)` | `public(package)` | Getter — returns `u64`. |
| `handover(cfg)` | `public(package)` | Getter — returns `&HandoverPolicy`. |
| `descent(cfg)` | `public(package)` | Getter — returns `&DescentPolicy`. |
| `retire(cfg)` | `public(package)` | Getter — returns `&RetirePolicy`. |
| `credit_curve(cfg)` | `public(package)` | Getter — returns `&CurveShape`. |
| `descent_curve(cfg)` | `public(package)` | Getter — returns `&CurveShape`. |
| `price_function(cfg)` | `public(package)` | Getter — returns `&PriceFunction`. |
| `tenure_boundary(cfg, phase_start_ms)` | `public(package)` | Dispatch helper — tenure phase boundary. |
| `handover_expiry(cfg, now, phase_start_ms)` | `public(package)` | Dispatch helper — handover countdown expiry with saturation. |
| `descent_boundary(cfg, phase_start_ms)` | `public(package)` | Dispatch helper — descent phase boundary; returns `phase_start_ms` under `Skipped`. |
| `descent_window_ceiling(cfg)` | `public(package)` | Dispatch helper — descent window width; aborts on `Skipped`. |
| `retire_unlock(cfg, integrated_at_ms)` | `public(package)` | Dispatch helper — retire guard threshold; returns `0` under `Immediate`. |

**Integration flow (PTB):** an integrator builds, in any order:
- `CurveShape` values via `curve_shape::new_*` (`public`)
- `PriceFunction` value via `price_function::new_*` (`public`)
- `HandoverPolicy` / `DescentPolicy` / `RetirePolicy` values via the
  config variant constructors (`public`)

then calls `config::new_config(...)` to validate and bundle, then
passes the resulting `IntegrationConfig` to `rental_escrow::integrate`.
All layers are `public` and composable from a PTB. Error constants are
`public` so the SDK can map abort codes to human-readable messages.

**Depends on:** `curve_shape`, `price_function` (type imports —
`CurveShape`, `PriceFunction`).
