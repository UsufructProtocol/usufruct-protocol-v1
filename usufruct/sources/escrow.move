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
    cap_authorization::CapAuthorization,
    config::{Self, IntegrationConfig},
    curve_shape::CurveShape,
    descent_policy,
    engine_state::{Self, EngineState},
    handover_policy,
    owner_cap::{Self, OwnerCap},
    pending_transition::{Self, PendingTransition},
    phases,
    price_function::{Self, PriceFunction},
    protocol_fee_inbox::{Self, ProtocolFeeRef},
    retire_policy,
    tenant_cap::TenantCap,
};

// === Errors ===

const ENotRented:           u64 = 0;
const ENotRetired:          u64 = 6;
const EWrongEscrowOwnerCap: u64 = 11;

// === Structs ===

/// Central shared object. One per integrated asset.
///
/// Immutable escrow context (`config`, `fee_inbox_id`, `integrated_at_ms`)
/// lives here — written once at `integrate` time, never mutated.
/// `escrow_id` is always `object::id(&escrow)` — not stored.
///
/// `state` holds the mutable engine (lifecycle + owner earnings).
public struct Escrow<Asset: key + store, phantom CoinType> has key {
    id:               UID,
    config:           IntegrationConfig,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
    state:            Option<EngineState<Asset, CoinType>>,
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
    let engine = engine_state::new<Asset, CoinType>(asset, owner_cap_id);
    transfer::share_object(Escrow<Asset, CoinType> {
        id:    uid,
        config:           cfg,
        fee_inbox_id,
        integrated_at_ms,
        state: option::some(engine),
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
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state = escrow.state.extract();
    let (new_state, coin) = engine_state::execute_withdraw_earnings(
        state, &escrow.config, escrow_id, fee_inbox_id, owner_cap, clock, ctx,
    );
    escrow.state.fill(new_state);
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

    let escrow_id        = object::id(&escrow);
    let owner_cap_id     = object::id(&owner_cap);
    let owner_addr       = ctx.sender();
    let config           = escrow.config;
    let fee_inbox_id     = escrow.fee_inbox_id;

    let Escrow { id, config: _, fee_inbox_id: _, integrated_at_ms: _, state } = escrow;
    let engine = option::destroy_some(state);
    let engine = engine_state::apply_pending_transitions(engine, &config, escrow_id, fee_inbox_id, clock, ctx);
    assert!(engine_state::is_inactive(&engine), ENotRetired);

    let (asset, earnings) = engine_state::unwrap_for_claim(engine, &owner_cap, ctx);
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
    let escrow_id        = object::id(escrow);
    let fee_inbox_id     = escrow.fee_inbox_id;
    let integrated_at_ms = escrow.integrated_at_ms;
    let state = escrow.state.extract();
    let new_state = engine_state::execute_retire(
        state, &escrow.config, escrow_id, fee_inbox_id, integrated_at_ms, clock, ctx,
    );
    escrow.state.fill(new_state);
}

/// Single entry point to become tenant or place a bid.
public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut Escrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state = escrow.state.extract();
    let (new_state, cap) = engine_state::execute_rent(
        state, &escrow.config, escrow_id, fee_inbox_id, payment, clock, ctx,
    );
    escrow.state.fill(new_state);
    cap
}

/// Tenant-side asset borrow.
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt) {
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state = escrow.state.extract();
    let (new_state, asset, receipt) = engine_state::execute_borrow(
        state, &escrow.config, escrow_id, fee_inbox_id, tenant_cap, clock, ctx,
    );
    escrow.state.fill(new_state);
    (asset, receipt)
}

/// Tenant-side asset return.
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let escrow_id = object::id(escrow);
    let state = escrow.state.extract();
    let new_state = engine_state::execute_return(state, escrow_id, asset, receipt_in);
    escrow.state.fill(new_state);
}

/// Burn a stale `TenantCap` for gas recovery.
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state = escrow.state.extract();
    let new_state = engine_state::execute_burn_tenant_cap(
        state, &escrow.config, escrow_id, fee_inbox_id, cap, clock, ctx,
    );
    escrow.state.fill(new_state);
}

/// Permissionless settler.
public fun apply_pending_transitions<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state = escrow.state.extract();
    let new_state = engine_state::apply_pending_transitions(
        state, &escrow.config, escrow_id, fee_inbox_id, clock, ctx,
    );
    escrow.state.fill(new_state);
}

/// Detect the single transition that is due at `now`, if any.
public fun next_pending<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): Option<PendingTransition> {
    engine_state::next_pending(read_engine(escrow), &escrow.config, clock)
}

// === View Functions ===

// ─── State predicates ────────────────────────────────────────────────────────

public fun is_idle<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_idle_state(read_engine(escrow))
}

public fun is_at_dutch_auction<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_at_dutch_state(read_engine(escrow))
}

public fun is_handover_open<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_handover_open_state(read_engine(escrow))
}

public fun is_handover_confirmed<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_handover_confirmed_state(read_engine(escrow))
}

public fun is_retired<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_inactive(read_engine(escrow))
}

public fun is_rented<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_rented_state(read_engine(escrow))
}

public fun is_descent_skipped<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    descent_policy::is_skipped(config::descent(&escrow.config))
}

public fun is_retire_immediate<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    retire_policy::is_immediate(config::retire(&escrow.config))
}

public fun is_handover_instant<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy::is_instant(config::handover(&escrow.config))
}

public fun is_handover_fixed_time<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    handover_policy::is_fixed_time(config::handover(&escrow.config))
}

public fun is_retiring<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): bool {
    engine_state::is_retiring_state(read_engine(escrow))
}

// ─── Action classification ───────────────────────────────────────────────────
// Callers use the is_* predicates on the engine state directly.

// ─── Identity views ──────────────────────────────────────────────────────────

public fun asset_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    engine_state::asset_id(read_engine(escrow))
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
    engine_state::owner_cap_id(read_engine(escrow))
}

public fun current_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    engine_state::current_addr_opt(read_engine(escrow))
}

public fun current_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    engine_state::current_cap_id_opt(read_engine(escrow))
}

public fun pending_tenant_addr<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<address> {
    engine_state::pending_addr_opt(read_engine(escrow))
}

public fun pending_tenant_cap_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<ID> {
    engine_state::pending_cap_id_opt(read_engine(escrow))
}

// ─── Stake views ─────────────────────────────────────────────────────────────

public fun current_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine_state::current_stake_opt(read_engine(escrow))
}

public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine_state::pending_stake_opt(read_engine(escrow))
}

// ─── Temporal views ───────────────────────────────────────────────────────────

public fun phase_start_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine_state::phase_start_ms_opt(read_engine(escrow))
}

public fun tenure_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    let s = read_engine(escrow);
    if (!engine_state::is_rented_state(s)) return option::none();
    let ps = *option::borrow(&engine_state::phase_start_ms_opt(s));
    option::some(phases::boundary_at(ps, config::tenure_ceiling(&escrow.config)))
}

public fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine_state::handover_expiry_opt(read_engine(escrow))
}

public fun compute_handover_expiry_at<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    bid_time_ms: u64,
): Option<u64> {
    let s = read_engine(escrow);
    if (!engine_state::is_handover_open_state(s)) return option::none();
    let phase_start = *option::borrow(&engine_state::phase_start_ms_opt(s));
    let tenure      = config::tenure_ceiling(&escrow.config);
    option::some(handover_policy::expiry_at(config::handover(&escrow.config), bid_time_ms, phase_start, tenure))
}

public fun tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    config::tenure_ceiling(&escrow.config)
}

public fun integrated_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    escrow.integrated_at_ms
}

public fun retire_unlocks_at_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    retire_policy::unlock_at_ms(config::retire(&escrow.config), escrow.integrated_at_ms)
}

// ─── Cap views ───────────────────────────────────────────────────────────────

public fun tenant_cap_status<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    cap_id: ID,
): CapAuthorization {
    engine_state::cap_authorization(read_engine(escrow), cap_id)
}

// ─── Timing views ────────────────────────────────────────────────────────────

public fun has_pending_transitions<Asset: key + store, CoinType>(
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
        option::some(pending_transition::boundary_ms(option::borrow(&pending)))
    } else {
        option::none()
    }
}

// ─── Pricing views ───────────────────────────────────────────────────────────

public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    engine_state::used_credit_at(read_engine(escrow), &escrow.config, clock::timestamp_ms(clock))
}

public fun compute_used_credit_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    engine_state::used_credit_at(read_engine(escrow), &escrow.config, timestamp_ms)
}

public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    engine_state::floor_price_at(read_engine(escrow), &escrow.config, clock::timestamp_ms(clock))
}

public fun compute_floor_price_at_ms<Asset: key + store, CoinType>(
    escrow:       &Escrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    engine_state::floor_price_at(read_engine(escrow), &escrow.config, timestamp_ms)
}

public fun compute_next_ascending_floor<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    bid_amount: u64,
): u64 {
    price_function::evaluate_price_fn(config::price_function(&escrow.config), bid_amount)
}

public fun last_acq_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    engine_state::last_acq_price_opt(read_engine(escrow))
}

// ─── Settlement views ────────────────────────────────────────────────────────

public fun compute_handover_settlement<Asset: key + store, CoinType>(
    escrow:      &Escrow<Asset, CoinType>,
    boundary_ms: u64,
): (u64, u64, u64) {
    let s     = read_engine(escrow);
    let stake = engine_state::current_stake_value(s);
    let used  = engine_state::used_credit_at(s, &escrow.config, boundary_ms);
    let (owner_share, protocol_fee) = engine_state::split_fee(used);
    (stake - used, owner_share, protocol_fee)
}

public fun compute_tenure_settlement<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): (u64, u64) {
    let s = read_engine(escrow);
    assert!(engine_state::is_rented_state(s), ENotRented);
    engine_state::split_fee(engine_state::current_stake_value(s))
}

// ─── Earnings views ──────────────────────────────────────────────────────────

public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    engine_state::owner_balance(read_engine(escrow))
}

// ─── Config views ────────────────────────────────────────────────────────────

public fun integration_config<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): IntegrationConfig {
    escrow.config
}

public fun fee_inbox_id<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): ID {
    escrow.fee_inbox_id
}

public fun protocol_fee_bps(): u64 { engine_state::protocol_fee_bps() }
public fun bps_denominator():  u64 { engine_state::bps_denominator() }

public fun min_rent_price<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    config::min_rent_price(&escrow.config)
}

public fun dutch_auction_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    descent_policy::window_ceiling_opt(config::descent(&escrow.config))
}

public fun handover_countdown_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    handover_policy::countdown_floor_ms_opt(config::handover(&escrow.config))
}

public fun retire_floor_ms<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): Option<u64> {
    retire_policy::floor_ms_opt(config::retire(&escrow.config))
}

public fun credit_curve<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShape {
    *config::credit_curve(&escrow.config)
}

public fun descent_curve<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): CurveShape {
    *config::descent_curve(&escrow.config)
}

public fun ascending_price_function<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): PriceFunction {
    *config::price_function(&escrow.config)
}

// === Private Functions ===

fun read_engine<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &EngineState<Asset, CoinType> {
    option::borrow(&escrow.state)
}

// === Test Functions ===

#[test_only]
public(package) fun read_engine_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): &engine_state::EngineState<Asset, CoinType> {
    read_engine(escrow)
}

#[test_only]
public(package) fun owner_value_for_testing<Asset: key + store, CoinType>(
    escrow: &Escrow<Asset, CoinType>,
): u64 {
    engine_state::owner_balance(read_engine(escrow))
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    engine_state::split_fee_for_testing(amount)
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    escrow:         &mut Escrow<Asset, CoinType>,
    tenant:         usufruct::tenant::Tenant<CoinType>,
    phase_start_ms: u64,
) {
    let escrow_id = object::id(escrow);
    let state     = escrow.state.extract();
    let new_state = engine_state::drive_to_rented_for_testing(state, tenant, phase_start_ms, escrow_id);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut Escrow<Asset, CoinType>,
    tenant:                    usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
) {
    let state     = escrow.state.extract();
    let new_state = engine_state::drive_to_demand_for_testing(state, tenant, handover_countdown_expiry);
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
    let escrow_id = object::id(escrow);
    let state     = escrow.state.extract();
    let new_state = engine_state::drive_to_at_dutch_for_testing(
        state, owner_amount, fee_amount, last_acq_price, new_phase_start_ms, escrow_id,
    );
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let state     = escrow.state.extract();
    let new_state = engine_state::drive_to_retired_for_testing(state);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut Escrow<Asset, CoinType>,
) {
    let state     = escrow.state.extract();
    let new_state = engine_state::drive_to_retiring_flag_for_testing(state);
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state     = escrow.state.extract();
    let new_state = engine_state::fire_do_handover_for_testing(
        state, &escrow.config, escrow_id, fee_inbox_id, boundary_ms, ctx,
    );
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id    = object::id(escrow);
    let fee_inbox_id = escrow.fee_inbox_id;
    let state     = escrow.state.extract();
    let new_state = engine_state::fire_do_tenure_expiry_for_testing(
        state, escrow_id, fee_inbox_id, boundary_ms, ctx,
    );
    escrow.state.fill(new_state);
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut Escrow<Asset, CoinType>,
    boundary_ms: u64,
) {
    let escrow_id = object::id(escrow);
    let state     = escrow.state.extract();
    let new_state = engine_state::fire_do_auction_expiry_for_testing(state, escrow_id, boundary_ms);
    escrow.state.fill(new_state);
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
public(package) fun asset_integrated_at_ms<A, C>(e: &AssetIntegrated<A, C>): u64         { e.integrated_at_ms }

#[test_only]
public(package) fun asset_claimed_escrow_id(e: &AssetClaimed): ID         { e.escrow_id }
#[test_only]
public(package) fun asset_claimed_owner_cap_id(e: &AssetClaimed): ID      { e.owner_cap_id }
#[test_only]
public(package) fun asset_claimed_owner(e: &AssetClaimed): address         { e.owner }
#[test_only]
public(package) fun asset_claimed_swept_earnings(e: &AssetClaimed): u64   { e.swept_earnings }
#[test_only]
public(package) fun asset_claimed_timestamp_ms(e: &AssetClaimed): u64     { e.timestamp_ms }
