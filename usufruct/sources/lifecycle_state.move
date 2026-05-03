// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::lifecycle_state;

// === Imports ===

use usufruct::{
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
/// advance in lockstep.
public(package) fun start_rent<Asset: key + store, CoinType>(
    s:              LifecycleState<Asset, CoinType>,
    t:              Tenant<CoinType>,
    phase_start_ms: u64,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state } => {
            LifecycleState::Rented {
                a_state:  asset_state::rent(a_state),
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
public(package) fun expire_tenure<Asset: key + store, CoinType>(
    s:              LifecycleState<Asset, CoinType>,
    owner_amount:   u64,
    fee_amount:     u64,
    last_acq_price: u64,
    escrow_id:      ID,
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
                    a_state: asset_state::expire(a_state, last_acq_price),
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

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_not_rented<Asset: key + store, CoinType>(s: &LifecycleState<Asset, CoinType>): bool {
    match (s) { LifecycleState::NotRented { .. } => true, _ => false }
}

#[test_only]
public fun is_rented<Asset: key + store, CoinType>(s: &LifecycleState<Asset, CoinType>): bool {
    match (s) { LifecycleState::Rented { .. } => true, _ => false }
}
