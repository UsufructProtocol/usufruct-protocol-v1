# commitment_policy

## § OVERVIEW

The only policy that constrains the owner rather than the tenant. All other policies in the ensemble shape the tenant experience — pricing, timing, curves. This one is the owner's side of the trust equation: it is set at integration time and governs when the owner is permitted to retire the escrow and reclaim their asset. An `Immediate` policy offers no guarantee — the owner can exit at any time, which tenants will price into their willingness to commit stake. A `Deferred` policy locks the owner out of retirement until at least `floor` milliseconds have elapsed since the commitment anchor, giving tenants a contractual guarantee of minimum availability. The owner can only extend this commitment, never shorten it, making deferred commitments a credible and verifiable signal on-chain. Assets that benefit most from this policy are those whose value to tenants depends on continuity — a domain name, a recurring-use access key, a long-horizon position — where tenants need assurance the asset will not be pulled mid-market.

## § TYPES

```
CommitmentPolicy   has copy, drop, store
  Immediate
  Deferred { floor: Duration }
```

- `Immediate` — no lockup; the owner can retire as soon as the escrow is idle.
- `Deferred` — retirement is blocked until `anchor + floor` has elapsed; `anchor` is updated each time the commitment is extended.

## § API

**Constructors** (public)
- `commitment_policy::new_immediate(): CommitmentPolicy`
- `commitment_policy::new_deferred(floor: Duration): CommitmentPolicy` — asserts `floor > 0`.

**Projections** (package)
- `commitment_policy::proj_is_immediate`, `proj_is_deferred`
- `commitment_policy::proj_floor_ms` — returns `Option<Duration>`.

**Computations** (package)
- `commitment_policy::compute_duration(&CommitmentPolicy): Duration` — returns `floor` for `Deferred`, zero for `Immediate`.
- `commitment_policy::compute_unlock_at(resolved: Duration, at: Timestamp): Timestamp` — `at + resolved`; the absolute unlock point.
- `commitment_policy::compute_unlock_boundary(resolved: Duration, at: Timestamp, now: Timestamp): Boundary` — whether the commitment has elapsed.

## § INVARIANTS

- `floor > 0` enforced at construction for `Deferred`; a zero-duration deferred policy would be indistinguishable from `Immediate`.
- The commitment anchor can only advance forward; `execute_extend_commitment` asserts the new expiry is ≥ the current expiry.

## § EVENTS

None.
