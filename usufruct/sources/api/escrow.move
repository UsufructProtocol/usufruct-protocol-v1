// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::escrow;

// === Imports ===

use std::string::{Self, String};
use std::type_name;
use sui::{
    clock::Clock,
    coin::Coin,
};
use usufruct::{
    policy_ensemble::{Self, PolicyEnsemble},
    curve_shape_policy::{Self as curve, CurveShapePolicy},
    tenures::{Self, Tenures},
    auction_window_policy,
    asset_state::{Self, EscrowCore, AssetState, AssetReceipt},
    handover_policy,
    rest_price_policy,
    tenure_extend_policy,
    math,
    tenure_duration_policy,
    monetary,
    owner_cap::{Self, OwnerCap},
    phases,
    price_escalation_policy::{Self, PriceEscalationPolicy},
    escrow_identity,
    protocol_fee_ref::{Self, ProtocolFeeRef},
    commitment_policy::{Self, CommitmentPolicy},
    refund_address::RefundAddress,
    tenant_cap::{Self, TenantCap},
};

// === Errors ===

const EAssetBorrowed: u64 = 20;

// === Constants ===

// === Structs ===

public struct Escrow<Asset: key + store, phantom CoinType> has key {
    id:    UID,
    core:  Option<EscrowCore<CoinType>>,
    state: Option<AssetState<Asset, CoinType>>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun integrate<Asset: key + store, CoinType>(
    asset:      Asset,
    ensemble:   PolicyEnsemble,
    commitment: CommitmentPolicy,
    fee_ref:    &ProtocolFeeRef,
    clock:      &Clock,
    ctx:        &mut TxContext,
): OwnerCap {
    let uid             = object::new(ctx);
    let (core, state, owner_cap) = asset_state::execute_integrate<Asset, CoinType>(
        asset, ensemble, commitment,
        protocol_fee_ref::proj_inbox_identity(fee_ref),
        escrow_identity::new(object::uid_to_inner(&uid)),
        phases::now(clock),
        ctx,
    );
    transfer::share_object(Escrow<Asset, CoinType> {
        id:    uid,
        core:  option::some(core),
        state: option::some(state),
    });
    owner_cap
}

public fun withdraw_earnings<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Coin<CoinType> {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (new_state, new_core, coin) = asset_state::execute_withdraw_earnings(state, core, owner_cap, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, new_state);
    coin
}

public fun claim_asset<Asset: key + store, CoinType>(
    escrow:    Escrow<Asset, CoinType>,
    owner_cap: OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    let Escrow { id, core, state } = escrow;
    let core_val          = core.destroy_some();
    let (asset, earnings) = asset_state::execute_claim(state.destroy_some(), core_val, &owner_cap, clock, ctx);
    owner_cap::burn(owner_cap, ctx.sender());
    id.delete();
    (asset, earnings)
}

public fun retire<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
) {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (new_state, new_core) = asset_state::execute_retire(state, core, owner_cap, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, new_state);
}

public fun extend_commitment<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    owner_cap:  &OwnerCap,
    new_policy: CommitmentPolicy,
    clock:      &Clock,
) {
    let core     = take_core(escrow);
    let new_core = asset_state::execute_extend_commitment(core, owner_cap, new_policy, clock);
    put_core(escrow, new_core);
}

public fun update_config<Asset: key + store, CoinType>(
    escrow:       &mut Escrow<Asset, CoinType>,
    owner_cap:    &OwnerCap,
    new_ensemble: PolicyEnsemble,
    clock:        &Clock,
    ctx:          &mut TxContext,
) {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (new_state, new_core) = asset_state::execute_update_config(state, core, owner_cap, new_ensemble, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, new_state);
}

public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut Escrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    tenures: Tenures,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (rs, new_core, cap) = asset_state::execute_rent(state, core, payment, tenures, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, asset_state::renting_into_state(rs));
    cap
}

public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt<Asset, CoinType>) {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (asset, receipt, new_core) = asset_state::execute_borrow(state, core, tenant_cap, clock, ctx);
    put_core(escrow, new_core);
    (asset, receipt)
}

public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt<Asset, CoinType>,
) {
    let core      = escrow.core.borrow();
    let rs = asset_state::execute_return(receipt_in, core, asset);
    put_state(escrow, asset_state::renting_into_state(rs));
}

public fun soft_burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (new_state, new_core) = asset_state::execute_soft_burn_tenant_cap(state, core, cap, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, new_state);
}

public fun update_tenant_refund_address<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    cap:         &TenantCap,
    new_address: RefundAddress,
    clock:       &Clock,
    ctx:         &mut TxContext,
) {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (new_state, new_core) = asset_state::execute_update_tenant_refund_address(state, core, cap, new_address, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, new_state);
}

public fun hard_burn_tenant_cap(cap: TenantCap, ctx: &mut TxContext) {
    tenant_cap::burn(cap, ctx)
}

public fun apply_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let state = take_state(escrow);
    let core  = take_core(escrow);
    let (new_state, new_core) = asset_state::execute_apply_pending_transition_states(state, core, clock, ctx);
    put_core(escrow, new_core);
    put_state(escrow, new_state);
}

// === View Functions ===

public fun is_idle<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_idle(read_state(escrow))
}

public fun is_in_descent<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_descent(read_state(escrow))
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
    auction_window_policy::proj_is_off(policy_ensemble::proj_auction_window(read_ensemble(escrow)))
}

public fun is_descent_window<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    auction_window_policy::proj_is_fixed(policy_ensemble::proj_auction_window(read_ensemble(escrow)))
}

public fun is_commitment_immediate<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    commitment_policy::proj_is_immediate(&asset_state::proj_commitment_policy(read_core(escrow)))
}

public fun is_commitment_deferred<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    commitment_policy::proj_is_deferred(&asset_state::proj_commitment_policy(read_core(escrow)))
}

public fun is_handover_off<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy::proj_is_off(policy_ensemble::proj_handover(read_ensemble(escrow)))
}

public fun is_handover_full_tenure<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy::proj_is_full_tenure(policy_ensemble::proj_handover(read_ensemble(escrow)))
}

public fun is_handover_fixed<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy::proj_is_fixed(policy_ensemble::proj_handover(read_ensemble(escrow)))
}

public fun is_retiring<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_state::proj_is_retiring(read_state(escrow))
}

public fun asset_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    asset_state::proj_asset_id(read_state(escrow))
}

public fun asset_type_name<Asset: key + store, CoinType>(
    _escrow: &Escrow<Asset, CoinType>,
): String {
    string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>()))
}

public fun coin_type_name<Asset: key + store, CoinType>(
    _escrow: &Escrow<Asset, CoinType>,
): String {
    string::from_ascii(type_name::with_defining_ids<CoinType>().into_string())
}

public fun owner_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    asset_state::proj_owner_cap_id(read_core(escrow))
}

public fun active_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    asset_state::proj_active_addr(read_state(escrow))
}

public fun active_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    asset_state::proj_active_cap_id(read_state(escrow))
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

public fun active_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_active_stake(read_state(escrow)).map!(|v| monetary::stake_mist(v))
}

public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_stake(read_state(escrow)).map!(|v| monetary::stake_mist(v))
}

public fun active_committed_tenures<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_active_committed_tenures(read_state(escrow)).map!(|v| tenures::tenures_count(v))
}

public fun pending_committed_tenures<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_committed_tenures(read_state(escrow)).map!(|v| tenures::tenures_count(v))
}

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
    option::some(phases::timestamp_ms(phases::compute_boundary_at(ps, ceiling)))
}

// Base cycle params resolved from the ACTIVE ensemble (never tenant-scaled).
public fun active_cycle_floor_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_active_cycle_params(read_state(escrow)).map!(|c| asset_state::cycle_params_floor_mist(&c))
}

public fun active_cycle_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_active_cycle_params(read_state(escrow)).map!(|c| asset_state::cycle_params_ceiling_ms(&c))
}

public fun active_cycle_handover_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_active_cycle_params(read_state(escrow)).map!(|c| asset_state::cycle_params_handover_ms(&c))
}

public fun active_cycle_descent_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_active_cycle_params(read_state(escrow)).map!(|c| asset_state::cycle_params_descent_ms(&c))
}

// Tenancy totals: base cycle ceiling/handover scaled by the active tenant's committed_tenures.
public fun active_tenure_ceiling_total_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_resolved_ceiling(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

public fun active_handover_total_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_resolved_handover(read_state(escrow)).map!(|v| phases::duration_ms(v))
}

// Base cycle params the PENDING (queued) ensemble would resolve to, computed on demand.
public fun pending_cycle_floor_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_cycle_params(read_core(escrow)).map!(|c| asset_state::cycle_params_floor_mist(&c))
}

public fun pending_cycle_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_cycle_params(read_core(escrow)).map!(|c| asset_state::cycle_params_ceiling_ms(&c))
}

public fun pending_cycle_handover_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_cycle_params(read_core(escrow)).map!(|c| asset_state::cycle_params_handover_ms(&c))
}

public fun pending_cycle_descent_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_pending_cycle_params(read_core(escrow)).map!(|c| asset_state::cycle_params_descent_ms(&c))
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

public fun active_tenant_time_remaining_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): Option<u64> {
    let s = read_state(escrow);
    if (asset_state::proj_is_occupied(s)) {
        let ps        = *asset_state::proj_phase_start(s).borrow();
        let ceiling   = *asset_state::proj_resolved_ceiling(s).borrow();
        let expiry_ms = phases::timestamp_ms(phases::compute_boundary_at(ps, ceiling));
        option::some(if (expiry_ms > now_ms) { expiry_ms - now_ms } else { 0 })
    } else if (asset_state::proj_is_demand(s)) {
        let expiry_ms = phases::timestamp_ms(*asset_state::proj_handover_expiry(s).borrow());
        option::some(if (expiry_ms > now_ms) { expiry_ms - now_ms } else { 0 })
    } else {
        option::none()
    }
}

public fun active_tenant_stake_remaining_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): Option<u64> {
    if (!asset_state::proj_is_rented(read_state(escrow))) return option::none();
    let (remaining, _, _) = compute_handover_settlement(escrow, now_ms);
    option::some(remaining)
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
    option::some(phases::timestamp_ms(handover_policy::compute_expiry_at(resolved_handover, resolved_ceiling, phases::timestamp(bid_time_ms), phase_start)))
}

public fun tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::duration_ms(tenure_duration_policy::proj_min_ceiling(policy_ensemble::proj_tenure_duration(read_ensemble(escrow))))
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
    let resolved = commitment_policy::compute_duration(&asset_state::proj_commitment_policy(c));
    phases::timestamp_ms(commitment_policy::compute_unlock_at(resolved, asset_state::proj_commitment_anchor(c)))
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

public fun owner_cap_is_valid<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): bool {
    asset_state::proj_owner_cap_id(read_core(escrow)) == cap_id
}

public fun tenant_cap_is_active<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): bool {
    asset_state::cap_is_active(read_state(escrow), tenant_cap::from_id(cap_id))
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


public fun has_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): bool {
    asset_state::compute_next_pending(read_state(escrow), phases::timestamp(now_ms)).is_some()
}

public fun next_transition_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): Option<u64> {
    asset_state::compute_next_pending(read_state(escrow), phases::timestamp(now_ms))
        .map!(|t| phases::timestamp_ms(t))
}

public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): u64 {
    monetary::stake_mist(asset_state::compute_used_credit_at(read_state(escrow), read_core(escrow), phases::timestamp(now_ms)))
}

public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    now_ms: u64,
): u64 {
    monetary::price_mist(asset_state::compute_floor_price_at(read_state(escrow), read_core(escrow), phases::timestamp(now_ms)))
}

public fun compute_next_ascending_floor<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    bid_amount: u64,
): u64 {
    monetary::price_mist(price_escalation_policy::compute_next_price(policy_ensemble::proj_price_escalation(read_ensemble(escrow)), monetary::price(bid_amount)))
}

public fun last_acq_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_state::proj_last_acq_price(read_state(escrow)).map!(|v| monetary::price_mist(v))
}

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

public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::stake_mist(asset_state::proj_owner_balance(read_core(escrow)))
}

public fun active_ensemble<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): PolicyEnsemble {
    *read_ensemble(escrow)
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

public fun pending_ensemble<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<PolicyEnsemble> {
    asset_state::proj_pending_config(read_core(escrow))
}

public fun protocol_fee_bps(): u64 { asset_state::protocol_fee_bps() }
public fun bps_denominator():  u64 { asset_state::bps_denominator() }

public fun min_rent_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::price_mist(rest_price_policy::compute_floor_price(policy_ensemble::proj_rest_price(read_ensemble(escrow))))
}

public fun descent_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    auction_window_policy::proj_fixed_ceiling(policy_ensemble::proj_auction_window(read_ensemble(escrow))).map!(|v| phases::duration_ms(v))
}

public fun handover_countdown_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    handover_policy::proj_fixed_floor_ms(policy_ensemble::proj_handover(read_ensemble(escrow))).map!(|v| phases::duration_ms(v))
}

public fun commitment_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    commitment_policy::proj_floor_ms(&asset_state::proj_commitment_policy(read_core(escrow))).map!(|v| phases::duration_ms(v))
}

public fun credit_shape<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShapePolicy {
    *policy_ensemble::proj_credit_shape(read_ensemble(escrow))
}

public fun auction_shape<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShapePolicy {
    *policy_ensemble::proj_auction_shape(read_ensemble(escrow))
}

public fun ascending_price_function_state<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): PriceEscalationPolicy {
    *policy_ensemble::proj_price_escalation(read_ensemble(escrow))
}

public fun tenure_ceiling_is_fixed<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    tenure_duration_policy::proj_is_fixed(policy_ensemble::proj_tenure_duration(read_ensemble(escrow)))
}

public fun tenure_ceiling_fixed_ms<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): u64 {
    phases::duration_ms(tenure_duration_policy::proj_fixed_ceiling(policy_ensemble::proj_tenure_duration(read_ensemble(escrow))).destroy_some())
}

public fun min_rent_price_fixed_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): u64 {
    monetary::price_mist(rest_price_policy::proj_fixed_price(policy_ensemble::proj_rest_price(read_ensemble(escrow))).destroy_some())
}

public fun credit_shape_is_linear<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_linear(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_is_smoothstep<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_smoothstep(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_is_logistic<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_logistic(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_is_power_law<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_power_law(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_is_exponential<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_exponential(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_power_law_alpha_num<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_num(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_power_law_alpha_den<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_den(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_exponential_alpha_abs<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_exponential_alpha_abs(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun credit_shape_exponential_alpha_neg<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<bool> {
    curve::proj_exponential_alpha_neg(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}

public fun auction_shape_is_linear<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_linear(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_is_smoothstep<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_smoothstep(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_is_logistic<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_logistic(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_is_power_law<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_power_law(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_is_exponential<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    curve::proj_is_exponential(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_power_law_alpha_num<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_num(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_power_law_alpha_den<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_power_law_alpha_den(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_exponential_alpha_abs<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u8> {
    curve::proj_exponential_alpha_abs(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun auction_shape_exponential_alpha_neg<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<bool> {
    curve::proj_exponential_alpha_neg(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}

public fun price_fn_is_fixed_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    price_escalation_policy::proj_is_fixed_delta(policy_ensemble::proj_price_escalation(read_ensemble(escrow)))
}

public fun price_fn_is_compound_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    price_escalation_policy::proj_is_compound_delta(policy_ensemble::proj_price_escalation(read_ensemble(escrow)))
}

public fun price_fn_fixed_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_escalation_policy::proj_fixed_delta(policy_ensemble::proj_price_escalation(read_ensemble(escrow))).map!(|v| monetary::price_mist(v))
}

public fun price_fn_compound_delta_bps<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_escalation_policy::proj_compound_delta_bps(policy_ensemble::proj_price_escalation(read_ensemble(escrow))).map!(|v| math::bps_value(v))
}

public fun price_fn_compound_delta_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_escalation_policy::proj_compound_delta_delta(policy_ensemble::proj_price_escalation(read_ensemble(escrow))).map!(|v| monetary::price_mist(v))
}

public fun rest_price_policy_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    rest_price_policy::proj_rest_price_policy(policy_ensemble::proj_rest_price(read_ensemble(escrow)))
}
public fun tenure_duration_policy_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    tenure_duration_policy::proj_tenure_duration_policy(policy_ensemble::proj_tenure_duration(read_ensemble(escrow)))
}
public fun tenure_extend_policy_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    tenure_extend_policy::proj_tenure_extend_policy(policy_ensemble::proj_tenure_extend(read_ensemble(escrow)))
}
public fun handover_policy_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    handover_policy::proj_handover_policy(policy_ensemble::proj_handover(read_ensemble(escrow)))
}
public fun auction_window_policy_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    auction_window_policy::proj_auction_window_policy(policy_ensemble::proj_auction_window(read_ensemble(escrow)))
}
public fun credit_shape_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    curve::proj_curve_shape_policy(policy_ensemble::proj_credit_shape(read_ensemble(escrow)))
}
public fun auction_shape_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    curve::proj_curve_shape_policy(policy_ensemble::proj_auction_shape(read_ensemble(escrow)))
}
public fun price_fn_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    price_escalation_policy::proj_price_escalation_policy(policy_ensemble::proj_price_escalation(read_ensemble(escrow)))
}
public fun price_fn_delta_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): u64 {
    price_escalation_policy::proj_price_escalation_delta_mist(policy_ensemble::proj_price_escalation(read_ensemble(escrow)))
}
public fun commitment_policy_kind<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): String {
    commitment_policy::proj_commitment_policy(&asset_state::proj_commitment_policy(read_core(escrow)))
}

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

fun take_state<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    assert!(escrow.state.is_some(), EAssetBorrowed);
    escrow.state.extract()
}

fun put_state<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    new_state: AssetState<Asset, CoinType>,
) {
    escrow.state.fill(new_state)
}

fun read_state<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &AssetState<Asset, CoinType> {
    assert!(escrow.state.is_some(), EAssetBorrowed);
    escrow.state.borrow()
}

fun take_core<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
): EscrowCore<CoinType> {
    escrow.core.extract()
}

fun put_core<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    new_core: EscrowCore<CoinType>,
) {
    escrow.core.fill(new_core)
}

fun read_core<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &EscrowCore<CoinType> {
    escrow.core.borrow()
}

fun read_ensemble<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &PolicyEnsemble {
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
    tenant:         usufruct::tenant_seat::TenantSeat<CoinType>,
    phase_start_ms: u64,
) {
    let state = take_state(escrow);
    let new_state = asset_state::drive_to_rented_for_testing(
        state, escrow.core.borrow(), tenant, phases::timestamp(phase_start_ms),
    );
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut Escrow<Asset, CoinType>,
    tenant:                    usufruct::tenant_seat::TenantSeat<CoinType>,
    handover_countdown_expiry: u64,
) {
    let state = take_state(escrow);
    let new_state = asset_state::drive_to_demand_for_testing(
        state, tenant, phases::timestamp(handover_countdown_expiry),
    );
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun drive_to_descent_for_testing<Asset: key + store, CoinType>(
    escrow:             &mut Escrow<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
) {
    let state = take_state(escrow);
    let new_state = asset_state::drive_to_descent_for_testing(
        state, escrow.core.borrow(), owner_amount, fee_amount, last_acq_price, phases::timestamp(new_phase_start_ms),
    );
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let state = take_state(escrow);
    let new_state = asset_state::drive_to_retired_for_testing(state);
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let state = take_state(escrow);
    let new_state = asset_state::drive_to_retiring_flag_for_testing(state);
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let state = take_state(escrow);
    let new_state = asset_state::fire_do_handover_for_testing(state, escrow.core.borrow_mut(), boundary, ctx);
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let state = take_state(escrow);
    let new_state = asset_state::fire_do_tenure_expiry_for_testing(state, escrow.core.borrow_mut(), boundary, ctx);
    put_state(escrow, new_state);
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
) {
    let state = take_state(escrow);
    let new_state = asset_state::fire_do_auction_expiry_for_testing(state, escrow.core.borrow_mut(), boundary);
    put_state(escrow, new_state);
}

