HANDOVER_POLICY MODULE — SPECIFICATION
=======================================

Module: `handover_policy`
Design reference: design-compact.md §2 (state machine, HandoverConfirmed)
                  design-compact.md §3 (handover funds distribution)


0. MODULE RESPONSIBILITY
------------------------

`handover_policy` owns the `HandoverPolicy` enum and every dispatch over it.
The policy parameterizes the **handover countdown rule**: how long the protocol
waits between a bid landing in `HandoverOpen` (transitioning the state to
`HandoverConfirmed`) and the actual handover firing.

**Owns:**

- `HandoverPolicy` — enumerated variants of the handover countdown rule. All
  dispatch on this type lives here.
- Variant constructors (`new_handover_instant`, `new_handover_countdown`,
  `new_handover_fixed_time`) — `public`, PTB-callable. Validate intra-variant
  invariants (e.g., `Countdown.floor_ms > 0`).
- `has_expired` — bool dispatcher: has the handover countdown reached its
  boundary? Called by `rental_escrow::apply_pending_transitions` to gate the
  HandoverConfirmed → handover-fires transition.
- `expiry_at` — u64 sister: returns the boundary timestamp itself. Used by
  the same call site to forward the canonical "as-of" time to `do_handover`,
  by `compute_used_credit` to clamp credit accrual at the boundary, and by
  `do_place_bid` to emit `BidPlaced.handover_countdown_expiry`.
- `countdown_floor_lt` — cross-field predicate consumed by `config::new_config`
  to enforce `Countdown.floor_ms < tenure_ceiling`. Encapsulated here because
  pattern-matching on enum variants is restricted to the defining module
  (Move 2024 E04001).

**Does not own:**

- `IntegrationConfig` — lives in `config`. `config` carries a `HandoverPolicy`
  field and delegates to this module for the cross-field check.
- Reading the clock — `rental_escrow` extracts `now` once from
  `clock::timestamp_ms` and forwards it.
- Naked timestamp arithmetic — all `+` and `min` over timestamps route
  through `phases` (see `phases.spec.md` §6 P7).
- Protocol state, fund movements, event emission, access control.

**Dependency direction:** `handover_policy` calls `phases`. `config` and
`rental_escrow` call `handover_policy`. There are no inverse dependencies.


1. ERROR CONSTANTS
------------------

    const E_HANDOVER_FLOOR_ZERO: u64 = 0;  // new_handover_countdown(0) — use Instant

The cross-field error `E_HANDOVER_FLOOR_EXCEEDS_TENURE` lives in `config`
because `config::new_config` is the call site that raises it; this module
provides the predicate (`countdown_floor_lt`) that informs the assert but
does not own the abort code.


2. TYPE
-------

### HandoverPolicy — enum

Defines the handover countdown rule. Three variants cover the three
operational regimes for "how long does the bid wait before handover fires":

```move
public enum HandoverPolicy has copy, drop, store {
    Instant,
    Countdown { floor_ms: u64 },
    FixedTime,
}
```

**Variant semantics:**

| Variant | Boundary timestamp | Operational meaning |
|---------|--------------------|---------------------|
| `Instant` | `bid_time_ms` | Handover fires at the moment of the bid (zero countdown). |
| `Countdown { floor_ms }` | `min(bid_time_ms + floor_ms, phase_start_ms + tenure_ceiling)` | Handover fires after `floor_ms` from the bid, but never later than the tenure boundary. |
| `FixedTime` | `phase_start_ms + tenure_ceiling` | Handover fires at the tenure boundary regardless of when the bid landed. |

**Field-level constraints (validated by constructors in §2.3):**

- `Countdown`: `floor_ms > 0`. Zero floor means "instant" — the `Instant`
  variant is the canonical encoding.

**Cross-field constraint (validated by `config::new_config` via
`countdown_floor_lt`, §5):**

- `Countdown.floor_ms < tenure_ceiling`. Equality is the `FixedTime` variant
  — a separate operational mode, not the upper edge of `Countdown`.


### 2.3 Constructors

Enum variants are private to `handover_policy.move` (Move 2024 enforces
this — variants of a `public enum` declared in another module cannot be
constructed externally). External callers — including PTB integrators
assembling an `IntegrationConfig` — must construct `HandoverPolicy` values
through these functions:

    public fun new_handover_instant():    HandoverPolicy
    public fun new_handover_fixed_time(): HandoverPolicy

    public fun new_handover_countdown(floor_ms: u64): HandoverPolicy
    // Validates:
    //   assert!(floor_ms > 0, E_HANDOVER_FLOOR_ZERO)


3. `has_expired`
----------------

### Signature

    public(package) fun has_expired(
        policy:         &HandoverPolicy,
        bid_time_ms:    u64,
        phase_start_ms: u64,
        tenure_ceiling: u64,
        now_ms:         u64,
    ): bool

### Semantics

True iff the handover countdown has reached its boundary — the protocol
should fire the pending bid.

```move
match (policy) {
    Instant   => phases::has_passed(bid_time_ms,    0,              now_ms),
    FixedTime => phases::has_passed(phase_start_ms, tenure_ceiling, now_ms),
    Countdown { floor_ms } =>
        phases::has_passed(bid_time_ms,    *floor_ms,      now_ms) ||
        phases::has_passed(phase_start_ms, tenure_ceiling, now_ms),
}
```

**Vacuous-variant note:** `Instant` is implemented as
`phases::has_passed(bid_time_ms, 0, now_ms)` (= `now_ms >= bid_time_ms`),
not as `=> true`. This makes the dispatcher monotone in `now_ms` for every
variant and preserves the **sister identity** (§6 P1) unconditionally — the
gate opens AT the bid moment, never vacuously before. In production with
clock-monotone, the two formulations are observationally identical. See §6
for the architectural rationale.

**Countdown saturation rule:** the bool form `has_passed(A) || has_passed(B)`
is the algebraic dual of the u64 form `now >= min(A, B)`. The disjunction
expresses the saturation directly without computing the intermediate `min`
— a discovery that motivated the bool API. See `expiry_at` (§4) for the u64
form that does compute the boundary explicitly.


4. `expiry_at`
--------------

### Signature

    public(package) fun expiry_at(
        policy:         &HandoverPolicy,
        bid_time_ms:    u64,
        phase_start_ms: u64,
        tenure_ceiling: u64,
    ): u64

### Semantics

Canonical handover boundary timestamp — the moment at which the pending
bid finalizes. Sister view of `has_expired`.

```move
match (policy) {
    Instant   => bid_time_ms,
    FixedTime => phases::boundary_at(phase_start_ms, tenure_ceiling),
    Countdown { floor_ms } =>
        phases::earliest(
            phases::boundary_at(bid_time_ms,    *floor_ms),
            phases::boundary_at(phase_start_ms, tenure_ceiling),
        ),
}
```

### Why both `has_expired` and `expiry_at` exist

The bool form is sufficient for the gating decision (`if expired then fire`),
but the boundary timestamp itself is consumed at non-gate sites:

- `compute_used_credit` clamps the effective accrual time at `expiry_at` — credit
  freezes when handover triggers, regardless of how much later the cascade
  actually executes.
- `BidPlaced.handover_countdown_expiry` event payload — off-chain consumers
  read the canonical boundary timestamp.
- `do_handover` receives the boundary as `boundary_ms` and propagates it to
  `compute_used_credit` and the `HandoverCompleted.timestamp_ms` event.

Two parallel views of the same concept: bool answers "did it cross?", u64
answers "when?". The sister identity (§6 P1) pins them to one truth.


5. `countdown_floor_lt`
-----------------------

### Signature

    public(package) fun countdown_floor_lt(policy: &HandoverPolicy, ceiling: u64): bool

### Semantics

True iff a `Countdown` variant's `floor_ms` is strictly less than `ceiling`.
`Instant` and `FixedTime` carry no countdown floor and satisfy the predicate
vacuously.

```move
match (policy) {
    Countdown { floor_ms } => *floor_ms < ceiling,
    Instant | FixedTime    => true,
}
```

### Why this predicate lives here

`config::new_config` enforces the cross-field constraint
`Countdown.floor_ms < tenure_ceiling`. The constraint is on a field of a
variant, so the check requires pattern-matching on `HandoverPolicy`. Move 2024
restricts variant matching to the defining module (E04001), so config cannot
match directly — it calls this predicate, which encapsulates the match.

Equality (`floor_ms == tenure_ceiling`) is the `FixedTime` variant, a
separate operational mode. The strict less-than reflects this.


6. PROPERTIES
-------------

### P1 — Sister identity (load-bearing, unconditional)

For every `(policy, bid_time, phase_start, tenure, now)`:

    has_expired(policy, bid_time, phase_start, tenure, now)
        ⇔
    now >= expiry_at(policy, bid_time, phase_start, tenure)

The bool dispatcher and the u64 dispatcher must agree on every input. This
is the architectural invariant the policy layer rests on. If anyone changes
the saturation rule in `expiry_at` without updating `has_expired` (or vice
versa), this property fires.

**Unconditionally** holds — including for `Instant` under degenerate inputs
where `now < bid_time`. The vacuous-variant defensive-monotone refactor
(see §6 P3) is what makes this true; before that refactor, `Instant`
returned `=> true` and the identity broke whenever `now < bid_time`.

Verified by `handover_policy_tests::has_expired_iff_now_ge_expiry_at`.

### P2 — Monotone in `now`

For every `(policy, bid_time, phase_start, tenure, n)`:

    has_expired(policy, bid_time, phase_start, tenure, n) = true
        ⇒
    ∀k ≥ 0,  has_expired(policy, bid_time, phase_start, tenure, n + k) = true

Every variant gates through `phases::has_passed` (or a disjunction of two),
each of which is monotone. The disjunction preserves monotonicity. Verified
by `handover_policy_tests::has_expired_monotone_in_now_under_countdown`.

### P3 — Defensive-monotone vacuous variants

The `Instant` variant gates through `phases::has_passed(bid_time_ms, 0,
now_ms)`, not `=> true`. Rationale: a vacuous gate is non-monotone and
breaks the sister identity (P1). Defensive monotonicity preserves both
properties unconditionally — and in production, where clock-monotone always
holds, the two formulations are observationally identical.

This pattern applies to **every** vacuous-feeling variant across the policy
layer (`descent_policy::Skipped`, `retire_policy::Immediate`). The
architectural rule: every variant of every dispatcher routes through the
time layer; none are vacuous. See `descent_policy.spec.md` §6 P3 and
`retire_policy.spec.md` §4 P3.

### P4 — Variant invariants

| Variant | `expiry_at` returns | Independent of |
|---------|---------------------|----------------|
| `Instant` | `bid_time_ms` | `phase_start`, `tenure` |
| `FixedTime` | `phase_start_ms + tenure_ceiling` | `bid_time` |
| `Countdown` | `min(bid_time + floor, phase_start + tenure)` | (depends on all) |

Verified by `handover_policy_tests::expiry_at_table` (the FixedTime row
explicitly varies `bid_time` to confirm independence).

### P5 — Saturation invariant on `Countdown.expiry_at`

For every `(bid_time, phase_start, tenure, floor)` where `Countdown { floor }`
is well-formed:

    expiry_at(Countdown{floor}, bid_time, phase_start, tenure)
        <= phase_start + tenure

The countdown can only fire at or before the tenure boundary, never after.
This is the `min` half of the saturation rule. Implicit in the definition
via `phases::earliest`; spot-checked by table cases in
`handover_policy_tests::expiry_at_table`.


7. TEST STRATEGY
----------------

Pure arithmetic — no `test_scenario`, no objects. Tests live in
`tests/handover_policy_tests.move`.

**Per dispatcher:**

- Variant coverage: every variant of every dispatcher exercised in a table.
- Boundary triple (before / at / after) for `has_expired` per variant
  (per branch of the `||` for `Countdown`).
- Independence cases for the variants whose invariants assert it
  (`FixedTime`'s independence from `bid_time`, `Instant`'s independence from
  `phase_start`/`tenure`).

**Cross-dispatcher (architectural):**

- `has_expired_iff_now_ge_expiry_at` — sister identity sweep across every
  variant × position-relative-to-boundary. THE test that the policy-layer
  refactor exists to make verifiable.

**Behavioral:**

- `has_expired_monotone_in_now_under_countdown` — sweep `now` across the
  boundaries; once true, stays true. Catches comparator inversion and
  mis-encoded disjunction (`&&` instead of `||`).

**Aborts:**

- `new_handover_countdown_rejects_zero` — pins
  `E_HANDOVER_FLOOR_ZERO` as the abort code.

Total: 6 test functions, ~80 assertions through table sweeps.


8. MODULE BOUNDARY
------------------

**Inputs:** `&HandoverPolicy` references + `u64` timestamps and durations.

**Outputs:** `bool` for gates and predicates, `u64` for boundaries.

**State:** none. **Events:** none. **Objects:** none.

**Visibility:**

- `public` on the variant constructors (`new_handover_*`) — PTB-callable for
  external integrators assembling `IntegrationConfig`.
- `public(package)` on the dispatchers (`has_expired`, `expiry_at`,
  `countdown_floor_lt`) — internal to the package; consumed by `config` and
  `rental_escrow`.
- `public enum HandoverPolicy` — externally visible as a type for
  `IntegrationConfig`'s field; variants are not externally constructible.

**Calls:** `phases::has_passed`, `phases::boundary_at`, `phases::earliest`.
Nothing else.
