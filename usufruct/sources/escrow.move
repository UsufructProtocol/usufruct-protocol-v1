// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::escrow;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
    random::Random,
};
use usufruct::{
    asset::AssetReceipt,
    config::{Self, IntegrationConfig},
    curve_shape_state::{Self as curve, CurveShapeState},
    cycles::Cycles,
    descent_policy_state,
    asset_context_state::{Self, AssetContext, CapAuthorizationState},
    handover_policy_state,
    floor_price_policy_state,
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
/// Context (config, fee_inbox_id, integrated_at_ms, escrow_id) now lives
/// inside Engine — Escrow holds only identity (UID) and the engine slot.
public struct Escrow<Asset: key + store, phantom CoinType> has key {
    id:     UID,
    asset_context: Option<AssetContext<Asset, CoinType>>,
}

// === Events ===

public struct AssetIntegrated<phantom Asset, phantom CoinType> has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    owner:            address,
    asset_id:         ID,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
}

public struct AssetClaimed has copy, drop {
    escrow_id:      ID,
    owner_cap_id:   ID,
    owner:          address,
    swept_earnings: u64,
    timestamp_ms:   u64,
}

// === Public Functions ===

/// Create and share an `Escrow`. Mints the `OwnerCap` and
/// returns it to the caller.
public fun integrate<Asset: key + store, CoinType>(
    asset:      Asset,
    cfg:        IntegrationConfig,
    commitment: CommitmentPolicyState,
    fee_ref:    &ProtocolFeeRef,
    random:     &Random,
    clock:      &Clock,
    ctx:        &mut TxContext,
): OwnerCap {
    let uid              = object::new(ctx);
    let raw_escrow_id    = object::uid_to_inner(&uid);
    let escrow_identity  = escrow_identity::new(raw_escrow_id);
    let asset_id         = object::id(&asset);
    let owner_addr       = ctx.sender();
    let owner_cap          = owner_cap::new(escrow_identity, owner_addr, ctx);
    let owner_cap_identity = owner_cap::identity(&owner_cap);
    let fee_inbox_id       = protocol_fee_ref::proj_inbox_id(fee_ref);
    let inbox_identity     = protocol_fee_ref::proj_inbox_identity(fee_ref);
    let integrated_at_ms   = clock::timestamp_ms(clock);

    config::emit_registration(&cfg, raw_escrow_id);
    let mut generator = sui::random::new_generator(random, ctx);
    let context = asset_context_state::new<Asset, CoinType>(
        asset, owner_cap_identity, cfg, commitment, inbox_identity, integrated_at_ms, escrow_identity, &mut generator,
    );
    transfer::share_object(Escrow<Asset, CoinType> {
        id:     uid,
        asset_context: option::some(context),
    });
    event::emit(AssetIntegrated<Asset, CoinType> {
        escrow_id: raw_escrow_id, owner_cap_id: owner_cap::cap_id(owner_cap_identity), owner: owner_addr, asset_id, fee_inbox_id, integrated_at_ms,
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
    let context = take_context(escrow);
    let (new_context, coin) = asset_context_state::execute_withdraw_earnings(context, owner_cap, random, clock, ctx);
    put_context(escrow, new_context);
    coin
}

/// Owner-gated terminal claim. Consumes the escrow by value.
public fun claim_asset<Asset: key + store, CoinType>(
    escrow:    Escrow<Asset, CoinType>,
    owner_cap: OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    let escrow_id    = object::id(&escrow);
    let owner_cap_id = object::id(&owner_cap);
    let owner_addr   = ctx.sender();

    let Escrow { id, asset_context } = escrow;
    let context = option::destroy_some(asset_context);
    let (asset, earnings) = asset_context_state::execute_claim(context, &owner_cap, random, clock, ctx);
    let swept_earnings    = coin::value(&earnings);
    owner_cap::burn(owner_cap, owner_addr);
    object::delete(id);

    event::emit(AssetClaimed {
        escrow_id, owner_cap_id, owner: owner_addr, swept_earnings,
        timestamp_ms: clock::timestamp_ms(clock),
    });
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
    let context = take_context(escrow);
    let new_context = asset_context_state::execute_retire(context, owner_cap, random, clock, ctx);
    put_context(escrow, new_context);
}

/// Owner-gated commitment extension. New expiry must be ≥ current expiry.
public fun extend_commitment<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    owner_cap:  &OwnerCap,
    new_policy: CommitmentPolicyState,
    clock:      &Clock,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::execute_extend_commitment(context, owner_cap, new_policy, clock);
    escrow.asset_context.fill(context);
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
    let context = take_context(escrow);
    let new_context = asset_context_state::execute_update_config(context, owner_cap, new_cfg, random, clock, ctx);
    put_context(escrow, new_context);
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
    let context = take_context(escrow);
    let (new_context, cap) = asset_context_state::execute_rent(context, payment, cycles, random, clock, ctx);
    put_context(escrow, new_context);
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
    let context = take_context(escrow);
    let (new_context, asset, receipt) = asset_context_state::execute_borrow(context, tenant_cap, random, clock, ctx);
    put_context(escrow, new_context);
    (asset, receipt)
}

/// Tenant-side asset return.
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::execute_return(context, asset, receipt_in);
    put_context(escrow, new_context);
}

/// Burn a stale `TenantCap` for gas recovery.
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    cap:    TenantCap,
    random: &Random,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::execute_burn_tenant_cap(context, cap, random, clock, ctx);
    put_context(escrow, new_context);
}

/// Permissionless settler.
public fun apply_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    random: &Random,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::apply_pending_transition_states(context, random, clock, ctx);
    put_context(escrow, new_context);
}

/// Detect the single transition that is due at `now`, if any.
public fun next_pending<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): Option<PendingTransitionState> {
    asset_context_state::next_pending(read_context(escrow), clock)
}

// === View Functions ===

// ─── State predicates ────────────────────────────────────────────────────────

public fun is_idle<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_idle(read_context(escrow))
}

public fun is_at_dutch_auction<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_at_dutch(read_context(escrow))
}

public fun is_handover_open<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_handover_open(read_context(escrow))
}

public fun is_handover_confirmed<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_handover_confirmed(read_context(escrow))
}

public fun is_active<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_active(read_context(escrow))
}

public fun is_retired<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_inactive(read_context(escrow))
}

public fun is_rented<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_is_rented(read_context(escrow))
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
    commitment_policy_state::proj_is_immediate(&asset_context_state::proj_commitment_policy(read_context(escrow)))
}

public fun is_commitment_deferred<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    commitment_policy_state::proj_is_deferred(&asset_context_state::proj_commitment_policy(read_context(escrow)))
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
    asset_context_state::proj_is_retiring(read_context(escrow))
}

// ─── Identity views ──────────────────────────────────────────────────────────

public fun asset_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    asset_context_state::proj_asset_id(read_context(escrow))
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
    asset_context_state::proj_owner_cap_id(read_context(escrow))
}

public fun current_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    asset_context_state::proj_current_addr(read_context(escrow))
}

public fun current_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    asset_context_state::proj_current_cap_id(read_context(escrow))
}

public fun pending_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    asset_context_state::proj_pending_addr(read_context(escrow))
}

public fun pending_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    asset_context_state::proj_pending_cap_id(read_context(escrow))
}

// ─── Stake views ─────────────────────────────────────────────────────────────

public fun current_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_current_stake(read_context(escrow));
    if (option::is_some(&opt)) option::some(monetary::stake_mist(option::destroy_some(opt)))
    else option::none()
}

public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_pending_stake(read_context(escrow));
    if (option::is_some(&opt)) option::some(monetary::stake_mist(option::destroy_some(opt)))
    else option::none()
}

// ─── Temporal views ───────────────────────────────────────────────────────────

public fun phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_phase_start(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::timestamp_ms(option::destroy_some(opt)))
    else option::none()
}

public fun tenure_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let e = read_context(escrow);
    if (!asset_context_state::proj_is_rented(e)) return option::none();
    let ps      = *option::borrow(&asset_context_state::proj_phase_start(e));
    let ceiling = *option::borrow(&asset_context_state::proj_resolved_ceiling(e));
    option::some(phases::timestamp_ms(phases::boundary_at(ps, ceiling)))
}

public fun active_tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_resolved_ceiling(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun active_handover_duration_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_resolved_handover(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun active_floor_price_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_resolved_floor(read_context(escrow));
    if (option::is_some(&opt)) option::some(monetary::price_mist(option::destroy_some(opt)))
    else option::none()
}

public fun next_floor_price_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_waiting_resolved_floor(read_context(escrow));
    if (option::is_some(&opt)) option::some(monetary::price_mist(option::destroy_some(opt)))
    else option::none()
}

public fun next_tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_waiting_resolved_ceiling(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun next_handover_duration_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_waiting_resolved_handover(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun auction_descent_duration_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_waiting_resolved_descent(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_handover_expiry(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::timestamp_ms(option::destroy_some(opt)))
    else option::none()
}

public fun compute_handover_expiry_at<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    bid_time_ms: u64,
): Option<u64> {
    let e = read_context(escrow);
    if (!asset_context_state::proj_is_handover_open(e)) return option::none();
    let phase_start       = *option::borrow(&asset_context_state::proj_phase_start(e));
    let resolved_ceiling  = *option::borrow(&asset_context_state::proj_resolved_ceiling(e));
    let resolved_handover = *option::borrow(&asset_context_state::proj_resolved_handover(e));
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
    phases::timestamp_ms(asset_context_state::proj_integrated_at(read_context(escrow)))
}

public fun commitment_unlocks_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    let e        = read_context(escrow);
    let resolved = commitment_policy_state::resolve(&asset_context_state::proj_commitment_policy(e));
    phases::timestamp_ms(commitment_policy_state::unlock_at(resolved, asset_context_state::proj_commitment_anchor(e)))
}

public fun commitment_anchor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    phases::timestamp_ms(asset_context_state::proj_commitment_anchor(read_context(escrow)))
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
    asset_context_state::proj_owner_cap_id(read_context(escrow)) == object::id(owner_cap)
}

public fun tenant_cap_status<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    asset_context_state::cap_authorization_state(read_context(escrow), tenant_cap::from_id(cap_id))
}

public fun tenant_cap_is_current<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
): bool {
    asset_context_state::proj_is_current(&asset_context_state::cap_authorization_state(read_context(escrow), tenant_cap::from_id(object::id(tenant_cap))))
}

public fun tenant_cap_is_pending<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
): bool {
    asset_context_state::proj_is_pending(&asset_context_state::cap_authorization_state(read_context(escrow), tenant_cap::from_id(object::id(tenant_cap))))
}

public fun tenant_cap_is_stale<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
): bool {
    asset_context_state::proj_is_stale(&asset_context_state::cap_authorization_state(read_context(escrow), tenant_cap::from_id(object::id(tenant_cap))))
}

// ─── Timing views ────────────────────────────────────────────────────────────

public fun has_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): bool {
    option::is_some(&next_pending(escrow, clock))
}

public fun next_transition_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): Option<u64> {
    let pending = next_pending(escrow, clock);
    if (option::is_some(&pending)) {
        option::some(pending_transition_state::boundary_ms(option::borrow(&pending)))
    } else {
        option::none()
    }
}

// ─── Pricing views ───────────────────────────────────────────────────────────

public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    monetary::stake_mist(asset_context_state::used_credit_at(read_context(escrow), phases::now(clock)))
}

public fun compute_used_credit_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    monetary::stake_mist(asset_context_state::used_credit_at(read_context(escrow), phases::timestamp(timestamp_ms)))
}

public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    monetary::price_mist(asset_context_state::floor_price_at(read_context(escrow), phases::now(clock)))
}

public fun compute_floor_price_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    monetary::price_mist(asset_context_state::floor_price_at(read_context(escrow), phases::timestamp(timestamp_ms)))
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
    let opt = asset_context_state::proj_last_acq_price(read_context(escrow));
    if (option::is_some(&opt)) option::some(monetary::price_mist(option::destroy_some(opt)))
    else option::none()
}

// ─── Credit context views ─────────────────────────────────────────────────────

public fun credit_is_accruing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_credit_is_accruing(read_context(escrow))
}

public fun credit_is_capped<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    asset_context_state::proj_credit_is_capped(read_context(escrow))
}

public fun credit_stake_mist<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_credit_stake(read_context(escrow));
    if (option::is_some(&opt)) option::some(monetary::stake_mist(option::destroy_some(opt)))
    else option::none()
}

public fun credit_phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_credit_phase_start(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::timestamp_ms(option::destroy_some(opt)))
    else option::none()
}

public fun credit_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = asset_context_state::proj_credit_expiry(read_context(escrow));
    if (option::is_some(&opt)) option::some(phases::timestamp_ms(option::destroy_some(opt)))
    else option::none()
}

// ─── Settlement views ────────────────────────────────────────────────────────

public fun compute_handover_settlement<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    boundary_ms: u64,
): (u64, u64, u64) {
    let (remaining, owner, fee) = asset_context_state::proj_handover_settlement(
        read_context(escrow), phases::timestamp(boundary_ms),
    );
    (monetary::stake_mist(remaining), monetary::stake_mist(owner), monetary::stake_mist(fee))
}

public fun compute_tenure_settlement<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): (u64, u64) {
    let (owner, fee) = asset_context_state::proj_tenure_settlement(read_context(escrow));
    (monetary::stake_mist(owner), monetary::stake_mist(fee))
}

// ─── Earnings views ──────────────────────────────────────────────────────────

public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::stake_mist(asset_context_state::proj_owner_balance(read_context(escrow)))
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
    asset_context_state::proj_fee_inbox_id(read_context(escrow))
}

public fun has_pending_config_update<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    option::is_some(&asset_context_state::proj_pending_config(read_context(escrow)))
}

public fun protocol_fee_bps(): u64 { asset_context_state::protocol_fee_bps() }
public fun bps_denominator():  u64 { asset_context_state::bps_denominator() }

public fun min_rent_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::price_mist(floor_price_policy_state::floor_for_view(config::proj_min_rent_price(cfg(escrow))))
}

public fun dutch_auction_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = descent_policy_state::proj_window_ceiling(config::proj_descent(cfg(escrow)));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun handover_countdown_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = handover_policy_state::proj_countdown_floor_ms(config::proj_handover(cfg(escrow)));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun commitment_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let opt = commitment_policy_state::proj_floor_ms(&asset_context_state::proj_commitment_policy(read_context(escrow)));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
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
    let opt = tenure_policy_state::proj_fixed_ceiling(config::proj_tenure_ceiling(cfg(escrow)));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun tenure_ceiling_range_min_ms<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    let opt = tenure_policy_state::proj_range_min(config::proj_tenure_ceiling(cfg(escrow)));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

public fun tenure_ceiling_range_max_ms<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    let opt = tenure_policy_state::proj_range_max(config::proj_tenure_ceiling(cfg(escrow)));
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

// ─── Floor price policy views ─────────────────────────────────────────────────

public fun min_rent_price_is_fixed<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    floor_price_policy_state::proj_is_fixed(config::proj_min_rent_price(cfg(escrow)))
}

public fun min_rent_price_is_random_in_range<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): bool {
    floor_price_policy_state::proj_is_random_in_range(config::proj_min_rent_price(cfg(escrow)))
}

public fun min_rent_price_fixed_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    let opt = floor_price_policy_state::proj_fixed_price(config::proj_min_rent_price(cfg(escrow)));
    if (option::is_some(&opt)) option::some(monetary::price_mist(option::destroy_some(opt)))
    else option::none()
}

public fun min_rent_price_range_min_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    let opt = floor_price_policy_state::proj_range_min(config::proj_min_rent_price(cfg(escrow)));
    if (option::is_some(&opt)) option::some(monetary::price_mist(option::destroy_some(opt)))
    else option::none()
}

public fun min_rent_price_range_max_mist<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    let opt = floor_price_policy_state::proj_range_max(config::proj_min_rent_price(cfg(escrow)));
    if (option::is_some(&opt)) option::some(monetary::price_mist(option::destroy_some(opt)))
    else option::none()
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
    price_function_state::proj_fixed_delta(config::proj_price_function_state(cfg(escrow)))
}

public fun price_fn_compound_delta_bps<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_function_state::proj_compound_delta_bps(config::proj_price_function_state(cfg(escrow)))
}

public fun price_fn_compound_delta_delta<Asset: key + store, CoinType>(escrow: &Escrow<Asset, CoinType>): Option<u64> {
    price_function_state::proj_compound_delta_delta(config::proj_price_function_state(cfg(escrow)))
}

// === Private Functions ===

fun read_context<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &AssetContext<Asset, CoinType> {
    option::borrow(&escrow.asset_context)
}

fun take_context<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    escrow.asset_context.extract()
}

fun put_context<Asset: key + store, CoinType>(
    escrow:  &mut Escrow<Asset, CoinType>,
    context: AssetContext<Asset, CoinType>,
) {
    escrow.asset_context.fill(context)
}

fun cfg<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &IntegrationConfig {
    asset_context_state::proj_config(read_context(escrow))
}

// === Test Functions ===

#[test_only]
public(package) fun owner_value_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    monetary::stake_mist(asset_context_state::proj_owner_balance(read_context(escrow)))
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    asset_context_state::split_fee_for_testing(amount)
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    escrow:         &mut Escrow<Asset, CoinType>,
    tenant:         usufruct::tenant::Tenant<CoinType>,
    phase_start_ms: u64,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::drive_to_rented_for_testing(
        context, tenant, phases::timestamp(phase_start_ms),
    );
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut Escrow<Asset, CoinType>,
    tenant:                    usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::drive_to_demand_for_testing(
        context, tenant, phases::timestamp(handover_countdown_expiry),
    );
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    escrow:             &mut Escrow<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::drive_to_at_dutch_for_testing(
        context, owner_amount, fee_amount, last_acq_price, phases::timestamp(new_phase_start_ms),
    );
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::drive_to_retired_for_testing(context);
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::drive_to_retiring_flag_for_testing(context);
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::fire_do_handover_for_testing(context, boundary, ctx);
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let context = take_context(escrow);
    let new_context = asset_context_state::fire_do_tenure_expiry_for_testing(context, boundary, ctx);
    put_context(escrow, new_context);
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
) {
    let mut generator = sui::random::new_generator_from_seed_for_testing(vector[0u8, 1u8]);
    let context = take_context(escrow);
    let new_context = asset_context_state::fire_do_auction_expiry_for_testing(context, boundary, &mut generator);
    put_context(escrow, new_context);
}

// ─── Event field accessors (test-only) ───────────────────────────────────────


#[test_only]
public(package) fun asset_claimed_swept_earnings(e: &AssetClaimed): u64 { e.swept_earnings }
