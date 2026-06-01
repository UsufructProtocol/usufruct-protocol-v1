# asset_state

## § OVERVIEW

The core of the protocol. `asset_state` is the finite state machine that governs every phase of an asset's lifecycle inside an escrow: from first integration through successive tenancies, dutch auction descent phases, pending bids, handovers, and final retirement. All financial logic, all price computation, all settlement arithmetic, and all state transitions live here. Every other module in the engine is a building block that `asset_state` composes.

The FSM is structured as a two-level enum hierarchy. The outer level distinguishes whether the asset is currently rented or not. The inner levels describe the specific phase within each branch. This bifurcation means that functions operating only on the renting branch carry `CoinType` in their signature, while functions operating only on the waiting branch do not — the type system makes the financial state explicit.

`EscrowCore` is the financial and configuration context that travels alongside every state. It holds the governor's seat, the active policy ensemble (and optionally a staged pending update), the fee inbox identity, the commitment schedule, the integration timestamp, and the escrow identity. Together, `AssetState` and `EscrowCore` form the complete runtime representation of an escrow.

`execute_borrow` and `execute_return` are the only two functions that dissolve and reconstitute the `AssetState`. `execute_borrow` extracts the `RentingState` from the escrow and wraps it in an `AssetReceipt` hot potato, leaving the escrow with no state. `execute_return` consumes the receipt and re-inserts the state. Because `AssetReceipt` has no `drop` or `store`, both calls are forced into the same Programmable Transaction Block — the asset and the receipt must be returned before the transaction ends. The window between the two calls is the usufructuary's execution space: arbitrary Move logic can run against the live asset, composed freely with other protocols, while the escrow is structurally frozen. No state machine advance, no rental operation, and no governor operation is possible during this window because there is no `AssetState` to operate on. The hot potato is the enforcement mechanism — it is not a runtime check but a type-system guarantee. Because the entire borrow–use–return sequence executes atomically within a single transaction, no external observer ever sees the escrow in a partially-borrowed state: the `None` window is invisible to the outside world.

## § TYPES

**State hierarchy**

```
AssetState<Asset: key+store, CoinType: phantom>   has store
  Waiting(WaitingState<Asset>)
  Renting(RentingState<Asset, CoinType>)
```

```
WaitingState<Asset: key+store>   has store
  Idle     { asset: AssetCustodyLocked<Asset>, cycle: CycleParams }
  Descent  { asset: AssetCustodyLocked<Asset>, auction: AuctionTerms, cycle: CycleParams }
  Retired  { asset: AssetCustodyLocked<Asset> }
```

```
RentingState<Asset: key+store, CoinType: phantom>   has store
  Occupied { asset: AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, cycle: CycleParams }
  Demand   { asset: AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, bid: DemandTerms<CoinType>, cycle: CycleParams }
```

**Supporting record types**

```
CycleParams { floor: Price, ceiling: Duration, handover: Duration, descent: Duration }
```
Resolved policy parameters for the current cycle. Computed once when the cycle begins by sampling all random policies; carried through the cycle so the same values apply consistently.

```
TenancySchedule { phase_start: Timestamp, ceiling_total: Duration, handover_total: Duration, committed_tenures: Tenures }
```
The committed rental terms for the current occupant. `ceiling_total` and `handover_total` are the policy ceiling and handover durations scaled by `committed_tenures` — so a 3-tenure rental at 100s ceiling yields `ceiling_total = 300s`. These totals are used for all deadline arithmetic throughout the occupancy.

```
OccupiedTerms<CoinType> { schedule: TenancySchedule, current: UsufructuarySeat<CoinType>, retire: RetireCondition }
```
The current usufructuary's full context: their schedule, their locked stake (and identity), and whether the governor has flagged the escrow for retirement after this tenure.

```
DemandTerms<CoinType> { pending: UsufructuarySeat<CoinType>, handover: HandoverTerms }
```
A pending usufructuary's bid: their locked stake and the handover countdown terms.

```
HandoverTerms { expiry: Timestamp, tenures: Tenures }
```
When the handover transition may fire, and how many tenures the pending usufructuary committed to.

```
AuctionTerms { last_acq_price: Price, phase_start: Timestamp }
```
The starting price and anchor time of the dutch auction phase.

```
EnsembleSlot { active: PolicyEnsemble, pending: Option<PolicyEnsemble> }
```
The active configuration and an optionally staged update. The pending ensemble is applied exclusively at `Descent → Idle` (`do_auction_expiry`) — never mid-tenure, never at `Occupied → Descent`. On an immediate retire, the pending is discarded (`config.pending = none`).

```
RetireCommitmentSlot   { policy: RetireCommitmentPolicy,   anchor: Timestamp }
EnsembleCommitmentSlot { policy: EnsembleCommitmentPolicy, anchor: Timestamp }
```
Two independent commitment locks, each a policy plus the timestamp from which its floor is measured: `retire_commitment` gates how soon the governor may retire; `ensemble_commitment` gates how soon the active policy ensemble may change.

```
EscrowCore<CoinType> {
    governor_seat:       GovernorSeat,
    ensemble:            EnsembleSlot,
    fee_inbox_identity:  FeeInboxIdentity,
    integrated_at:       Timestamp,
    retire_commitment:   RetireCommitmentSlot,
    ensemble_commitment: EnsembleCommitmentSlot,
    escrow_identity:     EscrowIdentity,
}
```
Financial and configuration context. Travels alongside `AssetState` through every operation. The `governor_seat` carries no balance and no coin type — it records the governing cap identity and the `EarningsInbox` destination; income is settled to that inbox, never accumulated here.

```
RetireCondition   has drop, store
  NotRetiring
  Retiring
```
A flag set by `execute_retire` while the asset is occupied or in demand. Causes the next tenure expiry to transition to `Retired` rather than `Descent`.

```
FeeAllocation { governor_share: Stake, protocol_fee: Stake }   has drop
```
Transient record produced by `split_fee`; holds the two portions of consumed credit before they are routed: 90% as `governor_share`, 10% as `protocol_fee`. Created and consumed inline within a single transition function.

```
AssetReceipt<Asset: key+store, CoinType: phantom>
    identity: EscrowedAssetIdentity
    renting:  RentingState<Asset, CoinType>
```
Hot potato returned by `execute_borrow`. Carries the escrowed-asset identity (for return validation) and the full `RentingState` extracted from the escrow. Must be consumed by `execute_return` in the same transaction.

## § API

**Integration**
- `asset_state::execute_integrate<Asset, C>(asset, ensemble, retire_commitment, ensemble_commitment, fee_inbox_identity, escrow_identity, integrated_at, generator, ctx): (EscrowCore<C>, AssetState<Asset, C>, GovernanceCap, EarningsInbox)` — creates the `EscrowCore`, resolves initial `CycleParams` from the ensemble, produces `Waiting(Idle)`, and mints a fresh `GovernanceCap` + `EarningsInbox` pair (born together, exactly once); emits `AssetIntegrated` and `PolicyEnsembleRegistered`. The root of the one-pair-per-portfolio invariant.
- `asset_state::execute_integrate_into_portfolio<Asset, C>(asset, ensemble, retire_commitment, ensemble_commitment, fee_inbox_identity, governance_cap: &GovernanceCap, inbox: &EarningsInbox, escrow_identity, integrated_at, generator, ctx): (EscrowCore<C>, AssetState<Asset, C>)` — same idle core + state, but binds the new escrow to a **caller-held** cap + inbox instead of minting: the `GovernorSeat` records the existing cap identity and inbox destination. Both integrate paths share one private body (`build_idle_core_and_state`) that assembles the idle core + state from a resolved `(cap_identity, inbox_identity)` pair and emits `AssetIntegrated`; they differ only in where the identities come from (minted vs caller-held).

**State machine advance**
- `asset_state::execute_apply_pending_transition_states<Asset, C>(&mut AssetState, &mut EscrowCore<C>, rng, clock, ctx)` — evaluates all pending transitions in fixed order: `step_handover` → `step_tenure_expiry` → `step_auction_expiry`. Each step only fires if its condition is met:
  - `Demand` + handover crossed → `step_handover` → `Renting(Occupied)`.
  - `Occupied` + tenure crossed → `step_tenure_expiry` → `Waiting(Descent | Retired)` (never directly to `Idle`).
  - `Descent` + auction window elapsed → `step_auction_expiry` → `Waiting(Idle)`.
  - Steps chain: a single call can transition `Demand → Occupied → Descent` or `Demand → Occupied → Retired`.

**Rental**
- `asset_state::execute_rent<Asset, C>(AssetState, EscrowCore<C>, payment: Coin<C>, tenures: Tenures, rng, clock, ctx): (RentingState<Asset, C>, EscrowCore<C>, UsufructCap)` — advances state machine first, validates `TenureExtendPolicy`, then:
  - From `Idle` or `Descent` → `do_install` → `Occupied`.
  - From `Occupied` → `do_place_bid` → `Demand`. Aborts with `ERetireFlagBlocksBid` if the retire flag is already set.
  - From `Demand` → `do_supersede_bid` → `Demand` with new pending usufructuary; displaced usufructuary receives `Total` refund. The new bidder **inherits the same `handover_expiry`** from the displaced bid — the countdown is not reset.
  - From `Retired` → aborts.

  In every branch that mints a new `UsufructuarySeat` (`do_install`, `do_place_bid`, `do_supersede_bid`), the seat's refund destination is set at construction time to `ctx.sender()` — that is the initial address where any future refund routed through this seat will land (on `do_handover` for the active, on `do_supersede_bid` for the pending). Because `UsufructCap` is `key + store` and freely transferable, this initial pinning can become stale once the cap changes hands; `execute_update_usufructuary_refund_address` (see Cap management below) is the only mechanism that mutates this address after construction.

**Asset access**
- `asset_state::execute_borrow<Asset, C>(AssetState, EscrowCore<C>, usufruct_cap, rng, clock, ctx): (Asset, AssetReceipt<Asset, C>, EscrowCore<C>)` — advances state machine, then extracts the asset from custody. Only the **current** usufructuary's cap is authorised; a pending cap is explicitly rejected (`EPendingUsufructCap`), and a stale cap aborts (`EStaleUsufructCap`). Valid in both `Occupied` and `Demand` states — the current usufructuary retains borrow rights even while a pending bid is waiting.
- `asset_state::execute_return<Asset, C>(AssetReceipt<Asset, C>, &EscrowCore<C>, asset: Asset): RentingState<Asset, C>` — validates both that the receipt's escrow identity matches and that the returned asset object ID matches the borrowed one; re-inserts asset into custody; returns the reconstituted `RentingState`.

**Governor operations**
- `asset_state::execute_retire<Asset, C>(&mut AssetState, &mut EscrowCore<C>, governance_cap, rng, clock, ctx)` — validates commitment has elapsed; advances state machine first; then: transitions immediately to `Retired` from `Idle` or `Descent`; sets the `RetireCondition` flag from `Occupied` or `Demand` so the next tenure expiry goes to `Retired` instead of `Descent`.
- `asset_state::execute_update_config<Asset, C>(AssetState, EscrowCore<C>, governance_cap, new_ensemble, rng, clock, ctx): (AssetState, EscrowCore<C>)` — advances state machine first, then:
  - `Idle` → applies immediately, re-resolves `CycleParams` from new ensemble; emits `ConfigUpdated`.
  - `Descent`, `Occupied`, `Demand` → stages as pending; emits `ConfigUpdateScheduled`. Aborts if retire flag is already set.
  - `Retired` → aborts.
- `asset_state::execute_extend_commitment<C>(EscrowCore<C>, governance_cap, new_policy, clock): EscrowCore<C>` — extends the commitment unlock time; asserts new expiry ≥ current expiry. The anchor is updated to `now`, making the new floor measured from the current time. **Does not advance the state machine** — the only `execute_*` that omits this step.
- `asset_state::execute_claim<Asset, C>(AssetState, EscrowCore<C>, governance_cap: &GovernanceCap, rng, clock, ctx): Asset` — advances state machine first; then consumes state and core and unlocks the asset, returning **only the asset**. Governor income was settled to the `EarningsInbox` each settlement (never accumulated in the seat), so there is nothing to sweep. Takes `&GovernanceCap` — not consumed, since the cap may govern other escrows. Aborts unless state is `Retired` after the advance.

**Cap management**
- `asset_state::execute_soft_burn_usufruct_cap<Asset, C>(&AssetState, &EscrowCore<C>, cap: UsufructCap, rng, clock, ctx)` — burns a stale cap; asserts it is neither current nor pending.
- `asset_state::execute_update_usufructuary_refund_address<Asset, C>(AssetState, EscrowCore<C>, cap: &UsufructCap, new_address: RefundAddress, clock, ctx): (AssetState, EscrowCore<C>)` — advances state machine first; matches the presented cap's identity against the active and pending seats and mutates the refund address of the matching one via `usufructuary_seat::set_refund_address`. The address being overwritten is the one captured by `execute_rent` at construction time from `ctx.sender()` (see Rental above), or any subsequent redirect on the same seat. Authority derives from the cap reference alone — the call's sender is **not** consulted; only `usufruct_cap::identity(&cap)` matters. Emits `ActiveUsufructuaryRefundAddressUpdated` or `PendingUsufructuaryRefundAddressUpdated` depending on which seat matched. Aborts with `EUsufructCapStale` if the cap matches neither (including `Waiting` states where no seat exists). The cap is taken by reference, so its identity (and the historical link to past events) is preserved. Idempotent: emits even if `new_address == old_address`.

  No `GovernanceCap` analogue exists, and none is needed. Governor value is **caller-initiated** by someone present at the call: income arrives as `EarningsMessage`s at the `EarningsInbox` and is drained by its bearer (`earnings::collect_earnings_messages`), and `execute_claim` returns the asset to the sender. The asymmetry is structural: usufructuary refunds (`do_handover`, `do_supersede_bid`) are **event-initiated** from a third party's transaction, with the displaced usufructuary absent at payout, so a pre-stored destination on the `UsufructuarySeat` is required. The `GovernorSeat` carries no balance and no payout destination — only the cap identity and the inbox the income is mailed to.

**View functions** (package)
- State shape: `proj_is_idle`, `proj_is_descent`, `proj_is_occupied`, `proj_is_demand`, `proj_is_active`, `proj_is_retired`, `proj_is_rented`, `proj_is_retiring`
- Asset & usufructuary: `proj_asset_id`, `proj_active_addr`, `proj_active_cap_id`, `proj_pending_addr`, `proj_pending_cap_id`, `proj_active_stake`, `proj_pending_stake`
- Timing: `proj_phase_start`, `proj_handover_expiry`, `proj_resolved_ceiling`, `proj_resolved_handover`, `proj_resolved_floor`, `proj_commitment_policy`, `proj_commitment_anchor`, `proj_governor_balance`
- Pricing: `compute_floor_price_at<C>(state, core, now): Price` — `Idle`: the resolved rest price from `CycleParams`; `Descent`: descending from last acquisition price toward floor; `Occupied`: escalated from current usufructuary's per-tenure stake; `Demand`: escalated from the **pending** bid's per-tenure stake (the most recent market signal); `Retired`: aborts.
- Credit: `compute_used_credit_at<C>(state, core, now): Stake` — amount of the current usufructuary's stake considered consumed at `now`.
- Settlement preview:
  - `compute_used_credit_at<C>(state, core, now): Stake` — credit consumed by the **current** usufructuary at `now`. In `Occupied`: accrues freely via `credit_shape`. In `Demand`: frozen at `min(now, handover.expiry)` — once the handover deadline passes, the displaced usufructuary's credit is fixed. Aborts if not rented.
  - `proj_handover_settlement<C>(state, core, now): (Stake, Stake, Stake)` — (remaining stake, governor share, protocol fee) if handover fired at `now`.
  - `proj_tenure_settlement<C>(state): (Stake, Stake)` — (governor share, protocol fee) if the tenure expired now; full principal consumed.
- Waiting state projections: `proj_waiting_resolved_floor`, `proj_waiting_resolved_ceiling`, `proj_waiting_resolved_handover`, `proj_waiting_resolved_descent`, `proj_last_acq_price`
- Credit state projections: `proj_credit_stake`, `proj_credit_phase_start`, `proj_credit_is_accruing`, `proj_credit_is_capped`, `proj_credit_expiry`
- Cap validation: `cap_is_active`, `cap_is_pending`, `cap_is_stale`
- Next firing: `compute_next_pending<C>(state, clock): Option<Timestamp>` — earliest timestamp at which a state transition can fire.

## § INVARIANTS

- `PROTOCOL_FEE_BPS = 1_000` (10%) is hard-coded; governor always receives 90% of credit used.
- The asset is never duplicated: `AssetCustodyOpen` enforces single-holder discipline via `Option`; `close_tenancy` aborts if the asset is currently borrowed.
- Every cap-gated operation validates `cap.escrow_identity == escrow_identity` before proceeding.
- Commitment can only extend forward: `execute_extend_commitment` aborts if the new expiry is less than the current.
- A pending ensemble never replaces the active one mid-tenure; it is applied only on the next state transition.
- `execute_claim` aborts unless state is `Retired`; the asset cannot be reclaimed while any usufructuary slot is active.
- Only the **current** usufructuary's cap can borrow the asset. A pending usufructuary cap is explicitly rejected at `execute_borrow` — the pending usufructuary must wait for the handover to fire and become current before they can access the asset.
- `execute_update_config` aborts if the retire flag is already set; a scheduled retirement and a config update cannot coexist.

## § TRANSITIONS

```
             execute_rent                execute_rent
             (do_install)                (do_install)
   Idle ──────────────────► Occupied ◄───────────── Descent
    ▲                          │  │                    ▲
    │  step_auction_expiry      │  │ execute_rent       │
    │  (do_auction_expiry)      │  │ (do_place_bid)     │ step_tenure_expiry
    └──────────────────────────┘  ▼                    │ (do_tenure_expiry)
                               Demand ─────────────────┘  [not retiring]
                                │  ▲
                                │  └── execute_rent (do_supersede_bid, self-loop)
                                │
                                │ step_handover (do_handover)
                                └──────────────────────────────────────────────► Occupied
                                                                                  [see above]

   Idle ──► Retired    execute_retire (do_retire_immediately)
  Descent ──► Retired  execute_retire (do_retire_immediately)
  Occupied ──► Retired  step_tenure_expiry [retire flag set]
  Demand ──► Occupied ──► Retired  step_handover then step_tenure_expiry [retire flag set]

                         Retired ──► (consumed)  execute_claim
```

`execute_apply_pending_transition_states` chains in fixed order per call:
`step_handover` → `step_tenure_expiry` → `step_auction_expiry`.
A single call can therefore chain `Demand → Occupied → Descent` or `Demand → Occupied → Retired`.

**Transition semantics:**

- **`Idle → Occupied`** (`do_install`): resolves cycle params from the active ensemble, installs usufructuary, mints `UsufructCap`, emits `RentStarted`.
- **`Descent → Occupied`** (`do_install`): same as above; price is the descending auction price at the moment of the bid.
- **`Occupied → Demand`** (`do_place_bid`): validates payment against escalated floor; resolves handover countdown; parks new usufructuary as pending; emits `BidPlaced`.
- **`Demand → Demand`** (`do_supersede_bid`): superseded pending usufructuary receives `Total` refund; new bidder takes the pending slot with the same `handover_expiry` as the displaced bid — the countdown is not reset; emits `BidSuperseded`.
- **`Demand → Occupied`** (`step_handover` → `do_handover`): handover countdown has crossed; credit is computed up to the handover boundary and settled via `RefundState::from_departing`; the displaced usufructuary receives any remaining stake; the pending usufructuary's `UsufructuarySeat` becomes the new current occupant, inheriting the retire flag; emits `HandoverCompleted`.
- **`Occupied → Descent`** (`step_tenure_expiry` → `do_tenure_expiry`): tenure ceiling crossed; full principal consumed as credit (100% — `RefundState::Nothing`); the existing `CycleParams` are carried into `Descent` unchanged — no pending ensemble is applied here; emits `TenureExpired`. The `last_acq_price` recorded in `AuctionTerms` is the full principal. If `auction_window` is `Skipped`, `step_auction_expiry` fires immediately in the same `execute_apply` call, continuing to `Idle`.
- **`Occupied → Retired`** (`step_tenure_expiry` with retire flag): retire condition is `Retiring`; asset goes directly to `Retired` instead of `Descent`; emits `AssetRetired`. The retire flag can be set from both `Occupied` and `Demand` — in the `Demand` case it is carried into the resulting `Occupied` after `step_handover` fires in the same call.
- **`Descent → Idle`** (`step_auction_expiry` → `do_auction_expiry`): auction window elapsed with no bid; applies pending ensemble if present (emits `ConfigUpdated`); re-resolves a fresh `CycleParams` from the now-active ensemble; emits `AuctionExpired`. This is the only transition that applies a staged config update.
- **`Idle | Descent → Retired`** (`execute_retire` immediate): commitment elapsed; no active usufructuary; emits `AssetRetired`.

## § EVENTS

```
AssetIntegrated {
    escrow_id: ID, governance_cap_id: ID, governor_address: address,
    asset_id: ID, fee_inbox_id: ID, earnings_inbox_id: ID,
    asset_type: String, coin_type: String, integrated_at_ms: u64
}
```
Emitted once at both `execute_integrate` and `execute_integrate_into_portfolio` (the shared body). Records the full birth context — the governing cap, the income inbox, and the escrow — as the root of the event star schema.

```
RentStarted {
    escrow_id: ID, usufruct_cap_id: ID, usufructuary: address,
    phase_start_ms: u64, price_paid: u64, floor_price: u64,
    committed_tenures: u64, ceiling_total_ms: u64, handover_total_ms: u64
}
```
Emitted when a usufructuary enters `Occupied` from `Idle` or `Descent` via `do_install`.

```
BidPlaced {
    escrow_id: ID,
    active_usufruct_cap_id: ID, active_usufructuary_addr: address,
    active_stake_balance: u64, active_phase_start_ms: u64,
    pending_usufruct_cap_id: ID, pending_usufructuary: address,
    bid_amount: u64, floor_price: u64,
    handover_countdown_expiry: u64, committed_tenures: u64, timestamp_ms: u64
}
```
Emitted when a new usufructuary bid is placed on an occupied asset via `do_place_bid`.

```
BidSuperseded {
    escrow_id: ID,
    protected_usufruct_cap_id: ID, protected_usufructuary_addr: address,
    protected_stake_balance: u64, protected_phase_start_ms: u64,
    displaced_usufruct_cap_id: ID, displaced_bidder: address, refunded_amount: u64,
    new_usufruct_cap_id: ID, new_bidder: address, new_bid_amount: u64,
    floor_price: u64, handover_countdown_expiry: u64, committed_tenures: u64, timestamp_ms: u64
}
```
Emitted when a pending bid is replaced by a newer bid via `do_supersede_bid`. Carries both the protected (current) usufructuary context and the full displacement record.

```
HandoverCompleted {
    escrow_id: ID,
    displaced_usufruct_cap_id: ID, displaced_usufructuary: address,
    displaced_phase_start_ms: u64, displaced_ceiling_total_ms: u64, displaced_handover_total_ms: u64,
    new_usufruct_cap_id: ID, new_usufructuary_addr: address, new_stake_balance: u64,
    used_credit: u64, remain_credit: u64,
    governor_share: u64, protocol_fee: u64, new_rent_price: u64,
    committed_tenures: u64, ceiling_total_ms: u64, handover_total_ms: u64,
    timestamp_ms: u64
}
```
Emitted when the handover countdown fires and the pending usufructuary becomes the current occupant. The displaced bundle (`displaced_phase_start_ms`, `displaced_ceiling_total_ms`, `displaced_handover_total_ms`) gives the full temporal context of the outgoing tenancy — including the original planned ceiling — so consumers can compute the shortfall without a look-back join. The incoming schedule fields (`committed_tenures`, `ceiling_total_ms`, `handover_total_ms`) describe the new usufructuary's terms, rescaled from the displaced usufructuary's schedule by the incoming/outgoing tenure ratio.

```
TenureExpired {
    escrow_id: ID, usufruct_cap_id: ID, usufructuary: address,
    phase_start_ms: u64, governor_share: u64, protocol_fee: u64,
    last_acquisition_price: u64, timestamp_ms: u64
}
```
Emitted when the tenure ceiling is crossed. `last_acquisition_price` is the full principal (= stake paid), which is entirely consumed as credit at natural expiry.

```
AuctionExpired {
    escrow_id: ID, phase_start_ms: u64,
    last_acq_price: u64, timestamp_ms: u64
}
```
Emitted when the dutch auction window elapses with no bid; escrow returns to `Idle`.

```
CycleParamsResolved {
    escrow_id: ID, floor_mist: u64, ceiling_ms: u64,
    handover_ms: u64, descent_ms: u64, timestamp_ms: u64
}
```
Emitted by `resolve_and_emit_cycle_params` when the engine adopts a new active ensemble — at `execute_integrate`, at `execute_update_config` when applied immediately (Idle), and at `do_auction_expiry` when a pending ensemble is applied. Carries the resolved parameters the engine operates on (a pure function of the active ensemble), so consumers need not replay the policy resolution. Not emitted on the auction-expiry recompute with no pending ensemble, since the parameters are unchanged there.

```
AssetRetired { escrow_id: ID, timestamp_ms: u64 }
```
Emitted when the escrow enters `Retired` — both on immediate retire and on tenure-expiry-with-retire-flag.

```
AssetClaimed {
    escrow_id: ID, governance_cap_id: ID, governor_address: address,
    asset_type: String, coin_type: String, timestamp_ms: u64
}
```
Emitted on `execute_claim`. Carries no swept-earnings amount — claim returns only the asset; income was settled to the `EarningsInbox` throughout.

```
AssetBorrowed { escrow_id: ID, usufruct_cap_id: ID, usufructuary: address, timestamp_ms: u64 }
```
Emitted when a usufructuary extracts the asset via `execute_borrow`.

```
AssetReturned { escrow_id: ID, usufruct_cap_id: ID, usufructuary: address }
```
Emitted when the asset is re-inserted via `execute_return`. Carries no `timestamp_ms`: `AssetReceipt` is a hot potato (no `drop`/`store`/`key`/`copy`), so it must be consumed by `execute_return` in the same transaction that produced it via `execute_borrow`. A `Clock` is read-only within a transaction — its `timestamp_ms` is fixed by the consensus commit prologue before user code runs and cannot be mutated by it — so a return timestamp would always equal the value already pinned by `AssetBorrowed`. The borrow timestamp dates the whole borrow↔return interval.

```
ConfigUpdateScheduled { escrow_id: ID, new_config: PolicyEnsemble }
```
Emitted when a new ensemble is staged as pending while the escrow is occupied or in demand.

```
ConfigUpdated { escrow_id: ID, new_config: PolicyEnsemble }
```
Emitted when a staged ensemble becomes the active configuration.

```
CommitmentExtended {
    escrow_id: ID, new_policy: CommitmentPolicy,
    new_expiry_ms: u64, timestamp_ms: u64
}
```
Emitted on `execute_extend_commitment`.

```
RetireFlagSet { escrow_id: ID, governance_cap_id: ID, governor: address, timestamp_ms: u64 }
```
Emitted whenever the governor signals retirement intent — both when the flag is set on an occupied/demand escrow (deferred retire) and when `do_retire_immediately` fires from Idle or Descent (immediate retire). Always paired with `AssetRetired` in the immediate case.

```
ActiveUsufructuaryRefundAddressUpdated {
    escrow_id: ID, usufruct_cap_id: ID,
    old_address: address, new_address: address, timestamp_ms: u64
}
```
Emitted by `execute_update_usufructuary_refund_address` when the presented cap matches the **active** usufructuary seat (`Occupied.terms.active`, or `Demand.terms.active`). Records the address transition so off-chain consumers can rewrite their refund routing without re-reading the seat.

```
PendingUsufructuaryRefundAddressUpdated {
    escrow_id: ID, usufruct_cap_id: ID,
    old_address: address, new_address: address, timestamp_ms: u64
}
```
Emitted by `execute_update_usufructuary_refund_address` when the presented cap matches the **pending** bidder seat (`Demand.bid.pending`). The address transition applies to the refund returned on bid supersession (`do_supersede_bid`).
