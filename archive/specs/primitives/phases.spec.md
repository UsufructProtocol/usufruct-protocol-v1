> **Archive.** This spec was written during the first implementation of the protocol, before the codebase led the design. Module names, terminology, and mechanics may differ from what is currently implemented. The protocol was renamed from **Liquid Renting** to **usufruct** during development. The ultimate source of truth is the source code in `usufruct/sources/`; the current specs in `specs/` document what the code does.

---

PHASES MODULE — SPECIFICATION
==============================

Module: `phases`
Design reference: design-compact.md §2 (state-machine clock semantics)


0. MODULE RESPONSIBILITY
------------------------

`phases` is the time-layer abstraction of the protocol. It owns every operation
that takes a timestamp as input — comparisons against the clock, arithmetic on
durations, saturation on subtractions, minimum-of-timestamps. No protocol
types, no objects, no Sui framework dependencies.

The module exists to enforce a **single-owner property** for temporal logic:
no module outside `phases` performs a naked `+`, `<`, `>=`, or `min` on a
value whose semantic is a timestamp. Any future evolution of time semantics
(clock skew, unit changes, saturation rules) has one home.

**Owns:**

- `has_passed` — bool primitive: has the clock crossed an `anchor + duration`
  boundary? Used by every policy module's bool dispatcher and by the
  HandoverOpen branch of `rental_escrow::apply_pending_transitions`.
- `elapsed_since` — saturating subtraction `now - start`, returning 0 when
  `now < start`. Used by `compute_used_credit` and `compute_price_descent`
  to derive curve-input "elapsed since phase start" without underflow.
- `boundary_at` — u64 sister of `has_passed`. Returns the boundary
  timestamp `anchor + duration` itself, for downstream consumers that need
  the value (event payloads, `do_handover` cascade, credit clamps).
- `earliest` — `min` over two timestamps. Used both for clock-vs-boundary
  clamps (`compute_used_credit`) and boundary-vs-boundary saturation
  (`handover_policy::expiry_at` Countdown rule).

**Does not own:**

- Reading the clock — `clock::timestamp_ms` is called by `rental_escrow` at
  entry points; `phases` only operates on already-extracted u64 values.
- Policy semantics — each `*_policy` module owns its own enum, dispatch
  table, and the meaning of "expired" / "unlocked" for its variants.
- Protocol state, fund movements, access control, event emission.

**Dependency direction:** `phases` calls only `std::u64`. Every other
module that performs timestamp arithmetic (handover_policy, descent_policy,
retire_policy, rental_escrow) calls into `phases`. There are no inverse
dependencies.


1. ERROR CONSTANTS
------------------

None. `phases` raises only Move's built-in `arithmetic_error` on u64
overflow in `+` (paths: `has_passed`, `boundary_at` when
`anchor_ms + duration_ms > u64::MAX`). Saturating operations
(`elapsed_since`, `earliest`) cannot abort.


2. `has_passed`
---------------

### Signature

    public(package) fun has_passed(anchor_ms: u64, duration_ms: u64, now_ms: u64): bool

### Semantics

    result = (now_ms >= anchor_ms + duration_ms)

The bool primitive that all policy modules use to express "this phase
boundary has been crossed". Calling sites express the gate without writing
a comparison operator.

### Aborts

- `anchor_ms + duration_ms > u64::MAX` → Move arithmetic abort.

### Algebraic identity

For any `(anchor, duration, now)` such that `anchor + duration` does not
overflow:

    has_passed(anchor, duration, now)  ⇔  now >= boundary_at(anchor, duration)

This is the time-layer **sister identity** between the bool view and the
u64 view. See §6 P1.


3. `elapsed_since`
------------------

### Signature

    public(package) fun elapsed_since(start_ms: u64, now_ms: u64): u64

### Semantics

    result = if now_ms >= start_ms then now_ms - start_ms else 0

Saturating subtraction. The "before start" case returns 0 instead of
underflowing, so the caller does not need to guard against historical
timestamps.

### Aborts

Never. The conditional branch eliminates underflow on `-`.

### Algebraic identity

For any `(start, now)` such that `now >= start`:

    elapsed_since(start, now) + start = now

(Information-preserving in the non-saturated regime — see §6 P3.)


4. `boundary_at`
----------------

### Signature

    public(package) fun boundary_at(anchor_ms: u64, duration_ms: u64): u64

### Semantics

    result = anchor_ms + duration_ms

The u64 sister of `has_passed`. Names the boundary timestamp itself for
downstream consumers (`BidPlaced.handover_countdown_expiry` event payload,
`do_handover` boundary forwarding, `compute_used_credit` clamp ceiling).

### Aborts

- `anchor_ms + duration_ms > u64::MAX` → Move arithmetic abort.


5. `earliest`
-------------

### Signature

    public(package) fun earliest(a_ms: u64, b_ms: u64): u64

### Semantics

    result = u64::min(a_ms, b_ms)

Earlier of two timestamps. Used in two distinct contexts:

- **Clock vs boundary clamp** — `earliest(now, expiry)` in
  `compute_used_credit`: credit accrual freezes at `expiry`, so the effective
  time used in curve evaluation is the smaller of the clock and the freeze
  boundary.
- **Boundary vs boundary saturation** — `earliest(countdown_boundary,
  tenure_boundary)` in `handover_policy::expiry_at` Countdown: the policy
  fires at whichever sub-boundary comes first.

### Aborts

Never. `min` cannot overflow.


6. PROPERTIES
-------------

### P1 — Sister identity (load-bearing)

For all `(anchor, duration, now)` where `anchor + duration` does not
overflow:

    has_passed(anchor, duration, now)  ⇔  now >= boundary_at(anchor, duration)

The bool dispatcher and the u64 dispatcher must agree on every input. This
is the architectural invariant the time layer rests on. Every policy module
exposes the same identity at its own level; this primitive identity is the
one they all collapse to.

Verified by `phases_tests::has_passed_iff_now_ge_boundary_at`.

### P2 — Monotone in `now`

For all `(anchor, duration, n)`:

    has_passed(anchor, duration, n) = true  ⇒
        ∀k ≥ 0,  has_passed(anchor, duration, n + k) = true

Once the gate fires, it stays fired under clock advancement (the protocol's
clock-non-decreasing precondition). Verified inline in
`phases_tests::has_passed_table_and_monotone_in_now`.

### P3 — Reciprocal of `elapsed_since` in the non-saturated regime

For all `(start, now)` where `now >= start`:

    elapsed_since(start, now) + start = now

The function is information-preserving when no saturation occurs.
Verified inline in
`phases_tests::elapsed_since_table_and_reciprocal_when_after_start`.

### P4 — Saturation of `elapsed_since`

For all `(start, now)` where `now < start`:

    elapsed_since(start, now) = 0

Verified by table cases in
`phases_tests::elapsed_since_table_and_reciprocal_when_after_start`.

### P5 — Commutativity of `earliest`

For all `(a, b)`:

    earliest(a, b) = earliest(b, a)

Verified inline in `phases_tests::earliest_table_and_commutative`.

### P6 — Idempotent `earliest`

For all `a`:

    earliest(a, a) = a

Verified by table case in `phases_tests::earliest_table_and_commutative`.

### P7 — Single-owner architectural invariant (mechanically chequeable)

`phases` is the **only** module in the codebase that performs `+` or
`u64::min` on values whose semantic is a timestamp. Verifiable by a single
grep:

    grep -nE "_ms\s*\+|u64::min" usufruct/sources/*.move \
        | grep -v "phases.move"

This grep returns no code hits in any other source file (a single
docstring mention of `phase_start_ms + tenure_ceiling` in
`handover_policy.move` describing the boundary semantically is the only
non-code match). Any future change that introduces naked timestamp
arithmetic outside `phases` will surface in this grep — the property is
not "we try to keep it that way" but "we can mechanically check it."

The discriminator suffix `_ms` is what makes the grep precise: `+` over
arbitrary `u64` is too broad to enforce as a single-owner property.
Tagging timestamps with a unit suffix at every call boundary is the price
that lets the architectural invariant be cheap to verify.


7. TEST STRATEGY
----------------

Pure arithmetic — no `test_scenario`, no objects, no `TxContext`. Tests live
in `tests/phases_tests.move`.

**Per primitive:**

- Boundary triple (before / at / after) for every comparator-based primitive.
- Edge cases: zero anchor, zero duration, `u64::MAX` clock, last representable
  boundary (anchor + duration == u64::MAX).
- Algebraic invariant alongside the pinned table value where one applies
  (monotonicity sweep for `has_passed`, reciprocal for `elapsed_since`,
  commutativity for `earliest`).

**Cross-primitive:**

- Sister identity `has_passed_iff_now_ge_boundary_at` — sweeps every variant
  shape and asserts the bool view and u64 view agree. The architectural
  backstop.

**Aborts:**

- `has_passed_overflow_in_anchor_plus_duration_aborts` — pins the arithmetic
  abort contract for the `+` overflow path.
- `boundary_at_overflow_aborts` — same for `boundary_at`.

Total: 7 test functions, ~50 assertions through table sweeps.


8. MODULE BOUNDARY
------------------

**Inputs:** `u64` timestamps and durations from callers (already extracted
from the Sui clock or from escrow state).

**Outputs:** `bool` for gates, `u64` for boundaries / elapsed times.

**State:** none. **Events:** none. **Objects:** none.

**Visibility:** all four primitives are `public(package)`. Not PTB-callable —
the time layer is internal infrastructure consumed by the policy and escrow
modules within the package. External callers go through policy dispatchers
or escrow entry functions, which extract the clock once and forward `u64`
values into the layer.

**Calls:** `std::u64::min` (in `earliest`). Nothing else.
