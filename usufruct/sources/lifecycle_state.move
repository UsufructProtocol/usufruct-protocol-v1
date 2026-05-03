// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::lifecycle_state;

// === Imports ===

use usufruct::{
    asset::AssetReceipt,
    asset_state::{Self, AssetState},
    refund_state::{Self, RefundState},
    tenant::{Self, Tenant},
    tenant_state::{Self, TenantState},
};

// === Errors ===

const EInvariantViolation: u64 = 0xDEADC0DE;

// === Constants ===

// === Structs ===

/// Two-variant cross-product of the asset and tenant state machines.
/// Fine-grained position (Idle vs AtDutch vs Retired; Occupied vs
/// Demand) lives in the sub-states; `LifecycleState` only encodes
/// the business-level boundary: is there an active tenant or not?
///
/// The owner's `Owner<C>` does not live inside this enum — owner has
/// no per-rental state machine (its identity is the cap_id, its
/// material is the long-lived earnings container). It sits at the
/// rental-escrow layer next to this state and is mutated by `&mut`
/// when boundary transitions produce shares.
public enum LifecycleState<Asset: key + store, phantom CoinType> has store {
    /// No active tenant. `a_state` may be Idle, AtDutch (last_acquisition_price
    /// carried inside), or Retired.
    NotRented {
        a_state: AssetState<Asset>,
        t_state: TenantState<CoinType>,
    },
    /// Active tenant. `a_state` is HandoverOpen or HandoverConfirmed;
    /// `t_state` is Occupied or Demand (handover_countdown_expiry
    /// carried inside Demand).
    Rented {
        a_state:        AssetState<Asset>,
        t_state:        TenantState<CoinType>,
        phase_start_ms: u64,
        retiring:       bool,
    },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_not_rented<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) { LifecycleState::NotRented { .. } => true, _ => false }
}

public(package) fun is_rented<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) { LifecycleState::Rented { .. } => true, _ => false }
}

/// Read `Rented.retiring`. Returns `false` for NotRented (the flag
/// is only meaningful while a tenant is active — `retire_now` from
/// the inactive states transitions directly to Retired).
public(package) fun is_retiring<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::Rented { retiring, a_state: _a, t_state: _t, phase_start_ms: _ } => *retiring,
        LifecycleState::NotRented { a_state: _a, t_state: _t } => false,
    }
}

// ─── a_state delegating predicates ────────────────────────────────────────────
// Read the inner `AssetState` slot's variant. Used by `state_tag` and
// APT to derive the projected `EscrowStateTag` and gate transitions.

public(package) fun is_a_state_idle<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::is_idle(a_state),
        LifecycleState::Rented    { a_state, t_state: _t, phase_start_ms: _, retiring: _ } => asset_state::is_idle(a_state),
    }
}

public(package) fun is_a_state_at_dutch<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::is_at_dutch(a_state),
        LifecycleState::Rented    { a_state, t_state: _t, phase_start_ms: _, retiring: _ } => asset_state::is_at_dutch(a_state),
    }
}

public(package) fun is_a_state_handover_open<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::is_handover_open(a_state),
        LifecycleState::Rented    { a_state, t_state: _t, phase_start_ms: _, retiring: _ } => asset_state::is_handover_open(a_state),
    }
}

public(package) fun is_a_state_handover_confirmed<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::is_handover_confirmed(a_state),
        LifecycleState::Rented    { a_state, t_state: _t, phase_start_ms: _, retiring: _ } => asset_state::is_handover_confirmed(a_state),
    }
}

public(package) fun is_a_state_retired<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::is_retired(a_state),
        LifecycleState::Rented    { a_state, t_state: _t, phase_start_ms: _, retiring: _ } => asset_state::is_retired(a_state),
    }
}

// ─── t_state delegating predicates ────────────────────────────────────────────

/// True iff the slot currently holds a pending bid. Always false in
/// NotRented (tenant slot is Absence there).
public(package) fun is_t_state_demand<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): bool {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant_state::is_demand(t_state),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => false,
    }
}

// ─── Time fields ──────────────────────────────────────────────────────────────

/// Read the phase_start_ms field. In Rented, it is the rental's start.
/// In NotRented{AtDutch}, it is the auction's start (stamped by
/// `expire_tenure`). Aborts in NotRented{Idle} / NotRented{Retired}
/// where no phase is in progress.
public(package) fun phase_start_ms<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): u64 {
    match (s) {
        LifecycleState::Rented    { phase_start_ms, a_state: _a, t_state: _t, retiring: _ } => *phase_start_ms,
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::at_dutch_phase_start_ms(a_state),
    }
}

/// Absolute timestamp at which the pending bid auto-wins. Aborts
/// unless the lifecycle is in Rented + Demand.
public(package) fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): u64 {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant_state::demand_expiry_ms(t_state),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Anchor price of the active Dutch auction. Aborts unless the
/// lifecycle is in NotRented{AtDutch}.
public(package) fun last_acq_price_of_at_dutch<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): u64 {
    match (s) {
        LifecycleState::NotRented { a_state, t_state: _t } => asset_state::at_dutch_last_acq_price(a_state),
        LifecycleState::Rented    { a_state: _a, t_state: _t, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

// ─── Tenant data ─────────────────────────────────────────────────────────────

/// Stake value of the current tenant (t1). Valid in Rented (Occupied
/// or Demand). Aborts in NotRented.
public(package) fun current_stake_value<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): u64 {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant::stake_value(tenant_state::current(t_state)),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Stake value of the pending tenant (t2). Valid only in Rented +
/// Demand. Used by `compute_floor_price` for HandoverConfirmed.
public(package) fun pending_stake_value<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): u64 {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant::stake_value(tenant_state::pending(t_state)),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Cap id of the current tenant (t1). Valid in Rented; aborts in
/// NotRented. Consumed by `borrow_asset` to gate cap-id matching.
public(package) fun current_cap_id<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): ID {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant::id_cap_id(tenant::identity(tenant_state::current(t_state))),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Address of the current tenant (t1). Valid in Rented; aborts in
/// NotRented. Consumed by event payloads at boundary transitions.
public(package) fun current_addr<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): address {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant::id_address(tenant::identity(tenant_state::current(t_state))),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Cap id of the pending tenant (t2). Valid only in Rented + Demand.
public(package) fun pending_cap_id<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): ID {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant::id_cap_id(tenant::identity(tenant_state::pending(t_state))),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Address of the pending tenant (t2). Valid only in Rented + Demand.
public(package) fun pending_addr<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): address {
    match (s) {
        LifecycleState::Rented    { t_state, a_state: _a, phase_start_ms: _, retiring: _ } => tenant::id_address(tenant::identity(tenant_state::pending(t_state))),
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct the initial lifecycle — asset enters escrow as `Idle`,
/// tenant slot empty.
public(package) fun new<Asset: key + store, CoinType>(
    asset: Asset,
): LifecycleState<Asset, CoinType> {
    LifecycleState::NotRented {
        a_state: asset_state::new(asset),
        t_state: tenant_state::absence(),
    }
}

// ─── Boundary-crossing transitions ─────────────────────────────────────────────

/// NotRented → Rented. New tenant starts the rental; sub-states
/// advance in lockstep. `escrow_id` is threaded into `asset_state::rent`
/// so the asset wrapper can stamp its identity at this transition.
public(package) fun start_rent<Asset: key + store, CoinType>(
    s:              LifecycleState<Asset, CoinType>,
    t:              Tenant<CoinType>,
    phase_start_ms: u64,
    escrow_id:      ID,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state } => {
            LifecycleState::Rented {
                a_state:  asset_state::rent(a_state, escrow_id),
                t_state:  tenant_state::occupy(t_state, t),
                phase_start_ms,
                retiring: false,
            }
        },
        LifecycleState::Rented { a_state: _a, t_state: _t, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

/// Rented → NotRented. Tenure expires with no pending bid; current
/// tenant departs, owner's share + fee extracted, asset enters
/// AtDutch. Returns the new state plus a `RefundState::Nothing` —
/// in tenure expiry the full stake is consumed (owner + fee) and
/// nothing is owed back to the tenant.
///
/// `new_phase_start_ms` is stamped onto the resulting AtDutch slot
/// (the timestamp at which the auction starts — typically the tenure
/// boundary `boundary_ms` supplied by the caller). It is the input
/// `descent_policy` will read in the subsequent APT cycle.
public(package) fun expire_tenure<Asset: key + store, CoinType>(
    s:                  LifecycleState<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
    escrow_id:          ID,
): (LifecycleState<Asset, CoinType>, RefundState<CoinType>) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms: _, retiring: _ } => {
            let (new_t_state, mut departing) = tenant_state::vacate(t_state);
            let owner_earnings    = tenant::take_owner_earnings(&mut departing, owner_amount);
            let fee_share         = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
            let (identity, stake) = tenant::unbundle(departing);
            tenant::destroy_empty_stake(stake);
            (
                LifecycleState::NotRented {
                    a_state: asset_state::expire(a_state, last_acq_price, new_phase_start_ms),
                    t_state: new_t_state,
                },
                refund_state::nothing(identity, fee_share, owner_earnings),
            )
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

// ─── Within-NotRented transitions ───────────────────────────────────────────────

/// NotRented: AtDutch → Idle (via asset_state::no_winner). Auction
/// ended with no winner; variant stays NotRented.
public(package) fun expire_auction<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state } => {
            LifecycleState::NotRented {
                a_state: asset_state::no_winner(a_state),
                t_state,
            }
        },
        LifecycleState::Rented { a_state: _a, t_state: _t, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

/// NotRented: Idle | AtDutch → Retired (via asset_state::retire).
/// Variant stays NotRented.
public(package) fun retire_now<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state } => {
            LifecycleState::NotRented {
                a_state: asset_state::retire(a_state),
                t_state,
            }
        },
        LifecycleState::Rented { a_state: _a, t_state: _t, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

// ─── Within-Rented transitions ───────────────────────────────────────────────────

/// Rented: Occupied → Demand. A competing bid arrives; variant stays
/// Rented. `handover_countdown_expiry` is stored in TenantState::Demand.
public(package) fun place_bid<Asset: key + store, CoinType>(
    s:                         LifecycleState<Asset, CoinType>,
    t:                         Tenant<CoinType>,
    handover_countdown_expiry: u64,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms, retiring } => {
            LifecycleState::Rented {
                a_state: asset_state::bid(a_state),
                t_state: tenant_state::demand(t_state, t, handover_countdown_expiry),
                phase_start_ms,
                retiring,
            }
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Rented: Demand → Demand. Higher bid displaces pending; variant
/// stays Rented. Returns `RefundState::Total` carrying the displaced
/// tenant — full stake refunded, no owner share, no fee.
public(package) fun supersede_bid<Asset: key + store, CoinType>(
    s:                         LifecycleState<Asset, CoinType>,
    t:                         Tenant<CoinType>,
    handover_countdown_expiry: u64,
): (LifecycleState<Asset, CoinType>, RefundState<CoinType>) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms, retiring } => {
            let (new_t_state, displaced) = tenant_state::redemand(t_state, t, handover_countdown_expiry);
            let (identity, stake) = tenant::unbundle(displaced);
            (
                LifecycleState::Rented {
                    a_state,
                    t_state: new_t_state,
                    phase_start_ms,
                    retiring,
                },
                refund_state::total(identity, stake),
            )
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Rented: Demand → Occupied. Countdown expires; t2 takes over from
/// t1. Variant stays Rented; owner's share + fee extracted from t1's
/// stake. Returns `RefundState::Parcial` if a remainder exists, or
/// `RefundState::Nothing` when used_credit consumed the full stake.
public(package) fun accept_bid<Asset: key + store, CoinType>(
    s:                  LifecycleState<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    new_phase_start_ms: u64,
    escrow_id:          ID,
): (LifecycleState<Asset, CoinType>, RefundState<CoinType>) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms: _, retiring } => {
            let (new_t_state, mut departing) = tenant_state::reoccupy(t_state);
            let owner_earnings    = tenant::take_owner_earnings(&mut departing, owner_amount);
            let fee_share         = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
            let new_state = LifecycleState::Rented {
                a_state: asset_state::handover(a_state),
                t_state: new_t_state,
                phase_start_ms: new_phase_start_ms,
                retiring,
            };
            let refund = if (tenant::stake_value(&departing) > 0) {
                let (identity, stake) = tenant::unbundle(departing);
                refund_state::parcial(identity, stake, fee_share, owner_earnings)
            } else {
                let (identity, stake) = tenant::unbundle(departing);
                tenant::destroy_empty_stake(stake);
                refund_state::nothing(identity, fee_share, owner_earnings)
            };
            (new_state, refund)
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Retired → (AssetState, TenantState). Decomposes the terminal
/// `NotRented` (Retired inner asset) into its two sub-states for the
/// caller: `asset_state::claim` for the asset, and the absent tenant
/// state for sanity checks. The owner's earnings live separately at
/// the rental-escrow layer and are drained via `owner::withdraw`.
public(package) fun decompose_retired<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): (AssetState<Asset>, TenantState<CoinType>) {
    match (s) {
        LifecycleState::NotRented { a_state, t_state } => (a_state, t_state),
        LifecycleState::Rented { a_state: _a, t_state: _t, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

// ─── Retire flag mutator ─────────────────────────────────────────────────────

/// Sets `retiring: true` while keeping the lifecycle in Rented. Used
/// by `escrow_coordinator::do_set_retiring_flag` when the owner asks
/// to retire mid-rental — the flag blocks new bids but lets the
/// current tenant's tenure run to completion. Aborts on NotRented;
/// the inactive states transition directly to Retired via `retire_now`.
public(package) fun set_retiring<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms, retiring: _ } =>
            LifecycleState::Rented { a_state, t_state, phase_start_ms, retiring: true },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

// ─── Borrow protocol wrappers ────────────────────────────────────────────────

/// Extract the asset from the inner `Asset<U>` wrapper, mint an
/// `AssetReceipt`, and return the new lifecycle (with the asset slot
/// now empty). Aborts in NotRented; the borrow path is only valid
/// while a tenant holds the rental.
public(package) fun give<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): (LifecycleState<Asset, CoinType>, Asset, AssetReceipt) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms, retiring } => {
            let (new_a, u, receipt) = asset_state::give(a_state);
            (
                LifecycleState::Rented { a_state: new_a, t_state, phase_start_ms, retiring },
                u,
                receipt,
            )
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

/// Counterpart to `give`. Refills the asset slot via `asset::put`,
/// which enforces the three-assert safety on the receipt
/// (cross-escrow, receipt-mismatch, asset-swap). Aborts in NotRented.
public(package) fun give_back<Asset: key + store, CoinType>(
    s:       LifecycleState<Asset, CoinType>,
    asset:   Asset,
    receipt: AssetReceipt,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::Rented { a_state, t_state, phase_start_ms, retiring } => {
            let new_a = asset_state::give_back(a_state, asset, receipt);
            LifecycleState::Rented { a_state: new_a, t_state, phase_start_ms, retiring }
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t } => abort EInvariantViolation,
    }
}

// === Private Functions ===

// === Test Functions ===
