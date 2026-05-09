// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Context-State pattern: AssetContext (context carrier) + AssetState co-resident.
///
/// AssetState is a binary split: Renting (active tenancy) vs Waiting (no tenant).
///   · Renting embeds TenancyContext + TenancyState (Occupied / Demand sub-machine).
///   · Waiting embeds WaitingContext + WaitingState (Idle / AtDutch / Retired sub-machine).
///
/// All nested enum types must co-reside: Move 2024 restricts pattern access to the
/// defining module.
module usufruct::asset_context_state;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::{Self, AssetReceipt},
    config::{Self, IntegrationConfig},
    descent_policy_state,
    monetary::{Self, Price, Stake},
    owner::{Self, Owner},
    owner_cap::{Self, OwnerCap},
    pending_transition_state::{Self, PendingTransitionState},
    price_state,
    retire_policy_state,
    credit_context_state::{Self as credit_state},
    handover_policy_state,
    math,
    phases::{Self, Timestamp},
    refund_state,
    tenant::{Self, Tenant},
    tenant_cap::{Self, TenantCap},
};

// === Errors ===

const ENotRented:             u64 = 0;
const EInsufficientPayment:   u64 = 1;
const ERetiredNoBid:          u64 = 3;
const ERetireFloorNotElapsed: u64 = 4;
const EAlreadyRetired:        u64 = 5;
const EWrongEscrowTenantCap:  u64 = 6;
const EWrongEscrowOwnerCap:   u64 = 11;
const EStaleTenantCap:        u64 = 8;
const EReceiptEscrowMismatch: u64 = 10;
const ENotRetired:            u64 = 12;
const ENoEarnings:            u64 = 13;

// === Structs ===

/// Role a `TenantCap` plays relative to the current lifecycle state.
/// Co-resident with asset_context_state so match arms can branch on variants
/// directly — Move restricts pattern access to the defining module.
///
///   · `Current` — cap belongs to the active tenant. May borrow.
///   · `Pending` — cap belongs to the pending bidder (HandoverConfirmed). May not borrow.
///   · `Stale`   — cap is superseded, former tenant, or no active rental.
public enum CapAuthorizationState has drop {
    Current,
    Pending,
    Stale,
}

public(package) fun proj_is_current(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Current => true, _ => false }
}
public(package) fun proj_is_pending(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Pending => true, _ => false }
}
public(package) fun proj_is_stale(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Stale => true, _ => false }
}

/// Result of splitting a credit amount into owner earnings and protocol fee.
/// Named fields prevent positional swap between the two semantically distinct
/// monetary roles.
public struct FeeAllocation has drop {
    owner_share:  Stake,
    protocol_fee: Stake,
}

/// Binary lifecycle split: active tenancy vs. no tenant.
///
///   · Renting — active tenancy (Occupied or Demand sub-state via TenancyContext).
///   · Waiting — no tenant: Idle, AtDutch, or Retired (sub-state via WaitingContext).
public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Renting { tenancy: TenancyContext<Asset, CoinType> },
    Waiting { waiting: WaitingContext<Asset> },
}

/// Sub-machine state for waiting (no-tenant) lifecycle phases.
public enum WaitingState has store, drop {
    Idle,
    AtDutch { last_acq_price: Price, phase_start: Timestamp },
    Retired,
}

/// Context-State carrier for the no-tenant phases embedded in AssetState::Waiting.
///
///   · asset — present in all three waiting states; extracted here so match arms
///     never repeat it.
///   · state — Idle, AtDutch (auction in progress), or Retired (awaiting claim).
public struct WaitingContext<Asset: key + store> has store {
    asset: asset::AssetCustodyLocked<Asset>,
    state: WaitingState,
}

/// Sub-machine state for the active tenancy. Shared fields live in TenancyContext.
public enum TenancyState<phantom Asset: key + store, phantom CoinType> has store {
    Occupied { tenant: Tenant<CoinType> },
    Demand   { current: Tenant<CoinType>, pending: Tenant<CoinType>, handover_expiry: Timestamp },
}

/// Context-State carrier for the active tenancy sub-machine embedded in
/// AssetState::Renting.
///
///   · asset / phase_start_ms / retiring — present in both Occupied and Demand;
///     extracted here so match arms never repeat them.
///   · state — Occupied (single tenant) or Demand (tenant + pending bidder).
public struct TenancyContext<Asset: key + store, phantom CoinType> has store {
    asset:       asset::AssetCustodyOpen<Asset>,
    phase_start: Timestamp,
    retiring:    bool,
    state:       TenancyState<Asset, CoinType>,
}

/// Result of do_apt_transition. Co-resident with fire — matched directly
/// via nested struct pattern, no accessor functions needed.
public enum RentingFireResultState<Asset: key + store, phantom CoinType> {
    /// Demand → Occupied handover completed; tenancy stays active.
    Handover {
        tenancy: TenancyContext<Asset, CoinType>,
    },
    /// Occupied tenure expired; caller decides AtDutch vs Retired.
    TenureExpired {
        asset:          Asset,
        last_acq_price: Price,
        retiring:       bool,
    },
}

/// Central engine: lifecycle state + owner + immutable escrow context.
///
/// Context fields (config, fee_inbox_id, integrated_at, escrow_id) are
/// written once at integrate time and never mutated. Stored in Escrow as
/// Option<Engine> to enable by-value extraction.
public struct AssetContext<Asset: key + store, phantom CoinType> has store {
    asset_state:      AssetState<Asset, CoinType>,
    owner:            Owner<CoinType>,
    config:           IntegrationConfig,
    fee_inbox_id:     ID,
    integrated_at: Timestamp,
    escrow_id:     ID,
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

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###
// (AssetContext has store only — not directly observable by SDK; wrappers in runtime_projection.move)

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
        asset_state:   AssetState::Waiting { waiting: WaitingContext { asset: asset::lock(asset), state: WaitingState::Idle } },
        owner:         owner::new<CoinType>(owner_cap_id),
        config,
        fee_inbox_id,
        integrated_at: phases::timestamp(integrated_at_ms),
        escrow_id,
    }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_active<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::Retired => false, _ => true },
        AssetState::Renting { .. } => true,
    }
}

public(package) fun proj_is_inactive<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::Retired => true, _ => false },
        AssetState::Renting { .. } => false,
    }
}

// ─── Context accessors ────────────────────────────────────────────────────────

public(package) fun proj_config<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): &IntegrationConfig { &e.config }

public(package) fun proj_fee_inbox_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID { e.fee_inbox_id }

public(package) fun proj_integrated_at_ms<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): u64 { phases::timestamp_ms(e.integrated_at) }

public(package) fun proj_escrow_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID { e.escrow_id }

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun proj_asset_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID {
    match (&e.asset_state) {
        AssetState::Waiting { waiting }  => asset::proj_locked_id(&waiting.asset),
        AssetState::Renting { tenancy }  => asset_id_for_tenancy(tenancy),
    }
}

public(package) fun proj_owner_balance<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): u64 {
    owner::proj_value(&e.owner)
}

public(package) fun proj_owner_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID {
    owner::proj_cap_id(owner::proj_identity(&e.owner))
}

// ─── State predicate views (SDK surface via escrow.move) ──────────────────────

public(package) fun proj_is_idle<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::Idle => true, _ => false },
        _ => false,
    }
}

public(package) fun proj_is_at_dutch<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::AtDutch { .. } => true, _ => false },
        _ => false,
    }
}

/// True iff there is an active tenancy (Occupied or Demand).
public(package) fun proj_is_rented<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Renting { .. } => true, _ => false }
}

/// True iff renting and tenancy is Occupied (no pending bid yet).
public(package) fun proj_is_handover_open<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => is_occupied(tenancy),
        _ => false,
    }
}

/// True iff renting and tenancy is Demand (pending bidder present).
public(package) fun proj_is_handover_confirmed<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => is_demand(tenancy),
        _ => false,
    }
}

public(package) fun proj_is_retiring<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => is_retiring(tenancy),
        _ => false,
    }
}

// ─── Tenant data views (Option variants — only present in Renting) ────────────

public(package) fun proj_current_addr<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<address> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(current_addr(tenancy)),
        _ => option::none(),
    }
}

public(package) fun proj_current_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<ID> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(current_cap_id(tenancy)),
        _ => option::none(),
    }
}

public(package) fun proj_pending_addr<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<address> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => pending_addr_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_pending_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<ID> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => pending_cap_id_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Stake> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(current_stake(tenancy)),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake_value<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Stake {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => current_stake(tenancy),
        _ => abort ENotRented,
    }
}

public(package) fun proj_pending_stake<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Stake> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => pending_stake_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_phase_start<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(phase_start(tenancy)),
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { phase_start, .. } => option::some(*phase_start),
            _ => option::none(),
        },
    }
}

public(package) fun proj_handover_expiry<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => handover_expiry_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_last_acq_price<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Price> {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { last_acq_price, .. } => option::some(*last_acq_price),
            _ => option::none(),
        },
        _ => option::none(),
    }
}

// ─── Pricing views ────────────────────────────────────────────────────────────

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    e:   &AssetContext<Asset, CoinType>,
    now: Timestamp,
): Price {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            floor_price_at_for_tenancy(tenancy, &e.config, now),
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::Idle => config::proj_min_rent_price(&e.config),
            WaitingState::AtDutch { last_acq_price, phase_start } => {
                let ps = price_state::descending(*last_acq_price, *phase_start);
                price_state::floor_price(&ps, &e.config, now)
            },
            WaitingState::Retired => abort ERetiredNoBid,
        },
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    e:   &AssetContext<Asset, CoinType>,
    now: Timestamp,
): Stake {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            used_credit_at_for_tenancy(tenancy, &e.config, now),
        _ => abort ENotRented,
    }
}

/// Typed settlement for a handover boundary: (remaining_credit, owner_share, protocol_fee).
/// Extraction to u64 happens in escrow at the PTB boundary.
public(package) fun proj_handover_settlement<Asset: key + store, CoinType>(
    e:   &AssetContext<Asset, CoinType>,
    now: Timestamp,
): (Stake, Stake, Stake) {
    let stake = proj_current_stake_value(e);
    let used  = used_credit_at(e, now);
    let alloc = split_fee(used);
    (
        monetary::stake(monetary::stake_mist(stake) - monetary::stake_mist(used)),
        alloc.owner_share,
        alloc.protocol_fee,
    )
}

/// Typed settlement for a tenure expiry: (owner_share, protocol_fee).
/// Extraction to u64 happens in escrow at the PTB boundary.
public(package) fun proj_tenure_settlement<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): (Stake, Stake) {
    assert!(proj_is_rented(e), ENotRented);
    let alloc = split_fee(proj_current_stake_value(e));
    (alloc.owner_share, alloc.protocol_fee)
}



// ─── Cap-authorization view ───────────────────────────────────────────────────

public(package) fun cap_authorization_state<Asset: key + store, CoinType>(
    e:      &AssetContext<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => cap_auth_for_tenancy(tenancy, cap_id),
        _ => CapAuthorizationState::Stale,
    }
}

// ─── APT and pending detection ────────────────────────────────────────────────

public(package) fun next_pending<Asset: key + store, CoinType>(
    e:     &AssetContext<Asset, CoinType>,
    clock: &Clock,
): Option<PendingTransitionState> {
    let now = phases::now(clock);
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            next_pending_from_tenancy(tenancy, &e.config, now),
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { phase_start, .. } => {
                let policy = config::proj_descent(&e.config);
                let start  = *phase_start;
                if (descent_policy_state::has_expired(policy, start, now).is_crossed()) {
                    return option::some(
                        pending_transition_state::auction(descent_policy_state::expiry_at(policy, start))
                    )
                };
                option::none()
            },
            WaitingState::Idle | WaitingState::Retired => option::none(),
        },
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
    let now    = phases::now(clock);
    let floor  = floor_price_at(&context, now);
    assert!(coin::value(&payment) >= monetary::price_mist(floor), EInsufficientPayment);
    match (context) {
        // Compiler bug (not a language restriction): deeply nested struct-in-enum patterns
        // cause an internal panic in match_compilation.rs instead of compiling or producing
        // a proper diagnostic. Two-level match is the workaround.
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: _a, state: WaitingState::Retired } }, owner: _o, .. } =>
            abort ERetiredNoBid,
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: _ } }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let (new_state, cap) = do_install(asset, escrow_id, payment, monetary::price_mist(floor), now, ctx);
            (AssetContext { asset_state: new_state, owner, config, fee_inbox_id, integrated_at, escrow_id }, cap)
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let (new_tenancy, cap) = accept_rent_payment(
                tenancy, &mut owner, &config, escrow_id, fee_inbox_id, payment, monetary::price_mist(floor), now, ctx,
            );
            (AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }, cap)
        },
    }
}

public(package) fun execute_retire<Asset: key + store, CoinType>(
    context:   AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): AssetContext<Asset, CoinType> {
    assert!(owner_cap::proj_escrow_id(owner_cap) == context.escrow_id, EWrongEscrowOwnerCap);
    let context = apply_pending_transition_states(context, clock, ctx);
    let now = phases::now(clock);
    assert!(
        retire_policy_state::is_unlocked(
            config::proj_retire(&context.config),
            context.integrated_at,
            now,
        ).is_crossed(),
        ERetireFloorNotElapsed,
    );
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: _a, state: WaitingState::Retired } }, owner: _o, .. } =>
            abort EAlreadyRetired,
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: _ } }, owner, config, fee_inbox_id, integrated_at, escrow_id } =>
            AssetContext { asset_state: do_retire_immediately(asset, escrow_id, now, ctx), owner, config, fee_inbox_id, integrated_at, escrow_id },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let new_tenancy = set_retiring_flag_checked(tenancy, escrow_id, now, ctx);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
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
    assert!(tenant_cap::proj_escrow_id(tenant_cap) == context.escrow_id, EWrongEscrowTenantCap);
    let cap_id = object::id(tenant_cap);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let (new_tenancy, u, receipt) = take_asset(tenancy, escrow_id, cap_id);
            (AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }, u, receipt)
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort EStaleTenantCap,
    }
}

public(package) fun execute_return<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let new_tenancy = put_asset(tenancy, escrow_id, asset_in, receipt_in);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort EReceiptEscrowMismatch,
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
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let is_retired = match (&waiting.state) { WaitingState::Retired => true, _ => false };
            if (!is_retired) { assert!(tenant_cap::proj_escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap) };
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            assert!(tenant_cap::proj_escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            match (cap_auth_for_tenancy(&tenancy, object::id(&cap))) {
                CapAuthorizationState::Stale => {},
                _ => abort ETenantCapNotStale,
            };
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
    }
}

public(package) fun execute_withdraw_earnings<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (AssetContext<Asset, CoinType>, Coin<CoinType>) {
    assert!(owner_cap::proj_escrow_id(owner_cap) == context.escrow_id, EWrongEscrowOwnerCap);
    let context       = apply_pending_transition_states(context, clock, ctx);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();
    let AssetContext { asset_state, mut owner, config, fee_inbox_id, integrated_at, escrow_id } = context;
    let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
    event::emit(EarningsWithdrawn { escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms });
    (AssetContext { asset_state, owner, config, fee_inbox_id, integrated_at, escrow_id }, coin)
}

/// Terminal: consume a Retired engine and return (asset, residual earnings).
public(package) fun unwrap_for_claim<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    assert!(owner_cap::proj_escrow_id(owner_cap) == context.escrow_id, EWrongEscrowOwnerCap);
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }, mut owner, .. } => {
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            owner::destroy_empty(owner);
            (asset::unlock(asset), coin)
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRetired,
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRetired,
    }
}

// ─── Tenancy-state content (merged) ─────────────────────────────────────────

// === Errors ===

const EAlreadyRetiring:     u64 = 14;
const ERetireFlagBlocksBid: u64 = 2;
const EPendingTenantCap:    u64 = 7;
const ETenantCapNotStale:   u64 = 9;

// === Constants ===

const PROTOCOL_FEE_BPS: u64 = 1_000;

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

fun split_fee(amount: Stake): FeeAllocation {
    let mist         = monetary::stake_mist(amount);
    let protocol_fee = math::apply_bps(mist, math::bps(PROTOCOL_FEE_BPS));
    FeeAllocation {
        owner_share:  monetary::stake(mist - protocol_fee),
        protocol_fee: monetary::stake(protocol_fee),
    }
}

public(package) fun protocol_fee_bps(): u64 { PROTOCOL_FEE_BPS }
public(package) fun bps_denominator():  u64 { math::bps_denominator() }

// ─── Constructor ──────────────────────────────────────────────────────────────

public(package) fun new_occupied<Asset: key + store, CoinType>(
    asset:        asset::AssetCustodyOpen<Asset>,
    tenant:       Tenant<CoinType>,
    phase_start:  Timestamp,
): TenancyContext<Asset, CoinType> {
    TenancyContext { asset, phase_start, retiring: false, state: TenancyState::Occupied { tenant } }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_occupied<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): bool {
    match (&t.state) { TenancyState::Occupied { .. } => true, _ => false }
}

public(package) fun is_demand<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): bool {
    match (&t.state) { TenancyState::Demand { .. } => true, _ => false }
}

public(package) fun is_retiring<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): bool {
    t.retiring
}

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun asset_id_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): ID {
    asset::proj_asset_id(&t.asset)
}

public(package) fun current_addr<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): address {
    match (&t.state) {
        TenancyState::Occupied { tenant  } => tenant::proj_address(tenant::proj_identity(tenant)),
        TenancyState::Demand   { current, .. } => tenant::proj_address(tenant::proj_identity(current)),
    }
}

public(package) fun current_cap_id<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): ID {
    match (&t.state) {
        TenancyState::Occupied { tenant  } => tenant::proj_cap_id(tenant::proj_identity(tenant)),
        TenancyState::Demand   { current, .. } => tenant::proj_cap_id(tenant::proj_identity(current)),
    }
}

public(package) fun pending_addr_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<address> {
    match (&t.state) {
        TenancyState::Demand   { pending, .. } => option::some(tenant::proj_address(tenant::proj_identity(pending))),
        TenancyState::Occupied { .. }          => option::none(),
    }
}

public(package) fun pending_cap_id_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<ID> {
    match (&t.state) {
        TenancyState::Demand   { pending, .. } => option::some(tenant::proj_cap_id(tenant::proj_identity(pending))),
        TenancyState::Occupied { .. }          => option::none(),
    }
}

public(package) fun current_stake<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Stake {
    match (&t.state) {
        TenancyState::Occupied { tenant  } => monetary::stake(tenant::proj_stake_value(tenant)),
        TenancyState::Demand   { current, .. } => monetary::stake(tenant::proj_stake_value(current)),
    }
}

public(package) fun pending_stake_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<Stake> {
    match (&t.state) {
        TenancyState::Demand   { pending, .. } => option::some(monetary::stake(tenant::proj_stake_value(pending))),
        TenancyState::Occupied { .. }          => option::none(),
    }
}

public(package) fun phase_start<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Timestamp {
    t.phase_start
}

public(package) fun handover_expiry_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&t.state) {
        TenancyState::Demand   { handover_expiry, .. } => option::some(*handover_expiry),
        TenancyState::Occupied { .. }                  => option::none(),
    }
}

// ─── Pricing / credit views ───────────────────────────────────────────────────

public(package) fun floor_price_at_for_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    config: &IntegrationConfig,
    now:    Timestamp,
): Price {
    let stake = match (&t.state) {
        TenancyState::Occupied { tenant  } => tenant::proj_stake_value(tenant),
        TenancyState::Demand   { pending, .. } => tenant::proj_stake_value(pending),
    };
    let ps = price_state::ascending(monetary::stake(stake));
    price_state::floor_price(&ps, config, now)
}

public(package) fun used_credit_at_for_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    config: &IntegrationConfig,
    now:    Timestamp,
): Stake {
    let cs = match (&t.state) {
        TenancyState::Occupied { tenant } =>
            credit_state::accruing(monetary::stake(tenant::proj_stake_value(tenant)), t.phase_start),
        TenancyState::Demand { current, handover_expiry, .. } =>
            credit_state::capped(
                monetary::stake(tenant::proj_stake_value(current)),
                t.phase_start,
                *handover_expiry,
            ),
    };
    credit_state::used_credit(&cs, config, now)
}

// ─── Cap authorization view ───────────────────────────────────────────────────

public(package) fun cap_auth_for_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    cap_id: ID,
): CapAuthorizationState {
    match (&t.state) {
        TenancyState::Occupied { tenant } => {
            if (cap_id == tenant::proj_cap_id(tenant::proj_identity(tenant))) CapAuthorizationState::Current
            else CapAuthorizationState::Stale
        },
        TenancyState::Demand { current, pending, .. } => {
            if      (cap_id == tenant::proj_cap_id(tenant::proj_identity(current))) CapAuthorizationState::Current
            else if (cap_id == tenant::proj_cap_id(tenant::proj_identity(pending))) CapAuthorizationState::Pending
            else CapAuthorizationState::Stale
        },
    }
}

// ─── APT pending detection ────────────────────────────────────────────────────

public(package) fun next_pending_from_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    config: &IntegrationConfig,
    now:    Timestamp,
): Option<PendingTransitionState> {
    match (&t.state) {
        TenancyState::Demand { handover_expiry, .. } => {
            if (phases::check_boundary(*handover_expiry, phases::zero(), now).is_crossed()) {
                return option::some(pending_transition_state::handover(*handover_expiry))
            };
            option::none()
        },
        TenancyState::Occupied { .. } => {
            let start  = t.phase_start;
            let tenure = config::proj_tenure_ceiling(config);
            if (phases::check_boundary(start, tenure, now).is_crossed()) {
                return option::some(
                    pending_transition_state::tenure(phases::boundary_at(start, tenure))
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
    tenancy:      TenancyContext<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    payment:      Coin<CoinType>,
    floor:        u64,
    now:          Timestamp,
    ctx:          &mut TxContext,
): (TenancyContext<Asset, CoinType>, TenantCap) {
    let TenancyContext { asset, phase_start, retiring, state } = tenancy;
    match (state) {
        TenancyState::Occupied { tenant } =>
            do_place_bid(asset, tenant, phase_start, retiring, config, escrow_id, payment, floor, now, ctx),
        TenancyState::Demand { current, pending, handover_expiry } =>
            do_supersede_bid(
                asset, current, pending, handover_expiry, phase_start, retiring,
                owner, escrow_id, fee_inbox_id, payment, floor, now, ctx,
            ),
    }
}

/// Dispatch the pending APT transition. Match lives here so engine_state::fire
/// receives a typed result and never inspects TenancyState variant internals.
/// Owner is mutated in-place; caller (Engine) owns it and passes &mut.
public(package) fun do_apt_transition<Asset: key + store, CoinType>(
    tenancy:      TenancyContext<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    ID,
    fee_inbox_id: ID,
    boundary:     Timestamp,
    ctx:          &mut TxContext,
): RentingFireResultState<Asset, CoinType> {
    let TenancyContext { asset, phase_start, retiring, state } = tenancy;
    match (state) {
        TenancyState::Demand { current, pending, handover_expiry: _ } => {
            let new_tenancy = do_handover(
                asset, current, pending, phase_start, retiring,
                owner, config, escrow_id, fee_inbox_id, boundary, ctx,
            );
            RentingFireResultState::Handover { tenancy: new_tenancy }
        },
        TenancyState::Occupied { tenant } => {
            let (wrapped, last_acq_price, retiring) = do_tenure_expiry(
                asset, tenant, phase_start, retiring,
                owner, escrow_id, fee_inbox_id, boundary, ctx,
            );
            RentingFireResultState::TenureExpired { asset: asset::unbundle(wrapped), last_acq_price, retiring }
        },
    }
}

/// Set the retiring flag, aborting if already set. Consolidates the
/// is_retiring check into tenancy_state where it belongs.
public(package) fun set_retiring_flag_checked<Asset: key + store, CoinType>(
    tenancy:   TenancyContext<Asset, CoinType>,
    escrow_id: ID,
    now:       Timestamp,
    ctx:       &TxContext,
): TenancyContext<Asset, CoinType> {
    assert!(!is_retiring(&tenancy), EAlreadyRetiring);
    set_retiring_flag(tenancy, escrow_id, now, ctx)
}

/// Demand → Occupied: fire the handover transition at `boundary_ms`.
/// Distributes used credit to owner; retiring flag propagates to new Occupied.
fun do_handover<Asset: key + store, CoinType>(
    asset:       asset::AssetCustodyOpen<Asset>,
    current:     Tenant<CoinType>,
    pending:     Tenant<CoinType>,
    phase_start: Timestamp,
    retiring:    bool,
    owner:       &mut Owner<CoinType>,
    config:      &IntegrationConfig,
    escrow_id:   ID,
    fee_inbox_id: ID,
    boundary:    Timestamp,
    ctx:         &mut TxContext,
): TenancyContext<Asset, CoinType> {
    let principal   = monetary::stake(tenant::proj_stake_value(&current));
    let used_credit = {
        let cs = credit_state::capped(principal, phase_start, boundary);
        credit_state::used_credit(&cs, config, boundary)
    };
    let alloc         = split_fee(used_credit);
    let remain_credit = monetary::stake_mist(principal) - monetary::stake_mist(used_credit);

    let displaced_cap_id = tenant::proj_cap_id(tenant::proj_identity(&current));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&current));

    let mut departing  = current;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_id);
    let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, owner, fee_inbox_id, ctx);

    let new_cap_id     = tenant::proj_cap_id(tenant::proj_identity(&pending));
    let new_addr       = tenant::proj_address(tenant::proj_identity(&pending));
    let new_stake      = tenant::proj_stake_value(&pending);
    let new_rent_price = monetary::price_mist({
        let ps = price_state::ascending(monetary::stake(new_stake));
        price_state::floor_price(&ps, config, boundary)
    });
    let boundary_ms = phases::timestamp_ms(boundary);

    event::emit(HandoverCompleted {
        escrow_id,
        displaced_tenant_cap_id:  displaced_cap_id,
        displaced_tenant:         displaced_addr,
        displaced_phase_start_ms: phases::timestamp_ms(phase_start),
        new_tenant_cap_id:        new_cap_id,
        new_tenant_addr:          new_addr,
        new_tenant_stake:         new_stake,
        used_credit:              monetary::stake_mist(used_credit),
        owner_share:              monetary::stake_mist(alloc.owner_share),
        protocol_fee:             monetary::stake_mist(alloc.protocol_fee),
        remain_credit,
        new_rent_price,
        timestamp_ms:             boundary_ms,
    });

    TenancyContext {
        asset,
        phase_start: boundary,
        retiring,
        state: TenancyState::Occupied { tenant: pending },
    }
}

/// Consume an Occupied tenancy at tenure expiry. Distributes full stake to
/// owner/protocol. Returns (wrapped_asset, last_acq_price, retiring_flag).
fun do_tenure_expiry<Asset: key + store, CoinType>(
    asset:       asset::AssetCustodyOpen<Asset>,
    tenant:      Tenant<CoinType>,
    phase_start: Timestamp,
    retiring:    bool,
    owner:        &mut Owner<CoinType>,
    escrow_id:    ID,
    fee_inbox_id: ID,
    boundary:     Timestamp,
    ctx:          &mut TxContext,
): (asset::AssetCustodyOpen<Asset>, Price, bool) {
    let principal      = monetary::stake(tenant::proj_stake_value(&tenant));
    let tenant_cap_id  = tenant::proj_cap_id(tenant::proj_identity(&tenant));
    let tenant_addr    = tenant::proj_address(tenant::proj_identity(&tenant));
    let alloc = split_fee(principal);

    let mut departing  = tenant;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_id);
    let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, owner, fee_inbox_id, ctx);

    event::emit(TenureExpired {
        escrow_id,
        tenant_cap_id,
        tenant:                 tenant_addr,
        phase_start_ms:         phases::timestamp_ms(phase_start),
        owner_share:            monetary::stake_mist(alloc.owner_share),
        protocol_fee:           monetary::stake_mist(alloc.protocol_fee),
        last_acquisition_price: monetary::stake_mist(principal),
        timestamp_ms:           phases::timestamp_ms(boundary),
    });

    (asset, monetary::as_reference_price(principal), retiring)
}

/// Set the retiring flag on the current tenancy (Occupied or Demand).
/// Emits RetireFlagSet.
public(package) fun set_retiring_flag<Asset: key + store, CoinType>(
    tenancy:   TenancyContext<Asset, CoinType>,
    escrow_id: ID,
    now:       Timestamp,
    ctx:       &TxContext,
): TenancyContext<Asset, CoinType> {
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms: phases::timestamp_ms(now) });
    let TenancyContext { asset, phase_start, retiring: _, state } = tenancy;
    TenancyContext { asset, phase_start, retiring: true, state }
}

/// Borrow the underlying asset. Aborts if `cap_id` is stale or pending.
public(package) fun take_asset<Asset: key + store, CoinType>(
    tenancy:   TenancyContext<Asset, CoinType>,
    escrow_id: ID,
    cap_id:    ID,
): (TenancyContext<Asset, CoinType>, Asset, AssetReceipt) {
    let auth = cap_auth_for_tenancy(&tenancy, cap_id);
    let TenancyContext { mut asset, phase_start, retiring, state } = tenancy;
    let (tenant_addr, state) = match (state) {
        TenancyState::Occupied { tenant } => {
            match (auth) {
                CapAuthorizationState::Current => (tenant::proj_address(tenant::proj_identity(&tenant)), TenancyState::Occupied { tenant }),
                CapAuthorizationState::Pending => abort EPendingTenantCap,
                CapAuthorizationState::Stale   => abort EStaleTenantCap,
            }
        },
        TenancyState::Demand { current, pending, handover_expiry } => {
            match (auth) {
                CapAuthorizationState::Current => {
                    let addr = tenant::proj_address(tenant::proj_identity(&current));
                    (addr, TenancyState::Demand { current, pending, handover_expiry })
                },
                CapAuthorizationState::Pending => abort EPendingTenantCap,
                CapAuthorizationState::Stale   => abort EStaleTenantCap,
            }
        },
    };
    let (u, receipt) = asset::take(&mut asset);
    event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });
    (TenancyContext { asset, phase_start, retiring, state }, u, receipt)
}

/// Return the borrowed asset.
public(package) fun put_asset<Asset: key + store, CoinType>(
    tenancy:    TenancyContext<Asset, CoinType>,
    escrow_id:  ID,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): TenancyContext<Asset, CoinType> {
    let TenancyContext { mut asset, phase_start, retiring, state } = tenancy;
    let (tenant_cap_id, tenant_addr) = match (&state) {
        TenancyState::Occupied { tenant } => (
            tenant::proj_cap_id(tenant::proj_identity(tenant)),
            tenant::proj_address(tenant::proj_identity(tenant)),
        ),
        TenancyState::Demand { current, .. } => (
            tenant::proj_cap_id(tenant::proj_identity(current)),
            tenant::proj_address(tenant::proj_identity(current)),
        ),
    };
    asset::put(&mut asset, asset_in, receipt_in);
    event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });
    TenancyContext { asset, phase_start, retiring, state }
}

// === Private Functions ===

/// Occupied → Demand.
fun do_place_bid<Asset: key + store, CoinType>(
    asset:       asset::AssetCustodyOpen<Asset>,
    tenant:      Tenant<CoinType>,
    phase_start: Timestamp,
    retiring:    bool,
    config:         &IntegrationConfig,
    escrow_id:      ID,
    payment:        Coin<CoinType>,
    floor:          u64,
    now:            Timestamp,
    ctx:            &mut TxContext,
): (TenancyContext<Asset, CoinType>, TenantCap) {
    assert!(!retiring, ERetireFlagBlocksBid);
    let current_cap_id = tenant::proj_cap_id(tenant::proj_identity(&tenant));
    let current_addr   = tenant::proj_address(tenant::proj_identity(&tenant));
    let current_stake  = tenant::proj_stake_value(&tenant);
    let tenure         = config::proj_tenure_ceiling(config);
    let expiry       = handover_policy_state::expiry_at(
        config::proj_handover(config),
        now,
        phase_start,
        tenure,
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
        current_phase_start_ms:    phases::timestamp_ms(phase_start),
        tenant_cap_id:             cap_id,
        pending_tenant:            pending_addr,
        bid_amount,
        floor_price:               floor,
        handover_countdown_expiry: phases::timestamp_ms(expiry),
        timestamp_ms:              phases::timestamp_ms(now),
    });
    (
        TenancyContext {
            asset,
            phase_start,
            retiring,
            state: TenancyState::Demand { current: tenant, pending: t, handover_expiry: expiry },
        },
        cap,
    )
}

/// Demand → Demand: displace the existing pending bidder.
fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyOpen<Asset>,
    current:         Tenant<CoinType>,
    pending:         Tenant<CoinType>,
    handover_expiry: Timestamp,
    phase_start:     Timestamp,
    retiring:        bool,
    owner:           &mut Owner<CoinType>,
    escrow_id:       ID,
    fee_inbox_id:    ID,
    payment:         Coin<CoinType>,
    floor:           u64,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (TenancyContext<Asset, CoinType>, TenantCap) {
    let protected_cap_id = tenant::proj_cap_id(tenant::proj_identity(&current));
    let protected_addr   = tenant::proj_address(tenant::proj_identity(&current));
    let protected_stake  = tenant::proj_stake_value(&current);
    let displaced_cap_id = tenant::proj_cap_id(tenant::proj_identity(&pending));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&pending));
    let refunded_amount  = tenant::proj_stake_value(&pending);

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
        protected_phase_start_ms:  phases::timestamp_ms(phase_start),
        displaced_tenant_cap_id:   displaced_cap_id,
        new_tenant_cap_id:         cap_id,
        displaced_bidder:          displaced_addr,
        refunded_amount,
        new_bidder,
        new_bid_amount,
        floor_price:               floor,
        handover_countdown_expiry: phases::timestamp_ms(handover_expiry),
        timestamp_ms:              phases::timestamp_ms(now),
    });
    (
        TenancyContext {
            asset,
            phase_start,
            retiring,
            state: TenancyState::Demand { current, pending: t, handover_expiry },
        },
        cap,
    )
}

// === Test Functions ===

public(package) fun emit_retire_flag_set(escrow_id: ID, owner: address, timestamp_ms: u64) {
    event::emit(RetireFlagSet { escrow_id, owner, timestamp_ms });
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    let alloc = split_fee(monetary::stake(amount));
    (monetary::stake_mist(alloc.owner_share), monetary::stake_mist(alloc.protocol_fee))
}

#[test_only]
public(package) fun set_retiring_flag_for_testing<Asset: key + store, CoinType>(
    tenancy: TenancyContext<Asset, CoinType>,
): TenancyContext<Asset, CoinType> {
    let TenancyContext { asset, phase_start, retiring: _, state } = tenancy;
    TenancyContext { asset, phase_start, retiring: true, state }
}

/// Drive Occupied → Demand for testing (without full bid mechanics).
#[test_only]
fun tenancy_drive_to_demand_for_testing<Asset: key + store, CoinType>(
    asset:                     asset::AssetCustodyOpen<Asset>,
    tenant:                    Tenant<CoinType>,
    phase_start:               Timestamp,
    retiring:                  bool,
    tenant_in:                 Tenant<CoinType>,
    handover_countdown_expiry: Timestamp,
): TenancyContext<Asset, CoinType> {
    TenancyContext {
        asset,
        phase_start,
        retiring,
        state: TenancyState::Demand { current: tenant, pending: tenant_in, handover_expiry: handover_countdown_expiry },
    }
}

/// Consume an Occupied tenancy for test state driving. Discards tenant funds.
#[test_only]
fun unbundle_occupied_for_testing<Asset: key + store, CoinType>(
    asset:        asset::AssetCustodyOpen<Asset>,
    mut tenant:   Tenant<CoinType>,
    owner_amount: u64,
    fee_amount:   u64,
    escrow_id:    ID,
): asset::AssetCustodyOpen<Asset> {
    let owner_earnings = tenant::take_owner_earnings(&mut tenant, monetary::stake(owner_amount));
    let fee_share      = tenant::take_fee_share(&mut tenant, monetary::stake(fee_amount), escrow_id);
    let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
    refund_state::destroy_for_testing(refund);
    asset
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

// === Private Functions ===

fun fire<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    t:      PendingTransitionState,
    ctx:    &mut TxContext,
): AssetContext<Asset, CoinType> {
    let boundary = pending_transition_state::proj_boundary(&t);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            match (do_apt_transition(tenancy, &mut owner, &config, escrow_id, fee_inbox_id, boundary, ctx)) {
                RentingFireResultState::Handover { tenancy: new_tenancy } =>
                    AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id },
                RentingFireResultState::TenureExpired { asset, last_acq_price, retiring } => {
                    let locked       = asset::lock(asset);
                    let boundary_ms  = phases::timestamp_ms(boundary);
                    if (retiring) {
                        event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
                        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: locked, state: WaitingState::Retired } }, owner, config, fee_inbox_id, integrated_at, escrow_id }
                    } else {
                        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: locked, state: WaitingState::AtDutch { last_acq_price, phase_start: boundary } } }, owner, config, fee_inbox_id, integrated_at, escrow_id }
                    }
                },
            }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start } } }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let new_state = do_auction_expiry(asset, last_acq_price, phase_start, escrow_id, boundary);
            AssetContext { asset_state: new_state, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

fun do_withdraw<CoinType>(
    owner:     &mut Owner<CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Coin<CoinType>, u64) {
    let amount = owner::proj_value(owner);
    assert!(amount > 0, ENoEarnings);
    let coin = owner::withdraw(owner, owner_cap, ctx);
    (coin, amount)
}

fun do_install<Asset: key + store, CoinType>(
    locked:    asset::AssetCustodyLocked<Asset>,
    escrow_id: ID,
    payment:   Coin<CoinType>,
    floor:     u64,
    now:       Timestamp,
    ctx:       &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let price_paid  = coin::value(&payment);
    let tenant_addr = ctx.sender();
    let now_ms      = phases::timestamp_ms(now);
    let (cap, cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, tenant_addr, coin::into_balance(payment));
    let wrapped = asset::new(asset::unlock(locked), escrow_id);
    event::emit(RentStarted {
        escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr,
        phase_start_ms: now_ms, price_paid, floor_price: floor,
    });
    (AssetState::Renting { tenancy: new_occupied(wrapped, t, now) }, cap)
}

fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:          asset::AssetCustodyLocked<Asset>,
    last_acq_price: Price,
    phase_start:    Timestamp,
    escrow_id:      ID,
    boundary:       Timestamp,
): AssetState<Asset, CoinType> {
    event::emit(AuctionExpired { escrow_id, phase_start_ms: phases::timestamp_ms(phase_start), last_acq_price: monetary::price_mist(last_acq_price), timestamp_ms: phases::timestamp_ms(boundary) });
    AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Idle } }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:     asset::AssetCustodyLocked<Asset>,
    escrow_id: ID,
    now:       Timestamp,
    ctx:       &TxContext,
): AssetState<Asset, CoinType> {
    let timestamp_ms = phases::timestamp_ms(now);
    emit_retire_flag_set(escrow_id, ctx.sender(), timestamp_ms);
    event::emit(AssetRetired { escrow_id, timestamp_ms });
    AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }
}

// === Test Functions ===


#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, phase_start, retiring, state: TenancyState::Demand { current, pending, handover_expiry: _ } } }, mut owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let new_tenancy = do_handover(
                asset, current, pending, phase_start, retiring,
                &mut owner, &config, escrow_id, fee_inbox_id, boundary, ctx,
            );
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, phase_start: _p, retiring: _r, state: TenancyState::Occupied { tenant: _t } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, phase_start, retiring, state: TenancyState::Occupied { tenant } } }, mut owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let (wrapped, last_acq_price, retiring) = do_tenure_expiry(
                asset, tenant, phase_start, retiring,
                &mut owner, escrow_id, fee_inbox_id, boundary, ctx,
            );
            let raw_asset = asset::unbundle(wrapped);
            let locked = asset::lock(raw_asset);
            let boundary_ms = phases::timestamp_ms(boundary);
            if (retiring) {
                event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
                AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: locked, state: WaitingState::Retired } }, owner, config, fee_inbox_id, integrated_at, escrow_id }
            } else {
                AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: locked, state: WaitingState::AtDutch { last_acq_price, phase_start: boundary } } }, owner, config, fee_inbox_id, integrated_at, escrow_id }
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, phase_start: _p, retiring: _r, state: TenancyState::Demand { current: _c, pending: _p2, handover_expiry: _e } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let WaitingContext { asset, state } = waiting;
            match (state) {
                WaitingState::AtDutch { last_acq_price, phase_start } =>
                    AssetContext { asset_state: do_auction_expiry(asset, last_acq_price, phase_start, escrow_id, boundary), owner, config, fee_inbox_id, integrated_at, escrow_id },
                _ => abort ENotRented,
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    context:     AssetContext<Asset, CoinType>,
    tenant_in:   tenant::Tenant<CoinType>,
    phase_start: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let WaitingContext { asset, state } = waiting;
            match (state) {
                WaitingState::Idle => {
                    let tenancy = new_occupied(asset::new(asset::unlock(asset), escrow_id), tenant_in, phase_start);
                    AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
                },
                _ => abort ENotRented,
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    tenant_in:                 usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, phase_start, retiring, state: TenancyState::Occupied { tenant } } }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let new_tenancy = tenancy_drive_to_demand_for_testing(
                asset, tenant, phase_start, retiring, tenant_in, handover_countdown_expiry,
            );
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, phase_start: _p, retiring: _r, state: TenancyState::Demand { current: _c, pending: _p2, handover_expiry: _e } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_amount:    u64,
    fee_amount:      u64,
    last_acq_price:  u64,
    new_phase_start: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, phase_start: _, retiring: _, state: TenancyState::Occupied { tenant } } }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let wrapped = unbundle_occupied_for_testing(
                asset, tenant, owner_amount, fee_amount, escrow_id,
            );
            let raw_asset = asset::unbundle(wrapped);
            AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: asset::lock(raw_asset), state: WaitingState::AtDutch { last_acq_price: monetary::price(last_acq_price), phase_start: new_phase_start } } }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, phase_start: _p, retiring: _r, state: TenancyState::Demand { current: _c, pending: _p2, handover_expiry: _e } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {
            let WaitingContext { asset, state } = waiting;
            match (state) {
                WaitingState::Idle =>
                    AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }, owner, config, fee_inbox_id, integrated_at, escrow_id },
                _ => abort ENotRented,
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id } => {

            let new_tenancy = set_retiring_flag_for_testing(tenancy);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, config, fee_inbox_id, integrated_at, escrow_id }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
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
