> **Archive.** This spec was written during the first implementation of the protocol, before the codebase led the design. Module names, terminology, and mechanics may differ from what is currently implemented. The protocol was renamed from **Liquid Renting** to **usufruct** during development. The ultimate source of truth is the source code in `usufruct/sources/`; the current specs in `specs/` document what the code does.

---

DESCENT_POLICY MODULE — SPECIFICATION
======================================

Module: `descent_policy`
Design reference: design-compact.md §2 (state machine, AtDutchAuction)


0. MODULE RESPONSIBILITY
------------------------

`descent_policy` owns the `DescentPolicy` enum and every dispatch over it.
The policy parameterizes the **dutch-auction descent rule**: whether the
auction window exists at all, and if so, how long it lasts before the
state collapses back to `Idle`.

**Owns:**

- `DescentPolicy` — enumerated variants of the descent window rule. All
  dispatch on this type lives here.
- Variant constructors (`new_descent_skipped`, `new_descent_window`) —
  `public`, PTB-callable. Validate intra-variant invariants (e.g.,
  `Window.ceiling_ms > 0`).
- `has_expired` — bool dispatcher: has the descent window expired? Called
  by `rental_escrow::apply_pending_transitions` to gate the
  AtDutchAuction → Idle transition.
- `expiry_at` — u64 sister: returns the boundary timestamp. Used by the
  same call site to forward the boundary to `do_auction_expiry` for the
  `AuctionExpired.timestamp_ms` event payload.
- `window_ceiling` — getter for the auction window duration, consumed by
  `compute_price_descent` as the `t_max` input to the descent curve. Aborts
  on `Skipped`: the call site is structurally unreachable under that
  variant (see §5).

**Does not own:**

- `IntegrationConfig` — lives in `config`. `config` carries a `DescentPolicy`
  field and exposes a getter (`config::descent`).
- The descent curve itself — `curve_shape::evaluate_curve` evaluates the
  `descent_curve` (also in `IntegrationConfig`) over `[0, window_ceiling]`.
  This module only owns the window's existence and length, not its shape.
- Naked timestamp arithmetic — all `+` and `min` over timestamps route
  through `phases` (see `phases.spec.md` §6 P7).
- Protocol state, fund movements, event emission, access control.

**Dependency direction:** `descent_policy` calls `phases`. `config` and
`rental_escrow` call `descent_policy`. There are no inverse dependencies.


1. ERROR CONSTANTS
------------------

    const E_DESCENT_CEILING_ZERO:     u64 = 0;  // new_descent_window(0) — use Skipped
    const E_DESCENT_SKIPPED_NO_WINDOW: u64 = 1;  // window_ceiling on Skipped


2. TYPE
-------

### DescentPolicy — enum

Defines whether the dutch-auction window exists, and if so, its duration:

```move
public enum DescentPolicy has copy, drop, store {
    Skipped,
    Window { ceiling_ms: u64 },
}
```

**Variant semantics:**

| Variant | Boundary timestamp | Operational meaning |
|---------|--------------------|---------------------|
| `Skipped` | `phase_start_ms` | The auction collapses immediately — `AtDutchAuction → Idle` in one APT step. The variant is structurally unobservable (see §5). |
| `Window { ceiling_ms }` | `phase_start_ms + ceiling_ms` | Auction descends from `last_acquisition_price` toward `min_rent_price` over `ceiling_ms`, then collapses to `Idle` if no buyer. |

**Field-level constraints (validated by constructors in §2.3):**

- `Window`: `ceiling_ms > 0`. Zero ceiling means "no auction" — the `Skipped`
  variant is the canonical encoding.

No cross-field constraints.


### 2.3 Constructors

Enum variants are private to `descent_policy.move` (Move 2024 enforces
this — variants of a `public enum` declared in another module cannot be
constructed externally). External callers — including PTB integrators
assembling an `IntegrationConfig` — must construct `DescentPolicy` values
through these functions:

    public fun new_descent_skipped(): DescentPolicy

    public fun new_descent_window(ceiling_ms: u64): DescentPolicy
    // Validates:
    //   assert!(ceiling_ms > 0, E_DESCENT_CEILING_ZERO)


3. `has_expired`
----------------

### Signature

    public(package) fun has_expired(
        policy:         &DescentPolicy,
        phase_start_ms: u64,
        now_ms:         u64,
    ): bool

### Semantics

True iff the descent window has expired — the auction should collapse to
`Idle`.

```move
match (policy) {
    Skipped               => phases::has_passed(phase_start_ms, 0,           now_ms),
    Window { ceiling_ms } => phases::has_passed(phase_start_ms, *ceiling_ms, now_ms),
}
```

**Vacuous-variant note:** `Skipped` gates through
`phases::has_passed(phase_start_ms, 0, now_ms)` (= `now_ms >= phase_start_ms`),
not `=> true`. This makes the dispatcher monotone in `now_ms` for every
variant and preserves the **sister identity** (§6 P1) unconditionally — the
auction collapses AT phase entry, never vacuously before. In production
with clock-monotone, the two formulations are observationally identical.
See `handover_policy.spec.md` §6 P3 for the architectural rationale shared
across all policy modules.


4. `expiry_at`
--------------

### Signature

    public(package) fun expiry_at(
        policy:         &DescentPolicy,
        phase_start_ms: u64,
    ): u64

### Semantics

Canonical auction-collapse boundary timestamp — the moment at which
`do_auction_expiry` fires.

```move
match (policy) {
    Skipped               => phase_start_ms,
    Window { ceiling_ms } => phases::boundary_at(phase_start_ms, *ceiling_ms),
}
```

### Why both `has_expired` and `expiry_at` exist

The bool form is sufficient for the gating decision in
`apply_pending_transitions`. The u64 form is consumed at one non-gate site:
`do_auction_expiry` receives the boundary as `boundary_ms` and emits it as
`AuctionExpired.timestamp_ms` — the canonical "as-of" time of the auction
collapse for off-chain consumers. The sister identity (§6 P1) pins them to
one truth.


5. `window_ceiling`
-------------------

### Signature

    public(package) fun window_ceiling(policy: &DescentPolicy): u64

### Semantics

Width of the descent window. Used by `compute_price_descent` as the `t_max`
input to `curve_shape::evaluate_curve` over the descent curve.

```move
match (policy) {
    Window { ceiling_ms } => *ceiling_ms,
    Skipped               => abort E_DESCENT_SKIPPED_NO_WINDOW,
}
```

### Why the abort on `Skipped`

`window_ceiling` is called from `compute_price_descent`, which is itself
only invoked from `compute_floor_price`'s `AtDutchAuction` branch. Under
`Skipped`, the auction collapses to `Idle` in a single APT step (see §3
and `has_expired` semantics) — `AtDutchAuction` is **structurally
unobservable** under this policy, so `compute_price_descent` cannot be
reached either.

The abort is the deterministic-failure contract for an otherwise
unreachable path: a future refactor that breaks the unobservability
invariant fires `E_DESCENT_SKIPPED_NO_WINDOW` instead of returning a
wrong value silently. The unreachability is design-level (spec M6b / Q11
in `rental_escrow.spec.md`), not enforced by the type system.


6. PROPERTIES
-------------

### P1 — Sister identity (load-bearing, unconditional)

For every `(policy, phase_start, now)`:

    has_expired(policy, phase_start, now)
        ⇔
    now >= expiry_at(policy, phase_start)

Architectural invariant — the bool dispatcher and the u64 dispatcher must
agree on every input. Holds **unconditionally** including for `Skipped`
under degenerate `now < phase_start`, thanks to the defensive-monotone
implementation of the vacuous arm.

Verified by `descent_policy_tests::has_expired_iff_now_ge_expiry_at`.

### P2 — Monotone in `now`

For every `(policy, phase_start, n)`:

    has_expired(policy, phase_start, n) = true
        ⇒
    ∀k ≥ 0,  has_expired(policy, phase_start, n + k) = true

Both variants gate through `phases::has_passed`; both monotone. Verified
implicitly by table boundary triples in
`descent_policy_tests::has_expired_table`.

### P3 — Defensive-monotone vacuous variant

Same architectural rationale as `handover_policy.spec.md` §6 P3: `Skipped`
gates through `phases::has_passed(phase_start_ms, 0, now_ms)`, not
`=> true`. Every variant routes through the time layer; none are vacuous.

### P4 — Variant invariants

| Variant | `expiry_at` returns | `window_ceiling` |
|---------|---------------------|------------------|
| `Skipped` | `phase_start_ms` | aborts (`E_DESCENT_SKIPPED_NO_WINDOW`) |
| `Window { ceiling_ms }` | `phase_start_ms + ceiling_ms` | `ceiling_ms` |

Verified by `descent_policy_tests::expiry_at_table`,
`descent_policy_tests::window_ceiling_returns_ceiling_for_window`, and
`descent_policy_tests::window_ceiling_aborts_on_skipped`.

### P5 — Identity on `window_ceiling(Window)`

For every `c > 0`:

    window_ceiling(new_descent_window(c)) = c

The constructor stores `ceiling_ms` verbatim and the getter returns it
verbatim. Verified by
`descent_policy_tests::window_ceiling_returns_ceiling_for_window`.


7. TEST STRATEGY
----------------

Pure arithmetic — no `test_scenario`, no objects. Tests live in
`tests/descent_policy_tests.move`.

**Per dispatcher:**

- Variant coverage in tables for each of `has_expired`, `expiry_at`,
  `window_ceiling`.
- Boundary triple (before / at / after) for `has_expired` per variant.
- Window-ceiling identity sweep across realistic ceilings (1 ms, 50 ms,
  10 s, 1 day).

**Cross-dispatcher (architectural):**

- `has_expired_iff_now_ge_expiry_at` — sister identity sweep, holds
  unconditionally after the defensive-monotone refactor.

**Aborts:**

- `new_descent_window_rejects_zero` — pins
  `E_DESCENT_CEILING_ZERO`.
- `window_ceiling_aborts_on_skipped` — pins
  `E_DESCENT_SKIPPED_NO_WINDOW` as the contract for the unreachable
  path.

Total: 6 test functions, ~30 assertions through table sweeps.


8. MODULE BOUNDARY
------------------

**Inputs:** `&DescentPolicy` references + `u64` timestamps and durations.

**Outputs:** `bool` for the gate, `u64` for boundaries and ceilings.

**State:** none. **Events:** none. **Objects:** none.

**Visibility:**

- `public` on the variant constructors (`new_descent_*`) — PTB-callable.
- `public(package)` on the dispatchers (`has_expired`, `expiry_at`,
  `window_ceiling`).
- `public enum DescentPolicy` — externally visible as a type for
  `IntegrationConfig`'s field; variants are not externally constructible.

**Calls:** `phases::has_passed`, `phases::boundary_at`. Nothing else.
