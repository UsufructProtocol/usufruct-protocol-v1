# policy_ensemble

## § OVERVIEW

The complete, validated configuration bundle for a single escrow. An ensemble packages all eight policy dimensions into one value that is created by the governor at integration time and can be updated — with safe staging — while the escrow is live. Every execution path in the engine reads exclusively from the active ensemble; there is no ad-hoc policy configuration scattered across the state machine. This makes the configuration surface explicit, auditable, and consistent: an ensemble that passes construction is guaranteed internally coherent.

The eight dimensions and what they govern:

| Field               | Policy type               | What it controls                                    |
|---------------------|---------------------------|-----------------------------------------------------|
| `rest_price`        | `RestPricePolicy`         | Price when idle; bottom of the auction descent      |
| `tenure_duration`   | `TenureDurationPolicy`    | How long each tenure lasts                          |
| `tenure_extend`     | `TenureExtendPolicy`      | Whether multi-tenure rentals are allowed            |
| `handover`          | `HandoverPolicy`          | Grace window for current usufructuary when demand arrives |
| `auction_window`    | `AuctionWindowPolicy`     | Length and shape of the dutch auction phase         |
| `credit_shape`      | `CurveShapePolicy`        | Accrual curve for credit during a tenure            |
| `auction_shape`     | `CurveShapePolicy`        | Descent curve for price during a dutch auction      |
| `price_escalation`  | `PriceEscalationPolicy`   | How the floor price grows from one tenure to next   |

## § TYPES

```
PolicyEnsemble {
    rest_price:       RestPricePolicy,
    tenure_duration:  TenureDurationPolicy,
    tenure_extend:    TenureExtendPolicy,
    handover:         HandoverPolicy,
    auction_window:   AuctionWindowPolicy,
    credit_shape:     CurveShapePolicy,
    auction_shape:    CurveShapePolicy,
    price_escalation: PriceEscalationPolicy,
}   has copy, drop, store
```

## § API

**Constructors** (package — public entry is `ensemble::new_ensemble`)
- `policy_ensemble::new_ensemble(rest_price, tenure_duration, tenure_extend, handover, auction_window, credit_shape, auction_shape, price_escalation): PolicyEnsemble` — validates cross-policy consistency before constructing; aborts with `EHandoverFloorExceedsTenure` if the handover floor ≥ tenure minimum ceiling.

**Accessors** (package)
- `policy_ensemble::proj_rest_price`, `proj_tenure_duration`, `proj_tenure_extend`, `proj_handover`, `proj_auction_window`, `proj_credit_shape`, `proj_auction_shape`, `proj_price_escalation` — each returns an immutable reference to the corresponding policy field.

**Emission** (package)
- `policy_ensemble::emit_registration(&PolicyEnsemble, escrow_identity: EscrowIdentity, timestamp: Timestamp)` — emits `PolicyEnsembleRegistered`; called at integration and whenever a pending config is applied immediately.
- `policy_ensemble::emit_ensemble_updated(&PolicyEnsemble, escrow_identity: EscrowIdentity, timestamp: Timestamp)` — emits `EnsembleUpdated` when a staged ensemble becomes the active configuration.
- `policy_ensemble::emit_ensemble_update_scheduled(&PolicyEnsemble, escrow_identity: EscrowIdentity, timestamp: Timestamp)` — emits `EnsembleUpdateScheduled` when an ensemble is staged as pending (escrow occupied or in demand).

## § INVARIANTS

- `handover_floor < tenure_min_ceiling` is the only cross-policy constraint enforced at construction; all other constraints are per-policy.
- An ensemble is immutable after construction (`copy, drop, store`); updates go through the staging slot in `EnsembleSlot` in `EscrowCore`, ensuring the active config never changes mid-tenure.

## § EVENTS

Three events share one **flattened snapshot** shape: the full ensemble decoded into a self-describing row (policy kind strings + their resolved values), keyed by `escrow_id` and `timestamp_ms`. The ensemble is not emitted as a nested value — it is flattened so an indexer needs no on-chain decode.

```
PolicyEnsembleRegistered {
    escrow_id: ID, timestamp_ms: u64,
    rest_price_policy: String, rest_price: u64,
    tenure_duration_policy: String, tenure_duration_ms: u64,
    tenure_extend_policy: String,
    handover_policy: String, handover_floor_ms: Option<u64>,
    auction_window_policy: String, auction_window_ceiling_ms: Option<u64>,
    credit_shape_policy: String, credit_alpha_num/den/abs: Option<u8>, credit_alpha_neg: Option<bool>,
    auction_shape_policy: String, auction_alpha_num/den/abs: Option<u8>, auction_alpha_neg: Option<bool>,
    price_escalation_policy: String, price_escalation_delta: u64, price_escalation_bps: Option<u64>,
}
```
Emitted at integration (first registration). `EnsembleUpdated` (same shape) is emitted when a staged ensemble becomes active; `EnsembleUpdateScheduled` (same shape) when an ensemble is staged as pending. Together they form the policy-audit chain `PolicyEnsembleRegistered → EnsembleUpdateScheduled → EnsembleUpdated`.
