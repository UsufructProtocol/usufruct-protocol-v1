# ensemble_commitment_policy

## § OVERVIEW

One of the two owner-side trust commitments. It governs **stability of terms**: whether the owner is permitted to call `update_ensemble` to change the escrow's `PolicyEnsemble` (rest price, tenure duration, curves, handover/auction windows, price escalation). It is set at integration time. An `Immediate` policy offers no guarantee — the owner can change the terms at any moment (subject to the existing per-state scheduling rules of `update_ensemble`). A `Deferred` policy **freezes the entire ensemble** until at least `floor` milliseconds have elapsed since the commitment anchor, giving tenants and prospective tenants a contractual guarantee that the rules will not move out from under them. The owner can only extend this commitment, never shorten it.

This is the twin of [[retire_commitment_policy]]. Where retire-commitment promises the asset *stays in the market* (availability), ensemble-commitment promises the *terms of the market stay fixed* (stability). Availability without stability is hollow — "the asset is rentable for a year, but tomorrow I raise the rest price 100×" — so the two commitments are orthogonal halves of a single credibility signal. They are deliberately distinct types rather than one generic, mirroring the structural asymmetry of what each gates (`retire` vs `update_ensemble`).

## § TYPES

```
EnsembleCommitmentPolicy   has copy, drop, store
  Immediate
  Deferred { floor: Duration }
```

- `Immediate` — no freeze; `update_ensemble` follows its normal per-state behaviour.
- `Deferred` — `update_ensemble` is blocked until `anchor + floor` has elapsed; `anchor` advances each time the commitment is extended.

## § API

**Constructors** (public)
- `ensemble_commitment_policy::new_immediate(): EnsembleCommitmentPolicy`
- `ensemble_commitment_policy::new_deferred(floor: Duration): EnsembleCommitmentPolicy` — asserts `floor > 0`.

**Projections** (package)
- `ensemble_commitment_policy::proj_is_immediate(&EnsembleCommitmentPolicy): bool`, `proj_is_deferred`
- `ensemble_commitment_policy::proj_floor_ms(&EnsembleCommitmentPolicy): Option<Duration>`
- `ensemble_commitment_policy::proj_ensemble_commitment_policy(&EnsembleCommitmentPolicy): String` — canonical kind label (`"Immediate"` / `"Deferred"`).
- `ensemble_commitment_policy::proj_ensemble_commitment_floor_ms(&EnsembleCommitmentPolicy): Option<u64>`

**Computations** (package)
- `ensemble_commitment_policy::compute_duration(&EnsembleCommitmentPolicy): Duration` — returns `floor` for `Deferred`, zero for `Immediate`.
- `ensemble_commitment_policy::compute_unlock_at(resolved: Duration, at: Timestamp): Timestamp` — `at + resolved`; the absolute unlock point.
- `ensemble_commitment_policy::compute_unlock_boundary(resolved: Duration, at: Timestamp, now: Timestamp): Boundary` — whether the freeze has elapsed.

## § INVARIANTS

- `floor > 0` enforced at construction for `Deferred`; a zero-duration deferred policy would be indistinguishable from `Immediate`.
- **Blanket freeze.** While the floor is pending, `update_ensemble` aborts in *every* escrow state (Idle, Occupied, Descent, Demand) — it never schedules a pending reset. The guard (`asset_state::assert_ensemble_commitment_elapsed`) runs before any state dispatch, so the freeze is all-or-nothing, matching the structure of the retire gate. After the floor elapses, `update_ensemble` resumes its pre-existing per-state behaviour unchanged.
- **Announcements made before the freeze survive it.** Because the freeze blocks `update_ensemble` *entirely*, no new pending reset can be created while frozen. A pending reset announced *before* a later `extend_ensemble_commitment` is **not** retracted by the extend: it still applies at the next natural boundary (`do_auction_expiry`). The freeze halts new announcements; it does not undo one already made.
- The commitment anchor can only advance forward; `asset_state::execute_extend_ensemble_commitment` accumulates (new expiry = old expiry + new floor) and rejects `Immediate` (zero duration is not an extension).

## § EVENTS

None defined in this module. The extend operation emits `EnsembleCommitmentExtended` from `asset_state`.
