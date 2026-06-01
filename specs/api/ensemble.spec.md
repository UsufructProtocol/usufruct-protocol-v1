# ensemble (api)

## § OVERVIEW

The public PTB construction chain for a `PolicyEnsemble`. Exposes the value-type constructors (`price`, `duration`, `tenures`) and every policy constructor, grouped by axis, plus `new_ensemble` to bundle the per-tenancy policies into one value. This is the only `public` surface for building the configuration an escrow is integrated with; the policy semantics live in the per-policy specs under `policies/`, the value types under `domain/`, and the bundle structure in `policies/policy_ensemble`.

## § API

**Value types**
- `ensemble::price(mist: u64): Price`
- `ensemble::duration(ms: u64): Duration`
- `ensemble::tenures(n: u64): Tenures`

**AuctionWindowPolicy** — `new_descent_off()`, `new_descent_fixed(ceiling: Duration)`
**RetireCommitmentPolicy** — `new_retire_commitment_immediate()`, `new_retire_commitment_deferred(floor: Duration)`
**EnsembleCommitmentPolicy** — `new_ensemble_commitment_immediate()`, `new_ensemble_commitment_deferred(floor: Duration)`
**CurveShapePolicy** (credit and auction shapes) — `new_linear()`, `new_smoothstep()`, `new_logistic()`, `new_power_law(alpha_num: u8, alpha_den: u8)`, `new_exponential(alpha_abs: u8, alpha_neg: bool)`
**HandoverPolicy** — `new_handover_off()`, `new_handover_full_tenure()`, `new_handover_fixed(floor: Duration)`
**PriceEscalationPolicy** — `new_price_fixed_delta(delta: Price)`, `new_price_compound_delta(bps: BasisPoints, delta: Price)`
**RestPricePolicy** — `new_rest_price_fixed(price: Price)`
**TenureDurationPolicy** — `new_tenure_duration_fixed(ceiling: Duration)`
**TenureExtendPolicy** — `new_tenure_single()`, `new_tenure_multi()`

**Bundle**
- `ensemble::new_ensemble(...): PolicyEnsemble` — bundles the per-tenancy policies (rest price, tenure duration, tenure extend, handover, auction window, auction shape, credit shape, price escalation) into a `PolicyEnsemble`. The two commitment policies (`RetireCommitmentPolicy`, `EnsembleCommitmentPolicy`) are **not** part of the ensemble — they are passed separately to `escrow::integrate`. See `policies/policy_ensemble` for the bundle's field structure.

## § INVARIANTS

- Pure constructors — no shared state, no events. They only assemble value types validated downstream at `integrate`.

## § EVENTS

None.
