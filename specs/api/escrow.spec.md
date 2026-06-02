# escrow

## § OVERVIEW

The public surface of the protocol. `Escrow` is the single shared Sui object that represents an active asset rental market: it wraps `AssetState` and `EscrowCore` inside `Option` fields, exposing every governor and usufructuary operation as a public entry point and every observable property as a view function.

The `Option` wrapper serves a structural purpose: when a usufructuary calls `borrow_asset`, the `AssetState` is extracted from the escrow and placed inside an `AssetReceipt` that travels with the asset. While the asset is out, `escrow.state` is `None`. Any view function that reads state aborts with `EAssetBorrowed` during this window. `return_asset` re-inserts state by filling the `Option` back.

`EscrowCore` uses the same pattern for mutation (take/put via `Option::extract`/`fill`) but `return_asset` borrows it immutably — it only needs `escrow_identity` for validation, not mutation.

The view layer is the protocol's query surface for off-chain clients and PTBs. It exposes the full runtime state, all policy configuration parameters, credit and price computations, settlement previews, and cap validation — all as pure functions over the shared object.

## § TYPES

```
Escrow<Asset: key+store, CoinType: phantom> {
    id:    UID,
    core:  Option<EscrowCore<CoinType>>,
    state: Option<AssetState<Asset, CoinType>>,
}   has key
```
Shared object. One per integrated asset. `state` is `None` while the asset is borrowed by a usufructuary; all other times it is `Some`.

## § API

**Integration**
- `escrow::integrate<Asset, C>(asset, ensemble, retire_commitment, ensemble_commitment, fee_ref: &ProtocolFeeRef, clock, ctx): (GovernanceCap, EarningsInbox)` — opens a new portfolio: mints a fresh `GovernanceCap` + `EarningsInbox` pair (born together in the engine) and shares the `Escrow`. The caller receives **both** instruments, thereafter independent — keep the cap, sell/rent the inbox, or either, in any combination (see PATTERNS).
- `escrow::integrate_into_portfolio<Asset, C>(asset, ensemble, retire_commitment, ensemble_commitment, fee_ref: &ProtocolFeeRef, governance_cap: &GovernanceCap, inbox: &EarningsInbox, clock, ctx)` — joins an existing portfolio: binds the new escrow to a caller-held cap + inbox; mints neither (holding both objects by reference is the authorization). Governance routes to the existing cap, income to the existing inbox. This is the one-pair-to-many path: a single cap + inbox govern and collect for a whole fleet of escrows.

**Governor operations**
- `escrow::claim_asset<Asset, C>(Escrow, governance_cap: &GovernanceCap, clock, ctx): Asset` — consumes the `Escrow` by value and deletes its UID; returns **only the asset**. Governor income was settled to the `EarningsInbox` throughout (never accumulated in the escrow), so there is nothing to sweep. Takes `&GovernanceCap` — the cap may govern other escrows, so claiming one does not consume it. State must be `Retired` after the state-machine advance.
- `escrow::retire<Asset, C>(&mut Escrow, governance_cap: &GovernanceCap, clock, ctx)` — sets the retire flag (if rented) or retires immediately (if idle/descending). Validates commitment has elapsed.
- `escrow::extend_commitment<Asset, C>(&mut Escrow, governance_cap: &GovernanceCap, new_policy: CommitmentPolicy, clock)` — extends the commitment; does not advance the state machine.
- `escrow::update_config<Asset, C>(&mut Escrow, governance_cap: &GovernanceCap, new_ensemble: PolicyEnsemble, clock, ctx)` — stages or applies config update depending on state.

**Usufructuary operations**
- `escrow::rent<Asset, C>(&mut Escrow, payment: Coin<C>, tenures: Tenures, clock, ctx): UsufructCap` — advances state machine; installs, bids, or supersedes. Returns a freshly-minted `UsufructCap` to the transaction sender. The new seat's refund destination is **captured at this moment from `ctx.sender()`** — that is the initial address where any future refund routed through this seat will land:
    - on `do_handover`, if this seat is the active that gets displaced;
    - on `do_supersede_bid`, if this seat is the pending bid that gets displaced.

  Because `UsufructCap` is `key + store` and freely transferable, this initial pinning can become stale the moment the cap changes hands (sale on a secondary market, transfer to a cold wallet, deposit into a vault, etc.). The current holder of the cap can redirect the destination at any later point via `escrow::update_usufructuary_refund_address` — see that entry below.
- `escrow::borrow_asset<Asset, C>(&mut Escrow, usufruct_cap: &UsufructCap, clock, ctx): (Asset, AssetReceipt<Asset, C>)` — advances state machine; extracts the asset; sets `escrow.state = None`. Only the current usufructuary's cap is authorised.
- `escrow::return_asset<Asset, C>(&mut Escrow, asset: Asset, receipt_in: AssetReceipt<Asset, C>)` — validates identity; re-inserts asset into custody; fills `escrow.state`. Borrows core immutably — no state machine advance.
- `escrow::burn_stale_usufruct_cap<Asset, C>(&mut Escrow, cap: UsufructCap, clock, ctx)` — guarded disposal: advances state machine; burns a stale cap. Aborts if cap is current or pending. Requires the live escrow to verify staleness. (The unguarded, escrow-free counterpart is `cap::burn_usufruct_cap` — see the `cap` spec.)
- `escrow::update_usufructuary_refund_address<Asset, C>(&mut Escrow, cap: &UsufructCap, new_address: RefundAddress, clock, ctx)` — advances state machine; redirects the refund destination of the seat whose `cap_identity` matches the presented cap. The address being overwritten is the one captured at `rent` time from `ctx.sender()` (see `rent` above), or any subsequent redirect on the same seat. Authority derives entirely from holding the cap: the call's sender is **not** consulted, only `usufruct_cap::identity(&cap)` is. This is what makes the cap economically self-contained — a buyer on a secondary market can take possession of the cap and redirect refunds without any coordination with the original usufructuary. Aborts with `EUsufructCapStale` if the cap does not match the active or pending seat (a stale cap in renting, or any cap presented while waiting), or `EWrongEscrowUsufructCap` if it belongs to a different escrow.

  Note — no `GovernanceCap` analogue exists, and none is needed. Governor value flows two ways, both **caller-initiated** by someone present at the call: income arrives as `EarningsMessage`s at the `EarningsInbox` and is drained by its bearer via `earnings::collect_earnings_messages` (returning a `Coin<C>` to the sender); `claim_asset` returns the asset directly to the sender. Neither needs a pre-stored destination. The asymmetry is structural: usufructuary refunds (`do_handover`, `do_supersede_bid`) are **event-initiated** from a third party's transaction (the new bidder, or any keeper calling `apply_pending_transition_states`), with the displaced usufructuary absent at the moment of payout; the protocol must therefore carry a pre-stored destination on each `UsufructuarySeat`. Governor flows are caller-initiated, so no such destination is ever needed on the governor side.

**State machine**
- `escrow::apply_pending_transition_states<Asset, C>(&mut Escrow, clock, ctx)` — manually advances the FSM. Called by the protocol automatically at the start of most operations; exposed publicly so keepers can trigger transitions without performing any other action.

**View — runtime state (which lifecycle state the escrow is in)**
- `is_idle(): bool` — Waiting, no usufructuary, asset resting at the floor
- `is_descending(): bool` — Waiting, descent/auction window open, price decaying
- `is_occupied(): bool` — Renting, a current usufructuary, no pending bid
- `is_demand(): bool` — Renting, a current usufructuary plus a pending bid awaiting handover
- `is_rented(): bool` — Renting (Occupied ∨ Demand): someone holds the asset
- `is_retired(): bool` — terminal: asset claimable, escrow closed
- `is_live(): bool` — not Retired (everything except the terminal state)
- `is_retiring(): bool` — Renting with the retire flag set: collapses to Retired at tenure expiry

**View — policy variant predicates** (`<axis>_is_<variant>`, read from the active ensemble)
- `auction_window_is_off(): bool`, `auction_window_is_fixed(): bool` — descent skipped vs a fixed descent window
- `commitment_is_immediate(): bool`, `commitment_is_deferred(): bool` — governor free immediately vs locked for a floor
- `handover_is_off(): bool`, `handover_is_full_tenure(): bool`, `handover_is_fixed(): bool` — handover disabled / at tenure expiry / on a fixed countdown
- `tenure_duration_is_fixed(): bool` — tenure ceiling is a fixed value
- `credit_shape_is_{linear,smoothstep,logistic,power_law,exponential}(): bool` — the credit curve shape
- `auction_shape_is_{linear,smoothstep,logistic,power_law,exponential}(): bool` — the descent curve shape
- `price_fn_is_fixed_delta(): bool`, `price_fn_is_compound_delta(): bool` — escalation is additive vs compounding

**View — identity**
- `asset_id(): ID` — the escrowed asset's object ID
- `asset_type_name(): String`, `coin_type_name(): String` — fully-qualified type names of the asset and payment coin
- `governance_cap_id(): ID` — the ID of the `GovernanceCap` that binds this escrow
- `fee_inbox_id(): ID` — the protocol fee inbox this escrow routes fees to
- `active_ensemble(): PolicyEnsemble` — the full policy bundle currently in force
- `pending_ensemble(): Option<PolicyEnsemble>` — the queued bundle awaiting application, if any
- `has_pending_config_update(): bool` — whether a config update is staged

**View — usufructuary** (`<scope>_usufructuary_<attr>`; `Some` only when that seat exists)
- `active_usufructuary_addr(): Option<address>` — current usufructuary's refund destination
- `active_usufruct_cap_id(): Option<ID>` — current usufructuary's `UsufructCap` ID
- `active_stake_balance_mist(): Option<u64>` — current usufructuary's staked amount
- `active_usufructuary_committed_tenures(): Option<u64>` — number of tenures the current usufructuary committed
- `pending_usufructuary_addr(): Option<address>`, `pending_usufruct_cap_id(): Option<ID>`, `pending_stake_balance_mist(): Option<u64>`, `pending_usufructuary_committed_tenures(): Option<u64>` — same, for the pending bidder
- `active_usufructuary_time_remaining_ms(now_ms): Option<u64>` — ms until the current usufructuary's clock runs out (tenure expiry in Occupied, handover expiry in Demand); `0` past the boundary
- `active_stake_balance_remaining_mist(now_ms): Option<u64>` — the current usufructuary's refundable stake at `now_ms` (stake minus credit already consumed)

**View — timing (active tenancy)**
- `phase_start_ms(): Option<u64>` — when the current phase began (occupancy start, or descent start)
- `tenure_expiry_ms(): Option<u64>` — absolute deadline of the current tenure
- `active_ceiling_total_ms(): Option<u64>` — current tenure's total length (base ceiling × committed_tenures)
- `active_handover_total_ms(): Option<u64>` — current tenancy's total handover window (base × committed_tenures)
- `handover_expiry_ms(): Option<u64>` — absolute time the handover fires (Demand only)
- `handover_expiry_if_bid_at(bid_time_ms): Option<u64>` — hypothetical handover-fire time if a bid arrived at `bid_time_ms` (Occupied only)
- `integrated_at_ms(): u64` — when the asset was integrated
- `tenure_ceiling_ms(): u64` — base tenure length from the live policy (always available, all states)

**View — cycle params by scope** (base, resolved per ensemble; never usufructuary-scaled; `Option<u64>`)
- `active_ensemble_{floor_price_mist,ceiling_ms,handover_ms,descent_ms}()` — the current tenancy's resolved cycle params (`Some` only while rented)
- `pending_ensemble_{floor_price_mist,ceiling_ms,handover_ms,descent_ms}()` — what the queued ensemble would resolve to, computed on demand (`Some` only while a pending config exists). Previews a config change without decoding `PolicyEnsemble`.
- `next_ensemble_{floor_price_mist,ceiling_ms,handover_ms,descent_ms}()` — what the next `rent()` would resolve to, read from the Waiting state (`Some` only while Idle/Descent)

**View — commitment**
- `commitment_anchor_ms(): u64` — start of the current commitment lock segment (re-anchors on `extend_commitment`)
- `commitment_unlocks_at_ms(): u64` — when the governor's lock lifts (anchor + floor)
- `commitment_remaining_ms(now_ms): u64` — ms until unlock; `0` once unlocked
- `commitment_floor_ms(): Option<u64>` — minimum lock duration; `None` for `Immediate`

**View — credit** (the active usufructuary's accrued credit window)
- `credit_is_accruing(): bool` — credit still growing (Occupied)
- `credit_is_capped(): bool` — credit frozen at its cap (Demand)
- `credit_capped_at_ms(): Option<u64>` — time the credit freezes, i.e. the incoming handover (Demand only)
- `accrued_credit_mist(now_ms): u64` — credit consumed by the current usufructuary at `now_ms`

**View — price**
- `floor_price_mist(now_ms): u64` — minimum valid payment for `rent()` in the current state at `now_ms`; always a non-aborting payment in every rentable state
- `next_floor_price_mist(total_bid_mist, tenures): u64` — the entry floor a *next* usufructuary would face after a bid of `total_bid_mist` over `tenures` (escalation applied per-tenure)
- `last_rent_price_mist(): Option<u64>` — last acquisition price, the descent's starting point (Descent only)

**View — settlement** (pure preview of how a usufructuary's stake would split)
- `handover_settlement(boundary_ms): (u64, u64, u64)` — `(remaining→refund, governor share, fee)` if the handover fired at `boundary_ms`; time-dependent (partial credit consumption)
- `tenure_settlement(): (u64, u64)` — `(governor share, fee)` at natural tenure expiry; full stake consumed, no refund

**View — transitions**
- `transition_is_ready(now_ms): bool` — whether a pending transition can fire at `now_ms`
- `next_transition_ms(now_ms): Option<u64>` — earliest time a transition can fire

**View — cap validation**
- `governance_cap_is_valid(cap_id): bool` — does `cap_id` bind this escrow's governor
- `usufruct_cap_is_active(cap_id): bool`, `usufruct_cap_is_pending(cap_id): bool`, `usufruct_cap_is_stale(cap_id): bool` — the presented cap's standing against the current/pending seats

**View — policy detail** (introspection into the active ensemble)
- Policy-bound durations/prices: `rest_price_floor_mist(): u64` (resting floor price), `descent_ceiling_ms(): Option<u64>` (max descent window), `handover_floor_ms(): Option<u64>` (min handover countdown), `commitment_floor_ms(): Option<u64>` (min commitment lock)
- Single-variant accessors (guarded by the matching predicate): `tenure_ceiling_fixed_ms(): u64`, `rest_price_floor_fixed_mist(): u64`
- Typed policy getters (`<axis>()`, where the enum carries composable params): `credit_shape(): CurveShapePolicy`, `auction_shape(): CurveShapePolicy`, `price_fn(): PriceEscalationPolicy`
- Curve param accessors (`Some` only for the matching shape): `{credit,auction}_shape_power_law_alpha_{num,den}(): Option<u8>`, `{credit,auction}_shape_exponential_alpha_abs(): Option<u8>`, `{credit,auction}_shape_exponential_alpha_neg(): Option<bool>`
- Escalation param accessors: `price_fn_fixed_delta(): Option<u64>`, `price_fn_compound_delta_bps(): Option<u64>`, `price_fn_compound_delta_delta(): Option<u64>`, `price_fn_delta_mist(): u64`
- Policy kind strings (`<axis>_kind(): String`): `rest_price_kind`, `tenure_duration_kind`, `tenure_extend_kind`, `handover_kind`, `auction_window_kind`, `credit_shape_kind`, `auction_shape_kind`, `price_fn_kind`, `commitment_kind`
- Protocol constants: `protocol_fee_bps(): u64`, `bps_denominator(): u64`

## § VIEW NAMING CONVENTIONS

Canonical rules the view layer follows. A new view must conform; an inconsistency is a defect to fix, not a precedent.

- **Variant predicates — `<axis>_is_<variant>` (infix).** e.g. `handover_is_fixed`, `commitment_is_deferred`, `credit_shape_is_linear`. Groups every introspection mechanism of an axis under one prefix.
- **Kind string — `<axis>_kind(): String`.** The variant name as a string for off-chain branching. No `_policy` infix.
- **Typed policy getter — `<axis>()`.** Returns the policy enum, provided only where the enum carries composable params worth matching on-chain: `credit_shape()`, `auction_shape()`, `price_fn()`.
- **Policy bounds — `<phase>_<floor|ceiling>_ms`.** `floor` = lower bound, `ceiling` = upper bound, reflecting each phase's role: tenure and descent have a ceiling (they end at it); handover and commitment have a floor (they cannot fire/lift before it).
- **Cycle params by scope.** `active_ensemble_*` (current tenancy), `pending_ensemble_*` (queued config), `next_ensemble_*` (next rent) — all base, never usufructuary-scaled. `active_*_total_ms` is the only usufructuary-scaled form (base × committed_tenures); `pending`/`next` have no `total` because no usufructuary exists yet.
- **Usufructuary attributes — `<scope>_usufructuary_<attr>`.** The `usufructuary` infix distinguishes usufructuary data from config data under the same `active_`/`pending_` scope (`active_stake_balance_mist` vs `active_ensemble_floor_price_mist`).
- **Units always suffixed.** `_ms` for durations and timestamps, `_mist` for money. Counts use the noun (`_tenures`). Tuple-returning views (settlements) carry no unit suffix.
- **Domain verb over generic.** Prefer the precise domain verb where one exists: `unlocks_at` (commitment lock lifts), `capped_at` (credit freezes) — reserve `expiry` for things that genuinely expire (`tenure_expiry_ms`, `handover_expiry_ms`).
- **Time as a primitive.** Runtime views take `now_ms: u64`, not `&Clock`, so the same view serves a live clock or any hypothetical instant.
- **Resolved / hypothetical twins share a stem.** `handover_expiry_ms` (resolved) ↔ `handover_expiry_if_bid_at` (what-if).
- **No comments in production source.** Each view's meaning lives here in the spec, not in `//` comments in `escrow.move`.

## § INVARIANTS

- `Escrow` is a shared object; it can never be owned or transferred.
- `escrow.state` is `None` only while the asset is borrowed. All view functions and mutations that read state abort with `EAssetBorrowed` during this window.
- `claim_asset` is the only operation that consumes the `Escrow` value. It also burns the `GovernanceCap` and deletes the UID, making the escrow permanently unreachable after a successful claim.
- `return_asset` does not advance the state machine; it must not, since it is called while the core holds an immutable borrow.

## § EVENTS

None. All events are emitted by `asset_state` and the entity modules. `escrow.move` is a pass-through layer.
