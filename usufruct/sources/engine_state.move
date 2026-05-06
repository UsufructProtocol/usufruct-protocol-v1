// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Flat engine state machine.
///
/// Five variants correspond exactly to the five observable states of the
/// rental protocol. No cross-product — each variant carries only the data
/// that is legal in that state. Zero `unreachable()`.
///
/// Absorbs lifecycle_state, asset_state, and tenant_state. Transitions are
/// direct `match` arms; intermediate dispatch types (RentAction, RetireRoute,
/// TenureExpiryState) are eliminated.
///
/// Immutable escrow context (config, fee_inbox_id, integrated_at_ms,
/// escrow_id) lives at the coordinator layer and is passed explicitly.
module usufruct::engine_state;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::{Self, AssetReceipt},
    cap_authorization_state::{Self, CapAuthorizationState},
    config::{Self, IntegrationConfig},
    credit_state,
    descent_policy_state,
    handover_policy_state,
    math,
    owner::{Self, Owner},
    owner_cap::OwnerCap,
    pending_transition_state::{Self, PendingTransitionState},
    phases,
    price_state,
    refund_state,
    retire_policy_state,
    tenant::{Self, Tenant},
    tenant_cap::{Self, TenantCap},
};

// === Errors ===

const ENotRented:             u64 = 0;
const EInsufficientPayment:   u64 = 1;
const ERetireFlagBlocksBid:   u64 = 2;
const ERetiredNoBid:          u64 = 3;
const ERetireFloorNotElapsed: u64 = 4;
const EAlreadyRetired:        u64 = 5;
const EWrongEscrowTenantCap:  u64 = 6;
const EPendingTenantCap:      u64 = 7;
const EStaleTenantCap:        u64 = 8;
const ETenantCapNotStale:     u64 = 9;
const EReceiptEscrowMismatch: u64 = 10;
const EReceiptAssetMismatch:  u64 = 11;
const ENotRetired:            u64 = 12;
const ENoEarnings:            u64 = 13;

// === Constants ===

const PROTOCOL_FEE_BPS: u64 = 1_000;
const BPS_PER_UNIT:     u64 = 10_000;

// === Structs ===

/// Flat engine state — one variant per observable protocol state.
/// Eliminates the EngineState × LifecycleState × AssetState cross-product
/// and makes all previously-impossible states structurally unrepresentable.
///
/// Immutable escrow context (config, fee_inbox_id, integrated_at_ms,
/// escrow_id) lives at the coordinator layer and is passed explicitly.
/// Functions consume and return `EngineState` by value; views take `&`.
///
///   · Idle            — no tenant, no auction. Asset sits in escrow.
///   · Rented          — single active tenant. Asset may be borrowed.
///   · HandoverPending — active tenant + pending bidder. Countdown running.
///   · AtDutch         — Dutch auction in progress. No active tenant.
///   · Retired         — asset extracted; awaiting owner claim.
public enum EngineState<Asset: key + store, phantom CoinType> has store {
    Idle {
        asset: Asset,
        owner: Owner<CoinType>,
    },
    Rented {
        asset:          asset::Asset<Asset>,
        tenant:         Tenant<CoinType>,
        phase_start_ms: u64,
        retiring:       bool,
        owner:          Owner<CoinType>,
    },
    HandoverPending {
        asset:           asset::Asset<Asset>,
        current:         Tenant<CoinType>,
        pending:         Tenant<CoinType>,
        handover_expiry: u64,
        phase_start_ms:  u64,
        retiring:        bool,
        owner:           Owner<CoinType>,
    },
    AtDutch {
        asset:          Asset,
        last_acq_price: u64,
        phase_start_ms: u64,
        owner:          Owner<CoinType>,
    },
    Retired {
        asset: Asset,
        owner: Owner<CoinType>,
    },
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

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    current_tenant_cap_id:     ID,
    current_tenant_addr:       address,
    current_tenant_stake:      u64,
    current_phase_start_ms:    u64,
    tenant_cap_id:             ID,
    pending_tenant:            address,
    bid_amount:                u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
    timestamp_ms:              u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:                 ID,
    protected_tenant_cap_id:   ID,
    protected_tenant_addr:     address,
    protected_tenant_stake:    u64,
    protected_phase_start_ms:  u64,
    displaced_tenant_cap_id:   ID,
    new_tenant_cap_id:         ID,
    displaced_bidder:          address,
    refunded_amount:           u64,
    new_bidder:                address,
    new_bid_amount:            u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
    timestamp_ms:              u64,
}

public struct HandoverCompleted has copy, drop {
    escrow_id:                ID,
    displaced_tenant_cap_id:  ID,
    displaced_tenant:         address,
    displaced_phase_start_ms: u64,
    new_tenant_cap_id:        ID,
    new_tenant_addr:          address,
    new_tenant_stake:         u64,
    used_credit:              u64,
    owner_share:              u64,
    protocol_fee:             u64,
    remain_credit:            u64,
    new_rent_price:           u64,
    timestamp_ms:             u64,
}

public struct TenureExpired has copy, drop {
    escrow_id:               ID,
    tenant_cap_id:           ID,
    tenant:                  address,
    phase_start_ms:          u64,
    owner_share:             u64,
    protocol_fee:            u64,
    last_acquisition_price:  u64,
    timestamp_ms:            u64,
}

public struct AuctionExpired has copy, drop {
    escrow_id:      ID,
    phase_start_ms: u64,
    last_acq_price: u64,
    timestamp_ms:   u64,
}

public struct RetireFlagSet has copy, drop {
    escrow_id:    ID,
    owner:        address,
    timestamp_ms: u64,
}

public struct AssetRetired has copy, drop {
    escrow_id:    ID,
    timestamp_ms: u64,
}

public struct AssetBorrowed has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    tenant:        address,
}

public struct AssetReturned has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    tenant:        address,
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
    asset:        Asset,
    owner_cap_id: ID,
): EngineState<Asset, CoinType> {
    EngineState::Idle {
        asset,
        owner: owner::new<CoinType>(owner_cap_id),
    }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_active<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) {
        EngineState::Retired { .. } => false,
        _                           => true,
    }
}

public(package) fun is_inactive<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) {
        EngineState::Retired { .. } => true,
        _                           => false,
    }
}

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun asset_id<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): ID {
    match (s) {
        EngineState::Idle            { asset, .. } => object::id(asset),
        EngineState::AtDutch         { asset, .. } => object::id(asset),
        EngineState::Retired         { asset, .. } => object::id(asset),
        EngineState::Rented          { asset, .. } => asset::id_asset_id(asset::identity(asset)),
        EngineState::HandoverPending { asset, .. } => asset::id_asset_id(asset::identity(asset)),
    }
}

public(package) fun owner_balance<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): u64 {
    match (s) {
        EngineState::Idle            { owner, .. } => owner::value(owner),
        EngineState::Rented          { owner, .. } => owner::value(owner),
        EngineState::HandoverPending { owner, .. } => owner::value(owner),
        EngineState::AtDutch         { owner, .. } => owner::value(owner),
        EngineState::Retired         { owner, .. } => owner::value(owner),
    }
}

public(package) fun owner_cap_id<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): ID {
    match (s) {
        EngineState::Idle            { owner, .. } => owner::id_cap_id(owner::identity(owner)),
        EngineState::Rented          { owner, .. } => owner::id_cap_id(owner::identity(owner)),
        EngineState::HandoverPending { owner, .. } => owner::id_cap_id(owner::identity(owner)),
        EngineState::AtDutch         { owner, .. } => owner::id_cap_id(owner::identity(owner)),
        EngineState::Retired         { owner, .. } => owner::id_cap_id(owner::identity(owner)),
    }
}

// ─── State predicate views (SDK surface via escrow.move) ──────────────────────

public(package) fun is_idle_state<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) { EngineState::Idle { .. } => true, _ => false }
}

public(package) fun is_at_dutch_state<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) { EngineState::AtDutch { .. } => true, _ => false }
}

/// True iff there is an active tenant (Rented or HandoverPending).
public(package) fun is_rented_state<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) {
        EngineState::Rented { .. } | EngineState::HandoverPending { .. } => true,
        _ => false,
    }
}

/// True iff in Rented (active tenant, no pending bid yet).
public(package) fun is_handover_open_state<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) { EngineState::Rented { .. } => true, _ => false }
}

/// True iff in HandoverPending (active tenant + pending bidder).
public(package) fun is_handover_confirmed_state<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) { EngineState::HandoverPending { .. } => true, _ => false }
}

public(package) fun is_retiring_state<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) {
        EngineState::Rented          { retiring, .. } => *retiring,
        EngineState::HandoverPending { retiring, .. } => *retiring,
        _ => false,
    }
}

// ─── Tenant data views (Option variants — only present in some states) ─────────

public(package) fun current_addr_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<address> {
    match (s) {
        EngineState::Rented          { tenant,  .. } => option::some(tenant::id_address(tenant::identity(tenant))),
        EngineState::HandoverPending { current, .. } => option::some(tenant::id_address(tenant::identity(current))),
        _ => option::none(),
    }
}

public(package) fun current_cap_id_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        EngineState::Rented          { tenant,  .. } => option::some(tenant::id_cap_id(tenant::identity(tenant))),
        EngineState::HandoverPending { current, .. } => option::some(tenant::id_cap_id(tenant::identity(current))),
        _ => option::none(),
    }
}

public(package) fun pending_addr_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<address> {
    match (s) {
        EngineState::HandoverPending { pending, .. } => option::some(tenant::id_address(tenant::identity(pending))),
        _ => option::none(),
    }
}

public(package) fun pending_cap_id_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        EngineState::HandoverPending { pending, .. } => option::some(tenant::id_cap_id(tenant::identity(pending))),
        _ => option::none(),
    }
}

public(package) fun current_stake_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<u64> {
    match (s) {
        EngineState::Rented          { tenant,  .. } => option::some(tenant::stake_value(tenant)),
        EngineState::HandoverPending { current, .. } => option::some(tenant::stake_value(current)),
        _ => option::none(),
    }
}

public(package) fun current_stake_value<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): u64 {
    match (s) {
        EngineState::Rented          { tenant,  .. } => tenant::stake_value(tenant),
        EngineState::HandoverPending { current, .. } => tenant::stake_value(current),
        _ => abort ENotRented,
    }
}

public(package) fun pending_stake_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<u64> {
    match (s) {
        EngineState::HandoverPending { pending, .. } => option::some(tenant::stake_value(pending)),
        _ => option::none(),
    }
}

public(package) fun phase_start_ms_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<u64> {
    match (s) {
        EngineState::Rented          { phase_start_ms, .. } => option::some(*phase_start_ms),
        EngineState::HandoverPending { phase_start_ms, .. } => option::some(*phase_start_ms),
        EngineState::AtDutch         { phase_start_ms, .. } => option::some(*phase_start_ms),
        _ => option::none(),
    }
}

public(package) fun handover_expiry_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<u64> {
    match (s) {
        EngineState::HandoverPending { handover_expiry, .. } => option::some(*handover_expiry),
        _ => option::none(),
    }
}

public(package) fun last_acq_price_opt<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): Option<u64> {
    match (s) {
        EngineState::AtDutch { last_acq_price, .. } => option::some(*last_acq_price),
        _ => option::none(),
    }
}

// ─── Pricing views ────────────────────────────────────────────────────────────

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    s:            &EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    match (s) {
        EngineState::Idle { .. } =>
            config::min_rent_price(config),
        EngineState::Rented { tenant, .. } => {
            let ps = price_state::ascending(tenant::stake_value(tenant));
            price_state::floor_price(&ps, config, timestamp_ms)
        },
        EngineState::HandoverPending { pending, .. } => {
            let ps = price_state::ascending(tenant::stake_value(pending));
            price_state::floor_price(&ps, config, timestamp_ms)
        },
        EngineState::AtDutch { last_acq_price, phase_start_ms, .. } => {
            let ps = price_state::descending(*last_acq_price, *phase_start_ms);
            price_state::floor_price(&ps, config, timestamp_ms)
        },
        EngineState::Retired { .. } => abort ERetiredNoBid,
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    s:            &EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    match (s) {
        EngineState::Rented { tenant, phase_start_ms, .. } => {
            let cs = credit_state::accruing(tenant::stake_value(tenant), *phase_start_ms);
            credit_state::used_credit(&cs, config, timestamp_ms)
        },
        EngineState::HandoverPending { current, phase_start_ms, handover_expiry, .. } => {
            let cs = credit_state::capped(
                tenant::stake_value(current), *phase_start_ms, *handover_expiry,
            );
            credit_state::used_credit(&cs, config, timestamp_ms)
        },
        _ => abort ENotRented,
    }
}

public(package) fun split_fee(amount: u64): (u64, u64) {
    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)
}

public(package) fun protocol_fee_bps(): u64 { PROTOCOL_FEE_BPS }
public(package) fun bps_denominator(): u64  { BPS_PER_UNIT }

// ─── Cap-authorization view ───────────────────────────────────────────────────

public(package) fun cap_authorization_state<Asset: key + store, CoinType>(
    s:      &EngineState<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    match (s) {
        EngineState::Rented { tenant, .. } => {
            if (cap_id == tenant::id_cap_id(tenant::identity(tenant))) cap_authorization_state::current()
            else cap_authorization_state::stale()
        },
        EngineState::HandoverPending { current, pending, .. } => {
            if (cap_id == tenant::id_cap_id(tenant::identity(current))) cap_authorization_state::current()
            else if (cap_id == tenant::id_cap_id(tenant::identity(pending))) cap_authorization_state::pending()
            else cap_authorization_state::stale()
        },
        _ => cap_authorization_state::stale(),
    }
}

// ─── APT and pending detection ────────────────────────────────────────────────

public(package) fun next_pending<Asset: key + store, CoinType>(
    s:      &EngineState<Asset, CoinType>,
    config: &IntegrationConfig,
    clock:  &Clock,
): Option<PendingTransitionState> {
    let now = clock::timestamp_ms(clock);
    match (s) {
        EngineState::HandoverPending { handover_expiry, .. } => {
            if (phases::has_passed(*handover_expiry, 0, now)) {
                return option::some(pending_transition_state::handover(*handover_expiry))
            };
            option::none()
        },
        EngineState::Rented { phase_start_ms, .. } => {
            let tenure = config::tenure_ceiling(config);
            if (phases::has_passed(*phase_start_ms, tenure, now)) {
                return option::some(
                    pending_transition_state::tenure(phases::boundary_at(*phase_start_ms, tenure))
                )
            };
            option::none()
        },
        EngineState::AtDutch { phase_start_ms, .. } => {
            let policy = config::descent(config);
            if (descent_policy_state::has_expired(policy, *phase_start_ms, now)) {
                return option::some(
                    pending_transition_state::auction(descent_policy_state::expiry_at(policy, *phase_start_ms))
                )
            };
            option::none()
        },
        EngineState::Idle { .. } | EngineState::Retired { .. } => option::none(),
    }
}

public(package) fun apply_pending_transition_states<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    clock:        &Clock,
    ctx:          &mut TxContext,
): EngineState<Asset, CoinType> {
    let mut current = state;
    let mut pending = next_pending(&current, config, clock);
    while (option::is_some(&pending)) {
        current = fire(current, config, escrow_id, fee_inbox_id, option::destroy_some(pending), ctx);
        pending = next_pending(&current, config, clock);
    };
    current
}

fun fire<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    t:            PendingTransitionState,
    ctx:          &mut TxContext,
): EngineState<Asset, CoinType> {
    // `next_pending` guarantees state↔transition pairing:
    //   HandoverPending → Handover, Rented → Tenure, AtDutch → Auction.
    // Match on state directly; boundary_ms from `t` is the only payload needed.
    let boundary_ms = pending_transition_state::boundary_ms(&t);
    match (state) {
        EngineState::HandoverPending {
            asset, current, pending, handover_expiry: _, phase_start_ms, retiring, owner
        } => do_handover(
            asset, current, pending, phase_start_ms, retiring, owner,
            config, escrow_id, fee_inbox_id, boundary_ms, ctx,
        ),
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner } =>
            do_tenure_expiry(
                asset, tenant, phase_start_ms, retiring, owner,
                escrow_id, fee_inbox_id, boundary_ms, ctx,
            ),
        EngineState::AtDutch { asset, last_acq_price, phase_start_ms, owner } =>
            do_auction_expiry(asset, last_acq_price, phase_start_ms, owner, escrow_id, boundary_ms),
        EngineState::Idle    { asset: _a, owner: _o } => abort ENotRented,
        EngineState::Retired { asset: _a, owner: _o } => abort ENotRented,
    }
}

// ─── Public action executors ──────────────────────────────────────────────────

public(package) fun execute_rent<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    payment:      Coin<CoinType>,
    clock:        &Clock,
    ctx:          &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    let state = apply_pending_transition_states(state, config, escrow_id, fee_inbox_id, clock, ctx);
    let now   = clock::timestamp_ms(clock);
    let floor = floor_price_at(&state, config, now);
    assert!(coin::value(&payment) >= floor, EInsufficientPayment);
    match (state) {
        EngineState::Idle { asset, owner } =>
            do_install(asset, owner, escrow_id, payment, floor, now, ctx),
        EngineState::AtDutch { asset, owner, .. } =>
            do_install(asset, owner, escrow_id, payment, floor, now, ctx),
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner } =>
            do_place_bid(
                asset, tenant, phase_start_ms, retiring, owner,
                config, escrow_id, payment, floor, now, ctx,
            ),
        EngineState::HandoverPending { asset, current, pending, handover_expiry, phase_start_ms, retiring, owner } =>
            do_supersede_bid(
                asset, current, pending, handover_expiry, phase_start_ms, retiring, owner,
                escrow_id, fee_inbox_id, payment, floor, now, ctx,
            ),
        EngineState::Retired { asset: _a, owner: _o } => abort ERetiredNoBid,
    }
}

public(package) fun execute_retire<Asset: key + store, CoinType>(
    state:            EngineState<Asset, CoinType>,
    config:           &IntegrationConfig,
    escrow_id:        ID,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
    clock:            &Clock,
    ctx:              &mut TxContext,
): EngineState<Asset, CoinType> {
    let state  = apply_pending_transition_states(state, config, escrow_id, fee_inbox_id, clock, ctx);
    let now_ms = clock::timestamp_ms(clock);
    assert!(
        retire_policy_state::is_unlocked(config::retire(config), integrated_at_ms, now_ms),
        ERetireFloorNotElapsed,
    );
    match (state) {
        EngineState::Retired { asset: _a, owner: _o } => abort EAlreadyRetired,
        EngineState::Idle    { asset, owner } =>
            do_retire_immediately(asset, owner, escrow_id, now_ms, ctx),
        EngineState::AtDutch { asset, owner, .. } =>
            do_retire_immediately(asset, owner, escrow_id, now_ms, ctx),
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner } => {
            assert!(!retiring, EAlreadyRetired);
            do_set_retiring_flag(asset, tenant, phase_start_ms, owner, escrow_id, now_ms, ctx)
        },
        EngineState::HandoverPending { asset, current, pending, handover_expiry, phase_start_ms, retiring, owner } => {
            assert!(!retiring, EAlreadyRetired);
            do_set_retiring_flag_hp(
                asset, current, pending, handover_expiry, phase_start_ms, owner,
                escrow_id, now_ms, ctx,
            )
        },
    }
}

public(package) fun execute_borrow<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    tenant_cap:   &TenantCap,
    clock:        &Clock,
    ctx:          &mut TxContext,
): (EngineState<Asset, CoinType>, Asset, AssetReceipt) {
    let state = apply_pending_transition_states(state, config, escrow_id, fee_inbox_id, clock, ctx);
    assert!(tenant_cap::escrow_id(tenant_cap) == escrow_id, EWrongEscrowTenantCap);
    let cap_id = object::id(tenant_cap);
    match (state) {
        EngineState::Rented { mut asset, tenant, phase_start_ms, retiring, owner } => {
            assert!(
                cap_id == tenant::id_cap_id(tenant::identity(&tenant)),
                EStaleTenantCap,
            );
            let tenant_addr = tenant::id_address(tenant::identity(&tenant));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });
            (EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner }, u, receipt)
        },
        EngineState::HandoverPending { mut asset, current, pending, handover_expiry, phase_start_ms, retiring, owner } => {
            if (cap_id == tenant::id_cap_id(tenant::identity(&pending))) { abort EPendingTenantCap };
            assert!(
                cap_id == tenant::id_cap_id(tenant::identity(&current)),
                EStaleTenantCap,
            );
            let tenant_addr = tenant::id_address(tenant::identity(&current));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });
            (
                EngineState::HandoverPending {
                    asset, current, pending, handover_expiry, phase_start_ms, retiring, owner
                },
                u,
                receipt,
            )
        },
        EngineState::Idle    { asset: _a, owner: _o }                                                  => abort EStaleTenantCap,
        EngineState::AtDutch { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }         => abort EStaleTenantCap,
        EngineState::Retired { asset: _a, owner: _o }                                                  => abort EStaleTenantCap,
    }
}

public(package) fun execute_return<Asset: key + store, CoinType>(
    state:      EngineState<Asset, CoinType>,
    escrow_id:  ID,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): EngineState<Asset, CoinType> {
    assert!(asset::receipt_escrow_id(&receipt_in)  == escrow_id,             EReceiptEscrowMismatch);
    assert!(asset::receipt_asset_id(&receipt_in)   == object::id(&asset_in), EReceiptAssetMismatch);
    match (state) {
        EngineState::Rented { mut asset, tenant, phase_start_ms, retiring, owner } => {
            let tenant_cap_id = tenant::id_cap_id(tenant::identity(&tenant));
            let tenant_addr   = tenant::id_address(tenant::identity(&tenant));
            asset::put(&mut asset, asset_in, receipt_in);
            event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });
            EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner }
        },
        EngineState::HandoverPending { mut asset, current, pending, handover_expiry, phase_start_ms, retiring, owner } => {
            let tenant_cap_id = tenant::id_cap_id(tenant::identity(&current));
            let tenant_addr   = tenant::id_address(tenant::identity(&current));
            asset::put(&mut asset, asset_in, receipt_in);
            event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });
            EngineState::HandoverPending { asset, current, pending, handover_expiry, phase_start_ms, retiring, owner }
        },
        EngineState::Idle    { asset: _a, owner: _o }                                                  => abort EReceiptEscrowMismatch,
        EngineState::AtDutch { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }         => abort EReceiptEscrowMismatch,
        EngineState::Retired { asset: _a, owner: _o }                                                  => abort EReceiptEscrowMismatch,
    }
}

public(package) fun execute_burn_tenant_cap<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    cap:          TenantCap,
    clock:        &Clock,
    ctx:          &mut TxContext,
): EngineState<Asset, CoinType> {
    let state = apply_pending_transition_states(state, config, escrow_id, fee_inbox_id, clock, ctx);
    match (state) {
        EngineState::Retired { asset, owner } => {
            tenant_cap::burn(cap, ctx);
            EngineState::Retired { asset, owner }
        },
        EngineState::Idle { asset, owner } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            tenant_cap::burn(cap, ctx);
            EngineState::Idle { asset, owner }
        },
        EngineState::AtDutch { asset, last_acq_price, phase_start_ms, owner } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            tenant_cap::burn(cap, ctx);
            EngineState::AtDutch { asset, last_acq_price, phase_start_ms, owner }
        },
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            let cap_id = object::id(&cap);
            assert!(
                cap_id != tenant::id_cap_id(tenant::identity(&tenant)),
                ETenantCapNotStale,
            );
            tenant_cap::burn(cap, ctx);
            EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner }
        },
        EngineState::HandoverPending { asset, current, pending, handover_expiry, phase_start_ms, retiring, owner } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            let cap_id = object::id(&cap);
            assert!(cap_id != tenant::id_cap_id(tenant::identity(&current)), ETenantCapNotStale);
            assert!(cap_id != tenant::id_cap_id(tenant::identity(&pending)), ETenantCapNotStale);
            tenant_cap::burn(cap, ctx);
            EngineState::HandoverPending { asset, current, pending, handover_expiry, phase_start_ms, retiring, owner }
        },
    }
}

public(package) fun execute_withdraw_earnings<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    owner_cap:    &OwnerCap,
    clock:        &Clock,
    ctx:          &mut TxContext,
): (EngineState<Asset, CoinType>, Coin<CoinType>) {
    let state        = apply_pending_transition_states(state, config, escrow_id, fee_inbox_id, clock, ctx);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();
    match (state) {
        EngineState::Idle { asset, mut owner } => {
            let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
            event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
            (EngineState::Idle { asset, owner }, coin)
        },
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, mut owner } => {
            let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
            event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
            (EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner }, coin)
        },
        EngineState::HandoverPending { asset, current, pending, handover_expiry, phase_start_ms, retiring, mut owner } => {
            let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
            event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
            (
                EngineState::HandoverPending {
                    asset, current, pending, handover_expiry, phase_start_ms, retiring, owner
                },
                coin,
            )
        },
        EngineState::AtDutch { asset, last_acq_price, phase_start_ms, mut owner } => {
            let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
            event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
            (EngineState::AtDutch { asset, last_acq_price, phase_start_ms, owner }, coin)
        },
        EngineState::Retired { asset, mut owner } => {
            let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
            event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
            (EngineState::Retired { asset, owner }, coin)
        },
    }
}

/// Terminal: consume a Retired engine and return (asset, residual earnings).
public(package) fun unwrap_for_claim<Asset: key + store, CoinType>(
    state:     EngineState<Asset, CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    match (state) {
        EngineState::Retired { asset, mut owner } => {
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            owner::destroy_empty(owner);
            (asset, coin)
        },
        EngineState::Idle    { asset: _a, owner: _o }                                                                                           => abort ENotRetired,
        EngineState::Rented  { asset: _a, tenant: _t, phase_start_ms: _p, retiring: _r, owner: _o }                                            => abort ENotRetired,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o } => abort ENotRetired,
        EngineState::AtDutch { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRetired,
    }
}

// === Private Functions ===

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
    owner:     Owner<CoinType>,
    escrow_id: ID,
    payment:   Coin<CoinType>,
    floor:     u64,
    now:       u64,
    ctx:       &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    let price_paid  = coin::value(&payment);
    let tenant_addr = ctx.sender();
    let (cap, cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, tenant_addr, coin::into_balance(payment));
    let wrapped = asset::new(asset, escrow_id);
    event::emit(RentStarted {
        escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr,
        phase_start_ms: now, price_paid, floor_price: floor,
    });
    (
        EngineState::Rented {
            asset: wrapped,
            tenant: t,
            phase_start_ms: now,
            retiring: false,
            owner,
        },
        cap,
    )
}

fun do_place_bid<Asset: key + store, CoinType>(
    asset:          asset::Asset<Asset>,
    tenant:         Tenant<CoinType>,
    phase_start_ms: u64,
    retiring:       bool,
    owner:          Owner<CoinType>,
    config:         &IntegrationConfig,
    escrow_id:      ID,
    payment:        Coin<CoinType>,
    floor:          u64,
    now:            u64,
    ctx:            &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    assert!(!retiring, ERetireFlagBlocksBid);
    let current_cap_id = tenant::id_cap_id(tenant::identity(&tenant));
    let current_addr   = tenant::id_address(tenant::identity(&tenant));
    let current_stake  = tenant::stake_value(&tenant);
    let tenure         = config::tenure_ceiling(config);
    let expiry         = handover_policy_state::expiry_at(
        config::handover(config), now, phase_start_ms, tenure,
    );
    let pending_addr = ctx.sender();
    let bid_amount   = coin::value(&payment);
    let (cap, cap_id) = tenant_cap::new(escrow_id, pending_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, pending_addr, coin::into_balance(payment));
    event::emit(BidPlaced {
        escrow_id,
        current_tenant_cap_id:     current_cap_id,
        current_tenant_addr:       current_addr,
        current_tenant_stake:      current_stake,
        current_phase_start_ms:    phase_start_ms,
        tenant_cap_id:             cap_id,
        pending_tenant:            pending_addr,
        bid_amount,
        floor_price:               floor,
        handover_countdown_expiry: expiry,
        timestamp_ms:              now,
    });
    (
        EngineState::HandoverPending {
            asset,
            current: tenant,
            pending: t,
            handover_expiry: expiry,
            phase_start_ms,
            retiring,
            owner,
        },
        cap,
    )
}

fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:           asset::Asset<Asset>,
    current:         Tenant<CoinType>,
    pending:         Tenant<CoinType>,
    handover_expiry: u64,
    phase_start_ms:  u64,
    retiring:        bool,
    mut owner:       Owner<CoinType>,
    escrow_id:       ID,
    fee_inbox_id:    ID,
    payment:         Coin<CoinType>,
    floor:           u64,
    now:             u64,
    ctx:             &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    let protected_cap_id      = tenant::id_cap_id(tenant::identity(&current));
    let protected_addr        = tenant::id_address(tenant::identity(&current));
    let protected_stake       = tenant::stake_value(&current);
    let displaced_cap_id      = tenant::id_cap_id(tenant::identity(&pending));
    let displaced_addr        = tenant::id_address(tenant::identity(&pending));
    let refunded_amount       = tenant::stake_value(&pending);

    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);
    let (cap, cap_id) = tenant_cap::new(escrow_id, new_bidder, ctx);
    let t = tenant::new<CoinType>(cap_id, new_bidder, coin::into_balance(payment));

    let (identity, stake) = tenant::unbundle(pending);
    let refund = refund_state::total(identity, stake);
    refund_state::distribute(refund, &mut owner, fee_inbox_id, ctx);

    event::emit(BidSuperseded {
        escrow_id,
        protected_tenant_cap_id:   protected_cap_id,
        protected_tenant_addr:     protected_addr,
        protected_tenant_stake:    protected_stake,
        protected_phase_start_ms:  phase_start_ms,
        displaced_tenant_cap_id:   displaced_cap_id,
        new_tenant_cap_id:         cap_id,
        displaced_bidder:          displaced_addr,
        refunded_amount,
        new_bidder,
        new_bid_amount,
        floor_price:               floor,
        handover_countdown_expiry: handover_expiry,
        timestamp_ms:              now,
    });
    (
        EngineState::HandoverPending {
            asset,
            current,
            pending: t,
            handover_expiry,
            phase_start_ms,
            retiring,
            owner,
        },
        cap,
    )
}

fun do_handover<Asset: key + store, CoinType>(
    asset:          asset::Asset<Asset>,
    current:        Tenant<CoinType>,
    pending:        Tenant<CoinType>,
    phase_start_ms: u64,
    retiring:       bool,
    mut owner:      Owner<CoinType>,
    config:         &IntegrationConfig,
    escrow_id:      ID,
    fee_inbox_id:   ID,
    boundary_ms:    u64,
    ctx:            &mut TxContext,
): EngineState<Asset, CoinType> {
    let principal     = tenant::stake_value(&current);
    let used_credit   = {
        let cs = credit_state::capped(principal, phase_start_ms, boundary_ms);
        credit_state::used_credit(&cs, config, boundary_ms)
    };
    let (owner_amount, fee_amount) = split_fee(used_credit);
    let remain_credit = principal - used_credit;

    let displaced_cap_id  = tenant::id_cap_id(tenant::identity(&current));
    let displaced_addr    = tenant::id_address(tenant::identity(&current));

    let mut departing = current;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, owner_amount);
    let fee_share      = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
    let refund = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, &mut owner, fee_inbox_id, ctx);

    let new_cap_id    = tenant::id_cap_id(tenant::identity(&pending));
    let new_addr      = tenant::id_address(tenant::identity(&pending));
    let new_stake     = tenant::stake_value(&pending);
    let new_rent_price = {
        let ps = price_state::ascending(new_stake);
        price_state::floor_price(&ps, config, boundary_ms)
    };

    event::emit(HandoverCompleted {
        escrow_id,
        displaced_tenant_cap_id:  displaced_cap_id,
        displaced_tenant:         displaced_addr,
        displaced_phase_start_ms: phase_start_ms,
        new_tenant_cap_id:        new_cap_id,
        new_tenant_addr:          new_addr,
        new_tenant_stake:         new_stake,
        used_credit,
        owner_share:              owner_amount,
        protocol_fee:             fee_amount,
        remain_credit,
        new_rent_price,
        timestamp_ms:             boundary_ms,
    });

    EngineState::Rented {
        asset,
        tenant: pending,
        phase_start_ms: boundary_ms,
        retiring,
        owner,
    }
}

fun do_tenure_expiry<Asset: key + store, CoinType>(
    asset:          asset::Asset<Asset>,
    tenant:         Tenant<CoinType>,
    phase_start_ms: u64,
    retiring:       bool,
    mut owner:      Owner<CoinType>,
    escrow_id:      ID,
    fee_inbox_id:   ID,
    boundary_ms:    u64,
    ctx:            &mut TxContext,
): EngineState<Asset, CoinType> {
    let principal      = tenant::stake_value(&tenant);
    let tenant_cap_id  = tenant::id_cap_id(tenant::identity(&tenant));
    let tenant_addr    = tenant::id_address(tenant::identity(&tenant));
    let (owner_amount, fee_amount) = split_fee(principal);

    let mut departing = tenant;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, owner_amount);
    let fee_share      = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
    let refund = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, &mut owner, fee_inbox_id, ctx);

    event::emit(TenureExpired {
        escrow_id,
        tenant_cap_id,
        tenant:                tenant_addr,
        phase_start_ms,
        owner_share:           owner_amount,
        protocol_fee:          fee_amount,
        last_acquisition_price: principal,
        timestamp_ms:          boundary_ms,
    });

    let raw_asset = asset::unbundle(asset);

    if (retiring) {
        event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
        EngineState::Retired { asset: raw_asset, owner }
    } else {
        EngineState::AtDutch {
            asset:          raw_asset,
            last_acq_price: principal,
            phase_start_ms: boundary_ms,
            owner,
        }
    }
}

fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:          Asset,
    last_acq_price: u64,
    phase_start_ms: u64,
    owner:          Owner<CoinType>,
    escrow_id:      ID,
    boundary_ms:    u64,
): EngineState<Asset, CoinType> {
    event::emit(AuctionExpired { escrow_id, phase_start_ms, last_acq_price, timestamp_ms: boundary_ms });
    EngineState::Idle { asset, owner }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:        Asset,
    owner:        Owner<CoinType>,
    escrow_id:    ID,
    timestamp_ms: u64,
    ctx:          &TxContext,
): EngineState<Asset, CoinType> {
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
    event::emit(AssetRetired  { escrow_id, timestamp_ms });
    EngineState::Retired { asset, owner }
}

fun do_set_retiring_flag<Asset: key + store, CoinType>(
    asset:          asset::Asset<Asset>,
    tenant:         Tenant<CoinType>,
    phase_start_ms: u64,
    owner:          Owner<CoinType>,
    escrow_id:      ID,
    timestamp_ms:   u64,
    ctx:            &TxContext,
): EngineState<Asset, CoinType> {
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
    EngineState::Rented { asset, tenant, phase_start_ms, retiring: true, owner }
}

fun do_set_retiring_flag_hp<Asset: key + store, CoinType>(
    asset:           asset::Asset<Asset>,
    current:         Tenant<CoinType>,
    pending:         Tenant<CoinType>,
    handover_expiry: u64,
    phase_start_ms:  u64,
    owner:           Owner<CoinType>,
    escrow_id:       ID,
    timestamp_ms:    u64,
    ctx:             &TxContext,
): EngineState<Asset, CoinType> {
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
    EngineState::HandoverPending {
        asset, current, pending, handover_expiry, phase_start_ms, retiring: true, owner
    }
}

// === Test Functions ===

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    split_fee(amount)
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    boundary_ms:  u64,
    ctx:          &mut TxContext,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::HandoverPending {
            asset, current, pending, handover_expiry: _, phase_start_ms, retiring, owner
        } => do_handover(asset, current, pending, phase_start_ms, retiring, owner, config, escrow_id, fee_inbox_id, boundary_ms, ctx),
        EngineState::Idle    { asset: _a, owner: _o }                                                                                           => abort ENotRented,
        EngineState::Rented  { asset: _a, tenant: _t, phase_start_ms: _p, retiring: _r, owner: _o }                                            => abort ENotRented,
        EngineState::AtDutch { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    escrow_id:    ID,
    fee_inbox_id: ID,
    boundary_ms:  u64,
    ctx:          &mut TxContext,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner } =>
            do_tenure_expiry(asset, tenant, phase_start_ms, retiring, owner, escrow_id, fee_inbox_id, boundary_ms, ctx),
        EngineState::Idle            { asset: _a, owner: _o }                                                                                           => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::AtDutch         { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    escrow_id:   ID,
    boundary_ms: u64,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::AtDutch { asset, last_acq_price, phase_start_ms, owner } =>
            do_auction_expiry(asset, last_acq_price, phase_start_ms, owner, escrow_id, boundary_ms),
        EngineState::Idle            { asset: _a, owner: _o }                                                                                           => abort ENotRented,
        EngineState::Rented          { asset: _a, tenant: _t, phase_start_ms: _p, retiring: _r, owner: _o }                                            => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    state:          EngineState<Asset, CoinType>,
    tenant_in:      Tenant<CoinType>,
    phase_start_ms: u64,
    escrow_id:      ID,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Idle { asset, owner } => EngineState::Rented {
            asset:    asset::new(asset, escrow_id),
            tenant:   tenant_in,
            phase_start_ms,
            retiring: false,
            owner,
        },
        EngineState::Rented          { asset: _a, tenant: _t, phase_start_ms: _p, retiring: _r, owner: _o }                                            => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::AtDutch         { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    state:                     EngineState<Asset, CoinType>,
    tenant_in:                 Tenant<CoinType>,
    handover_countdown_expiry: u64,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Rented { asset, tenant, phase_start_ms, retiring, owner } =>
            EngineState::HandoverPending {
                asset,
                current:         tenant,
                pending:         tenant_in,
                handover_expiry: handover_countdown_expiry,
                phase_start_ms,
                retiring,
                owner,
            },
        EngineState::Idle            { asset: _a, owner: _o }                                                                                           => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::AtDutch         { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    state:              EngineState<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
    escrow_id:          ID,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Rented { asset, mut tenant, phase_start_ms: _p, retiring: _r, owner } => {
            let owner_earnings = tenant::take_owner_earnings(&mut tenant, owner_amount);
            let fee_share      = tenant::take_fee_share(&mut tenant, fee_amount, escrow_id);
            let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
            refund_state::destroy_for_testing(refund);
            let raw_asset = asset::unbundle(asset);
            EngineState::AtDutch {
                asset: raw_asset,
                last_acq_price,
                phase_start_ms: new_phase_start_ms,
                owner,
            }
        },
        EngineState::Idle            { asset: _a, owner: _o }                                                                                           => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::AtDutch         { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Idle { asset, owner } => EngineState::Retired { asset, owner },
        EngineState::Rented          { asset: _a, tenant: _t, phase_start_ms: _p, retiring: _r, owner: _o }                                            => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::AtDutch         { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Rented { asset, tenant, phase_start_ms, retiring: _, owner } =>
            EngineState::Rented { asset, tenant, phase_start_ms, retiring: true, owner },
        EngineState::Idle            { asset: _a, owner: _o }                                                                                           => abort ENotRented,
        EngineState::HandoverPending { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r, owner: _o }         => abort ENotRented,
        EngineState::AtDutch         { asset: _a, last_acq_price: _l, phase_start_ms: _p, owner: _o }                                                  => abort ENotRented,
        EngineState::Retired         { asset: _a, owner: _o }                                                                                           => abort ENotRented,
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
public(package) fun bid_placed_escrow_id(e: &BidPlaced): ID                      { e.escrow_id }
#[test_only]
public(package) fun bid_placed_current_tenant_cap_id(e: &BidPlaced): ID          { e.current_tenant_cap_id }
#[test_only]
public(package) fun bid_placed_current_tenant_addr(e: &BidPlaced): address       { e.current_tenant_addr }
#[test_only]
public(package) fun bid_placed_current_tenant_stake(e: &BidPlaced): u64          { e.current_tenant_stake }
#[test_only]
public(package) fun bid_placed_current_phase_start_ms(e: &BidPlaced): u64        { e.current_phase_start_ms }
#[test_only]
public(package) fun bid_placed_tenant_cap_id(e: &BidPlaced): ID                  { e.tenant_cap_id }
#[test_only]
public(package) fun bid_placed_pending_tenant(e: &BidPlaced): address            { e.pending_tenant }
#[test_only]
public(package) fun bid_placed_bid_amount(e: &BidPlaced): u64                    { e.bid_amount }
#[test_only]
public(package) fun bid_placed_floor_price(e: &BidPlaced): u64                   { e.floor_price }
#[test_only]
public(package) fun bid_placed_handover_countdown_expiry(e: &BidPlaced): u64     { e.handover_countdown_expiry }
#[test_only]
public(package) fun bid_placed_timestamp_ms(e: &BidPlaced): u64                  { e.timestamp_ms }

#[test_only]
public(package) fun bid_superseded_escrow_id(e: &BidSuperseded): ID                  { e.escrow_id }
#[test_only]
public(package) fun bid_superseded_protected_cap_id(e: &BidSuperseded): ID           { e.protected_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_protected_addr(e: &BidSuperseded): address        { e.protected_tenant_addr }
#[test_only]
public(package) fun bid_superseded_protected_stake(e: &BidSuperseded): u64           { e.protected_tenant_stake }
#[test_only]
public(package) fun bid_superseded_protected_phase_start_ms(e: &BidSuperseded): u64  { e.protected_phase_start_ms }
#[test_only]
public(package) fun bid_superseded_displaced_cap_id(e: &BidSuperseded): ID           { e.displaced_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_new_cap_id(e: &BidSuperseded): ID                 { e.new_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_displaced_bidder(e: &BidSuperseded): address      { e.displaced_bidder }
#[test_only]
public(package) fun bid_superseded_refunded_amount(e: &BidSuperseded): u64           { e.refunded_amount }
#[test_only]
public(package) fun bid_superseded_new_bidder(e: &BidSuperseded): address            { e.new_bidder }
#[test_only]
public(package) fun bid_superseded_new_bid_amount(e: &BidSuperseded): u64            { e.new_bid_amount }
#[test_only]
public(package) fun bid_superseded_floor_price(e: &BidSuperseded): u64               { e.floor_price }
#[test_only]
public(package) fun bid_superseded_handover_countdown_expiry(e: &BidSuperseded): u64 { e.handover_countdown_expiry }
#[test_only]
public(package) fun bid_superseded_timestamp_ms(e: &BidSuperseded): u64              { e.timestamp_ms }

#[test_only]
public(package) fun handover_completed_escrow_id(e: &HandoverCompleted): ID                  { e.escrow_id }
#[test_only]
public(package) fun handover_completed_displaced_cap_id(e: &HandoverCompleted): ID           { e.displaced_tenant_cap_id }
#[test_only]
public(package) fun handover_completed_displaced_tenant(e: &HandoverCompleted): address      { e.displaced_tenant }
#[test_only]
public(package) fun handover_completed_displaced_phase_start_ms(e: &HandoverCompleted): u64  { e.displaced_phase_start_ms }
#[test_only]
public(package) fun handover_completed_new_cap_id(e: &HandoverCompleted): ID                 { e.new_tenant_cap_id }
#[test_only]
public(package) fun handover_completed_new_addr(e: &HandoverCompleted): address              { e.new_tenant_addr }
#[test_only]
public(package) fun handover_completed_new_stake(e: &HandoverCompleted): u64                 { e.new_tenant_stake }
#[test_only]
public(package) fun handover_completed_used_credit(e: &HandoverCompleted): u64               { e.used_credit }
#[test_only]
public(package) fun handover_completed_owner_share(e: &HandoverCompleted): u64               { e.owner_share }
#[test_only]
public(package) fun handover_completed_protocol_fee(e: &HandoverCompleted): u64              { e.protocol_fee }
#[test_only]
public(package) fun handover_completed_remain_credit(e: &HandoverCompleted): u64             { e.remain_credit }
#[test_only]
public(package) fun handover_completed_new_rent_price(e: &HandoverCompleted): u64            { e.new_rent_price }
#[test_only]
public(package) fun handover_completed_timestamp_ms(e: &HandoverCompleted): u64              { e.timestamp_ms }

#[test_only]
public(package) fun tenure_expired_escrow_id(e: &TenureExpired): ID                  { e.escrow_id }
#[test_only]
public(package) fun tenure_expired_tenant_cap_id(e: &TenureExpired): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun tenure_expired_tenant(e: &TenureExpired): address                { e.tenant }
#[test_only]
public(package) fun tenure_expired_phase_start_ms(e: &TenureExpired): u64            { e.phase_start_ms }
#[test_only]
public(package) fun tenure_expired_owner_share(e: &TenureExpired): u64               { e.owner_share }
#[test_only]
public(package) fun tenure_expired_protocol_fee(e: &TenureExpired): u64              { e.protocol_fee }
#[test_only]
public(package) fun tenure_expired_last_acquisition_price(e: &TenureExpired): u64    { e.last_acquisition_price }
#[test_only]
public(package) fun tenure_expired_last_acq_price(e: &TenureExpired): u64            { e.last_acquisition_price }
#[test_only]
public(package) fun tenure_expired_timestamp_ms(e: &TenureExpired): u64              { e.timestamp_ms }

#[test_only]
public(package) fun auction_expired_escrow_id(e: &AuctionExpired): ID                { e.escrow_id }
#[test_only]
public(package) fun auction_expired_phase_start_ms(e: &AuctionExpired): u64          { e.phase_start_ms }
#[test_only]
public(package) fun auction_expired_last_acq_price(e: &AuctionExpired): u64          { e.last_acq_price }
#[test_only]
public(package) fun auction_expired_timestamp_ms(e: &AuctionExpired): u64            { e.timestamp_ms }

#[test_only]
public(package) fun retire_flag_set_escrow_id(e: &RetireFlagSet): ID                 { e.escrow_id }
#[test_only]
public(package) fun retire_flag_set_owner(e: &RetireFlagSet): address                { e.owner }
#[test_only]
public(package) fun retire_flag_set_timestamp_ms(e: &RetireFlagSet): u64             { e.timestamp_ms }

#[test_only]
public(package) fun asset_retired_escrow_id(e: &AssetRetired): ID                    { e.escrow_id }
#[test_only]
public(package) fun asset_retired_timestamp_ms(e: &AssetRetired): u64                { e.timestamp_ms }

#[test_only]
public(package) fun asset_borrowed_escrow_id(e: &AssetBorrowed): ID                  { e.escrow_id }
#[test_only]
public(package) fun asset_borrowed_tenant_cap_id(e: &AssetBorrowed): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun asset_borrowed_tenant(e: &AssetBorrowed): address                { e.tenant }

#[test_only]
public(package) fun asset_returned_escrow_id(e: &AssetReturned): ID                  { e.escrow_id }
#[test_only]
public(package) fun asset_returned_tenant_cap_id(e: &AssetReturned): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun asset_returned_tenant(e: &AssetReturned): address                { e.tenant }

#[test_only]
public(package) fun earnings_withdrawn_escrow_id(e: &EarningsWithdrawn): ID          { e.escrow_id }
#[test_only]
public(package) fun earnings_withdrawn_owner_cap_id(e: &EarningsWithdrawn): ID       { e.owner_cap_id }
#[test_only]
public(package) fun earnings_withdrawn_owner(e: &EarningsWithdrawn): address         { e.owner }
#[test_only]
public(package) fun earnings_withdrawn_amount(e: &EarningsWithdrawn): u64            { e.amount }
#[test_only]
public(package) fun earnings_withdrawn_timestamp_ms(e: &EarningsWithdrawn): u64      { e.timestamp_ms }
