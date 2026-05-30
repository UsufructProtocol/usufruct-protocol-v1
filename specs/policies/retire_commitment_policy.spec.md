# retire_commitment_policy

## § OVERVIEW

One of the two owner-side trust commitments. It governs **availability**: when the owner is permitted to retire the escrow and reclaim the asset. It is set at integration time. An `Immediate` policy offers no guarantee — the owner can exit as soon as the escrow is idle, which tenants will price into their willingness to commit stake. A `Deferred` policy locks the owner out of retirement until at least `floor` milliseconds have elapsed since the commitment anchor, giving tenants a contractual guarantee of minimum availability. The owner can only extend this commitment, never shorten it, making deferred commitments a credible and verifiable signal on-chain. Assets that benefit most are those whose value to tenants depends on continuity — a domain name, a recurring-use access key, a long-horizon position — where tenants need assurance the asset will not be pulled mid-market.

Its twin is [[ensemble_commitment_policy]], which commits the owner to **stability of terms** rather than availability. Permanence without price stability is a hollow promise, so the two together form one credibility story: this policy promises the asset stays in the market, the twin promises the rules of the market stay fixed.

## § TYPES

```
RetireCommitmentPolicy   has copy, drop, store
  Immediate
  Deferred { floor: Duration }
```

- `Immediate` — no lockup; the owner can retire as soon as the escrow is idle.
- `Deferred` — retirement is blocked until `anchor + floor` has elapsed; `anchor` advances each time the commitment is extended.

## § API

**Constructors** (public)
- `retire_commitment_policy::new_immediate(): RetireCommitmentPolicy`
- `retire_commitment_policy::new_deferred(floor: Duration): RetireCommitmentPolicy` — asserts `floor > 0`.

**Projections** (package)
- `retire_commitment_policy::proj_is_immediate(&RetireCommitmentPolicy): bool`, `proj_is_deferred`
- `retire_commitment_policy::proj_floor_ms(&RetireCommitmentPolicy): Option<Duration>`
- `retire_commitment_policy::proj_retire_commitment_policy(&RetireCommitmentPolicy): String` — canonical kind label (`"Immediate"` / `"Deferred"`).
- `retire_commitment_policy::proj_retire_commitment_floor_ms(&RetireCommitmentPolicy): Option<u64>`

**Computations** (package)
- `retire_commitment_policy::compute_duration(&RetireCommitmentPolicy): Duration` — returns `floor` for `Deferred`, zero for `Immediate`.
- `retire_commitment_policy::compute_unlock_at(resolved: Duration, at: Timestamp): Timestamp` — `at + resolved`; the absolute unlock point.
- `retire_commitment_policy::compute_unlock_boundary(resolved: Duration, at: Timestamp, now: Timestamp): Boundary` — whether the commitment has elapsed.

## § INVARIANTS

- `floor > 0` enforced at construction for `Deferred`; a zero-duration deferred policy would be indistinguishable from `Immediate`.
- The commitment anchor can only advance forward; `asset_state::execute_extend_retire_commitment` accumulates (new expiry = old expiry + new floor) and rejects `Immediate` (zero duration is not an extension).

## § EVENTS

None defined in this module. The extend operation emits `RetireCommitmentExtended` from `asset_state`.
