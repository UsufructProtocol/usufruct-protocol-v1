// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Engine state and coordination.
///
/// `EngineState` aggregates everything the protocol's coordination
/// layer mutates or consults: the lifecycle state machine, the owner's
/// earnings, the integration config, and the immutable identity/anchor
/// metadata. Two variants:
///
///   Active   — engine is running; full operational state available.
///   Inactive — asset has been retired; only the asset and the owner's
///              residual earnings persist, awaiting `unwrap_for_claim`.
///
/// The `Active → Inactive` transition is one-way and fires at exactly
/// two boundaries:
///   1. `do_retire_immediately` (owner retires from Idle/AtDutch).
///   2. `do_tenure_expiry` with the retiring flag set (a tenure that
///      ended after the owner signalled retire mid-rental).
///
/// `Inactive` is terminal: no transitions out; only `unwrap_for_claim`
/// consumes it. Re-running an integration is a fresh `EngineState`,
/// not a transition from Inactive.
///
/// Function signatures take `EngineState` by value (consume + return)
/// or by reference for views — never `&mut`. The `Option<EngineState>`
/// take/put discipline lives at the outer layer (`escrow.move`) per the
/// canonical Sui Move pattern (see `lifecycle_state` for the analogous
/// convention with `AssetState` and `TenantState` — neither is wrapped
/// in `Option` because the take/put boundary lives one layer above).
module usufruct::engine_state;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::{Self, AssetReceipt},
    cap_authorization::{Self, CapAuthorization},
    config::{Self, IntegrationConfig},
    credit_state,
    descent_policy,
    handover_policy,
    lifecycle_state::{Self, LifecycleState},
    math,
    owner::{Self, Owner},
    owner_cap::{Self, OwnerCap},
    pending_transition::{Self, PendingTransition},
    phases,
    price_state,
    refund_state,
    rent_action,
    retire_policy,
    retire_route,
    tenant,
    tenant_cap::{Self, TenantCap},
    unreachable,
};

// === Errors ===

const ENotRented:               u64 = 0;
const EInsufficientPayment:     u64 = 1;
const ERetireFlagBlocksBid:     u64 = 2;
const ERetiredNoBid:            u64 = 3;
const ERetireFloorNotElapsed:   u64 = 4;
const EAlreadyRetired:          u64 = 5;
const EWrongEscrowTenantCap:    u64 = 6;
const EPendingTenantCap:        u64 = 7;
const EStaleTenantCap:          u64 = 8;
const ETenantCapNotStale:       u64 = 9;
const EReceiptEscrowMismatch:   u64 = 10;
const EReceiptAssetMismatch:    u64 = 11;
const ENotRetired:              u64 = 12;
const ENoEarnings:              u64 = 13;

// === Constants ===

/// Protocol fee — 10 % of `used_credit` at every boundary that touches
/// a tenant's stake (handover, tenure expiry).
const PROTOCOL_FEE_BPS: u64 = 1_000;
const BPS_PER_UNIT:     u64 = 10_000;

// === Structs ===

/// Engine state. See module docstring for the Active/Inactive split.
public enum EngineState<Asset: key + store, phantom CoinType> has store {
    Active {
        l_state:          LifecycleState<Asset, CoinType>,
        owner:            Owner<CoinType>,
        config:           IntegrationConfig,
        escrow_id:        ID,
        fee_inbox_id:     ID,
        integrated_at_ms: u64,
    },
    Inactive {
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

/// Construct a fresh Active engine. Called once at integrate time.
public(package) fun new<Asset: key + store, CoinType>(
    asset:            Asset,
    config:           IntegrationConfig,
    fee_inbox_id:     ID,
    owner_cap_id:     ID,
    integrated_at_ms: u64,
    escrow_id:        ID,
): EngineState<Asset, CoinType> {
    EngineState::Active {
        l_state:          lifecycle_state::new<Asset, CoinType>(asset),
        owner:            owner::new<CoinType>(owner_cap_id),
        config,
        escrow_id,
        fee_inbox_id,
        integrated_at_ms,
    }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_active<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) {
        EngineState::Active   { .. } => true,
        EngineState::Inactive { .. } => false,
    }
}

public(package) fun is_inactive<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): bool {
    match (s) {
        EngineState::Active   { .. } => false,
        EngineState::Inactive { .. } => true,
    }
}

// ─── Identity views (defined in every variant) ────────────────────────────────

/// Object ID of the wrapped asset. Defined in every state — for
/// Active, reads through the lifecycle's `asset_id`; for Inactive,
/// reads `object::id` of the held asset directly.
public(package) fun asset_id<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): ID {
    match (s) {
        EngineState::Active   { l_state, .. } => lifecycle_state::asset_id(l_state),
        EngineState::Inactive { asset,   .. } => object::id(asset),
    }
}

// ─── Active-only views ────────────────────────────────────────────────────────

public(package) fun config<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): &IntegrationConfig {
    match (s) {
        EngineState::Active   { config, .. } => config,
        EngineState::Inactive { .. }         => abort unreachable::unreachable(),
    }
}

public(package) fun escrow_id<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): ID {
    match (s) {
        EngineState::Active   { escrow_id, .. } => *escrow_id,
        EngineState::Inactive { .. }            => abort unreachable::unreachable(),
    }
}

public(package) fun fee_inbox_id<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): ID {
    match (s) {
        EngineState::Active   { fee_inbox_id, .. } => *fee_inbox_id,
        EngineState::Inactive { .. }               => abort unreachable::unreachable(),
    }
}

public(package) fun integrated_at_ms<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): u64 {
    match (s) {
        EngineState::Active   { integrated_at_ms, .. } => *integrated_at_ms,
        EngineState::Inactive { .. }                   => abort unreachable::unreachable(),
    }
}

public(package) fun lifecycle<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): &LifecycleState<Asset, CoinType> {
    match (s) {
        EngineState::Active   { l_state, .. } => l_state,
        EngineState::Inactive { .. }          => abort unreachable::unreachable(),
    }
}

public(package) fun owner_balance<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): u64 {
    match (s) {
        EngineState::Active   { owner, .. } => owner::value(owner),
        EngineState::Inactive { owner, .. } => owner::value(owner),
    }
}

public(package) fun owner_cap_id<Asset: key + store, CoinType>(
    s: &EngineState<Asset, CoinType>,
): ID {
    match (s) {
        EngineState::Active   { owner, .. } => owner::id_cap_id(owner::identity(owner)),
        EngineState::Inactive { owner, .. } => owner::id_cap_id(owner::identity(owner)),
    }
}

// ─── Pricing views ────────────────────────────────────────────────────────────

/// Used credit at `timestamp_ms`. Aborts unless the lifecycle is Rented.
public(package) fun used_credit_at<Asset: key + store, CoinType>(
    s:            &EngineState<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    match (s) {
        EngineState::Inactive { .. } => abort ENotRented,
        EngineState::Active { l_state, config, .. } => {
            assert!(lifecycle_state::is_rented(l_state), ENotRented);
            let stake          = lifecycle_state::current_stake_value(l_state);
            let phase_start_ms = lifecycle_state::phase_start_ms(l_state);
            let cs = if (lifecycle_state::is_t_state_demand(l_state)) {
                credit_state::capped(stake, phase_start_ms, lifecycle_state::handover_countdown_expiry_ms(l_state))
            } else {
                credit_state::accruing(stake, phase_start_ms)
            };
            credit_state::used_credit(&cs, config, timestamp_ms)
        },
    }
}

/// Floor price at `timestamp_ms`. Aborts on Retired (Inactive).
public(package) fun floor_price_at<Asset: key + store, CoinType>(
    s:            &EngineState<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    match (s) {
        EngineState::Inactive { .. } => abort ERetiredNoBid,
        EngineState::Active { l_state, config, .. } => {
            let ps = if (lifecycle_state::is_a_state_idle(l_state)) {
                price_state::rest()
            } else if (lifecycle_state::is_a_state_handover_open(l_state)) {
                price_state::ascending(lifecycle_state::current_stake_value(l_state))
            } else if (lifecycle_state::is_a_state_handover_confirmed(l_state)) {
                price_state::ascending(lifecycle_state::pending_stake_value(l_state))
            } else if (lifecycle_state::is_a_state_at_dutch(l_state)) {
                price_state::descending(
                    lifecycle_state::last_acq_price_of_at_dutch(l_state),
                    lifecycle_state::phase_start_ms(l_state),
                )
            } else {
                // Retired sub-state inside Active is unreachable — Active
                // never contains a Retired lifecycle.
                abort unreachable::unreachable()
            };
            price_state::floor_price(&ps, config, timestamp_ms)
        },
    }
}

/// Pure 90/10 split of `amount` into `(owner_share, protocol_fee)`.
public(package) fun split_fee(amount: u64): (u64, u64) {
    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)
}

public(package) fun protocol_fee_bps(): u64 { PROTOCOL_FEE_BPS }
public(package) fun bps_denominator(): u64  { BPS_PER_UNIT }

// ─── APT and pending detection ────────────────────────────────────────────────

/// Detect the single transition that is due at `now`, if any.
public(package) fun next_pending<Asset: key + store, CoinType>(
    s:     &EngineState<Asset, CoinType>,
    clock: &Clock,
): Option<PendingTransition> {
    match (s) {
        EngineState::Inactive { .. } => option::none(),
        EngineState::Active { l_state, config, .. } => {
            let now = clock::timestamp_ms(clock);

            if (lifecycle_state::is_rented(l_state) && lifecycle_state::is_t_state_demand(l_state)) {
                let expiry = lifecycle_state::handover_countdown_expiry_ms(l_state);
                if (phases::has_passed(expiry, 0, now)) {
                    return option::some(pending_transition::handover(expiry))
                };
            };

            if (lifecycle_state::is_rented(l_state) && lifecycle_state::is_a_state_handover_open(l_state)) {
                let phase_start = lifecycle_state::phase_start_ms(l_state);
                let tenure      = config::tenure_ceiling(config);
                if (phases::has_passed(phase_start, tenure, now)) {
                    return option::some(pending_transition::tenure(phases::boundary_at(phase_start, tenure)))
                };
            };

            if (lifecycle_state::is_not_rented(l_state) && lifecycle_state::is_a_state_at_dutch(l_state)) {
                let phase_start = lifecycle_state::phase_start_ms(l_state);
                let policy      = config::descent(config);
                if (descent_policy::has_expired(policy, phase_start, now)) {
                    return option::some(pending_transition::auction(descent_policy::expiry_at(policy, phase_start)))
                };
            };

            option::none()
        },
    }
}

/// Permissionless settler. Drives every elapsed lazy transition.
public(package) fun apply_pending_transitions<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
    clock: &Clock,
    ctx:   &mut TxContext,
): EngineState<Asset, CoinType> {
    let mut current = state;
    let mut i = 0u8;
    loop {
        if (is_inactive(&current)) break;
        let pending = next_pending(&current, clock);
        if (option::is_some(&pending)) {
            assert!(i < 3, unreachable::unreachable());
            current = fire(current, option::destroy_some(pending), ctx);
            i = i + 1;
        } else {
            break
        }
    };
    current
}

fun fire<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
    t:     PendingTransition,
    ctx:   &mut TxContext,
): EngineState<Asset, CoinType> {
    let boundary_ms = pending_transition::boundary_ms(&t);
    if (pending_transition::is_handover(&t)) {
        do_handover(state, boundary_ms, ctx)
    } else if (pending_transition::is_tenure(&t)) {
        do_tenure_expiry(state, boundary_ms, ctx)
    } else {
        do_auction_expiry(state, boundary_ms)
    }
}

// ─── Public action executors ──────────────────────────────────────────────────

/// Single entry point to become tenant or place a bid.
public(package) fun execute_rent<Asset: key + store, CoinType>(
    state:   EngineState<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    let state = apply_pending_transitions(state, clock, ctx);
    if (is_inactive(&state)) { abort ERetiredNoBid };

    let now   = clock::timestamp_ms(clock);
    let floor = floor_price_at(&state, now);
    assert!(coin::value(&payment) >= floor, EInsufficientPayment);
    let action = lifecycle_state::rent_action(lifecycle(&state));
    if (rent_action::is_install(&action)) {
        do_install_new_tenant(state, payment, floor, now, ctx)
    } else if (rent_action::is_place_bid(&action)) {
        do_place_bid(state, payment, floor, now, ctx)
    } else if (rent_action::is_supersede_bid(&action)) {
        do_supersede_bid(state, payment, floor, now, ctx)
    } else {
        // Retired action — unreachable: floor_price_at would have aborted
        // earlier (Inactive guarded above; Retired in Active is impossible).
        abort unreachable::unreachable()
    }
}

/// Owner-gated retire entry.
public(package) fun execute_retire<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
    clock: &Clock,
    ctx:   &mut TxContext,
): EngineState<Asset, CoinType> {
    let state = apply_pending_transitions(state, clock, ctx);
    let now_ms = clock::timestamp_ms(clock);
    match (state) {
        EngineState::Inactive { asset: _a, owner: _o } => abort EAlreadyRetired,
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            assert!(
                retire_policy::is_unlocked(config::retire(&config), integrated_at_ms, now_ms),
                ERetireFloorNotElapsed,
            );
            let route = lifecycle_state::retire_route(&l_state);
            let s = EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms };
            if (retire_route::is_immediate(&route)) {
                do_retire_immediately(s, now_ms, ctx)
            } else if (retire_route::is_deferred(&route)) {
                do_set_retiring_flag(s, now_ms, ctx)
            } else {
                // AlreadyRetired branch — unreachable since we matched on Active.
                abort unreachable::unreachable()
            }
        },
    }
}

/// Tenant-side asset borrow.
public(package) fun execute_borrow<Asset: key + store, CoinType>(
    state:      EngineState<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (EngineState<Asset, CoinType>, Asset, AssetReceipt) {
    let state = apply_pending_transitions(state, clock, ctx);
    match (state) {
        EngineState::Inactive { asset: _a, owner: _o } => abort EStaleTenantCap,
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            assert!(tenant_cap::escrow_id(tenant_cap) == escrow_id, EWrongEscrowTenantCap);
            let cap_id = object::id(tenant_cap);

            let auth = lifecycle_state::cap_authorization(&l_state, cap_id);
            if (cap_authorization::is_stale(&auth))   { abort EStaleTenantCap };
            if (cap_authorization::is_pending(&auth)) { abort EPendingTenantCap };

            let tenant_addr = lifecycle_state::current_addr(&l_state);
            let (new_l, asset_out, receipt) = lifecycle_state::give(l_state);

            event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });

            (
                EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms },
                asset_out,
                receipt,
            )
        },
    }
}

/// Tenant-side asset return.
public(package) fun execute_return<Asset: key + store, CoinType>(
    state:      EngineState<Asset, CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Inactive { asset: _a, owner: _o } => {
            // Returning to a retired escrow is impossible by construction:
            // borrow_asset (which mints AssetReceipt) is gated on Active,
            // and the receipt is hot-potato (must reach return_asset within
            // the same PTB — no APT runs in between). Treat as receipt
            // mismatch; abort consumes asset_in and receipt_in by divergence.
            abort EReceiptEscrowMismatch
        },
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            assert!(asset::receipt_escrow_id(&receipt_in)  == escrow_id,             EReceiptEscrowMismatch);
            assert!(asset::receipt_asset_id(&receipt_in)   == object::id(&asset_in), EReceiptAssetMismatch);
            assert!(lifecycle_state::is_rented(&l_state), unreachable::unreachable());

            let tenant_cap_id = lifecycle_state::current_cap_id(&l_state);
            let tenant_addr   = lifecycle_state::current_addr(&l_state);
            let new_l = lifecycle_state::give_back(l_state, asset_in, receipt_in);

            event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });

            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
    }
}

/// Burn a stale TenantCap for gas recovery.
public(package) fun execute_burn_tenant_cap<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
    cap:   TenantCap,
    clock: &Clock,
    ctx:   &mut TxContext,
): EngineState<Asset, CoinType> {
    let state = apply_pending_transitions(state, clock, ctx);
    match (state) {
        EngineState::Inactive { asset, owner } => {
            // Inactive — no live caps. Any cap belonging to this escrow is
            // stale. (If the cap belongs to a different escrow, the caller
            // (escrow.move) is expected to verify before calling — but we
            // also can't verify here without escrow_id, so trust the caller.)
            tenant_cap::burn(cap, ctx);
            EngineState::Inactive { asset, owner }
        },
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
            let cap_id = object::id(&cap);
            let auth = lifecycle_state::cap_authorization(&l_state, cap_id);
            if (!cap_authorization::is_stale(&auth)) { abort ETenantCapNotStale };
            tenant_cap::burn(cap, ctx);
            EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
    }
}

/// Owner-gated earnings withdrawal. Emits EarningsWithdrawn with the
/// engine's escrow_id (Active) or via the asset's wrapped escrow_id
/// stamp (Inactive — read at the lifecycle layer's wrap time).
public(package) fun execute_withdraw_earnings<Asset: key + store, CoinType>(
    state:     EngineState<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (EngineState<Asset, CoinType>, Coin<CoinType>) {
    let state = apply_pending_transitions(state, clock, ctx);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();

    match (state) {
        EngineState::Active { l_state, mut owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let amount = owner::value(&owner);
            assert!(amount > 0, ENoEarnings);
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            event::emit(EarningsWithdrawn {
                escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms,
            });
            (
                EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms },
                coin,
            )
        },
        EngineState::Inactive { asset, mut owner } => {
            let amount = owner::value(&owner);
            assert!(amount > 0, ENoEarnings);
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            // Inactive lacks a stored escrow_id; read it from the OwnerCap
            // (the cap-escrow binding stamped at integrate time).
            let escrow_id = owner_cap::escrow_id(owner_cap);
            event::emit(EarningsWithdrawn {
                escrow_id, owner_cap_id, owner: owner_addr, amount, timestamp_ms,
            });
            (EngineState::Inactive { asset, owner }, coin)
        },
    }
}

/// Terminal: consume an Inactive engine and return (asset, residual earnings coin).
public(package) fun unwrap_for_claim<Asset: key + store, CoinType>(
    state:     EngineState<Asset, CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    match (state) {
        EngineState::Inactive { asset, mut owner } => {
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            owner::destroy_empty(owner);
            (asset, coin)
        },
        EngineState::Active { l_state: _l, owner: _o, config: _, escrow_id: _, fee_inbox_id: _, integrated_at_ms: _ } => abort ENotRetired,
    }
}

// ─── Cap-authorization view (for SDK) ─────────────────────────────────────────

public(package) fun cap_authorization<Asset: key + store, CoinType>(
    s:      &EngineState<Asset, CoinType>,
    cap_id: ID,
): CapAuthorization {
    match (s) {
        EngineState::Active   { l_state, .. } => lifecycle_state::cap_authorization(l_state, cap_id),
        EngineState::Inactive { .. }          => cap_authorization::stale(),
    }
}

// === Private Functions ===

// ─── do_* dispatch (rent path) ───────────────────────────────────────────────

/// Idle | AtDutchAuction → Rented{HandoverOpen}. Active stays Active.
fun do_install_new_tenant<Asset: key + store, CoinType>(
    state:   EngineState<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let price_paid  = coin::value(&payment);
            let tenant_addr = ctx.sender();

            let (cap, cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
            let t = tenant::new<CoinType>(cap_id, tenant_addr, coin::into_balance(payment));

            let new_l = lifecycle_state::start_rent<Asset, CoinType>(l_state, t, now, escrow_id);

            event::emit(RentStarted {
                escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr,
                phase_start_ms: now, price_paid, floor_price: floor,
            });

            (
                EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms },
                cap,
            )
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

/// Rented{HandoverOpen} → Rented{HandoverConfirmed}. Active stays Active.
fun do_place_bid<Asset: key + store, CoinType>(
    state:   EngineState<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            assert!(!lifecycle_state::is_retiring(&l_state), ERetireFlagBlocksBid);
            let current_cap_id   = lifecycle_state::current_cap_id(&l_state);
            let current_addr_val = lifecycle_state::current_addr(&l_state);
            let current_stake    = lifecycle_state::current_stake_value(&l_state);
            let phase_start      = lifecycle_state::phase_start_ms(&l_state);
            let tenure           = config::tenure_ceiling(&config);
            let expiry           = handover_policy::expiry_at(
                config::handover(&config), now, phase_start, tenure,
            );

            let pending_addr = ctx.sender();
            let bid_amount   = coin::value(&payment);

            let (cap, cap_id) = tenant_cap::new(escrow_id, pending_addr, ctx);
            let t = tenant::new<CoinType>(cap_id, pending_addr, coin::into_balance(payment));

            let new_l = lifecycle_state::place_bid<Asset, CoinType>(l_state, t, expiry);

            event::emit(BidPlaced {
                escrow_id,
                current_tenant_cap_id:     current_cap_id,
                current_tenant_addr:       current_addr_val,
                current_tenant_stake:      current_stake,
                current_phase_start_ms:    phase_start,
                tenant_cap_id:             cap_id,
                pending_tenant:            pending_addr,
                bid_amount,
                floor_price:               floor,
                handover_countdown_expiry: expiry,
                timestamp_ms:              now,
            });

            (
                EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms },
                cap,
            )
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

/// Rented{HandoverConfirmed} supersede. Active stays Active.
fun do_supersede_bid<Asset: key + store, CoinType>(
    state:   EngineState<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): (EngineState<Asset, CoinType>, TenantCap) {
    match (state) {
        EngineState::Active { l_state, mut owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let protected_cap_id      = lifecycle_state::current_cap_id(&l_state);
            let protected_addr        = lifecycle_state::current_addr(&l_state);
            let protected_stake       = lifecycle_state::current_stake_value(&l_state);
            let protected_phase_start = lifecycle_state::phase_start_ms(&l_state);
            let displaced_cap_id      = lifecycle_state::pending_cap_id(&l_state);
            let displaced_addr        = lifecycle_state::pending_addr(&l_state);
            let refunded_amount       = lifecycle_state::pending_stake_value(&l_state);
            let existing_expiry       = lifecycle_state::handover_countdown_expiry_ms(&l_state);

            let new_bidder     = ctx.sender();
            let new_bid_amount = coin::value(&payment);

            let (cap, cap_id) = tenant_cap::new(escrow_id, new_bidder, ctx);
            let t = tenant::new<CoinType>(cap_id, new_bidder, coin::into_balance(payment));

            let (new_l, refund) = lifecycle_state::supersede_bid<Asset, CoinType>(l_state, t, existing_expiry);
            refund_state::distribute(refund, &mut owner, fee_inbox_id, ctx);

            event::emit(BidSuperseded {
                escrow_id,
                protected_tenant_cap_id:   protected_cap_id,
                protected_tenant_addr:     protected_addr,
                protected_tenant_stake:    protected_stake,
                protected_phase_start_ms:  protected_phase_start,
                displaced_tenant_cap_id:   displaced_cap_id,
                new_tenant_cap_id:         cap_id,
                displaced_bidder:          displaced_addr,
                refunded_amount,
                new_bidder,
                new_bid_amount,
                floor_price:               floor,
                handover_countdown_expiry: existing_expiry,
                timestamp_ms:              now,
            });

            (
                EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms },
                cap,
            )
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

// ─── Boundary handlers ───────────────────────────────────────────────────────

/// Handover boundary. Active stays Active.
fun do_handover<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): EngineState<Asset, CoinType> {
    let used_credit = used_credit_at(&state, boundary_ms);
    let (owner_amount, fee_amount) = split_fee(used_credit);

    match (state) {
        EngineState::Active { l_state, mut owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let displaced_cap_id      = lifecycle_state::current_cap_id(&l_state);
            let displaced_addr        = lifecycle_state::current_addr(&l_state);
            let displaced_phase_start = lifecycle_state::phase_start_ms(&l_state);
            let principal             = lifecycle_state::current_stake_value(&l_state);
            let remain_credit         = principal - used_credit;

            let (new_l, refund) = lifecycle_state::accept_bid<Asset, CoinType>(
                l_state, owner_amount, fee_amount, boundary_ms, escrow_id,
            );
            refund_state::distribute(refund, &mut owner, fee_inbox_id, ctx);

            let new_tenant_cap_id = lifecycle_state::current_cap_id(&new_l);
            let new_tenant_addr   = lifecycle_state::current_addr(&new_l);
            let new_tenant_stake  = lifecycle_state::current_stake_value(&new_l);

            // After handover the lifecycle is in HandoverOpen; price regime is
            // Ascending(current_stake_value).
            let new_rent_price = {
                let ps = price_state::ascending(new_tenant_stake);
                price_state::floor_price(&ps, &config, boundary_ms)
            };

            event::emit(HandoverCompleted {
                escrow_id,
                displaced_tenant_cap_id:  displaced_cap_id,
                displaced_tenant:         displaced_addr,
                displaced_phase_start_ms: displaced_phase_start,
                new_tenant_cap_id,
                new_tenant_addr,
                new_tenant_stake,
                used_credit,
                owner_share:    owner_amount,
                protocol_fee:   fee_amount,
                remain_credit,
                new_rent_price,
                timestamp_ms:   boundary_ms,
            });

            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

/// Tenure boundary. May transition Active → Inactive (if retiring flag was set).
fun do_tenure_expiry<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, mut owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let principal              = lifecycle_state::current_stake_value(&l_state);
            let tenant_addr            = lifecycle_state::current_addr(&l_state);
            let tenant_cap_id          = lifecycle_state::current_cap_id(&l_state);
            let phase_start_ms         = lifecycle_state::phase_start_ms(&l_state);
            let (owner_amount, fee_amount) = split_fee(principal);
            let last_acquisition_price = principal;

            let (new_l, refund) = lifecycle_state::expire_tenure<Asset, CoinType>(
                l_state, owner_amount, fee_amount, last_acquisition_price, boundary_ms, escrow_id,
            );
            refund_state::distribute(refund, &mut owner, fee_inbox_id, ctx);

            event::emit(TenureExpired {
                escrow_id, tenant_cap_id, tenant: tenant_addr,
                phase_start_ms,
                owner_share:            owner_amount,
                protocol_fee:           fee_amount,
                last_acquisition_price,
                timestamp_ms:           boundary_ms,
            });

            if (lifecycle_state::is_a_state_retired(&new_l)) {
                let asset = lifecycle_state::take_asset(new_l);
                event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
                EngineState::Inactive { asset, owner }
            } else {
                EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
            }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

/// Auction boundary. Active stays Active.
fun do_auction_expiry<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    boundary_ms: u64,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let phase_start_ms = lifecycle_state::phase_start_ms(&l_state);
            let last_acq_price = lifecycle_state::last_acq_price_of_at_dutch(&l_state);
            let new_l          = lifecycle_state::expire_auction(l_state);

            event::emit(AuctionExpired { escrow_id, phase_start_ms, last_acq_price, timestamp_ms: boundary_ms });

            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

/// Retire from Idle | AtDutchAuction → Inactive. Active → Inactive.
fun do_retire_immediately<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    timestamp_ms: u64,
    ctx:          &TxContext,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config: _, escrow_id, fee_inbox_id: _, integrated_at_ms: _ } => {
            // Transition lifecycle to Retired (intermediate), then extract asset.
            let retired_l = lifecycle_state::retire_now(l_state);
            let asset     = lifecycle_state::take_asset(retired_l);

            event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
            event::emit(AssetRetired  { escrow_id, timestamp_ms });

            EngineState::Inactive { asset, owner }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

/// Set the retiring flag on an active rental. Active stays Active.
fun do_set_retiring_flag<Asset: key + store, CoinType>(
    state:        EngineState<Asset, CoinType>,
    timestamp_ms: u64,
    ctx:          &TxContext,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            assert!(!lifecycle_state::is_retiring(&l_state), EAlreadyRetired);
            let new_l = lifecycle_state::set_retiring(l_state);

            event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });

            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

// === Test Functions ===

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    split_fee(amount)
}

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): EngineState<Asset, CoinType> {
    do_handover(state, boundary_ms, ctx)
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): EngineState<Asset, CoinType> {
    do_tenure_expiry(state, boundary_ms, ctx)
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    state:       EngineState<Asset, CoinType>,
    boundary_ms: u64,
): EngineState<Asset, CoinType> {
    do_auction_expiry(state, boundary_ms)
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    state:          EngineState<Asset, CoinType>,
    tenant_in:      tenant::Tenant<CoinType>,
    phase_start_ms: u64,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let new_l = lifecycle_state::start_rent(l_state, tenant_in, phase_start_ms, escrow_id);
            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    state:                     EngineState<Asset, CoinType>,
    tenant_in:                 tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let new_l = lifecycle_state::place_bid(l_state, tenant_in, handover_countdown_expiry);
            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    state:              EngineState<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let (new_l, refund) = lifecycle_state::expire_tenure(
                l_state, owner_amount, fee_amount, last_acq_price, new_phase_start_ms, escrow_id,
            );
            refund_state::destroy_for_testing(refund);
            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config: _, escrow_id: _, fee_inbox_id: _, integrated_at_ms: _ } => {
            let retired_l = lifecycle_state::retire_now(l_state);
            let asset = lifecycle_state::take_asset(retired_l);
            EngineState::Inactive { asset, owner }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    state: EngineState<Asset, CoinType>,
): EngineState<Asset, CoinType> {
    match (state) {
        EngineState::Active { l_state, owner, config, escrow_id, fee_inbox_id, integrated_at_ms } => {
            let new_l = lifecycle_state::set_retiring(l_state);
            EngineState::Active { l_state: new_l, owner, config, escrow_id, fee_inbox_id, integrated_at_ms }
        },
        EngineState::Inactive { asset: _a, owner: _o } => abort unreachable::unreachable(),
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
