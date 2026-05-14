// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::escrow;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{
    clock::Clock,
    coin::Coin,
    random::Random,
};
use usufruct::{
    asset::AssetReceipt,
    config::{Self, IntegrationConfig},
    curve_shape_state::{Self as curve, CurveShapeState},
    cycles::Cycles,
    descent_policy_state,
    asset_state::{Self, EscrowCore, AssetState},
    handover_policy_state,
    floor_price_policy_state,
    math,
    tenure_policy_state,
    monetary,
    owner_cap::{Self, OwnerCap},
    pending_transition_state::{Self, PendingTransitionState},
    phases,
    price_function_state::{Self, PriceFunctionState},
    escrow_identity,
    protocol_fee_ref::{Self, ProtocolFeeRef},
    commitment_policy_state::{Self, CommitmentPolicyState},
    tenant_cap::{Self, TenantCap},
};

// === Errors ===

// === Structs ===

/// Central shared object. One per integrated asset.
///
/// Storage is split into two `Option` slots:
///   · `core`  — owner ledger + protocol envelope, orthogonal to lifecycle
///     state. Ortho actions (withdraw_earnings, extend_commitment) only
///     touch this slot.
///   · `state` — the lifecycle-state variant (Idle / AtDutch / Retired /
///     Occupied / Demand). APT and state transitions consume only this
///     slot.
///
/// The two `Option`s let entry functions extract `state` by value (for
/// the `execute_*` call) while keeping a `&mut` borrow into `core` —
/// physically disjoint borrows that the type system enforces.
public struct Escrow<Asset: key + store, phantom CoinType> has key {
    id:    UID,
    core:  Option<EscrowCore<CoinType>>,
    state: Option<AssetState<Asset, CoinType>>,
}

// === Public Functions ===

/// Create and share an `Escrow`. Mints the `OwnerCap` and returns it to
/// the caller. The lifecycle work (resolving policy values, building the
/// core, minting the cap, emitting events) lives in
/// `asset_state::execute_integrate`; this entry only handles the Sui
/// boundary that the `Escrow`-defining module must own: minting the
/// `UID` and sharing the wrapping struct.
public fun integrate<Asset: key + store, CoinType>(
    asset:      Asset,
    cfg:        IntegrationConfig,
    commitment: CommitmentPolicyState,
    fee_ref:    &ProtocolFeeRef,
    random:     &Random,
    clock:      &Clock,
    ctx:        &mut TxContext,
): OwnerCap {
    let uid           = object::new(ctx);
    let mut generator = sui::random::new_generator(random, ctx);
    let (core, state, owner_cap) = asset_state::execute_integrate<Asset, CoinType>(
        asset, cfg, commitment,
        protocol_fee_ref::proj_inbox_identity(fee_ref),
        escrow_identity::new(object::uid_to_inner(&uid)),
        phases::now(clock),
        &mut generator,
        ctx,
    );
    transfer::share_object(Escrow<Asset, CoinType> {
        id:    uid,
        core:  option::some(core),
        state: option::some(state),
    });
    owner_cap
}

/// Owner-gated earnings withdrawal.
public fun withdraw_earnings<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Coin<CoinType> {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let new_state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    let coin = asset_state::execute_withdraw_earnings(core, owner_cap, clock, ctx);
    escrow.state.fill(new_state);
    coin
}

/// Owner-gated terminal claim. Consumes the escrow by value. The
/// lifecycle work (APT settle, asset unlock, earnings withdrawal,
/// `AssetClaimed` emission) lives in `asset_state::execute_claim`; this
/// entry only handles the Sui boundary: unwrapping the `Escrow`,
/// burning the `OwnerCap`, deleting the `UID`.
public fun claim_asset<Asset: key + store, CoinType>(
    escrow:    Escrow<Asset, CoinType>,
    owner_cap: OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    let Escrow { id, core, state } = escrow;
    let mut core_val      = core.destroy_some();
    let new_state         = asset_state::apply_pending_transition_states(state.destroy_some(), &mut core_val, random, clock, ctx);
    let (asset, earnings) = asset_state::execute_claim(new_state, core_val, &owner_cap, clock, ctx);
    owner_cap::burn(owner_cap, ctx.sender());
    id.delete();
    (asset, earnings)
}

/// Owner-gated retire entry.
public fun retire<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
) {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    let new_state = asset_state::execute_retire(state, core, owner_cap, clock, ctx);
    escrow.state.fill(new_state);
}

/// Owner-gated commitment extension. New expiry must be ≥ current expiry.
public fun extend_commitment<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    owner_cap:  &OwnerCap,
    new_policy: CommitmentPolicyState,
    clock:      &Clock,
) {
    asset_state::execute_extend_commitment(escrow.core.borrow_mut(), owner_cap, new_policy, clock);
}

/// Owner-gated operational parameter reset.
public fun update_config<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    new_cfg:   IntegrationConfig,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
) {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    let new_state = asset_state::execute_update_config(state, core, owner_cap, new_cfg, random, ctx);
    escrow.state.fill(new_state);
}

/// Single entry point to become tenant or place a bid.
public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut Escrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    cycles:  Cycles,
    random:  &Random,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    let (new_state, cap) = asset_state::execute_rent(state, core, payment, cycles, clock, ctx);
    escrow.state.fill(new_state);
    cap
}

/// Tenant-side asset borrow.
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    random:     &Random,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt) {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    let (new_state, asset, receipt) = asset_state::execute_borrow(state, core, tenant_cap);
    escrow.state.fill(new_state);
    (asset, receipt)
}

/// Tenant-side asset return.
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let state = escrow.state.borrow_mut();
    let core  = escrow.core.borrow();
    asset_state::execute_return(state, core, asset, receipt_in);
}

/// Burn a stale `TenantCap` for gas recovery.
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    cap:    TenantCap,
    random: &Random,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    let new_state = asset_state::execute_burn_tenant_cap(state, core, cap, ctx);
    escrow.state.fill(new_state);
}

/// Permissionless settler.
public fun apply_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    random: &Random,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let state = escrow.state.extract();
    let core = escrow.core.borrow_mut();
    let new_state = asset_state::apply_pending_transition_states(state, core, random, clock, ctx);
    escrow.state.fill(new_state);
}

/// Detect the single transition that is due at `now`, if any.
public fun next_pending<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): Option<PendingTransitionState> {
    asset_state::next_pending(read_state(escrow), clock)
}

// === View Functions ===

// ─── State predicates ────────────────────────────────────────────────────────

public fun is_idle<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_idle(read_state(escrow))
}

public fun is_at_dutch_auction<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_at_dutch(read_state(escrow))
}

public fun is_occupied<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_occupied(read_state(escrow))
}

public fun is_demand<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_demand(read_state(escrow))
}

public fun is_active<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_active(read_state(escrow))
}

public fun is_retired<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_retired(read_state(escrow))
}

public fun is_rented<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_rented(read_state(escrow))
}

public fun is_descent_skipped<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    descent_policy_state::proj_is_skipped(config::proj_descent(cfg(escrow)))
}

public fun is_descent_window<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    descent_policy_state::proj_is_window(config::proj_descent(cfg(escrow)))
}

public fun is_commitment_immediate<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    commitment_policy_state::proj_is_immediate(&asset_state::proj_commitment_policy(read_core(escrow)))
}

public fun is_commitment_deferred<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    commitment_policy_state::proj_is_deferred(&asset_state::proj_commitment_policy(read_core(escrow)))
}

public fun is_handover_instant<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy_state::proj_is_instant(config::proj_handover(cfg(escrow)))
}

public fun is_handover_fixed_time<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy_state::proj_is_fixed_time(config::proj_handover(cfg(escrow)))
}

public fun is_handover_countdown<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy_state::proj_is_countdown(config::proj_handover(cfg(escrow)))
}

public fun is_retiring<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_retiring(read_state(escrow))
}

// ─── Identity views ──────────────────────────────────────────────────────────

public fun asset_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    asset_state::proj_asset_id(read_state(escrow))
}

public fun asset_type_name<Asset: key + store, CoinType>(
    _escrow: &Escrow<Asset, CoinType>,
): TypeName {
    type_name::with_defining_ids<Asset>()
}

public fun coin_type_name<Asset: key + store, CoinType>(
    _escrow: &Escrow<Asset, CoinType>,
): TypeName {
    type_name::with_defining_ids<CoinType>()
}

public fun owner_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    asset_state::proj_owner_cap_id(read_core(escrow))
}

public fun current_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    asset_state::proj_current_addr(read_state(escrow))
}

public fun current_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    asset_state::proj_current_cap_id(read_state(escrow))
}

public fun pending_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    asset_state::proj_pending_addr(read_state(escrow))
}

public fun pending_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    asset_state::proj_pending_cap_id(read_state(escrow))
}

// ─── Stake views ─────────────────────────────────────────────────────────────

public fun current_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_current_stake(read_state(escrow)).map!(|v| monetary::stake_mist(v))
}

public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_stake(read_state(escrow)).map!(|v| monetary::stake_mist(v))
}

// ─── Temporal views ───────────────────────────────────────────────────────────

public fun phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_phase_start(read_state(escrow)).map!(|v| phases::timestamp_ms(v))
}

public fun tenure_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let s = read_state(escrow);
    if (!asset_state::proj_is_rented(s)) return option::none();
    let ps      = *asset_state::proj_phase_start(s).borrow();
    let ceiling = *asset_state::proj_resolved_ceiling(s).borrow();
    option::some(phases::timestamp_ms(phases::boundary_at(ps, ceiling)))
}

public fun active_tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_resolved_ceiling(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

public fun active_handover_duration_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_resolved_handover(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

public fun active_floor_price_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_resolved_floor(read_state(escrow)).map!(|v| monetary::price_mist(v))
}

public fun next_floor_price_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_waiting_resolved_floor(read_state(escrow)).map!(|v| monetary::price_mist(v))
}

public fun next_tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_waiting_resolved_ceiling(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

public fun next_handover_duration_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_waiting_resolved_handover(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

public fun auction_descent_duration_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_waiting_resolved_descent(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

public fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_handover_expiry(read_state(escrow)).map!(|v| phases::timestamp_ms(v))
}

public fun compute_handover_expiry_at<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    bid_time_ms: u64,
): Option<u64> {
    let s = read_state(escrow);
    if (!asset_state::proj_is_occupied(s)) return option::none();
    let phase_start       = *asset_state::proj_phase_start(s).borrow();
    let resolved_ceiling  = *asset_state::proj_resolved_ceiling(s).borrow();
    let resolved_handover = *asset_state::proj_resolved_handover(s).borrow();
    option::some(phases::timestamp_ms(handover_policy_state::expiry_at(resolved_handover, resolved_ceiling, phases::timestamp(bid_time_ms), phase_start)))
}

public fun tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::duration_ms(tenure_policy_state::min_ceiling(config::proj_tenure_ceiling(cfg(escrow))))
}

public fun integrated_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::timestamp_ms(asset_state::proj_integrated_at(read_core(escrow)))
}

public fun commitment_unlocks_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    let c        = read_core(escrow);
    let resolved = commitment_policy_state::resolve(&asset_state::proj_commitment_policy(c));
    phases::timestamp_ms(commitment_policy_state::unlock_at(resolved, asset_state::proj_commitment_anchor(c)))
}

public fun commitment_anchor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::timestamp_ms(asset_state::proj_commitment_anchor(read_core(escrow)))
}

public fun commitment_remaining_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): u64 {
    let unlocks = commitment_unlocks_at_ms(escrow);
    if (now_ms >= unlocks) 0 else unlocks - now_ms
}

// ─── Cap views ───────────────────────────────────────────────────────────────

public fun owner_cap_is_valid<Asset: key + store, CoinType>(
    escrow:    &Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
): bool {
    asset_state::proj_owner_cap_id(read_core(escrow)) == object::id(owner_cap)
}

public fun tenant_cap_is_current<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): bool {
    asset_state::cap_is_current(read_state(escrow), tenant_cap::from_id(cap_id))
}

public fun tenant_cap_is_pending<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): bool {
    asset_state::cap_is_pending(read_state(escrow), tenant_cap::from_id(cap_id))
}

public fun tenant_cap_is_stale<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): bool {
    asset_state::cap_is_stale(read_state(escrow), tenant_cap::from_id(cap_id))
}


// ─── Timing views ────────────────────────────────────────────────────────────

public fun has_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): bool {
    next_pending(escrow, clock).is_some()
}

public fun next_transition_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): Option<u64> {
    next_pending(escrow, clock).map!(|v| phases::timestamp_ms(pending_transition_state::proj_boundary(&v)))
}

// ─── Pricing views ───────────────────────────────────────────────────────────

public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    monetary::stake_mist(asset_state::used_credit_at(read_state(escrow), read_core(escrow), phases::now(clock)))
}

public fun compute_used_credit_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    monetary::stake_mist(asset_state::used_credit_at(read_state(escrow), read_core(escrow), phases::timestamp(timestamp_ms)))
}

public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    monetary::price_mist(asset_state::floor_price_at(read_state(escrow), read_core(escrow), phases::now(clock)))
}

public fun compute_floor_price_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    monetary::price_mist(asset_state::floor_price_at(read_state(escrow), read_core(escrow), phases::timestamp(timestamp_ms)))
}

public fun compute_next_ascending_floor<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    bid_amount: u64,
): u64 {
    monetary::price_mist(price_function_state::evaluate_price_fn(config::proj_price_function_state(cfg(escrow)), monetary::price(bid_amount)))
}

public fun last_acq_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_last_acq_price(read_state(escrow)).map!(|v| monetary::price_mist(v))
}

// ─── Credit context views ─────────────────────────────────────────────────────

public fun credit_is_accruing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_credit_is_accruing(read_state(escrow))
}

public fun credit_is_capped<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_credit_is_capped(read_state(escrow))
}

public fun credit_stake_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_credit_stake(read_state(escrow)).map!(|v| monetary::stake_mist(v))
}

public fun credit_phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_credit_phase_start(read_state(escrow)).map!(|v| phases::timestamp_ms(v))
}

public fun credit_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_credit_expiry(read_state(escrow)).map!(|v| phases::timestamp_ms(v))
}

// ─── Settlement views ────────────────────────────────────────────────────────

public fun compute_handover_settlement<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    boundary_ms: u64,
): (u64, u64, u64) {
    let (remaining, owner, fee) = asset_state::proj_handover_settlement(
        read_state(escrow), read_core(escrow), phases::timestamp(boundary_ms),
    );
    (monetary::stake_mist(remaining), monetary::stake_mist(owner), monetary::stake_mist(fee))
}

public fun compute_tenure_settlement<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): (u64, u64) {
    let (owner, fee) = asset_state::proj_tenure_settlement(read_state(escrow));
    (monetary::stake_mist(owner), monetary::stake_mist(fee))
}

// ─── Earnings views ──────────────────────────────────────────────────────────

public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::stake_mist(asset_state::proj_owner_balance(read_core(escrow)))
}

// ─── Config views ────────────────────────────────────────────────────────────

public fun integration_config<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): IntegrationConfig {
    *cfg(escrow)
}

public fun fee_inbox_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    asset_state::proj_fee_inbox_id(read_core(escrow))
}

public fun has_pending_config_update<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_pending_config(read_core(escrow)).is_some()
}

public fun protocol_fee_bps(): u64 { asset_state::protocol_fee_bps() }
public fun bps_denominator():  u64 { asset_state::bps_denominator() }

public fun min_rent_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::price_mist(floor_price_policy_state::floor_for_view(config::proj_min_rent_price(cfg(escrow))))
}

public fun dutch_auction_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    descent_policy_state::proj_window_ceiling(config::proj_descent(cfg(escrow))).map!(|v| phases::duration_ms(v))
}

public fun handover_countdown_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    handover_policy_state::proj_countdown_floor_ms(config::proj_handover(cfg(escrow))).map!(|v| phases::duration_ms(v))
}

public fun commitment_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    commitment_policy_state::proj_floor_ms(&asset_state::proj_commitment_policy(read_core(escrow))).map!(|v| phases::duration_ms(v))
}

public fun credit_curve<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShapeState {
    *config::proj_credit_curve(cfg(escrow))
}

public fun descent_curve<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShapeState {
    *config::proj_descent_curve(cfg(escrow))
}

public fun ascending_price_function_state<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): PriceFunctionState {
    *config::proj_price_function_state(cfg(escrow))
}

// ─── Tenure policy views ──────────────────────────────────────────────────────

public fun tenure_ceiling_is_fixed<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    tenure_policy_state::proj_is_fixed(config::proj_tenure_ceiling(cfg(escrow)))
}

public fun tenure_ceiling_is_random_in_range<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    tenure_policy_state::proj_is_random_in_range(config::proj_tenure_ceiling(cfg(escrow)))
}

public fun tenure_ceiling_fixed_ms<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    tenure_policy_state::proj_fixed_ceiling(config::proj_tenure_ceiling(cfg(escrow))).map!(|v| phases::duration_ms(v))
}

public fun tenure_ceiling_range_min_ms<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    tenure_policy_state::proj_range_min(config::proj_tenure_ceiling(cfg(escrow))).map!(|v| phases::duration_ms(v))
}

public fun tenure_ceiling_range_max_ms<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    tenure_policy_state::proj_range_max(config::proj_tenure_ceiling(cfg(escrow))).map!(|v| phases::duration_ms(v))
}

// ─── Floor price policy views ─────────────────────────────────────────────────

public fun min_rent_price_is_fixed<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    floor_price_policy_state::proj_is_fixed(config::proj_min_rent_price(cfg(escrow)))
}

public fun min_rent_price_is_random_in_range<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    floor_price_policy_state::proj_is_random_in_range(config::proj_min_rent_price(cfg(escrow)))
}

public fun min_rent_price_fixed_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    floor_price_policy_state::proj_fixed_price(config::proj_min_rent_price(cfg(escrow))).map!(|v| monetary::price_mist(v))
}

public fun min_rent_price_range_min_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    floor_price_policy_state::proj_range_min(config::proj_min_rent_price(cfg(escrow))).map!(|v| monetary::price_mist(v))
}

public fun min_rent_price_range_max_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    floor_price_policy_state::proj_range_max(config::proj_min_rent_price(cfg(escrow))).map!(|v| monetary::price_mist(v))
}

// ─── Credit curve views ───────────────────────────────────────────────────────

public fun credit_curve_is_linear<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_linear(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_is_smoothstep<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_smoothstep(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_is_logistic<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_logistic(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_is_power_law<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_power_law(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_is_exponential<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_exponential(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_power_law_alpha_num<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_num(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_power_law_alpha_den<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_den(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_exponential_alpha_abs<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_exponential_alpha_abs(config::proj_credit_curve(cfg(escrow)))
}

public fun credit_curve_exponential_alpha_neg<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<bool> {
    curve::proj_exponential_alpha_neg(config::proj_credit_curve(cfg(escrow)))
}

// ─── Descent curve views ──────────────────────────────────────────────────────

public fun descent_curve_is_linear<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_linear(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_is_smoothstep<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_smoothstep(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_is_logistic<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_logistic(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_is_power_law<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_power_law(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_is_exponential<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_exponential(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_power_law_alpha_num<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_num(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_power_law_alpha_den<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_den(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_exponential_alpha_abs<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_exponential_alpha_abs(config::proj_descent_curve(cfg(escrow)))
}

public fun descent_curve_exponential_alpha_neg<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<bool> {
    curve::proj_exponential_alpha_neg(config::proj_descent_curve(cfg(escrow)))
}

// ─── Price function views ─────────────────────────────────────────────────────

public fun price_fn_is_fixed_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    price_function_state::proj_is_fixed_delta(config::proj_price_function_state(cfg(escrow)))
}

public fun price_fn_is_compound_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    price_function_state::proj_is_compound_delta(config::proj_price_function_state(cfg(escrow)))
}

public fun price_fn_fixed_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_function_state::proj_fixed_delta(config::proj_price_function_state(cfg(escrow))).map!(|v| monetary::price_mist(v))
}

public fun price_fn_compound_delta_bps<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_function_state::proj_compound_delta_bps(config::proj_price_function_state(cfg(escrow))).map!(|v| math::bps_value(v))
}

public fun price_fn_compound_delta_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_function_state::proj_compound_delta_delta(config::proj_price_function_state(cfg(escrow))).map!(|v| monetary::price_mist(v))
}

// === Private Functions ===

fun read_state<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &AssetState<Asset, CoinType> {
    escrow.state.borrow()
}

fun read_core<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &EscrowCore<CoinType> {
    escrow.core.borrow()
}

fun cfg<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &IntegrationConfig {
    asset_state::proj_config(read_core(escrow))
}

// === Test Functions ===

#[test_only]
public(package) fun owner_value_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::stake_mist(asset_state::proj_owner_balance(read_core(escrow)))
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    asset_state::split_fee_for_testing(amount)
}

#[test_only]
public(package) fun resolved_descent_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::duration_ms(asset_state::proj_resolved_descent_for_testing(read_state(escrow)))
}

#[test_only]
public(package) fun resolved_floor_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::price_mist(asset_state::proj_resolved_floor_for_testing(read_state(escrow)))
}

#[test_only]
public(package) fun resolved_ceiling_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::duration_ms(asset_state::proj_resolved_ceiling_for_testing(read_state(escrow)))
}

#[test_only]
public(package) fun resolved_handover_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::duration_ms(asset_state::proj_resolved_handover_for_testing(read_state(escrow)))
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    escrow:         &mut Escrow<Asset, CoinType>,
    tenant:         usufruct::tenant::Tenant<CoinType>,
    phase_start_ms: u64,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::drive_to_rented_for_testing(
        state, escrow.core.borrow(), tenant, phases::timestamp(phase_start_ms),
    );
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut Escrow<Asset, CoinType>,
    tenant:                    usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::drive_to_demand_for_testing(
        state, tenant, phases::timestamp(handover_countdown_expiry),
    );
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    escrow:             &mut Escrow<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::drive_to_at_dutch_for_testing(
        state, escrow.core.borrow(), owner_amount, fee_amount, last_acq_price, phases::timestamp(new_phase_start_ms),
    );
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::drive_to_retired_for_testing(state);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::drive_to_retiring_flag_for_testing(state);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::fire_do_handover_for_testing(state, escrow.core.borrow_mut(), boundary, ctx);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let state = escrow.state.extract();
    let new_state = asset_state::fire_do_tenure_expiry_for_testing(state, escrow.core.borrow_mut(), boundary, ctx);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
) {
    let mut generator = sui::random::new_generator_from_seed_for_testing(vector[0u8, 1u8]);
    let state = escrow.state.extract();
    let new_state = asset_state::fire_do_auction_expiry_for_testing(state, escrow.core.borrow_mut(), boundary, &mut generator);
    escrow.state.fill(new_state);
}
