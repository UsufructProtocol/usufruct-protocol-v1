# escrow

## § OVERVIEW

The public surface of the protocol. `Escrow` is the single shared Sui object that represents an active asset rental market: it wraps `AssetState` and `EscrowCore` inside `Option` fields, exposing every owner and tenant operation as a public entry point and every observable property as a view function.

The `Option` wrapper serves a structural purpose: when a tenant calls `borrow_asset`, the `AssetState` is extracted from the escrow and placed inside an `AssetReceipt` that travels with the asset. While the asset is out, `escrow.state` is `None`. Any view function that reads state aborts with `EAssetBorrowed` during this window. `return_asset` re-inserts state by filling the `Option` back.

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
Shared object. One per integrated asset. `state` is `None` while the asset is borrowed by a tenant; all other times it is `Some`.

## § API

**Integration**
- `escrow::integrate<Asset, C>(asset, ensemble, commitment, fee_ref: &ProtocolFeeRef, random, clock, ctx): OwnerCap` — creates and shares the `Escrow`; delegates to `asset_state::execute_integrate`; returns the `OwnerCap` to the transaction sender.

**Owner operations**
- `escrow::withdraw_earnings<Asset, C>(&mut Escrow, owner_cap: &OwnerCap, random, clock, ctx): Coin<C>` — advances state machine; drains owner accumulated balance.
- `escrow::claim_asset<Asset, C>(Escrow, owner_cap: OwnerCap, random, clock, ctx): (Asset, Coin<C>)` — consumes the `Escrow` by value; burns the `OwnerCap`; deletes the UID; returns the asset and swept earnings. State must be `Retired` after the state machine advance.
- `escrow::retire<Asset, C>(&mut Escrow, owner_cap: &OwnerCap, random, clock, ctx)` — sets the retire flag (if rented) or retires immediately (if idle/at_dutch). Validates commitment has elapsed.
- `escrow::extend_commitment<Asset, C>(&mut Escrow, owner_cap: &OwnerCap, new_policy: CommitmentPolicy, clock)` — extends the commitment; does not advance the state machine.
- `escrow::update_config<Asset, C>(&mut Escrow, owner_cap: &OwnerCap, new_ensemble: PolicyEnsemble, random, clock, ctx)` — stages or applies config update depending on state.

**Tenant operations**
- `escrow::rent<Asset, C>(&mut Escrow, payment: Coin<C>, cycles: Tenures, random, clock, ctx): TenantCap` — advances state machine; installs, bids, or supersedes. Returns a `TenantCap` to the transaction sender.
- `escrow::borrow_asset<Asset, C>(&mut Escrow, tenant_cap: &TenantCap, random, clock, ctx): (Asset, AssetReceipt<Asset, C>)` — advances state machine; extracts the asset; sets `escrow.state = None`. Only the current tenant's cap is authorised.
- `escrow::return_asset<Asset, C>(&mut Escrow, asset: Asset, receipt_in: AssetReceipt<Asset, C>)` — validates identity; re-inserts asset into custody; fills `escrow.state`. Borrows core immutably — no state machine advance.
- `escrow::soft_burn_tenant_cap<Asset, C>(&mut Escrow, cap: TenantCap, random, clock, ctx)` — advances state machine; burns a stale cap. Aborts if cap is current or pending.
- `escrow::hard_burn_tenant_cap(cap: TenantCap, ctx)` — burns a cap directly with no escrow context; valid for any cap the caller holds.

**State machine**
- `escrow::apply_pending_transition_states<Asset, C>(&mut Escrow, random, clock, ctx)` — manually advances the FSM. Called by the protocol automatically at the start of most operations; exposed publicly so keepers can trigger transitions without performing any other action.

**View — state shape**
- `is_idle`, `is_at_dutch_auction`, `is_occupied`, `is_demand`, `is_active`, `is_retired`, `is_rented`, `is_retiring`

**View — policy shape**
- `is_descent_skipped`, `is_descent_window`
- `is_commitment_immediate`, `is_commitment_deferred`
- `is_handover_off`, `is_handover_full_tenure`, `is_handover_fixed`

**View — identity**
- `asset_id(): ID`, `asset_type_name(): TypeName`, `coin_type_name(): TypeName`
- `owner_cap_id(): ID`, `fee_inbox_id(): ID`
- `active_ensemble(): PolicyEnsemble`, `pending_ensemble(): Option<PolicyEnsemble>`, `has_pending_config_update(): bool`

**View — tenant**
- `current_tenant_addr(): Option<address>`, `current_tenant_cap_id(): Option<ID>`, `current_stake(): Option<u64>`, `current_committed_tenures(): Option<u64>`
- `pending_tenant_addr(): Option<address>`, `pending_tenant_cap_id(): Option<ID>`, `pending_stake(): Option<u64>`, `pending_committed_tenures(): Option<u64>`

**View — timing (active tenure)**
- `phase_start_ms(): Option<u64>` — when current occupancy began
- `tenure_expiry_ms(): Option<u64>` — absolute deadline of the current tenure
- `active_tenure_ceiling_ms(): Option<u64>` — resolved ceiling duration for the current cycle
- `active_handover_duration_ms(): Option<u64>` — resolved handover window for the current cycle
- `active_floor_price_mist(): Option<u64>` — resolved rest price for the current cycle
- `handover_countdown_expiry_ms(): Option<u64>` — absolute deadline after which handover can fire (Demand only)
- `compute_handover_expiry_at(bid_time_ms: u64): Option<u64>` — hypothetical handover deadline if a bid were placed at `bid_time_ms` (Occupied only)

**View — timing (waiting/next cycle)**
- `next_floor_price_mist(): Option<u64>` — rest price resolved for the next Idle cycle
- `next_tenure_ceiling_ms(): Option<u64>` — tenure ceiling resolved for the next Idle cycle
- `next_handover_duration_ms(): Option<u64>` — handover duration resolved for the next Idle cycle
- `auction_descent_duration_ms(): Option<u64>` — descent window resolved for the current AtDutch phase
- `last_acq_price(): Option<u64>` — last acquisition price stored in `AuctionTerms` (AtDutch only)
- `tenure_ceiling_ms(): u64` — deterministic lower bound of the tenure ceiling from policy (always available)

**View — commitment**
- `commitment_unlocks_at_ms(): u64`, `commitment_anchor_ms(): u64`, `commitment_remaining_ms(now_ms): u64`
- `commitment_floor_ms(): Option<u64>` — `None` for `Immediate` policy

**View — credit**
- `credit_is_accruing(): bool`, `credit_is_capped(): bool`
- `credit_stake_mist(): Option<u64>`, `credit_phase_start_ms(): Option<u64>`, `credit_expiry_ms(): Option<u64>`
- `compute_used_credit(clock): u64` — credit consumed by current tenant at `now`
- `compute_used_credit_at_ms(timestamp_ms): u64` — credit consumed at an arbitrary timestamp

**View — price**
- `compute_floor_price(clock): u64` — current floor price for the state at `now`
- `compute_floor_price_at_ms(timestamp_ms): u64` — floor price at an arbitrary timestamp
- `compute_next_ascending_floor(bid_amount: u64): u64` — next escalated floor if `bid_amount` were the current stake

**View — settlement**
- `compute_handover_settlement(boundary_ms): (u64, u64, u64)` — (remaining stake, owner share, fee) at `boundary_ms`
- `compute_tenure_settlement(): (u64, u64)` — (owner share, fee) if the tenure expired now; full stake consumed
- `owner_balance(): u64` — owner's accumulated unwithdrawn earnings

**View — transitions**
- `has_pending_transition_states(clock): bool` — whether a transition is currently fireable
- `next_transition_ms(clock): Option<u64>` — earliest timestamp a transition can fire

**View — cap validation**
- `owner_cap_is_valid(owner_cap): bool`
- `tenant_cap_is_current(cap_id): bool`, `tenant_cap_is_pending(cap_id): bool`, `tenant_cap_is_stale(cap_id): bool`

**View — policy detail** (introspection into the active ensemble)
- `min_rent_price()`, `min_rent_price_is_fixed()`, `min_rent_price_is_random_in_range()`, `min_rent_price_fixed_mist()`, `min_rent_price_range_min_mist()`, `min_rent_price_range_max_mist()`
- `tenure_ceiling_is_fixed()`, `tenure_ceiling_is_random_in_range()`, `tenure_ceiling_fixed_ms()`, `tenure_ceiling_range_min_ms()`, `tenure_ceiling_range_max_ms()`
- `dutch_auction_ceiling_ms()`, `handover_countdown_floor_ms()`
- `credit_shape()`, `auction_shape()`, `ascending_price_function_state()`
- Per-curve and per-policy-variant breakdowns: `credit_shape_is_*`, `auction_shape_is_*`, `price_fn_is_*`, and their parameter accessors
- `protocol_fee_bps(): u64`, `bps_denominator(): u64`

## § INVARIANTS

- `Escrow` is a shared object; it can never be owned or transferred.
- `escrow.state` is `None` only while the asset is borrowed. All view functions and mutations that read state abort with `EAssetBorrowed` during this window.
- `claim_asset` is the only operation that consumes the `Escrow` value. It also burns the `OwnerCap` and deletes the UID, making the escrow permanently unreachable after a successful claim.
- `return_asset` does not advance the state machine; it must not, since it is called while the core holds an immutable borrow.

## § EVENTS

None. All events are emitted by `asset_state` and the entity modules. `escrow.move` is a pass-through layer.
