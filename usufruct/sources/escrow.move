// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::escrow;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::AssetReceipt,
    cap_authorization_state::CapAuthorizationState,
    config::{Self, IntegrationConfig},
    curve_shape_state::CurveShapeState,
    descent_policy_state,
    asset_context_state::{Self, AssetContext},
    handover_policy_state,
    owner_cap::{Self, OwnerCap},
    pending_transition_state::{Self, PendingTransitionState},
    phases,
    price_function_state::{Self, PriceFunctionState},
    protocol_fee_ref::{Self, ProtocolFeeRef},
    retire_policy_state,
    tenant_cap::TenantCap,
};

// === Errors ===

const ENotRented:           u64 = 0;
const ENotRetired:          u64 = 6;
const EWrongEscrowOwnerCap: u64 = 11;

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
    asset:   Asset,
    cfg:     IntegrationConfig,
    fee_ref: &ProtocolFeeRef,
    clock:   &Clock,
    ctx:     &mut TxContext,
): OwnerCap {
    let uid              = object::new(ctx);
    let escrow_id        = object::uid_to_inner(&uid);
    let asset_id         = object::id(&asset);
    let owner_addr       = ctx.sender();
    let owner_cap        = owner_cap::new(escrow_id, owner_addr, ctx);
    let owner_cap_id     = object::id(&owner_cap);
    let fee_inbox_id     = protocol_fee_ref::inbox_id(fee_ref);
    let integrated_at_ms = clock::timestamp_ms(clock);

    config::emit_registration(&cfg, escrow_id);
    let context = asset_context_state::new<Asset, CoinType>(
        asset, owner_cap_id, cfg, fee_inbox_id, integrated_at_ms, escrow_id,
    );
    transfer::share_object(Escrow<Asset, CoinType> {
        id:     uid,
        asset_context: option::some(context),
    });
    event::emit(AssetIntegrated<Asset, CoinType> {
        escrow_id, owner_cap_id, owner: owner_addr, asset_id, fee_inbox_id, integrated_at_ms,
    });
    owner_cap
}

/// Owner-gated earnings withdrawal.
public fun withdraw_earnings<Asset: key + store, CoinType>(
    escrow:    &mut Escrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Coin<CoinType> {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    let context = escrow.asset_context.extract();
    let (context, coin) = asset_context_state::execute_withdraw_earnings(context, owner_cap, clock, ctx);
    escrow.asset_context.fill(context);
    coin
}

/// Owner-gated terminal claim. Consumes the escrow by value.
public fun claim_asset<Asset: key + store, CoinType>(
    escrow:    Escrow<Asset, CoinType>,
    owner_cap: OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    assert!(owner_cap::escrow_id(&owner_cap) == object::id(&escrow), EWrongEscrowOwnerCap);
    let escrow_id    = object::id(&escrow);
    let owner_cap_id = object::id(&owner_cap);
    let owner_addr   = ctx.sender();

    let Escrow { id, asset_context } = escrow;
    let context = option::destroy_some(asset_context);
    let context = asset_context_state::apply_pending_transition_states(context, clock, ctx);
    assert!(asset_context_state::proj_is_inactive(&context), ENotRetired);

    let (asset, earnings) = asset_context_state::unwrap_for_claim(context, &owner_cap, ctx);
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
    clock:     &Clock,
    ctx:       &mut TxContext,
) {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    let context = escrow.asset_context.extract();
    let context = asset_context_state::execute_retire(context, clock, ctx);
    escrow.asset_context.fill(context);
}

/// Single entry point to become tenant or place a bid.
public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut Escrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    let context = escrow.asset_context.extract();
    let (context, cap) = asset_context_state::execute_rent(context, payment, clock, ctx);
    escrow.asset_context.fill(context);
    cap
}

/// Tenant-side asset borrow.
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt) {
    let context = escrow.asset_context.extract();
    let (context, asset, receipt) = asset_context_state::execute_borrow(context, tenant_cap, clock, ctx);
    escrow.asset_context.fill(context);
    (asset, receipt)
}

/// Tenant-side asset return.
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::execute_return(context, asset, receipt_in);
    escrow.asset_context.fill(context);
}

/// Burn a stale `TenantCap` for gas recovery.
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::execute_burn_tenant_cap(context, cap, clock, ctx);
    escrow.asset_context.fill(context);
}

/// Permissionless settler.
public fun apply_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::apply_pending_transition_states(context, clock, ctx);
    escrow.asset_context.fill(context);
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

public fun is_retire_immediate<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    retire_policy_state::proj_is_immediate(config::proj_retire(cfg(escrow)))
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
    asset_context_state::proj_current_stake(read_context(escrow))
}

public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_context_state::proj_pending_stake(read_context(escrow))
}

// ─── Temporal views ───────────────────────────────────────────────────────────

public fun phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_context_state::proj_phase_start_ms(read_context(escrow))
}

public fun tenure_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let e = read_context(escrow);
    if (!asset_context_state::proj_is_rented(e)) return option::none();
    let ps = *option::borrow(&asset_context_state::proj_phase_start_ms(e));
    option::some(phases::timestamp_ms(phases::boundary_at(phases::timestamp(ps), phases::duration(config::proj_tenure_ceiling(asset_context_state::proj_config(e))))))
}

public fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_context_state::proj_handover_expiry(read_context(escrow))
}

public fun compute_handover_expiry_at<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    bid_time_ms: u64,
): Option<u64> {
    let e = read_context(escrow);
    if (!asset_context_state::proj_is_handover_open(e)) return option::none();
    let phase_start = *option::borrow(&asset_context_state::proj_phase_start_ms(e));
    let c           = asset_context_state::proj_config(e);
    let tenure      = phases::duration(config::proj_tenure_ceiling(c));
    option::some(phases::timestamp_ms(handover_policy_state::expiry_at(config::proj_handover(c), phases::timestamp(bid_time_ms), phases::timestamp(phase_start), tenure)))
}

public fun tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    config::proj_tenure_ceiling(cfg(escrow))
}

public fun integrated_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    asset_context_state::proj_integrated_at_ms(read_context(escrow))
}

public fun retire_unlocks_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    let e = read_context(escrow);
    phases::timestamp_ms(retire_policy_state::unlock_at(config::proj_retire(asset_context_state::proj_config(e)), phases::timestamp(asset_context_state::proj_integrated_at_ms(e))))
}

// ─── Cap views ───────────────────────────────────────────────────────────────

public fun tenant_cap_status<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    asset_context_state::cap_authorization_state(read_context(escrow), cap_id)
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
    asset_context_state::used_credit_at(read_context(escrow), phases::now(clock))
}

public fun compute_used_credit_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    asset_context_state::used_credit_at(read_context(escrow), phases::timestamp(timestamp_ms))
}

public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    asset_context_state::floor_price_at(read_context(escrow), phases::now(clock))
}

public fun compute_floor_price_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    asset_context_state::floor_price_at(read_context(escrow), phases::timestamp(timestamp_ms))
}

public fun compute_next_ascending_floor<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    bid_amount: u64,
): u64 {
    price_function_state::evaluate_price_fn(config::proj_price_function_state(cfg(escrow)), bid_amount)
}

public fun last_acq_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    asset_context_state::proj_last_acq_price(read_context(escrow))
}

// ─── Settlement views ────────────────────────────────────────────────────────

public fun compute_handover_settlement<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    boundary_ms: u64,
): (u64, u64, u64) {
    let e     = read_context(escrow);
    let stake = asset_context_state::proj_current_stake_value(e);
    let used  = asset_context_state::used_credit_at(e, phases::timestamp(boundary_ms));
    let (owner_share, protocol_fee) = asset_context_state::split_fee(used);
    (stake - used, owner_share, protocol_fee)
}

public fun compute_tenure_settlement<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): (u64, u64) {
    let e = read_context(escrow);
    assert!(asset_context_state::proj_is_rented(e), ENotRented);
    asset_context_state::split_fee(asset_context_state::proj_current_stake_value(e))
}

// ─── Earnings views ──────────────────────────────────────────────────────────

public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    asset_context_state::proj_owner_balance(read_context(escrow))
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

public fun protocol_fee_bps(): u64 { asset_context_state::protocol_fee_bps() }
public fun bps_denominator():  u64 { asset_context_state::bps_denominator() }

public fun min_rent_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    config::proj_min_rent_price(cfg(escrow))
}

public fun dutch_auction_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    descent_policy_state::proj_window_ceiling(config::proj_descent(cfg(escrow)))
}

public fun handover_countdown_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    handover_policy_state::proj_countdown_floor_ms(config::proj_handover(cfg(escrow)))
}

public fun retire_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    retire_policy_state::proj_floor_ms(config::proj_retire(cfg(escrow)))
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

// === Private Functions ===

fun read_context<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &AssetContext<Asset, CoinType> {
    option::borrow(&escrow.asset_context)
}

fun cfg<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &IntegrationConfig {
    asset_context_state::proj_config(read_context(escrow))
}

// === Test Functions ===

#[test_only]
public(package) fun read_engine_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &asset_context_state::AssetContext<Asset, CoinType> {
    read_context(escrow)
}

#[test_only]
public(package) fun owner_value_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    asset_context_state::proj_owner_balance(read_context(escrow))
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
    let context = escrow.asset_context.extract();
    let context = asset_context_state::drive_to_rented_for_testing(context, tenant, phase_start_ms);
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut Escrow<Asset, CoinType>,
    tenant:                    usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::drive_to_demand_for_testing(context, tenant, handover_countdown_expiry);
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    escrow:             &mut Escrow<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::drive_to_at_dutch_for_testing(
        context, owner_amount, fee_amount, last_acq_price, new_phase_start_ms,
    );
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::drive_to_retired_for_testing(context);
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::drive_to_retiring_flag_for_testing(context);
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::fire_do_handover_for_testing(context, boundary, ctx);
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
    ctx:      &mut TxContext,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::fire_do_tenure_expiry_for_testing(context, boundary, ctx);
    escrow.asset_context.fill(context);
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:   &mut Escrow<Asset, CoinType>,
    boundary: phases::Timestamp,
) {
    let context = escrow.asset_context.extract();
    let context = asset_context_state::fire_do_auction_expiry_for_testing(context, boundary);
    escrow.asset_context.fill(context);
}

// ─── Event field accessors (test-only) ───────────────────────────────────────

#[test_only]
public(package) fun asset_integrated_escrow_id<A, C>(e: &AssetIntegrated<A, C>): ID      { e.escrow_id }
#[test_only]
public(package) fun asset_integrated_owner_cap_id<A, C>(e: &AssetIntegrated<A, C>): ID   { e.owner_cap_id }
#[test_only]
public(package) fun asset_integrated_owner<A, C>(e: &AssetIntegrated<A, C>): address      { e.owner }
#[test_only]
public(package) fun asset_integrated_asset_id<A, C>(e: &AssetIntegrated<A, C>): ID       { e.asset_id }
#[test_only]
public(package) fun asset_integrated_fee_inbox_id<A, C>(e: &AssetIntegrated<A, C>): ID   { e.fee_inbox_id }
#[test_only]
public(package) fun asset_integrated_integrated_at_ms<A, C>(e: &AssetIntegrated<A, C>): u64 { e.integrated_at_ms }

#[test_only]
public(package) fun asset_claimed_escrow_id(e: &AssetClaimed): ID      { e.escrow_id }
#[test_only]
public(package) fun asset_claimed_owner_cap_id(e: &AssetClaimed): ID   { e.owner_cap_id }
#[test_only]
public(package) fun asset_claimed_owner(e: &AssetClaimed): address     { e.owner }
#[test_only]
public(package) fun asset_claimed_swept_earnings(e: &AssetClaimed): u64 { e.swept_earnings }
#[test_only]
public(package) fun asset_claimed_timestamp_ms(e: &AssetClaimed): u64  { e.timestamp_ms }
