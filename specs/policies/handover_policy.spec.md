# handover_policy

## § OVERVIEW

The minimum guaranteed occupancy a tenant holds from the moment their tenure begins. When a new tenant bids on an occupied asset, the handover countdown starts — but the current tenant cannot be displaced until the configured floor has elapsed since their tenure began. This is the protocol's commitment to the current tenant: regardless of when a competing bid arrives, they are guaranteed at least the handover floor of uninterrupted occupancy. Only after that window expires can the next `apply_pending_transition_states` call fire the transition and hand the asset to the pending tenant.

`Off` offers no guarantee — a bid arriving at any point displaces immediately. `Fixed` and `RandomInRange` give the current tenant a known or probabilistic minimum window, making the asset more attractive to tenants who need a guaranteed minimum usage period. `FullTenure` equates the handover deadline to the tenure ceiling, meaning the current tenant is guaranteed their full tenure — no bid can displace them before it expires. The handover floor is also a cross-policy constraint: it must be strictly less than the tenure ceiling, ensuring a tenant is always guaranteed some occupancy before the tenure itself expires.

## § TYPES

```
HandoverPolicy   has copy, drop, store
  Off
  FullTenure
  Fixed          { floor: Duration }
  RandomInRange { min: Duration, max: Duration }
```

- `Off` — handover fires immediately; the current tenant has no grace window.
- `FullTenure` — handover deadline equals the tenure ceiling; the current tenant is guaranteed their full tenure with no possibility of early displacement.
- `Fixed` — handover fires `floor` milliseconds after the bid is placed.
- `RandomInRange` — handover duration is sampled from `[min, max)` at bid placement time.

## § API

**Constructors** (public)
- `handover_policy::new_handover_off(): HandoverPolicy`
- `handover_policy::new_handover_full_tenure(): HandoverPolicy`
- `handover_policy::new_handover_fixed(floor: Duration): HandoverPolicy` — asserts `floor > 0`.
- `handover_policy::new_handover_random_in_range(min: Duration, max: Duration): HandoverPolicy` — asserts `min > 0` and `min < max`.

**Projections** (package)
- `handover_policy::proj_is_off`, `proj_is_full_tenure`, `proj_is_fixed`, `proj_is_random_in_range`
- `handover_policy::proj_fixed_floor_ms`, `proj_range_min`, `proj_range_max` — each returns `Option<Duration>`.

**Computations** (package)
- `handover_policy::compute_countdown_floor_lt(&HandoverPolicy, ceiling: Duration): bool` — true if the handover floor is strictly less than `ceiling`; used by `policy_ensemble::new_ensemble` to validate cross-policy consistency.
- `handover_policy::compute_duration(&HandoverPolicy, ceiling: Duration, rng: &mut RandomGenerator): Duration` — resolves the handover window; samples if `RandomInRange`.
- `handover_policy::compute_expiry_boundary(floor: Duration, ceiling: Duration, bid_time: Timestamp, phase_start: Timestamp, now: Timestamp): Boundary` — whether the handover window has elapsed.
- `handover_policy::compute_expiry_at(floor: Duration, ceiling: Duration, bid_time: Timestamp, phase_start: Timestamp): Timestamp` — absolute handover deadline.

## § INVARIANTS

- `floor > 0` and `min < max` enforced at construction.
- `compute_countdown_floor_lt` is the cross-policy guard used at ensemble construction to ensure the handover window never exceeds the tenure ceiling.

## § EVENTS

None.
