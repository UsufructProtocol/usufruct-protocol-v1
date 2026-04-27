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
    // descent_ceiling >= 0 is trivially satisfied for u64 — no error constant needed.
    // descent_ceiling = 0 is a legitimate "no price-memory" configuration:
    // AtDutchAuction collapses to a transient phase that always settles to Idle
    // in the same apply_pending_transitions call (Check 3 fires immediately
    // because clock.now() >= phase_start_ms + 0). evaluate_curve handles t_max=0
    // structurally (the `t >= t_max` guard returns SCALE before any eval_*
    // function runs), so no division-by-zero risk. See design-compact.md §15
    // "Pure machine — no price memory" variant.
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
    escrow_id: ID,
    config:    IntegrationConfig,
}
```

**Abilities:** `copy + drop` — required by `event::emit`. `IntegrationConfig`
has `copy + drop + store`, so the nested form satisfies the Sui event
verifier.

**Field semantics:**
- `escrow_id` is the root FK that ties this row to every other event for
  the same escrow; it is the protocol's uniform schema anchor (see
  `rental_escrow.spec.md §3` — "Star schema").
- `config` carries the full immutable parameter snapshot by value. Field
  units and meanings are defined in §2 and not restated here — the single
  struct is the source of truth.

**Star-schema role.** `IntegrationConfigRegistered` is a **1:1 satellite
dimension** of the `escrows` fact table, emitted exactly once per escrow at
integration and never again (configs are immutable; no burn / update event
exists). It carries no child PK of its own — the config has no UID — so the
only key is `escrow_id`.

**Why emit the full snapshot at once.** The off-chain indexer needs to know
*which parameter combinations produce good liquid-renting mechanics*. A
single event carrying the full `IntegrationConfig` lets analytical queries
group escrows by any parameter (e.g. `WHERE config.tenure_ceiling > X`)
without reading the on-chain object. Splitting the snapshot across multiple
events would force envelope-timing joins — disallowed by star-schema
invariant (d). Nesting the struct inside the event (rather than mirroring
its fields flat) keeps `IntegrationConfig` as the single source of truth:
new config fields propagate to the event automatically, with no triplicated
mirror to keep in sync.

### `emit_registration` — function

```move
public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID)
```

**Visibility:** `public(package)` — only `rental_escrow::integrate` is
expected to call it. Not exposed to PTBs: an integrator cannot emit a
registration event decoupled from an actual escrow construction.

**Behavior:** emits a single `IntegrationConfigRegistered { escrow_id,
config: *cfg }`. `*cfg` is a cheap `copy` (all fields have `copy`). No
validation (inputs were already validated by `new_config`; `escrow_id` is
authoritative — it comes from `object::uid_to_inner` inside `integrate`).
No state mutation.

**Why split from `new_config`.** `new_config` runs in the PTB *before*
`rental_escrow::integrate` — there is no `escrow_id` yet. Folding
construction + emission into a single escrow-scoped call would break PTB
composability: integrators could no longer build `CurveShape` /
`PriceFunction` / `IntegrationConfig` as independent PTB steps. The split
keeps `new_config` as a pure builder and adds a separate emitter invoked
at the point the contextual data (the `escrow_id`) becomes known.

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

**P2 — Time parameters non-negative (only `tenure_ceiling` strictly positive):**
    cfg.tenure_ceiling  > 0
    cfg.handover_floor  >= 0   (0 = no bidding window — handover fires immediately)
    cfg.descent_ceiling >= 0   (0 = no price memory — Dutch phase is transient,
                                always settles to Idle in the same call as the
                                preceding tenure expiry; price resets to
                                min_rent_price for the next acquisition)

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


### 7.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::config_tests`.
Function names describe the asserted behaviour (e.g.
`new_config_rejects_min_rent_price_zero`,
`emit_registration_carries_full_config_snapshot`).

**Idioms.**

- `new_config` success rows (§7.1) translate as **one parametric loop**
  over a `vector<Case>` where each `Case` carries the eight scalar inputs
  plus the pre-built `CurveShape`/`PriceFunction` values. The loop runs
  `new_config(...)`, then the §7.3 round-trip predicate on the returned
  config.
- `new_config` abort rows (§7.2) translate as **one
  `#[test, expected_failure(abort_code = config::E_<NAME>)]` function
  each** — never mixed with success rows. Multi-violation inputs are
  omitted on purpose (§7.2 note).
- `emit_registration` rows (§7.4) require `sui::test_scenario` because
  `event::emit` records into transaction effects. Each scenario runs
  through two txs: tx1 builds the config and calls
  `emit_registration_for_testing`, tx2 inspects
  `test_scenario::num_user_events(&effects)` and the typed event vector.

**Fixtures.** For `new_config` tests, `tx_context::dummy()` is sufficient
(constructor takes no ctx). For `emit_registration` tests,
`sui::test_scenario::begin(@0xA)` is the canonical entry. The test module
declares the helper roster:

```
#[test_only] public fun emit_registration_for_testing(
    cfg: &IntegrationConfig, escrow_id: ID)
#[test_only] public fun capture_registered(
    effects: &TransactionEffects): vector<IntegrationConfigRegistered>
```

`emit_registration_for_testing` is a thin wrapper over the
`public(package)` `emit_registration` (the test module is not in the same
package). `capture_registered` uses `event::events_by_type<T>()` to pull
the typed payloads.

**Curve / price-function builders.** Tests construct `CurveShape` and
`PriceFunction` values via the `new_*` constructors from `curve_shape` /
`price_function`. No dedicated fixtures — the shorthand in §7.1 (`Lin`,
`Pow(1,2)`, `FD(1)`, …) maps directly to one `new_*` call each. For the
gcd-normalized PowerLaw round-trip (§7.3), tests construct with
`new_power_law(2, 4)` and compare against `new_power_law(1, 2)` — both
paths produce variants whose stored fields are `PowerLaw { 1, 2 }`.

**Canonical test config.** Where a test just needs "some valid config"
and the exact field values do not matter, use V2 (§7.1 row 2) as the
canonical fixture — it has no extreme boundaries and exercises every
variant category (Lin curves + FD price function).


### 7.1 Valid inputs (must not abort)

| # | min_rent_price | tenure_ceiling | handover_floor | descent_ceiling | retire_floor | credit_curve | descent_curve | price_function | Notes |
|---|---|---|---|---|---|---|---|---|---|
| V1 | 1 | 1 | 0 | 1 | 0 | Lin | Lin | FD(1) | Minimal valid config. handover_floor = 0 (immediate handover). |
| V2 | 1_000_000 | 86_400_000 | 3_600_000 | 43_200_000 | 0 | Lin | Lin | FD(1) | Typical: 1h handover in 24h tenure, 12h auction, no retire floor. |
| V3 | 100 | 10_000 | 5_000 | 10_000 | 7_200_000 | Smt | Smt | FD(10) | retire_floor = 2h — owner commits to keeping asset in escrow for 2h. |
| V4 | 50 | 100_000 | 0 | 50_000 | 0 | Pow(1,2) | Lin | FD(1) | handover_floor = 0 (no bidding window). |
| V5 | u64::MAX | 1_000 | 500 | 1_000 | 0 | Exp(3,false) | Exp(3,true) | FD(1) | max min_rent_price, mixed Exp curves. |
| V6 | 1 | u64::MAX | 1 | u64::MAX | u64::MAX | Log | Log | FD(1) | No upper bound on time parameters — including retire_floor. |
| V7 | 1_000 | 86_400_000 | 3_600_000 | 43_200_000 | 0 | Lin | Lin | CD(500,100) | CompoundDelta price function: 5% + 100 base units per cycle. |
| **[new] V8** | 1 | 1_000 | 1_000 | 1 | 0 | Lin | Lin | FD(1) | `handover_floor == tenure_ceiling` — upper boundary of P3. Replicates traditional fixed-term renting (§3 "handover_floor = tenure_ceiling" rationale). |
| **[new] V9** | 1 | u64::MAX | u64::MAX | 1 | 0 | Lin | Lin | FD(1) | P3 boundary at u64 extreme — guards that the `handover_floor <= tenure_ceiling` assert uses `<=` not `<`, and that both values saturated together are accepted. |
| **[new] V10** | 1 | 1_000 | 0 | 1 | 0 | Pow(2,4) | Pow(6,3) | FD(1) | PowerLaw inputs requiring gcd normalization — exercises the §7.3 "stored != raw" clause with both `credit_curve` (stored `PowerLaw{1,2}`) and `descent_curve` (stored `PowerLaw{2,1}`). |
| **[new] V11** | 1 | 1_000 | 500 | 1 | 0 | Exp(1,false) | Exp(8,true) | CD(1,1) | Extreme α values (min convex, max concave) + minimum `CompoundDelta` — exercises storage/round-trip of nested `Exponential` fields both signs. |
| **[new] V12** | 1 | 1_000 | 0 | 0 | 0 | Lin | Lin | FD(1) | `descent_ceiling = 0` — the "no price memory" variant. AtDutchAuction is structurally a transient phase under this config: Check 3 of `apply_pending_transitions` fires in the same call as Check 2 (because `phase_start_ms + 0 == phase_start_ms ≤ clock.now()`), so the escrow goes Rented → Idle in a single settlement, with `TenureExpired` and `AuctionExpired` co-emitted at the same `timestamp_ms`. `evaluate_curve` handles `t_max = 0` structurally via its `t >= t_max` guard returning SCALE — no division by zero. See `liquid-renting-protocol-design.md` §15 "Pure machine — no price memory" variant. |

**Note — unconstrained free variables:** `tenure_ceiling`, `descent_ceiling`,
and `retire_floor` have no upper bound. Absurd values (e.g. `u64::MAX`) are
accepted by `new_config`; any resulting arithmetic overflow surfaces at runtime
inside `curve` or `rental_escrow` via Move's checked arithmetic. Adding upper
bounds here would be the same mistake as the removed Logistic constraint —
validation noise for inputs that never occur in practice.

### 7.2 Invalid inputs (must abort with stated error code)

| # | Input description | Expected abort |
|---|---|---|
| I1 | min_rent_price = 0 | `E_MIN_RENT_PRICE_ZERO` |
| I2 | tenure_ceiling = 0 (all other fields valid) | `E_TENURE_CEILING_ZERO` |
| I3 | handover_floor > tenure_ceiling (floor=100, ceiling=50) | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` |
| I4 | handover_floor = tenure_ceiling + 1 (floor=1_001, ceiling=1_000) | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — smallest strictly-greater case, guards off-by-one on the `<=` check |
| I5 | handover_floor = u64::MAX, tenure_ceiling = u64::MAX − 1 | `E_HANDOVER_FLOOR_EXCEEDS_TENURE` — u64-saturated boundary, confirms the check is a plain unsigned compare (no arithmetic that could overflow) |

**Note — `descent_ceiling = 0` is valid, not an abort case.** Earlier
revisions of this spec rejected `descent_ceiling = 0` with a dedicated
abort code; that constraint was relaxed because the property emerges
correctly from the state machine (AtDutchAuction collapses to a
transient phase) and `evaluate_curve` handles `t_max = 0` structurally.
See V12 in §7.1 and the "Pure machine — no price memory" variant in
the design doc §15.

**Abort-ordering note.** The validation sequence in §3 is: `min_rent_price`
→ `tenure_ceiling` → `handover_floor <= tenure_ceiling`. Rows I1–I5 each
set exactly one field to an invalid value so the expected abort code is
unambiguous. Multi-violation inputs (e.g. `min_rent_price = 0` AND
`tenure_ceiling = 0`) are omitted — they would couple the test to the
order above. If the implementation reorders the asserts, rows I1–I5
still pass; a multi-violation row would not.


### 7.3 Getter round-trip (must hold for all valid configs)

Verifies that every value passed to `new_config` is returned unchanged by
its getter — the constructor does not transform, normalize, or discard any
field. **[property P5]** Translates as one predicate applied inside the
§7.1 parametric loop:

```
let c = new_config(mrp, tc, hf, dsc, rf, &g, &h, &pf);
assert_eq!(min_rent_price(&c),  mrp);
assert_eq!(tenure_ceiling(&c),  tc);
assert_eq!(handover_floor(&c),  hf);
assert_eq!(descent_ceiling(&c), dsc);
assert_eq!(retire_floor(&c),    rf);
assert_eq!(credit_curve(&c),    &g);
assert_eq!(descent_curve(&c),   &h);
assert_eq!(price_function(&c),  &pf);
```

**[new] Explicit round-trip rows — pin each field individually:**

| # | Field varied | Input value | Expected getter output | Note |
|---|---|---|---|---|
| R1 | `min_rent_price` | `u64::MAX` | `u64::MAX` | saturated scalar |
| R2 | `tenure_ceiling` | `86_400_000` | `86_400_000` | typical ms value |
| R3 | `handover_floor` | `0` | `0` | zero is a distinguished value (§3 rationale) |
| R4 | `descent_ceiling` | `1` | `1` | minimum valid |
| R5 | `retire_floor` | `u64::MAX` | `u64::MAX` | P4 boundary; confirms no implicit clamp |
| R6 | `credit_curve` | `new_power_law(2, 4)` (raw) | `&PowerLaw { 1, 2 }` (stored) | **gcd normalization** occurs in `curve_shape::new_power_law`, not here — the getter returns the already-reduced value. See §7.3 note below. |
| R7 | `descent_curve` | `new_logistic()` | `&Logistic` | no-field variant round-trip |
| R8 | `price_function` | `new_compound_delta(500, 100)` | `&CompoundDelta { 500, 100 }` | nested struct fields preserved |

Each row holds all other fields to the V2 canonical values (§7.0) so the
varied field is the only independent variable.

**Note on `CurveShape` gcd normalization:** `new_power_law` normalizes by
gcd before storing. Round-trip holds against the reduced value:

    g = new_power_law(2, 4)          // stored as PowerLaw { alpha_num: 1, alpha_den: 2 }
    credit_curve(&c) == &g           // &PowerLaw { 1, 2 } — correct
    credit_curve(&c) == &PowerLaw { alpha_num: 2, alpha_den: 4 }  // WRONG

This is not a `config` contract — `config::new_config` stores the value
as received. The normalization upstream is transparent at this layer.


### 7.4 `emit_registration` — event emission

Tests run in `sui::test_scenario` because `event::emit` is observable only
through transaction effects. Convention: tx1 calls
`emit_registration_for_testing(&cfg, escrow_id)`; tx2 inspects effects.

| # | Setup | Assertion |
|---|---|---|
| **[new] E1** | Build V2 config; pick `escrow_id = @0xE5C1.to_inner()` (literal ID via `#[test_only]` helper) | `num_user_events(&effects) == 1` AND `capture_registered(&effects)[0].escrow_id == escrow_id` AND `...[0].config == cfg` (struct equality — all eight fields match by value). |
| **[new] E2** | Build V10 config (PowerLaw gcd-normalized curves); emit | Event payload's `config.credit_curve == &PowerLaw { 1, 2 }` (reduced form — what was stored, not what was passed to `new_power_law`). Cross-check with the star-schema invariant: the event is self-describing, no indexer-side re-normalization needed. |
| **[new] E3** | Build V2 config; call `emit_registration_for_testing` twice on the same `(cfg, escrow_id)` pair in the same tx | `num_user_events == 2`; both payloads identical. Documents that `emit_registration` is not idempotent at the event-count level — the single-emit contract is a *caller* contract (`rental_escrow::integrate` calls it once), not a module-side guard. |

**[new] [property] P-SE — star-schema envelope invariants.** For every
row above:
1. `escrow_id` is present and non-zero (row E1 asserts the exact
   pre-built value; rows E2/E3 use the same fixture).
2. No child PK field exists on the payload — `IntegrationConfigRegistered`
   is a 1:1 satellite (§4).
3. The full `IntegrationConfig` is carried by value; the assertion
   `payload.config == cfg` holds structurally (all scalar fields equal,
   nested `CurveShape`/`PriceFunction` variant fields equal).


### 7.5 Open questions

- **Event-capture helper signature.** `capture_registered` is declared
  above as `(effects: &TransactionEffects) -> vector<IntegrationConfigRegistered>`.
  Sui framework 1.29+ provides `event::events_by_type<T>()` as a
  `test_only` entry, but the exact return shape (by-value vector vs
  reference) depends on the framework version pinned at implementation.
  Confirm at first use and adjust §7.0 helper roster.
- **Literal `ID` construction in tests.** Row E1 references
  `@0xE5C1.to_inner()` as shorthand for a fixture-owned `ID`. The
  canonical Move 2024 idiom is `object::id_from_address(@0xE5C1)` or
  `object::id_from_bytes(...)`; confirm at implementation time and fix
  the helper exposed by `config::test_helpers`.
- **Multi-violation abort ordering.** §7.2 note documents the stance
  that multi-violation inputs are out of scope. If operational needs
  later want to pin the order (e.g. SDK wants to report the "first"
  violation), promote the §3 validation order to a committed property
  and add one row per ordered pair.
- **Cross-module re-validation.** `new_config` does not re-validate
  `CurveShape` / `PriceFunction` internals (§0, §3). A test that passes
  an *unvalidated* `CurveShape` is impossible to construct — the enum
  fields are private, constructors are the only path. Document that
  `§7.1` rows exercise only already-validated curves; there is no
  "invalid curve bypasses `new_config`" row because the type system
  prevents it.


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
