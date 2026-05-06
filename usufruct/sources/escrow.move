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
    engine::{Self, Engine},
    handover_policy_state,
    owner_cap::{Self, OwnerCap},
    pending_transition_state::{Self, PendingTransitionState},
    phases,
    price_function_state::{Self, PriceFunctionState},
    protocol_fee_inbox::{Self, ProtocolFeeRef},
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
    engine: Option<Engine<Asset, CoinType>>,
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
    let fee_inbox_id     = protocol_fee_inbox::inbox_id(fee_ref);
    let integrated_at_ms = clock::timestamp_ms(clock);

    config::emit_registration(&cfg, escrow_id);
    let engine = engine::new<Asset, CoinType>(
        asset, owner_cap_id, cfg, fee_inbox_id, integrated_at_ms, escrow_id,
    );
    transfer::share_object(Escrow<Asset, CoinType> {
        id:     uid,
        engine: option::some(engine),
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
    let engine = escrow.engine.extract();
    let (engine, coin) = engine::execute_withdraw_earnings(engine, owner_cap, clock, ctx);
    escrow.engine.fill(engine);
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

    let Escrow { id, engine } = escrow;
    let engine = option::destroy_some(engine);
    let engine = engine::apply_pending_transition_states(engine, clock, ctx);
    assert!(engine::is_inactive(&engine), ENotRetired);

    let (asset, earnings) = engine::unwrap_for_claim(engine, &owner_cap, ctx);
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
    let engine = escrow.engine.extract();
    let engine = engine::execute_retire(engine, clock, ctx);
    escrow.engine.fill(engine);
}

/// Single entry point to become tenant or place a bid.
public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut Escrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    let engine = escrow.engine.extract();
    let (engine, cap) = engine::execute_rent(engine, payment, clock, ctx);
    escrow.engine.fill(engine);
    cap
}

/// Tenant-side asset borrow.
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt) {
    let engine = escrow.engine.extract();
    let (engine, asset, receipt) = engine::execute_borrow(engine, tenant_cap, clock, ctx);
    escrow.engine.fill(engine);
    (asset, receipt)
}

/// Tenant-side asset return.
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let engine = escrow.engine.extract();
    let engine = engine::execute_return(engine, asset, receipt_in);
    escrow.engine.fill(engine);
}

/// Burn a stale `TenantCap` for gas recovery.
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let engine = escrow.engine.extract();
    let engine = engine::execute_burn_tenant_cap(engine, cap, clock, ctx);
    escrow.engine.fill(engine);
}

/// Permissionless settler.
public fun apply_pending_transition_states<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let engine = escrow.engine.extract();
    let engine = engine::apply_pending_transition_states(engine, clock, ctx);
    escrow.engine.fill(engine);
}

/// Detect the single transition that is due at `now`, if any.
public fun next_pending<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): Option<PendingTransitionState> {
    engine::next_pending(read_engine(escrow), clock)
}

// === View Functions ===

// ─── State predicates ────────────────────────────────────────────────────────

public fun is_idle<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_idle_state(read_engine(escrow))
}

public fun is_at_dutch_auction<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_at_dutch_state(read_engine(escrow))
}

public fun is_handover_open<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_handover_open_state(read_engine(escrow))
}

public fun is_handover_confirmed<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_handover_confirmed_state(read_engine(escrow))
}

public fun is_retired<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_inactive(read_engine(escrow))
}

public fun is_rented<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_rented_state(read_engine(escrow))
}

public fun is_descent_skipped<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    descent_policy_state::is_skipped(config::descent(cfg(escrow)))
}

public fun is_retire_immediate<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    retire_policy_state::is_immediate(config::retire(cfg(escrow)))
}

public fun is_handover_instant<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy_state::is_instant(config::handover(cfg(escrow)))
}

public fun is_handover_fixed_time<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy_state::is_fixed_time(config::handover(cfg(escrow)))
}

public fun is_retiring<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine::is_retiring_state(read_engine(escrow))
}

// ─── Identity views ──────────────────────────────────────────────────────────

public fun asset_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    engine::asset_id(read_engine(escrow))
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
    engine::owner_cap_id(read_engine(escrow))
}

public fun current_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    engine::current_addr_opt(read_engine(escrow))
}

public fun current_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    engine::current_cap_id_opt(read_engine(escrow))
}

public fun pending_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    engine::pending_addr_opt(read_engine(escrow))
}

public fun pending_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    engine::pending_cap_id_opt(read_engine(escrow))
}

// ─── Stake views ─────────────────────────────────────────────────────────────

public fun current_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine::current_stake_opt(read_engine(escrow))
}

public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine::pending_stake_opt(read_engine(escrow))
}

// ─── Temporal views ───────────────────────────────────────────────────────────

public fun phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine::phase_start_ms_opt(read_engine(escrow))
}

public fun tenure_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let e = read_engine(escrow);
    if (!engine::is_rented_state(e)) return option::none();
    let ps = *option::borrow(&engine::phase_start_ms_opt(e));
    option::some(phases::boundary_at(ps, config::tenure_ceiling(engine::config(e))))
}

public fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine::handover_expiry_opt(read_engine(escrow))
}

public fun compute_handover_expiry_at<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    bid_time_ms: u64,
): Option<u64> {
    let e = read_engine(escrow);
    if (!engine::is_handover_open_state(e)) return option::none();
    let phase_start = *option::borrow(&engine::phase_start_ms_opt(e));
    let c           = engine::config(e);
    let tenure      = config::tenure_ceiling(c);
    option::some(handover_policy_state::expiry_at(config::handover(c), bid_time_ms, phase_start, tenure))
}

public fun tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    config::tenure_ceiling(cfg(escrow))
}

public fun integrated_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    engine::integrated_at_ms(read_engine(escrow))
}

public fun retire_unlocks_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    let e = read_engine(escrow);
    retire_policy_state::unlock_at_ms(config::retire(engine::config(e)), engine::integrated_at_ms(e))
}

// ─── Cap views ───────────────────────────────────────────────────────────────

public fun tenant_cap_status<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    engine::cap_authorization_state(read_engine(escrow), cap_id)
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
    engine::used_credit_at(read_engine(escrow), clock::timestamp_ms(clock))
}

public fun compute_used_credit_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    engine::used_credit_at(read_engine(escrow), timestamp_ms)
}

public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    engine::floor_price_at(read_engine(escrow), clock::timestamp_ms(clock))
}

public fun compute_floor_price_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    engine::floor_price_at(read_engine(escrow), timestamp_ms)
}

public fun compute_next_ascending_floor<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    bid_amount: u64,
): u64 {
    price_function_state::evaluate_price_fn(config::price_function_state(cfg(escrow)), bid_amount)
}

public fun last_acq_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine::last_acq_price_opt(read_engine(escrow))
}

// ─── Settlement views ────────────────────────────────────────────────────────

public fun compute_handover_settlement<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    boundary_ms: u64,
): (u64, u64, u64) {
    let e     = read_engine(escrow);
    let stake = engine::current_stake_value(e);
    let used  = engine::used_credit_at(e, boundary_ms);
    let (owner_share, protocol_fee) = engine::split_fee(used);
    (stake - used, owner_share, protocol_fee)
}

public fun compute_tenure_settlement<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): (u64, u64) {
    let e = read_engine(escrow);
    assert!(engine::is_rented_state(e), ENotRented);
    engine::split_fee(engine::current_stake_value(e))
}

// ─── Earnings views ──────────────────────────────────────────────────────────

public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    engine::owner_balance(read_engine(escrow))
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
    engine::fee_inbox_id(read_engine(escrow))
}

public fun protocol_fee_bps(): u64 { engine::protocol_fee_bps() }
public fun bps_denominator():  u64 { engine::bps_denominator() }

public fun min_rent_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    config::min_rent_price(cfg(escrow))
}

public fun dutch_auction_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    descent_policy_state::window_ceiling_opt(config::descent(cfg(escrow)))
}

public fun handover_countdown_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    handover_policy_state::countdown_floor_ms_opt(config::handover(cfg(escrow)))
}

public fun retire_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    retire_policy_state::floor_ms_opt(config::retire(cfg(escrow)))
}

public fun credit_curve<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShapeState {
    *config::credit_curve(cfg(escrow))
}

public fun descent_curve<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShapeState {
    *config::descent_curve(cfg(escrow))
}

public fun ascending_price_function_state<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): PriceFunctionState {
    *config::price_function_state(cfg(escrow))
}

// === Private Functions ===

fun read_engine<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &Engine<Asset, CoinType> {
    option::borrow(&escrow.engine)
}

fun cfg<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &IntegrationConfig {
    engine::config(read_engine(escrow))
}

// === Test Functions ===

#[test_only]
public(package) fun read_engine_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &engine::Engine<Asset, CoinType> {
    read_engine(escrow)
}

#[test_only]
public(package) fun owner_value_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    engine::owner_balance(read_engine(escrow))
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    engine::split_fee_for_testing(amount)
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    escrow:         &mut Escrow<Asset, CoinType>,
    tenant:         usufruct::tenant::Tenant<CoinType>,
    phase_start_ms: u64,
) {
    let engine = escrow.engine.extract();
    let engine = engine::drive_to_rented_for_testing(engine, tenant, phase_start_ms);
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut Escrow<Asset, CoinType>,
    tenant:                    usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
) {
    let engine = escrow.engine.extract();
    let engine = engine::drive_to_demand_for_testing(engine, tenant, handover_countdown_expiry);
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    escrow:             &mut Escrow<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
) {
    let engine = escrow.engine.extract();
    let engine = engine::drive_to_at_dutch_for_testing(
        engine, owner_amount, fee_amount, last_acq_price, new_phase_start_ms,
    );
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let engine = escrow.engine.extract();
    let engine = engine::drive_to_retired_for_testing(engine);
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let engine = escrow.engine.extract();
    let engine = engine::drive_to_retiring_flag_for_testing(engine);
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let engine = escrow.engine.extract();
    let engine = engine::fire_do_handover_for_testing(engine, boundary_ms, ctx);
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let engine = escrow.engine.extract();
    let engine = engine::fire_do_tenure_expiry_for_testing(engine, boundary_ms, ctx);
    escrow.engine.fill(engine);
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    boundary_ms: u64,
) {
    let engine = escrow.engine.extract();
    let engine = engine::fire_do_auction_expiry_for_testing(engine, boundary_ms);
    escrow.engine.fill(engine);
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
