# tenure_duration_policy

## § OVERVIEW

Sets the maximum length of a single tenure. The tenure ceiling is the clock boundary after which the current tenant's borrow right expires and the state machine must advance (either to a new auction or directly to idle). A fixed ceiling gives both owner and tenant a predictable schedule; a random range introduces variability that can prevent tenants from timing the market or gaming handover windows. The tenure duration is also the upper bound against which `HandoverPolicy` is validated — the handover window must fit within a tenure.

## § TYPES

```
TenureDurationPolicy   has copy, drop, store
  Fixed         { ceiling: Duration }
  RandomInRange { min: Duration, max: Duration }
```

- `Fixed` — every tenure lasts exactly `ceiling` milliseconds from phase start.
- `RandomInRange` — tenure duration is sampled uniformly from `[min, max)` at integration or config-application time; the same resolved ceiling applies for the lifetime of that config.

## § API

**Constructors** (public)
- `tenure_duration_policy::new_fixed(ceiling: Duration): TenureDurationPolicy` — asserts `ceiling > 0`.
- `tenure_duration_policy::new_random_in_range(min: Duration, max: Duration): TenureDurationPolicy` — asserts `min > 0` and `min < max`.

**Projections** (package)
- `tenure_duration_policy::proj_is_fixed`, `proj_is_random_in_range`
- `tenure_duration_policy::proj_fixed_ceiling`, `proj_range_min`, `proj_range_max` — each returns `Option<Duration>`.
- `tenure_duration_policy::proj_min_ceiling(&TenureDurationPolicy): Duration` — the deterministic lower bound of the tenure duration (fixed ceiling or range min); used for cross-policy validation without consuming randomness.

**Computations** (package)
- `tenure_duration_policy::compute_duration(&TenureDurationPolicy, rng: &mut RandomGenerator): Duration` — resolves the actual tenure ceiling; samples from range if `RandomInRange`.

## § INVARIANTS

- `ceiling > 0` and `min > 0` enforced at construction.
- `proj_min_ceiling` is used by `policy_ensemble::new_ensemble` to validate that the handover floor never exceeds the tenure ceiling; no randomness is consumed.

## § EVENTS

None.
