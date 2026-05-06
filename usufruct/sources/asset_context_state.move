// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Context-State pattern: AssetContext (context carrier) + AssetState (state machine)
/// co-resident in one module.
///
/// Move 2024 enforces enum variant visibility at the pattern level — matching
/// AssetState variants is only possible inside this module, making co-residence
/// a structural requirement, not a style choice.
///
/// TenancyState sub-machine (Occupied / Demand) lives in tenancy_state.move
/// and is embedded as AssetState::Renting { tenancy }.
module usufruct::asset_context_state;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::{Self, AssetReceipt},
    cap_authorization_state::CapAuthorizationState,
    config::{Self, IntegrationConfig},
    descent_policy_state,
    owner::{Self, Owner},
    owner_cap::OwnerCap,
    pending_transition_state::{Self, PendingTransitionState},
    price_state,
    retire_policy_state,
    tenant,
    tenant_cap::{Self, TenantCap},
    tenancy_state::{Self, TenancyState},
};

// === Errors ===

const ENotRented:             u64 = 0;
const EInsufficientPayment:   u64 = 1;
const ERetiredNoBid:          u64 = 3;
const ERetireFloorNotElapsed: u64 = 4;
const EAlreadyRetired:        u64 = 5;
const EWrongEscrowTenantCap:  u64 = 6;
const EStaleTenantCap:        u64 = 8;
const EReceiptEscrowMismatch: u64 = 10;
const EReceiptAssetMismatch:  u64 = 11;
const ENotRetired:            u64 = 12;
const ENoEarnings:            u64 = 13;

// === Structs ===

/// Lifecycle state — four outer variants. No owner field; owner lives in Engine.
///
///   · Idle    — no tenant, no auction. Asset sits in escrow.
///   · Renting — active tenancy (Occupied or Demand sub-state).
///   · AtDutch — Dutch auction in progress. No active tenant.
///   · Retired — asset extracted; awaiting owner claim.
public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Idle    { asset: Asset },
    Renting { tenancy: TenancyState<Asset, CoinType> },
    AtDutch { asset: Asset, last_acq_price: u64, phase_start_ms: u64 },
    Retired { asset: Asset },
}

/// Central engine: lifecycle state + owner + immutable escrow context.
///
/// Context fields (config, fee_inbox_id, integrated_at_ms, escrow_id) are
/// written once at integrate time and never mutated. Stored in Escrow as
/// Option<Engine> to enable by-value extraction.
public struct AssetContext<Asset: key + store, phantom CoinType> has store {
    asset_state:      AssetState<Asset, CoinType>,
    owner:            Owner<CoinType>,
    config:           IntegrationConfig,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
    escrow_id:        ID,
}

// === Events ===

public struct RentStarted has copy, drop {
    escrow_id:      ID,
    tenant_cap_id:  ID,
    tenant:         address,
    phase_start_ms: u64,
    price_paid:     u64,
    floor_price:    u64,
}

public struct AuctionExpired has copy, drop {
    escrow_id:      ID,
    phase_start_ms: u64,
    last_acq_price: u64,
    timestamp_ms:   u64,
}

public struct AssetRetired has copy, drop {
    escrow_id:    ID,
    timestamp_ms: u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:    ID,
    owner_cap_id: ID,
    owner:        address,
    amount:       u64,
    timestamp_ms: u64,
}

// === Public Functions ===

// ─── Constructor ──────────────────────────────────────────────────────────────

/// Construct a fresh engine. Called once at integrate time.
public(package) fun new<Asset: key + store, CoinType>(
    asset:            Asset,
    owner_cap_id:     ID,
    config:           IntegrationConfig,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
    escrow_id:        ID,
): AssetContext<Asset, CoinType> {
    AssetContext {
        asset_state:      AssetState::Idle { asset },
        owner:            owner::new<CoinType>(owner_cap_id),
        config,
        fee_inbox_id,
        integrated_at_ms,
        escrow_id,
    }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_active<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Retired { .. } => false, _ => true }
}

public(package) fun is_inactive<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Retired { .. } => true, _ => false }
}

// ─── Context accessors ────────────────────────────────────────────────────────

public(package) fun config<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): &IntegrationConfig { &e.config }

public(package) fun fee_inbox_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID { e.fee_inbox_id }

public(package) fun integrated_at_ms<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): u64 { e.integrated_at_ms }

public(package) fun escrow_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID { e.escrow_id }

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun asset_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID {
    match (&e.asset_state) {
        AssetState::Idle    { asset }    => object::id(asset),
        AssetState::AtDutch { asset, .. } => object::id(asset),
        AssetState::Retired { asset }    => object::id(asset),
        AssetState::Renting { tenancy }  => tenancy_state::asset_id(tenancy),
    }
}

public(package) fun owner_balance<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): u64 {
    owner::value(&e.owner)
}

public(package) fun owner_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID {
    owner::id_cap_id(owner::identity(&e.owner))
}

// ─── State predicate views (SDK surface via escrow.move) ──────────────────────

public(package) fun is_idle_state<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Idle { .. } => true, _ => false }
}

public(package) fun is_at_dutch_state<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::AtDutch { .. } => true, _ => false }
}

/// True iff there is an active tenancy (Occupied or Demand).
public(package) fun is_rented_state<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Renting { .. } => true, _ => false }
}

/// True iff renting and tenancy is Occupied (no pending bid yet).
public(package) fun is_handover_open_state<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::is_occupied(tenancy),
        _ => false,
    }
}

/// True iff renting and tenancy is Demand (pending bidder present).
public(package) fun is_handover_confirmed_state<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::is_demand(tenancy),
        _ => false,
    }
}

public(package) fun is_retiring_state<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::is_retiring(tenancy),
        _ => false,
    }
}

// ─── Tenant data views (Option variants — only present in Renting) ────────────

public(package) fun current_addr_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<address> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy_state::current_addr(tenancy)),
        _ => option::none(),
    }
}

public(package) fun current_cap_id_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<ID> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy_state::current_cap_id(tenancy)),
        _ => option::none(),
    }
}

public(package) fun pending_addr_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<address> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::pending_addr_opt(tenancy),
        _ => option::none(),
    }
}

public(package) fun pending_cap_id_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<ID> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::pending_cap_id_opt(tenancy),
        _ => option::none(),
    }
}

public(package) fun current_stake_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<u64> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy_state::current_stake(tenancy)),
        _ => option::none(),
    }
}

public(package) fun current_stake_value<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): u64 {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::current_stake(tenancy),
        _ => abort ENotRented,
    }
}

public(package) fun pending_stake_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<u64> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::pending_stake_opt(tenancy),
        _ => option::none(),
    }
}

public(package) fun phase_start_ms_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<u64> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy_state::phase_start_ms(tenancy)),
        AssetState::AtDutch { phase_start_ms, .. } => option::some(*phase_start_ms),
        _ => option::none(),
    }
}

public(package) fun handover_expiry_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<u64> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::handover_expiry_opt(tenancy),
        _ => option::none(),
    }
}

public(package) fun last_acq_price_opt<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<u64> {
    match (&e.asset_state) {
        AssetState::AtDutch { last_acq_price, .. } => option::some(*last_acq_price),
        _ => option::none(),
    }
}

// ─── Pricing views ────────────────────────────────────────────────────────────

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    e:            &AssetContext<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    match (&e.asset_state) {
        AssetState::Idle { .. } =>
            config::min_rent_price(&e.config),
        AssetState::Renting { tenancy } =>
            tenancy_state::floor_price_at(tenancy, &e.config, timestamp_ms),
        AssetState::AtDutch { last_acq_price, phase_start_ms, .. } => {
            let ps = price_state::descending(*last_acq_price, *phase_start_ms);
            price_state::floor_price(&ps, &e.config, timestamp_ms)
        },
        AssetState::Retired { .. } => abort ERetiredNoBid,
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    e:            &AssetContext<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            tenancy_state::used_credit_at(tenancy, &e.config, timestamp_ms),
        _ => abort ENotRented,
    }
}

public(package) fun split_fee(amount: u64): (u64, u64) {
    tenancy_state::split_fee(amount)
}

public(package) fun protocol_fee_bps(): u64 { tenancy_state::protocol_fee_bps() }
public(package) fun bps_denominator(): u64  { tenancy_state::bps_denominator() }

// ─── Cap-authorization view ───────────────────────────────────────────────────

public(package) fun cap_authorization_state<Asset: key + store, CoinType>(
    e:      &AssetContext<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => tenancy_state::cap_authorization_state(tenancy, cap_id),
        _ => usufruct::cap_authorization_state::stale(),
    }
}

// ─── APT and pending detection ────────────────────────────────────────────────

public(package) fun next_pending<Asset: key + store, CoinType>(
    e:     &AssetContext<Asset, CoinType>,
    clock: &Clock,
): Option<PendingTransitionState> {
    let now = clock::timestamp_ms(clock);
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            tenancy_state::next_pending_from_tenancy(tenancy, &e.config, now),
        AssetState::AtDutch { phase_start_ms, .. } => {
            let policy = config::descent(&e.config);
            if (descent_policy_state::has_expired(policy, *phase_start_ms, now)) {
                return option::some(
                    pending_transition_state::auction(descent_policy_state::expiry_at(policy, *phase_start_ms))
                )
            };
            option::none()
        },
        AssetState::Idle { .. } | AssetState::Retired { .. } => option::none(),
    }
}

public(package) fun apply_pending_transition_states<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
): AssetContext<Asset, CoinType> {
    let mut current = context;
    let mut pending = next_pending(&current, clock);
    while (option::is_some(&pending)) {
        current = fire(current, option::destroy_some(pending), ctx);
        pending = next_pending(&current, clock);
    };
    current
}

// ─── Action executors ─────────────────────────────────────────────────────────

public(package) fun execute_rent<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): (AssetContext<Asset, CoinType>, TenantCap) {
    let context = apply_pending_transition_states(context, clock, ctx);
    let now    = clock::timestamp_ms(clock);
    let floor  = floor_price_at(&context, now);
    assert!(coin::value(&payment) >= floor, EInsufficientPayment);
    match (context) {
        AssetContext { asset_state: AssetState::Idle { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let (new_state, cap) = do_install(asset, escrow_id, payment, floor, now, ctx);
            (AssetContext { asset_state: new_state, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }, cap)
        },
        AssetContext { asset_state: AssetState::AtDutch { asset, .. }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let (new_state, cap) = do_install(asset, escrow_id, payment, floor, now, ctx);
            (AssetContext { asset_state: new_state, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }, cap)
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let (new_tenancy, cap) = tenancy_state::accept_rent_payment(
                tenancy, &mut owner, &config, escrow_id, fee_inbox_id, payment, floor, now, ctx,
            );
            (AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }, cap)
        },
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ERetiredNoBid,
    }
}

public(package) fun execute_retire<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
): AssetContext<Asset, CoinType> {
    let context = apply_pending_transition_states(context, clock, ctx);
    let now_ms = clock::timestamp_ms(clock);
    assert!(
        retire_policy_state::is_unlocked(config::retire(&context.config), context.integrated_at_ms, now_ms),
        ERetireFloorNotElapsed,
    );
    match (context) {
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort EAlreadyRetired,
        AssetContext { asset_state: AssetState::Idle { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } =>
            AssetContext { asset_state: do_retire_immediately(asset, escrow_id, now_ms, ctx), owner, config, fee_inbox_id, integrated_at_ms, escrow_id },
        AssetContext { asset_state: AssetState::AtDutch { asset, .. }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } =>
            AssetContext { asset_state: do_retire_immediately(asset, escrow_id, now_ms, ctx), owner, config, fee_inbox_id, integrated_at_ms, escrow_id },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let new_tenancy = tenancy_state::set_retiring_flag_checked(tenancy, escrow_id, now_ms, ctx);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
    }
}

public(package) fun execute_borrow<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (AssetContext<Asset, CoinType>, Asset, AssetReceipt) {
    let context = apply_pending_transition_states(context, clock, ctx);
    assert!(tenant_cap::escrow_id(tenant_cap) == context.escrow_id, EWrongEscrowTenantCap);
    let cap_id = object::id(tenant_cap);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let (new_tenancy, u, receipt) = tenancy_state::take_asset(tenancy, escrow_id, cap_id);
            (AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }, u, receipt)
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort EStaleTenantCap,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort EStaleTenantCap,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort EStaleTenantCap,
    }
}

public(package) fun execute_return<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): AssetContext<Asset, CoinType> {
    assert!(asset::receipt_escrow_id(&receipt_in)  == context.escrow_id,             EReceiptEscrowMismatch);
    assert!(asset::receipt_asset_id(&receipt_in)   == object::id(&asset_in),        EReceiptAssetMismatch);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let new_tenancy = tenancy_state::put_asset(tenancy, escrow_id, asset_in, receipt_in);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort EReceiptEscrowMismatch,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort EReceiptEscrowMismatch,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort EReceiptEscrowMismatch,
    }
}

public(package) fun execute_burn_tenant_cap<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
): AssetContext<Asset, CoinType> {
    let context = apply_pending_transition_states(context, clock, ctx);
    match (context) {
        AssetContext { asset_state: AssetState::Retired { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Retired { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Idle { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::AtDutch { asset, last_acq_price, phase_start_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::AtDutch { asset, last_acq_price, phase_start_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            tenancy_state::assert_cap_stale(&tenancy, object::id(&cap));
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
    }
}

public(package) fun execute_withdraw_earnings<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (AssetContext<Asset, CoinType>, Coin<CoinType>) {
    let context       = apply_pending_transition_states(context, clock, ctx);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();
    let AssetContext { asset_state, mut owner, config, fee_inbox_id, integrated_at_ms, escrow_id } = context;
    let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
    event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
    (AssetContext { asset_state, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }, coin)
}

/// Terminal: consume a Retired engine and return (asset, residual earnings).
public(package) fun unwrap_for_claim<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    match (context) {
        AssetContext { asset_state: AssetState::Retired { asset }, mut owner, .. } => {
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            owner::destroy_empty(owner);
            (asset, coin)
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRetired,
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRetired,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRetired,
    }
}

// === Private Functions ===

fun fire<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    t:      PendingTransitionState,
    ctx:    &mut TxContext,
): AssetContext<Asset, CoinType> {
    let boundary_ms = pending_transition_state::boundary_ms(&t);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let result = tenancy_state::do_apt_transition(
                tenancy, &mut owner, &config, escrow_id, fee_inbox_id, boundary_ms, ctx,
            );
            if (tenancy_state::fire_result_is_handover(&result)) {
                let new_tenancy = tenancy_state::fire_result_into_handover(result);
                AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
            } else {
                let (asset, last_acq_price, retiring) = tenancy_state::fire_result_into_tenure_expired(result);
                if (retiring) {
                    event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
                    AssetContext { asset_state: AssetState::Retired { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
                } else {
                    AssetContext { asset_state: AssetState::AtDutch { asset, last_acq_price, phase_start_ms: boundary_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
                }
            }
        },
        AssetContext { asset_state: AssetState::AtDutch { asset, last_acq_price, phase_start_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let new_state = do_auction_expiry(asset, last_acq_price, phase_start_ms, escrow_id, boundary_ms);
            AssetContext { asset_state: new_state, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

fun do_withdraw<CoinType>(
    owner:     &mut Owner<CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Coin<CoinType>, u64) {
    let amount = owner::value(owner);
    assert!(amount > 0, ENoEarnings);
    let coin = owner::withdraw(owner, owner_cap, ctx);
    (coin, amount)
}

fun do_install<Asset: key + store, CoinType>(
    asset:     Asset,
    escrow_id: ID,
    payment:   Coin<CoinType>,
    floor:     u64,
    now:       u64,
    ctx:       &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let price_paid  = coin::value(&payment);
    let tenant_addr = ctx.sender();
    let (cap, cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, tenant_addr, coin::into_balance(payment));
    let wrapped = asset::new(asset, escrow_id);
    event::emit(RentStarted {
        escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr,
        phase_start_ms: now, price_paid, floor_price: floor,
    });
    (AssetState::Renting { tenancy: tenancy_state::new_occupied(wrapped, t, now) }, cap)
}

fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:          Asset,
    last_acq_price: u64,
    phase_start_ms: u64,
    escrow_id:      ID,
    boundary_ms:    u64,
): AssetState<Asset, CoinType> {
    event::emit(AuctionExpired { escrow_id, phase_start_ms, last_acq_price, timestamp_ms: boundary_ms });
    AssetState::Idle { asset }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:        Asset,
    escrow_id:    ID,
    timestamp_ms: u64,
    ctx:          &TxContext,
): AssetState<Asset, CoinType> {
    tenancy_state::emit_retire_flag_set(escrow_id, ctx.sender(), timestamp_ms);
    event::emit(AssetRetired { escrow_id, timestamp_ms });
    AssetState::Retired { asset }
}

// === Test Functions ===

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    split_fee(amount)
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let new_tenancy = tenancy_state::do_handover(
                tenancy, &mut owner, &config, escrow_id, fee_inbox_id, boundary_ms, ctx,
            );
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let (wrapped, last_acq_price, retiring) = tenancy_state::do_tenure_expiry(
                tenancy, &mut owner, escrow_id, fee_inbox_id, boundary_ms, ctx,
            );
            let raw_asset = asset::unbundle(wrapped);
            if (retiring) {
                event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
                AssetContext { asset_state: AssetState::Retired { asset: raw_asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
            } else {
                AssetContext { asset_state: AssetState::AtDutch { asset: raw_asset, last_acq_price, phase_start_ms: boundary_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
            }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary_ms: u64,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::AtDutch { asset, last_acq_price, phase_start_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } =>
            AssetContext { asset_state: do_auction_expiry(asset, last_acq_price, phase_start_ms, escrow_id, boundary_ms), owner, config, fee_inbox_id, integrated_at_ms, escrow_id },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    tenant_in:      tenant::Tenant<CoinType>,
    phase_start_ms: u64,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Idle { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let tenancy = tenancy_state::new_occupied(
                asset::new(asset, escrow_id), tenant_in, phase_start_ms,
            );
            AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    tenant_in:                 usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let new_tenancy = tenancy_state::drive_to_demand_for_testing(
                tenancy, tenant_in, handover_countdown_expiry,
            );
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let wrapped = tenancy_state::unbundle_occupied_for_testing(
                tenancy, owner_amount, fee_amount, escrow_id,
            );
            let raw_asset = asset::unbundle(wrapped);
            AssetContext { asset_state: AssetState::AtDutch { asset: raw_asset, last_acq_price, phase_start_ms: new_phase_start_ms }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Idle { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } =>
            AssetContext { asset_state: AssetState::Retired { asset }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id } => {
            let new_tenancy = tenancy_state::set_retiring_flag_for_testing(tenancy);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at_ms, escrow_id }
        },
        AssetContext { asset_state: AssetState::Idle    { asset: _a }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::AtDutch { asset: _a, .. }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Retired { asset: _a }, owner: _o, .. } => abort ENotRented,
    }
}

// ─── Test-only event accessors ────────────────────────────────────────────────

#[test_only]
public(package) fun rent_started_escrow_id(e: &RentStarted): ID                  { e.escrow_id }
#[test_only]
public(package) fun rent_started_tenant_cap_id(e: &RentStarted): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun rent_started_tenant(e: &RentStarted): address                { e.tenant }
#[test_only]
public(package) fun rent_started_phase_start_ms(e: &RentStarted): u64            { e.phase_start_ms }
#[test_only]
public(package) fun rent_started_price_paid(e: &RentStarted): u64                { e.price_paid }
#[test_only]
public(package) fun rent_started_floor_price(e: &RentStarted): u64               { e.floor_price }

#[test_only]
public(package) fun auction_expired_escrow_id(e: &AuctionExpired): ID            { e.escrow_id }
#[test_only]
public(package) fun auction_expired_phase_start_ms(e: &AuctionExpired): u64      { e.phase_start_ms }
#[test_only]
public(package) fun auction_expired_last_acq_price(e: &AuctionExpired): u64      { e.last_acq_price }
#[test_only]
public(package) fun auction_expired_timestamp_ms(e: &AuctionExpired): u64        { e.timestamp_ms }

#[test_only]
public(package) fun asset_retired_escrow_id(e: &AssetRetired): ID                { e.escrow_id }
#[test_only]
public(package) fun asset_retired_timestamp_ms(e: &AssetRetired): u64            { e.timestamp_ms }

#[test_only]
public(package) fun earnings_withdrawn_escrow_id(e: &EarningsWithdrawn): ID      { e.escrow_id }
#[test_only]
public(package) fun earnings_withdrawn_owner_cap_id(e: &EarningsWithdrawn): ID   { e.owner_cap_id }
#[test_only]
public(package) fun earnings_withdrawn_owner(e: &EarningsWithdrawn): address     { e.owner }
#[test_only]
public(package) fun earnings_withdrawn_amount(e: &EarningsWithdrawn): u64        { e.amount }
#[test_only]
public(package) fun earnings_withdrawn_timestamp_ms(e: &EarningsWithdrawn): u64  { e.timestamp_ms }
