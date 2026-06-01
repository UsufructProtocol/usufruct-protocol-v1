# tenure_duration_policy

## § OVERVIEW

Sets the maximum length of a single tenure. The tenure ceiling is the clock boundary after which the current usufructuary's borrow right expires and the state machine must advance (either to a new auction or directly to idle). A fixed ceiling gives both governor and usufructuary a predictable schedule. The tenure duration is also the upper bound against which `HandoverPolicy` is validated — the handover window must fit within a tenure.

## § TYPES

```
TenureDurationPolicy   has copy, drop, store
  Fixed { ceiling: Duration }
```

- `Fixed` — every tenure lasts exactly `ceiling` milliseconds from phase start.

## § API

**Constructors** (package)
- `tenure_duration_policy::new_fixed(ceiling: Duration): TenureDurationPolicy` — asserts `ceiling > 0`.

**Projections** (package)
- `tenure_duration_policy::proj_is_fixed`
- `tenure_duration_policy::proj_fixed_ceiling(&TenureDurationPolicy): Option<Duration>`
- `tenure_duration_policy::proj_tenure_duration_policy(&TenureDurationPolicy): String` — the variant kind string.
- `tenure_duration_policy::proj_tenure_duration_ms(&TenureDurationPolicy): Option<u64>`
- `tenure_duration_policy::proj_min_ceiling(&TenureDurationPolicy): Duration` — the deterministic tenure ceiling, used for cross-policy validation.

**Computations** (package)
- `tenure_duration_policy::compute_duration(&TenureDurationPolicy): Duration` — resolves the tenure ceiling (deterministic — equals the fixed ceiling).

## § INVARIANTS

- `ceiling > 0` enforced at construction.
- `proj_min_ceiling` is used by `policy_ensemble::new_ensemble` to validate that the handover floor never exceeds the tenure ceiling.

## § EVENTS

None.
