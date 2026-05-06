// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Two-variant renting sub-machine: Occupied (single active tenant) and
/// Demand (active tenant + pending bidder). Embedded in EngineState::Renting.
///
/// All tenancy-internal transitions, events, and views live here. Outer
/// transitions (install, tenure expiry, auction expiry, retire) belong to
/// engine_state.move.
module usufruct::tenancy_state;

// === Imports ===

use sui::{
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::{Self, AssetReceipt},
    cap_authorization_state::{Self, CapAuthorizationState},
    config::{Self, IntegrationConfig},
    credit_state,
    handover_policy_state,
    math,
    owner::Owner,
    pending_transition_state::{Self, PendingTransitionState},
    phases,
    price_state,
    refund_state,
    tenant::{Self, Tenant},
    tenant_cap::{Self, TenantCap},
};

// === Errors ===

const ERetireFlagBlocksBid: u64 = 2;
const EPendingTenantCap:    u64 = 7;
const EStaleTenantCap:      u64 = 8;
const ETenantCapNotStale:   u64 = 9;

// === Constants ===

const PROTOCOL_FEE_BPS: u64 = 1_000;
const BPS_PER_UNIT:     u64 = 10_000;

// === Structs ===

/// Two-variant sub-machine embedded in EngineState::Renting.
///
///   · Occupied — single active tenant. Asset may be borrowed.
///   · Demand   — active tenant + pending bidder. Handover countdown running.
public enum TenancyState<Asset: key + store, phantom CoinType> has store {
    Occupied {
        asset:          asset::Asset<Asset>,
        tenant:         Tenant<CoinType>,
        phase_start_ms: u64,
        retiring:       bool,
    },
    Demand {
        asset:           asset::Asset<Asset>,
        current:         Tenant<CoinType>,
        pending:         Tenant<CoinType>,
        handover_expiry: u64,
        phase_start_ms:  u64,
        retiring:        bool,
    },
}

// === Events ===

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
    escrow_id:              ID,
    tenant_cap_id:          ID,
    tenant:                 address,
    phase_start_ms:         u64,
    owner_share:            u64,
    protocol_fee:           u64,
    last_acquisition_price: u64,
    timestamp_ms:           u64,
}

public struct RetireFlagSet has copy, drop {
    escrow_id:    ID,
    owner:        address,
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

// === Public Functions ===

// ─── Fee helpers ──────────────────────────────────────────────────────────────

public(package) fun split_fee(amount: u64): (u64, u64) {
    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)
}

public(package) fun protocol_fee_bps(): u64 { PROTOCOL_FEE_BPS }
public(package) fun bps_denominator():  u64 { BPS_PER_UNIT }

// ─── Constructor ──────────────────────────────────────────────────────────────

public(package) fun new_occupied<Asset: key + store, CoinType>(
    asset:          asset::Asset<Asset>,
    tenant:         Tenant<CoinType>,
    phase_start_ms: u64,
): TenancyState<Asset, CoinType> {
    TenancyState::Occupied { asset, tenant, phase_start_ms, retiring: false }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_occupied<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): bool {
    match (t) { TenancyState::Occupied { .. } => true, _ => false }
}

public(package) fun is_demand<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): bool {
    match (t) { TenancyState::Demand { .. } => true, _ => false }
}

public(package) fun is_retiring<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): bool {
    match (t) {
        TenancyState::Occupied { retiring, .. } => *retiring,
        TenancyState::Demand   { retiring, .. } => *retiring,
    }
}

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun asset_id<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): ID {
    match (t) {
        TenancyState::Occupied { asset, .. } => asset::id_asset_id(asset::identity(asset)),
        TenancyState::Demand   { asset, .. } => asset::id_asset_id(asset::identity(asset)),
    }
}

public(package) fun current_addr<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): address {
    match (t) {
        TenancyState::Occupied { tenant,  .. } => tenant::id_address(tenant::identity(tenant)),
        TenancyState::Demand   { current, .. } => tenant::id_address(tenant::identity(current)),
    }
}

public(package) fun current_cap_id<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): ID {
    match (t) {
        TenancyState::Occupied { tenant,  .. } => tenant::id_cap_id(tenant::identity(tenant)),
        TenancyState::Demand   { current, .. } => tenant::id_cap_id(tenant::identity(current)),
    }
}

public(package) fun pending_addr_opt<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): Option<address> {
    match (t) {
        TenancyState::Demand   { pending, .. } => option::some(tenant::id_address(tenant::identity(pending))),
        TenancyState::Occupied { .. }          => option::none(),
    }
}

public(package) fun pending_cap_id_opt<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): Option<ID> {
    match (t) {
        TenancyState::Demand   { pending, .. } => option::some(tenant::id_cap_id(tenant::identity(pending))),
        TenancyState::Occupied { .. }          => option::none(),
    }
}

public(package) fun current_stake<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): u64 {
    match (t) {
        TenancyState::Occupied { tenant,  .. } => tenant::stake_value(tenant),
        TenancyState::Demand   { current, .. } => tenant::stake_value(current),
    }
}

public(package) fun pending_stake_opt<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): Option<u64> {
    match (t) {
        TenancyState::Demand   { pending, .. } => option::some(tenant::stake_value(pending)),
        TenancyState::Occupied { .. }          => option::none(),
    }
}

public(package) fun phase_start_ms<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): u64 {
    match (t) {
        TenancyState::Occupied { phase_start_ms, .. } => *phase_start_ms,
        TenancyState::Demand   { phase_start_ms, .. } => *phase_start_ms,
    }
}

public(package) fun handover_expiry_opt<Asset: key + store, CoinType>(
    t: &TenancyState<Asset, CoinType>,
): Option<u64> {
    match (t) {
        TenancyState::Demand   { handover_expiry, .. } => option::some(*handover_expiry),
        TenancyState::Occupied { .. }                  => option::none(),
    }
}

// ─── Pricing / credit views ───────────────────────────────────────────────────

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    t:            &TenancyState<Asset, CoinType>,
    config:       &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    match (t) {
        TenancyState::Occupied { tenant, .. } => {
            let ps = price_state::ascending(tenant::stake_value(tenant));
            price_state::floor_price(&ps, config, timestamp_ms)
        },
        TenancyState::Demand { pending, .. } => {
            let ps = price_state::ascending(tenant::stake_value(pending));
            price_state::floor_price(&ps, config, timestamp_ms)
        },
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    t:            &TenancyState<Asset, CoinType>,
    config:       &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    match (t) {
        TenancyState::Occupied { tenant, phase_start_ms, .. } => {
            let cs = credit_state::accruing(tenant::stake_value(tenant), *phase_start_ms);
            credit_state::used_credit(&cs, config, timestamp_ms)
        },
        TenancyState::Demand { current, phase_start_ms, handover_expiry, .. } => {
            let cs = credit_state::capped(
                tenant::stake_value(current), *phase_start_ms, *handover_expiry,
            );
            credit_state::used_credit(&cs, config, timestamp_ms)
        },
    }
}

// ─── Cap authorization view ───────────────────────────────────────────────────

public(package) fun cap_authorization_state<Asset: key + store, CoinType>(
    t:      &TenancyState<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    match (t) {
        TenancyState::Occupied { tenant, .. } => {
            if (cap_id == tenant::id_cap_id(tenant::identity(tenant))) cap_authorization_state::current()
            else cap_authorization_state::stale()
        },
        TenancyState::Demand { current, pending, .. } => {
            if      (cap_id == tenant::id_cap_id(tenant::identity(current))) cap_authorization_state::current()
            else if (cap_id == tenant::id_cap_id(tenant::identity(pending))) cap_authorization_state::pending()
            else cap_authorization_state::stale()
        },
    }
}

// ─── APT pending detection ────────────────────────────────────────────────────

public(package) fun next_pending_from_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyState<Asset, CoinType>,
    config: &IntegrationConfig,
    now:    u64,
): Option<PendingTransitionState> {
    match (t) {
        TenancyState::Demand { handover_expiry, .. } => {
            if (phases::has_passed(*handover_expiry, 0, now)) {
                return option::some(pending_transition_state::handover(*handover_expiry))
            };
            option::none()
        },
        TenancyState::Occupied { phase_start_ms, .. } => {
            let tenure = config::tenure_ceiling(config);
            if (phases::has_passed(*phase_start_ms, tenure, now)) {
                return option::some(
                    pending_transition_state::tenure(phases::boundary_at(*phase_start_ms, tenure))
                )
            };
            option::none()
        },
    }
}

// ─── Tenancy-internal transitions ─────────────────────────────────────────────

/// Dispatch a rent payment: Occupied → Demand (place_bid) or Demand → Demand
/// (supersede_bid). Owner receives the displaced bidder's refund only in the
/// supersede path; passes through unchanged for a fresh bid.
public(package) fun accept_rent_payment<Asset: key + store, CoinType>(
    tenancy:      TenancyState<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    payment:      Coin<CoinType>,
    floor:        u64,
    now:          u64,
    ctx:          &mut TxContext,
): (TenancyState<Asset, CoinType>, TenantCap) {
    match (tenancy) {
        TenancyState::Occupied { asset, tenant, phase_start_ms, retiring } =>
            do_place_bid(asset, tenant, phase_start_ms, retiring, config, escrow_id, payment, floor, now, ctx),
        TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring } =>
            do_supersede_bid(
                asset, current, pending, handover_expiry, phase_start_ms, retiring,
                owner, escrow_id, fee_inbox_id, payment, floor, now, ctx,
            ),
    }
}

/// Demand → Occupied: fire the handover transition at `boundary_ms`.
/// Distributes used credit to owner; retiring flag propagates to new Occupied.
public(package) fun do_handover<Asset: key + store, CoinType>(
    tenancy:      TenancyState<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    boundary_ms:  u64,
    ctx:          &mut TxContext,
): TenancyState<Asset, CoinType> {
    match (tenancy) {
        TenancyState::Demand { asset, current, pending, handover_expiry: _, phase_start_ms, retiring } => {
            let principal   = tenant::stake_value(&current);
            let used_credit = {
                let cs = credit_state::capped(principal, phase_start_ms, boundary_ms);
                credit_state::used_credit(&cs, config, boundary_ms)
            };
            let (owner_amount, fee_amount) = split_fee(used_credit);
            let remain_credit = principal - used_credit;

            let displaced_cap_id = tenant::id_cap_id(tenant::identity(&current));
            let displaced_addr   = tenant::id_address(tenant::identity(&current));

            let mut departing  = current;
            let owner_earnings = tenant::take_owner_earnings(&mut departing, owner_amount);
            let fee_share      = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
            let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
            refund_state::distribute(refund, owner, fee_inbox_id, ctx);

            let new_cap_id     = tenant::id_cap_id(tenant::identity(&pending));
            let new_addr       = tenant::id_address(tenant::identity(&pending));
            let new_stake      = tenant::stake_value(&pending);
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

            TenancyState::Occupied {
                asset,
                tenant:         pending,
                phase_start_ms: boundary_ms,
                retiring,
            }
        },
        TenancyState::Occupied { asset: _a, tenant: _t, phase_start_ms: _p, retiring: _r } =>
            abort 0,
    }
}

/// Consume an Occupied tenancy at tenure expiry. Distributes full stake to
/// owner/protocol. Returns (wrapped_asset, last_acq_price, retiring_flag).
public(package) fun do_tenure_expiry<Asset: key + store, CoinType>(
    tenancy:      TenancyState<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    escrow_id:    ID,
    fee_inbox_id: ID,
    boundary_ms:  u64,
    ctx:          &mut TxContext,
): (asset::Asset<Asset>, u64, bool) {
    match (tenancy) {
        TenancyState::Occupied { asset, tenant, phase_start_ms, retiring } => {
            let principal      = tenant::stake_value(&tenant);
            let tenant_cap_id  = tenant::id_cap_id(tenant::identity(&tenant));
            let tenant_addr    = tenant::id_address(tenant::identity(&tenant));
            let (owner_amount, fee_amount) = split_fee(principal);

            let mut departing  = tenant;
            let owner_earnings = tenant::take_owner_earnings(&mut departing, owner_amount);
            let fee_share      = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
            let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
            refund_state::distribute(refund, owner, fee_inbox_id, ctx);

            event::emit(TenureExpired {
                escrow_id,
                tenant_cap_id,
                tenant:                 tenant_addr,
                phase_start_ms,
                owner_share:            owner_amount,
                protocol_fee:           fee_amount,
                last_acquisition_price: principal,
                timestamp_ms:           boundary_ms,
            });

            (asset, principal, retiring)
        },
        TenancyState::Demand { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r } =>
            abort 0,
    }
}

/// Set the retiring flag on the current tenancy (Occupied or Demand).
/// Emits RetireFlagSet.
public(package) fun set_retiring_flag<Asset: key + store, CoinType>(
    tenancy:      TenancyState<Asset, CoinType>,
    escrow_id:    ID,
    timestamp_ms: u64,
    ctx:          &TxContext,
): TenancyState<Asset, CoinType> {
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
    match (tenancy) {
        TenancyState::Occupied { asset, tenant, phase_start_ms, retiring: _ } =>
            TenancyState::Occupied { asset, tenant, phase_start_ms, retiring: true },
        TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring: _ } =>
            TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring: true },
    }
}

/// Borrow the underlying asset. Aborts if `cap_id` is stale or pending.
public(package) fun take_asset<Asset: key + store, CoinType>(
    tenancy:   TenancyState<Asset, CoinType>,
    escrow_id: ID,
    cap_id:    ID,
): (TenancyState<Asset, CoinType>, Asset, AssetReceipt) {
    match (tenancy) {
        TenancyState::Occupied { mut asset, tenant, phase_start_ms, retiring } => {
            assert!(cap_id == tenant::id_cap_id(tenant::identity(&tenant)), EStaleTenantCap);
            let tenant_addr = tenant::id_address(tenant::identity(&tenant));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });
            (TenancyState::Occupied { asset, tenant, phase_start_ms, retiring }, u, receipt)
        },
        TenancyState::Demand { mut asset, current, pending, handover_expiry, phase_start_ms, retiring } => {
            if (cap_id == tenant::id_cap_id(tenant::identity(&pending))) { abort EPendingTenantCap };
            assert!(cap_id == tenant::id_cap_id(tenant::identity(&current)), EStaleTenantCap);
            let tenant_addr = tenant::id_address(tenant::identity(&current));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });
            (
                TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring },
                u,
                receipt,
            )
        },
    }
}

/// Return the borrowed asset.
public(package) fun put_asset<Asset: key + store, CoinType>(
    tenancy:    TenancyState<Asset, CoinType>,
    escrow_id:  ID,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): TenancyState<Asset, CoinType> {
    match (tenancy) {
        TenancyState::Occupied { mut asset, tenant, phase_start_ms, retiring } => {
            let tenant_cap_id = tenant::id_cap_id(tenant::identity(&tenant));
            let tenant_addr   = tenant::id_address(tenant::identity(&tenant));
            asset::put(&mut asset, asset_in, receipt_in);
            event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });
            TenancyState::Occupied { asset, tenant, phase_start_ms, retiring }
        },
        TenancyState::Demand { mut asset, current, pending, handover_expiry, phase_start_ms, retiring } => {
            let tenant_cap_id = tenant::id_cap_id(tenant::identity(&current));
            let tenant_addr   = tenant::id_address(tenant::identity(&current));
            asset::put(&mut asset, asset_in, receipt_in);
            event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });
            TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring }
        },
    }
}

/// Assert that `cap_id` is neither the current nor pending cap (safe to burn).
public(package) fun assert_cap_stale<Asset: key + store, CoinType>(
    t:      &TenancyState<Asset, CoinType>,
    cap_id: ID,
) {
    match (t) {
        TenancyState::Occupied { tenant, .. } =>
            assert!(cap_id != tenant::id_cap_id(tenant::identity(tenant)), ETenantCapNotStale),
        TenancyState::Demand { current, pending, .. } => {
            assert!(cap_id != tenant::id_cap_id(tenant::identity(current)), ETenantCapNotStale);
            assert!(cap_id != tenant::id_cap_id(tenant::identity(pending)), ETenantCapNotStale);
        },
    }
}

// === Private Functions ===

/// Occupied → Demand.
fun do_place_bid<Asset: key + store, CoinType>(
    asset:          asset::Asset<Asset>,
    tenant:         Tenant<CoinType>,
    phase_start_ms: u64,
    retiring:       bool,
    config:         &IntegrationConfig,
    escrow_id:      ID,
    payment:        Coin<CoinType>,
    floor:          u64,
    now:            u64,
    ctx:            &mut TxContext,
): (TenancyState<Asset, CoinType>, TenantCap) {
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
        TenancyState::Demand {
            asset,
            current:         tenant,
            pending:         t,
            handover_expiry: expiry,
            phase_start_ms,
            retiring,
        },
        cap,
    )
}

/// Demand → Demand: displace the existing pending bidder.
fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:           asset::Asset<Asset>,
    current:         Tenant<CoinType>,
    pending:         Tenant<CoinType>,
    handover_expiry: u64,
    phase_start_ms:  u64,
    retiring:        bool,
    owner:           &mut Owner<CoinType>,
    escrow_id:       ID,
    fee_inbox_id:    ID,
    payment:         Coin<CoinType>,
    floor:           u64,
    now:             u64,
    ctx:             &mut TxContext,
): (TenancyState<Asset, CoinType>, TenantCap) {
    let protected_cap_id = tenant::id_cap_id(tenant::identity(&current));
    let protected_addr   = tenant::id_address(tenant::identity(&current));
    let protected_stake  = tenant::stake_value(&current);
    let displaced_cap_id = tenant::id_cap_id(tenant::identity(&pending));
    let displaced_addr   = tenant::id_address(tenant::identity(&pending));
    let refunded_amount  = tenant::stake_value(&pending);

    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);
    let (cap, cap_id)  = tenant_cap::new(escrow_id, new_bidder, ctx);
    let t = tenant::new<CoinType>(cap_id, new_bidder, coin::into_balance(payment));

    let (identity, stake) = tenant::unbundle(pending);
    let refund = refund_state::total(identity, stake);
    refund_state::distribute(refund, owner, fee_inbox_id, ctx);

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
        TenancyState::Demand {
            asset,
            current,
            pending: t,
            handover_expiry,
            phase_start_ms,
            retiring,
        },
        cap,
    )
}

// === Test Functions ===

/// Emit RetireFlagSet on behalf of engine_state (Idle/AtDutch retire path).
/// Keeps the event struct and its construction in one module.
public(package) fun emit_retire_flag_set(escrow_id: ID, owner: address, timestamp_ms: u64) {
    event::emit(RetireFlagSet { escrow_id, owner, timestamp_ms });
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    split_fee(amount)
}

#[test_only]
public(package) fun set_retiring_flag_for_testing<Asset: key + store, CoinType>(
    tenancy: TenancyState<Asset, CoinType>,
): TenancyState<Asset, CoinType> {
    match (tenancy) {
        TenancyState::Occupied { asset, tenant, phase_start_ms, retiring: _ } =>
            TenancyState::Occupied { asset, tenant, phase_start_ms, retiring: true },
        TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring: _ } =>
            TenancyState::Demand { asset, current, pending, handover_expiry, phase_start_ms, retiring: true },
    }
}

/// Drive Occupied → Demand for testing (without full bid mechanics).
#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    tenancy:                   TenancyState<Asset, CoinType>,
    tenant_in:                 Tenant<CoinType>,
    handover_countdown_expiry: u64,
): TenancyState<Asset, CoinType> {
    match (tenancy) {
        TenancyState::Occupied { asset, tenant, phase_start_ms, retiring } =>
            TenancyState::Demand {
                asset,
                current:         tenant,
                pending:         tenant_in,
                handover_expiry: handover_countdown_expiry,
                phase_start_ms,
                retiring,
            },
        TenancyState::Demand { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r } =>
            abort 0,
    }
}

/// Consume an Occupied tenancy for test state driving. Discards tenant funds.
#[test_only]
public(package) fun unbundle_occupied_for_testing<Asset: key + store, CoinType>(
    tenancy:      TenancyState<Asset, CoinType>,
    owner_amount: u64,
    fee_amount:   u64,
    escrow_id:    ID,
): asset::Asset<Asset> {
    match (tenancy) {
        TenancyState::Occupied { asset, mut tenant, phase_start_ms: _, retiring: _ } => {
            let owner_earnings = tenant::take_owner_earnings(&mut tenant, owner_amount);
            let fee_share      = tenant::take_fee_share(&mut tenant, fee_amount, escrow_id);
            let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
            refund_state::destroy_for_testing(refund);
            asset
        },
        TenancyState::Demand { asset: _a, current: _c, pending: _p, handover_expiry: _e, phase_start_ms: _s, retiring: _r } =>
            abort 0,
    }
}

// ─── Test-only event accessors ────────────────────────────────────────────────

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
public(package) fun retire_flag_set_escrow_id(e: &RetireFlagSet): ID                 { e.escrow_id }
#[test_only]
public(package) fun retire_flag_set_owner(e: &RetireFlagSet): address                { e.owner }
#[test_only]
public(package) fun retire_flag_set_timestamp_ms(e: &RetireFlagSet): u64             { e.timestamp_ms }

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
