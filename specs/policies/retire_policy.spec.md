RETIRE_POLICY MODULE — SPECIFICATION
=====================================

Module: `retire_policy`
Design reference: design-compact.md §2 (state machine, Retire transitions)


0. MODULE RESPONSIBILITY
------------------------

`retire_policy` owns the `RetirePolicy` enum and every dispatch over it.
The policy parameterizes the **retire unlock rule**: whether `retire()` may
be called immediately upon integration, or only after a deferred floor
elapses.

**Owns:**

- `RetirePolicy` — enumerated variants of the unlock rule. All dispatch on
  this type lives here.
- Variant constructors (`new_retire_immediate`, `new_retire_deferred`) —
  `public`, PTB-callable. Validate intra-variant invariants (e.g.,
  `Deferred.floor_ms > 0`).
- `is_unlocked` — bool dispatcher: may `retire()` proceed? Called by
  `rental_escrow::retire` to gate the operation.

**Does not own:**

- A u64 sister dispatcher. Unlike `handover_policy` and `descent_policy`,
  `retire_policy` exposes only the bool view. The unlock timestamp has no
  non-gate consumer downstream — `retire()` either proceeds or aborts;
  nothing reads or emits the unlock time. See §4 P3.
- `IntegrationConfig` — lives in `config`. `config` carries a `RetirePolicy`
  field and exposes a getter (`config::retire`).
- Naked timestamp arithmetic — all `+` over timestamps route through
  `phases` (see `phases.spec.md` §6 P7).
- Protocol state, fund movements, event emission, access control.

**Dependency direction:** `retire_policy` calls `phases`. `config` and
`rental_escrow` call `retire_policy`. There are no inverse dependencies.


1. ERROR CONSTANTS
------------------

    const E_RETIRE_FLOOR_ZERO: u64 = 0;  // new_retire_deferred(0) — use Immediate

The retire-gate abort `E_RETIRE_FLOOR_NOT_ELAPSED` lives in `rental_escrow`
because the `retire()` entry function raises it; this module provides only
the bool predicate (`is_unlocked`).


2. TYPE
-------

### RetirePolicy — enum

Defines the unlock rule for `retire()`:

```move
public enum RetirePolicy has copy, drop, store {
    Immediate,
    Deferred { floor_ms: u64 },
}
```

**Variant semantics:**

| Variant | Unlock rule |
|---------|-------------|
| `Immediate` | `retire()` may be called from integration onward. |
| `Deferred { floor_ms }` | `retire()` may be called once `floor_ms` has elapsed since `integrated_at_ms`. |

**Field-level constraints (validated by constructors in §2.3):**

- `Deferred`: `floor_ms > 0`. Zero floor means "immediate" — the `Immediate`
  variant is the canonical encoding.

No cross-field constraints.


### 2.3 Constructors

Enum variants are private to `retire_policy.move` (Move 2024 enforces
this — variants of a `public enum` declared in another module cannot be
constructed externally). External callers — including PTB integrators
assembling an `IntegrationConfig` — must construct `RetirePolicy` values
through these functions:

    public fun new_retire_immediate(): RetirePolicy

    public fun new_retire_deferred(floor_ms: u64): RetirePolicy
    // Validates:
    //   assert!(floor_ms > 0, E_RETIRE_FLOOR_ZERO)


3. `is_unlocked`
----------------

### Signature

    public(package) fun is_unlocked(
        policy:           &RetirePolicy,
        integrated_at_ms: u64,
        now_ms:           u64,
    ): bool

### Semantics

True iff `retire()` may proceed.

```move
match (policy) {
    Immediate             => phases::has_passed(integrated_at_ms, 0,         now_ms),
    Deferred { floor_ms } => phases::has_passed(integrated_at_ms, *floor_ms, now_ms),
}
```

**Vacuous-variant note:** `Immediate` gates through
`phases::has_passed(integrated_at_ms, 0, now_ms)` (= `now_ms >=
integrated_at_ms`), not `=> true`. Every variant routes through the time
layer; none are vacuous. In production with clock-monotone, the two
formulations are observationally identical. See `handover_policy.spec.md`
§6 P3 for the architectural rationale shared across all policy modules.


4. PROPERTIES
-------------

### P1 — Monotone in `now`

For every `(policy, integrated_at, n)`:

    is_unlocked(policy, integrated_at, n) = true
        ⇒
    ∀k ≥ 0,  is_unlocked(policy, integrated_at, n + k) = true

Both variants gate through `phases::has_passed`; both monotone. Once the
gate opens, it stays open under clock advancement. Verified by
`retire_policy_tests::is_unlocked_monotone_in_now_under_deferred` and
implicitly by table cases for `Immediate`.

### P2 — Variant invariants

| Variant | `is_unlocked(p, integrated_at, now)` |
|---------|--------------------------------------|
| `Immediate` | `now >= integrated_at` |
| `Deferred { floor_ms }` | `now >= integrated_at + floor_ms` |

Verified by `retire_policy_tests::is_unlocked_table`.

### P3 — Defensive-monotone vacuous variant (no u64 sister)

`Immediate` gates through `phases::has_passed`, not `=> true`. Same
architectural rationale as `handover_policy.spec.md` §6 P3.

Unlike `handover_policy` and `descent_policy`, `retire_policy` exposes
**no `unlock_at` u64 sister**. This is a deliberate design decision
(documented in the refactor that introduced the layer): the unlock
timestamp has no non-gate consumer downstream — `retire()` either
proceeds or aborts; no event payload, no time-clamp, no boundary
forwarding. Without a downstream consumer, the u64 view is dead weight,
and the policy module's surface is the smaller for omitting it.

The architectural property the bool-only design preserves:
**every operation through the time layer is intentional**. Adding a
function with no consumer would erode this — and once added, future
contributors might consume it casually, building dependence on a
non-load-bearing API.

If a downstream consumer ever emerges (e.g., emit `unlock_at` in a future
`AssetRetired` event payload), `unlock_at` is trivially derivable: for
`Deferred`, `boundary_at(integrated_at, floor_ms)`; for `Immediate`,
`integrated_at`. Adding the dispatcher then is mechanical.


5. TEST STRATEGY
----------------

Pure arithmetic — no `test_scenario`, no objects. Tests live in
`tests/retire_policy_tests.move`.

**Per dispatcher:**

- Variant coverage in `is_unlocked_table`.
- Boundary triple (before / at / after) for `is_unlocked` per variant.
- Realistic protocol-scale values (multi-hour `floor_ms`).

**Behavioral:**

- `is_unlocked_monotone_in_now_under_deferred` — sweep `now` across the
  boundary; once true, stays true.

**Aborts:**

- `new_retire_deferred_rejects_zero` — pins `E_RETIRE_FLOOR_ZERO`.

**No sister identity test** — there is no u64 sister dispatcher to compare
against (see §4 P3). The architectural backstop that exists for
`handover_policy` and `descent_policy` is intentionally absent here.

Total: 3 test functions, ~15 assertions through table sweeps.


6. MODULE BOUNDARY
------------------

**Inputs:** `&RetirePolicy` references + `u64` timestamps.

**Outputs:** `bool` only. No `u64` outputs.

**State:** none. **Events:** none. **Objects:** none.

**Visibility:**

- `public` on the variant constructors (`new_retire_*`) — PTB-callable.
- `public(package)` on `is_unlocked`.
- `public enum RetirePolicy` — externally visible as a type for
  `IntegrationConfig`'s field; variants are not externally constructible.

**Calls:** `phases::has_passed`. Nothing else.
