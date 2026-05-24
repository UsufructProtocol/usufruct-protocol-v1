> **Archive.** This spec was written during the first implementation of the protocol, before the codebase led the design. Module names, terminology, and mechanics may differ from what is currently implemented. The protocol was renamed from **Liquid Renting** to **usufruct** during development. The ultimate source of truth is the source code in `usufruct/sources/`; the current specs in `specs/` document what the code does.

---

CONFIG MODULE — SPECIFICATION
==============================

Module: `config`
Design reference: design-compact.md §6
Depends on: `curve_shape`, `price_function`, `handover_policy`,
            `descent_policy`, `retire_policy`


0. MODULE RESPONSIBILITY
------------------------

`config` is the **data-carrier layer** of the protocol. It owns the
`IntegrationConfig` struct that bundles all immutable integration
parameters into a single value embedded inside `RentalEscrow`, the bundle
constructor `new_config` that assembles and cross-validates the bundle,
the per-field getters, and the registration event that snapshots the
bundle at integration time.

`config` does **not** own the policy enums (`HandoverPolicy`,
`DescentPolicy`, `RetirePolicy`) or their dispatch logic. Those live in
their own modules — see `handover_policy.spec.md`, `descent_policy.spec.md`,
`retire_policy.spec.md`. `config` carries the policies as fields and
delegates back to them for cross-field validation.

**Owns:**

- `IntegrationConfig` — plain data struct (`copy + drop + store`, no
  `key`). No UID. Not a shared object. Embedded field inside
  `RentalEscrow`. Bundles the eight integration parameters.
- `new_config(...)` — `public` bundle constructor. Validates scalar
  fields (`min_rent_price > 0`, `tenure_ceiling > 0`) and the one
  cross-field constraint (`Countdown.floor_ms < tenure_ceiling`). Aborts
  on any violation.
- One `public(package)` getter per field (scalar fields return by value;
  policy and curve fields return immutable references).
- `IntegrationConfigRegistered` — event struct capturing the full
  parameter snapshot at integration time, keyed by `escrow_id`.
- `emit_registration(cfg, escrow_id)` — `public(package)` emitter called
  from `rental_escrow::integrate` once the escrow ID is known. Split
  from `new_config` because the config is built in the PTB before the
  escrow exists, so the ID cannot be captured inside the constructor.

**Does not own:**

- The three policy enums or their constructors — live in
  `handover_policy`, `descent_policy`, `retire_policy`. Each policy
  module owns its enum, variant constructors, intra-variant validation,
  and dispatch functions.
- Dispatch over the policies (`has_expired`, `expiry_at`, `is_unlocked`,
  `window_ceiling`, `countdown_floor_lt`) — all in the policy modules.
  `rental_escrow` calls them directly via `config::handover(&cfg)` etc.
  (getter returning `&HandoverPolicy`).
- `CurveShape` and `PriceFunction` construction or evaluation — live in
  `curve_shape` / `price_function`. `config::new_config` receives
  already-constructed values and does not re-validate their internals.
- Naked timestamp arithmetic — every `+`/`min` over timestamps routes
  through `phases` (see `phases.spec.md` §6 P7).
- Protocol state, fund movements, capability objects, Sui framework
  object operations.

**Dependency direction:** `config` calls `handover_policy::countdown_floor_lt`
(for the cross-field assertion) and `sui::event::emit`. It stores values
of type `CurveShape`, `PriceFunction`, `HandoverPolicy`, `DescentPolicy`,
`RetirePolicy` but does not call into curve / price-function /
policy-dispatch logic. `rental_escrow` calls `config::new_config`, the
getters, and `emit_registration`.


1. ERROR CONSTANTS
------------------

All validation aborts originate in `new_config`. Constants are `public`
so the SDK can map abort codes to human-readable messages.

    public const E_MIN_RENT_PRICE_ZERO:           u64 = 0;  // min_rent_price == 0
    public const E_TENURE_CEILING_ZERO:           u64 = 1;  // tenure_ceiling == 0
    public const E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2;  // Countdown.floor_ms >= tenure_ceiling

`E_HANDOVER_FLOOR_EXCEEDS_TENURE` is strict (`>=`, not `>`): equality with
`tenure_ceiling` is `HandoverPolicy::FixedTime`, a separate variant — not
the upper edge of `Countdown`. The variants are disjoint: `Countdown
{ floor_ms }` requires `0 < floor_ms < tenure_ceiling`; `Instant` is the
`0` mode; `FixedTime` is the `= tenure_ceiling` mode.

**Errors no longer in `config`** (migrated to their owning modules):

| Error | Now in | Raised by |
|-------|--------|-----------|
| `E_HANDOVER_FLOOR_ZERO` | `handover_policy` | `new_handover_countdown(0)` |
| `E_DESCENT_CEILING_ZERO` | `descent_policy` | `new_descent_window(0)` |
| `E_RETIRE_FLOOR_ZERO` | `retire_policy` | `new_retire_deferred(0)` |
| `E_DESCENT_SKIPPED_NO_WINDOW` | `descent_policy` | `window_ceiling` on `Skipped` |


2. TYPE
-------

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
| `handover` | `HandoverPolicy` | Mode of the bidding window after a takeover bid. See `handover_policy.spec.md` §2. |
| `descent` | `DescentPolicy` | Mode of the Dutch Auction window. See `descent_policy.spec.md` §2. |
| `retire` | `RetirePolicy` | Mode of the `retire()` time guard. See `retire_policy.spec.md` §2. |
| `credit_curve` | — | `CurveShape g` — shape of `f_credit_ascent`. |
| `descent_curve` | — | `CurveShape h` — shape of `f_price_descent`. |
| `price_function` | — | `PriceFunction` — shape of `f_next_rent_price`. |

All fields are private. Access via getters only (§5).


3. `new_config` — bundle constructor
-----------------------------------

### Signature

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

### Visibility

`public` — callable from PTBs. Integrators build `CurveShape`,
`PriceFunction`, and the three policy values via their `public`
constructors (in their respective modules), then pass the assembled
values to `new_config`.

### Validation (in order)

```
assert!(min_rent_price > 0, E_MIN_RENT_PRICE_ZERO);
assert!(tenure_ceiling > 0, E_TENURE_CEILING_ZERO);

// Cross-field constraint: Countdown.floor_ms < tenure_ceiling.
// Equality is the FixedTime variant. Intra-variant invariants
// (e.g., floor_ms > 0) are owned by handover_policy's constructor.
// The variant-level check is encapsulated in
// handover_policy::countdown_floor_lt because pattern-matching on
// an enum variant is restricted to the defining module (Move 2024
// E04001).
assert!(
    handover_policy::countdown_floor_lt(&handover, tenure_ceiling),
    E_HANDOVER_FLOOR_EXCEEDS_TENURE,
);
```

**No re-validation of intra-variant invariants.** The previous
implementation re-validated `Countdown.floor_ms > 0`, `Window.ceiling_ms
> 0`, and `Deferred.floor_ms > 0` here as defense-in-depth against
direct enum construction. Move 2024 makes that defense unreachable —
variants of a `public enum` declared in another module cannot be
constructed externally. The only path to a `HandoverPolicy` /
`DescentPolicy` / `RetirePolicy` from outside the defining module is
the `public` variant constructor, which already enforces the invariant.

**No re-validation of curve/price-function internals.** Those were
validated by their own constructors in `curve_shape` / `price_function`.
The same reachability argument applies.

**Other accepted ranges:**

- `descent_ceiling > tenure_ceiling` is allowed: no asserted ordering
  between the two — the protocol does not branch on the sign of
  `(descent_ceiling − tenure_ceiling)`.
- `retire = Deferred { floor_ms }` has no upper bound. Owners can
  signal arbitrarily long commitments.

### Return

On success, returns an `IntegrationConfig` with all fields set to the
provided values. No implicit defaults, no transformations.


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

**Star-schema role.** `IntegrationConfigRegistered` is a **1:1 satellite
dimension** of the `escrows` fact table, emitted exactly once per escrow
at integration and never again (configs are immutable; no burn / update
event exists). It carries no child PK of its own — the config has no UID
— so the only key is `escrow_id`.

**Why emit the full snapshot at once.** The off-chain indexer needs to
know *which parameter combinations produce good liquid-renting
mechanics*. A single event carrying the full `IntegrationConfig` lets
analytical queries group escrows by any parameter (e.g. `WHERE
config.handover = FixedTime` or `WHERE config.tenure_ceiling > X`)
without reading the on-chain object. Splitting the snapshot across
multiple events would force envelope-timing joins — disallowed by
star-schema invariant (d). Nesting the struct inside the event (rather
than mirroring its fields flat) keeps `IntegrationConfig` as the single
source of truth: new config fields propagate to the event automatically,
with no triplicated mirror to keep in sync.

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
would also lose `copy` (a struct cannot have abilities its fields lack)
— but reference-returning getters would remain valid without signature
changes.

**Consumers.** `rental_escrow` reads policies via `config::handover(&cfg)`
etc. and forwards the references to the policy modules' dispatchers
(`handover_policy::has_expired(config::handover(&cfg), ...)`). This
keeps `config` as a pure data carrier — it never dispatches on its own
fields; the policy modules own all dispatch.

No setter exists. `IntegrationConfig` is write-once.


6. PROPERTIES
-------------

The following hold for any `IntegrationConfig` successfully constructed
via `new_config` — they are invariants the rest of the protocol may rely
on without re-checking.

**P1 — Price floor positive:**
    cfg.min_rent_price > 0

**P2 — Time scale positive:**
    cfg.tenure_ceiling > 0

**P3 — Handover policy contained within tenure (Countdown only):**
    For all cfg.handover == Countdown { floor_ms }:
        floor_ms < cfg.tenure_ceiling
    Enforced by `handover_policy::countdown_floor_lt` inside `new_config`.
    `floor_ms > 0` is enforced upstream by
    `handover_policy::new_handover_countdown` (intra-variant invariant).
    `Instant` and `FixedTime` are unconstrained at this layer (they
    encode "0" and "= tenure_ceiling" implicitly via variant identity,
    not via the field).

**P4 — Variant well-formedness (delegated):**
    Variant payloads are well-formed (per the policy modules' constructor
    contracts):
    - `Countdown.floor_ms > 0` — `handover_policy::E_HANDOVER_FLOOR_ZERO`
    - `Window.ceiling_ms > 0` — `descent_policy::E_DESCENT_CEILING_ZERO`
    - `Deferred.floor_ms > 0` — `retire_policy::E_RETIRE_FLOOR_ZERO`
    These are upstream invariants `new_config` does not re-validate.

**P5 — Variants are disjoint:**
    HandoverPolicy / DescentPolicy / RetirePolicy variants are mutually
    exclusive by construction. A config never has two co-existing modes
    for the same policy field.

**P6 — Getters are identity:**
    For all fields f: getter_f(new_config(..., f, ...)) == f
    The constructor stores values verbatim and the getters return them
    verbatim. No transformation, normalization, or projection.


7. TEST CASES
-------------

Format for `new_config(...)`:
`new_config(min_rent_price, tenure_ceiling, handover, descent, retire, credit_curve, descent_curve, price_function)`.

Curve shorthand: `Lin` = `new_linear()`, `Smt` = `new_smoothstep()`,
`Pow(n,d)` = `new_power_law(n, d)`, `Exp(a,neg)` = `new_exponential(a, neg)`,
`Log` = `new_logistic()`.
Price function: `FD(d)` = `new_fixed_delta(d)`, `CD(bps,d)` = `new_compound_delta(bps, d)`.
Policy shorthand: `H_INST` = `handover_policy::new_handover_instant()`,
`H_CD(x)` = `handover_policy::new_handover_countdown(x)`, `H_FIX` =
`handover_policy::new_handover_fixed_time()`, `D_SKP` =
`descent_policy::new_descent_skipped()`, `D_W(x)` =
`descent_policy::new_descent_window(x)`, `R_IMM` =
`retire_policy::new_retire_immediate()`, `R_DEF(x)` =
`retire_policy::new_retire_deferred(x)`.


### 7.0 Test strategy

**Test module.** `#[test_only] module usufruct::config_tests`.
Function names describe the asserted behaviour (e.g.
`new_config_rejects_min_rent_price_zero`,
`emit_registration_e1_full_snapshot`).

**Idioms.**

- `new_config` success rows (§7.1) translate as **one parametric loop**
  over a `vector<Case>` where each `Case` carries the eight inputs
  including the three policy enum values directly. The loop runs
  `new_config(...)`, then the §7.3 round-trip predicate.
- `new_config` abort rows (§7.2) translate as **one
  `#[test, expected_failure(abort_code = config::E_<NAME>)]` function
  each** — never mixed with success rows.
- `emit_registration` rows (§7.4) require `sui::test_scenario` because
  `event::emit` records into transaction effects.
- Constructor abort rows for the policy modules (`new_handover_countdown(0)`,
  `new_descent_window(0)`, `new_retire_deferred(0)`) are **not** in
  `config_tests`. They live in `handover_policy_tests`, `descent_policy_tests`,
  `retire_policy_tests` — each module owns its own constructor tests.

**Fixtures.** A canonical V2 config is exposed via `v2_config()`.
Per-policy helpers `v2_handover()`, `v2_descent()`, `v2_retire()` return
canonical V2 variants for use as constants in single-field-variation
rows.


### 7.1 Valid inputs (must not abort)

| # | min_rent_price | tenure_ceiling | handover | descent | retire | credit | descent | price | Notes |
|---|---|---|---|---|---|---|---|---|---|
| V1 | 1 | 1 | H_INST | D_W(1) | R_IMM | Lin | Lin | FD(1) | Minimal valid config; handover_instant. |
| V2 | 1_000_000 | 86_400_000 | H_CD(3_600_000) | D_W(43_200_000) | R_IMM | Lin | Lin | FD(1) | Typical: 1h countdown in 24h tenure, 12h auction. |
| V3 | 100 | 10_000 | H_CD(5_000) | D_W(10_000) | R_DEF(7_200_000) | Smt | Smt | FD(10) | retire_deferred = 2h. |
| V4 | 50 | 100_000 | H_INST | D_W(50_000) | R_IMM | Pow(1,2) | Lin | FD(1) | handover_instant. |
| V5 | u64::MAX | 1_000 | H_CD(500) | D_W(1_000) | R_IMM | Exp(3,false) | Exp(3,true) | FD(1) | max min_rent_price; mixed Exp curves. |
| V6 | 1 | u64::MAX | H_CD(1) | D_W(u64::MAX) | R_DEF(u64::MAX) | Log | Log | FD(1) | No upper bound on time params. |
| V7 | 1_000 | 86_400_000 | H_CD(3_600_000) | D_W(43_200_000) | R_IMM | Lin | Lin | CD(500,100) | CompoundDelta price function. |
| V8 | 1 | 1_000 | H_FIX | D_W(1) | R_IMM | Lin | Lin | FD(1) | `handover_fixed_time` — replicates traditional fixed-term renting. |
| V9 | 1 | u64::MAX | H_FIX | D_W(1) | R_IMM | Lin | Lin | FD(1) | FixedTime at u64-extreme tenure_ceiling. |
| V10 | 1 | 1_000 | H_INST | D_W(1) | R_IMM | Pow(2,4) | Pow(6,3) | FD(1) | PowerLaw inputs requiring gcd normalization. |
| V11 | 1 | 1_000 | H_CD(500) | D_W(1) | R_IMM | Exp(1,false) | Exp(8,true) | CD(1,1) | Extreme α values + minimum CompoundDelta. |
| V12 | 1 | 1_000 | H_INST | D_SKP | R_IMM | Lin | Lin | FD(1) | `descent_skipped` — AtDutchAuction unobservable (M6b). |

**Note — unconstrained free variables:** `tenure_ceiling`, the
`Window.ceiling_ms` payload of `DescentPolicy`, and the
`Deferred.floor_ms` payload of `RetirePolicy` have no upper bound.
Absurd values (e.g. `u64::MAX`) are accepted; any resulting arithmetic
overflow surfaces at runtime inside `phases`, `curve_shape`, or
`rental_escrow` via Move's checked arithmetic.


### 7.2 Invalid inputs (must abort with stated error code)

| # | Input description | Expected abort |
|---|---|---|
| I1 | min_rent_price = 0 | `E_MIN_RENT_PRICE_ZERO` |
| I2 | tenure_ceiling = 0 | `E_TENURE_CEILING_ZERO` |
| I3 | `H_CD(100)` paired with `tenure_ceiling = 50` | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` |
| I4 | `H_CD(1_001)` paired with `tenure_ceiling = 1_000` | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — guards off-by-one on the strict `<` check |
| I5 | `H_CD(u64::MAX)` paired with `tenure_ceiling = u64::MAX − 1` | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — u64-saturated boundary |
| I6 | `H_CD(t)` paired with `tenure_ceiling = t` (e.g. both `1_000`) | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — equality is `FixedTime`, not the upper edge of `Countdown` |

**Removed from this table:**

- Variant constructor abort rows (`new_handover_countdown(0)`,
  `new_descent_window(0)`, `new_retire_deferred(0)`) — migrated to the
  policy modules' own test suites: see
  `handover_policy_tests::new_handover_countdown_rejects_zero`,
  `descent_policy_tests::new_descent_window_rejects_zero`,
  `retire_policy_tests::new_retire_deferred_rejects_zero`.

**Abort-ordering note.** The validation sequence in §3 is:
`min_rent_price` → `tenure_ceiling` → handover cross-field. Rows I1–I6
each set exactly one field to an invalid value so the expected abort code
is unambiguous. Multi-violation inputs are omitted on purpose — they
would couple the test to the order above.


### 7.3 Getter round-trip (must hold for all valid configs)

Verifies that every value passed to `new_config` is returned unchanged by
its getter — the constructor does not transform, normalize, or discard
any field. **[property P6]** Translates as one predicate applied inside
the §7.1 parametric loop:

```move
let c = new_config(mrp, tc, h, d, r, g, h_curve, pf);
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

Each row holds all other fields to the V2 canonical values so the varied
field is the only independent variable.


### 7.4 `emit_registration` — event emission

Tests run in `sui::test_scenario` because `event::emit` is observable
only through transaction effects.

| # | Setup | Assertion |
|---|---|---|
| E1 | Build V2 config; pick literal `escrow_id` | `num_user_events == 1`; `events[0].escrow_id == escrow_id`; `events[0].config == cfg` (struct equality, all eight fields match by value). |
| E2 | Build V10 config (PowerLaw gcd-normalized curves); emit | Event payload's `config.credit_curve == &PowerLaw { 1, 2 }` (reduced form — what was stored, not what was passed to `new_power_law`). |
| E3 | Build V2 config; call `emit_registration` twice in the same tx | `num_user_events == 2`; both payloads identical. Documents that `emit_registration` is not idempotent at the event-count level — the single-emit contract is a *caller* contract (`rental_escrow::integrate` calls it once), not a module-side guard. |


### 7.5 Open questions

- **Cross-module re-validation.** `new_config` does not re-validate
  `CurveShape` / `PriceFunction` / policy enum internals. A test that
  passes an *unvalidated* value is impossible to construct — the
  variants are private to their defining modules and the public
  constructors are the only path. §7.1 rows exercise only
  already-validated values; there is no "invalid input bypasses
  `new_config`" row because the type system prevents it.


8. MODULE BOUNDARY
------------------

`config.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `E_MIN_RENT_PRICE_ZERO: u64 = 0` | `public` | SDK error handling. |
| `E_TENURE_CEILING_ZERO: u64 = 1` | `public` | SDK error handling. |
| `E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2` | `public` | SDK error handling. |
| `IntegrationConfig` (type) | `public` | `copy + drop + store`. Embedded in `RentalEscrow`. |
| `IntegrationConfigRegistered` (type) | `public` | Event. `copy + drop`. Emitted once at integration time. |
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

**Symbols no longer in `config.move`** (migrated to their owning modules):

| Symbol | Now in |
|--------|--------|
| `HandoverPolicy` (type) + variant constructors | `handover_policy` |
| `DescentPolicy` (type) + variant constructors | `descent_policy` |
| `RetirePolicy` (type) + variant constructors | `retire_policy` |
| `tenure_boundary` | inlined in `rental_escrow` (no policy enum to dispatch over — just `phase_start_ms + tenure_ceiling`) |
| `handover_expiry` | replaced by `handover_policy::expiry_at` (and `has_expired` for the bool form) |
| `descent_boundary` | replaced by `descent_policy::expiry_at` (and `has_expired`) |
| `descent_window_ceiling` | replaced by `descent_policy::window_ceiling` |
| `retire_unlock` | replaced by `retire_policy::is_unlocked` (bool only — no u64 sister; see `retire_policy.spec.md` §4 P3) |

**Integration flow (PTB):** an integrator builds, in any order:
- `CurveShape` values via `curve_shape::new_*` (`public`)
- `PriceFunction` value via `price_function::new_*` (`public`)
- `HandoverPolicy` value via `handover_policy::new_handover_*` (`public`)
- `DescentPolicy` value via `descent_policy::new_descent_*` (`public`)
- `RetirePolicy` value via `retire_policy::new_retire_*` (`public`)

then calls `config::new_config(...)` to validate and bundle, then passes
the resulting `IntegrationConfig` to `rental_escrow::integrate`. All
layers are `public` and composable from a PTB. Error constants are
`public` so the SDK can map abort codes to human-readable messages.

**Depends on:** `curve_shape`, `price_function` (type imports —
`CurveShape`, `PriceFunction`); `handover_policy`, `descent_policy`,
`retire_policy` (type imports for the policy enum fields, plus the
`countdown_floor_lt` predicate consumed inside `new_config`).
