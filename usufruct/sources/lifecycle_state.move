// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::lifecycle_state;

// === Imports ===

use usufruct::{
    asset_state::{Self, AssetState},
    owner_state::{Self, OwnerState},
    tenant_state::{Self, Tenant, TenantState},
};

// === Errors ===

const EInvariantViolation: u64 = 0xDEADC0DE;

// === Constants ===

// === Structs ===

/// Two-variant cross-product of the three rental state machines.
/// Fine-grained position (Idle vs AtDutch vs Retired; Occupied vs
/// Demand) lives in the sub-states; `LifecycleState` only encodes
/// the business-level boundary: is there an active tenant or not?
public enum LifecycleState<Asset: key + store, phantom CoinType> has store {
    /// No active tenant. `a_state` may be Idle, AtDutch (last_acquisition_price
    /// carried inside), or Retired. Earnings gate is closed (StopFlow).
    NotRented {
        a_state: AssetState<Asset>,
        t_state: TenantState<CoinType>,
        o_state: OwnerState<CoinType>,
    },
    /// Active tenant. `a_state` is HandoverOpen or HandoverConfirmed;
    /// `t_state` is Occupied or Demand (handover_countdown_expiry
    /// carried inside Demand). Earnings gate is open (CashFlow).
    Rented {
        a_state:        AssetState<Asset>,
        t_state:        TenantState<CoinType>,
        o_state:        OwnerState<CoinType>,
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
/// tenant slot empty, earnings gate closed.
public(package) fun new<Asset: key + store, CoinType>(
    asset: Asset,
): LifecycleState<Asset, CoinType> {
    LifecycleState::NotRented {
        a_state: asset_state::new(asset),
        t_state: tenant_state::absence(),
        o_state: owner_state::new(),
    }
}

// ─── Boundary-crossing transitions ─────────────────────────────────────────────

/// NotRented → Rented. New tenant starts the rental; all three
/// sub-states advance in lockstep.
public(package) fun start_rent<Asset: key + store, CoinType>(
    s:              LifecycleState<Asset, CoinType>,
    t:              Tenant<CoinType>,
    phase_start_ms: u64,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state, o_state } => {
            LifecycleState::Rented {
                a_state:  asset_state::rent(a_state),
                t_state:  tenant_state::occupy(t_state, t),
                o_state:  owner_state::cash_flow(o_state),
                phase_start_ms,
                retiring: false,
            }
        },
        LifecycleState::Rented { a_state: _a, t_state: _t, o_state: _o, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

/// Rented → NotRented. Tenure expires with no pending bid; current
/// tenant departs, owner's share is extracted, asset enters AtDutch.
/// Returns (new state, departing Tenant with remainder stake).
public(package) fun expire_tenure<Asset: key + store, CoinType>(
    s:              LifecycleState<Asset, CoinType>,
    owner_amount:   u64,
    last_acq_price: u64,
): (LifecycleState<Asset, CoinType>, Tenant<CoinType>) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, o_state, phase_start_ms: _, retiring: _ } => {
            let (new_t_state, departing) = tenant_state::vacate(t_state);
            let (departing, owner_balance) = tenant_state::split(departing, owner_amount);
            (
                LifecycleState::NotRented {
                    a_state: asset_state::expire(a_state, last_acq_price),
                    t_state: new_t_state,
                    o_state: owner_state::stop_flow(owner_state::deposit(o_state, owner_balance)),
                },
                departing,
            )
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t, o_state: _o } => abort EInvariantViolation,
    }
}

// ─── Within-NotRented transitions ───────────────────────────────────────────────

/// NotRented: AtDutch → Idle (via asset_state::no_winner). Auction
/// ended with no winner; variant stays NotRented.
public(package) fun expire_auction<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state, o_state } => {
            LifecycleState::NotRented {
                a_state: asset_state::no_winner(a_state),
                t_state,
                o_state,
            }
        },
        LifecycleState::Rented { a_state: _a, t_state: _t, o_state: _o, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
    }
}

/// NotRented: Idle | AtDutch → Retired (via asset_state::retire).
/// Variant stays NotRented.
public(package) fun retire_now<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): LifecycleState<Asset, CoinType> {
    match (s) {
        LifecycleState::NotRented { a_state, t_state, o_state } => {
            LifecycleState::NotRented {
                a_state: asset_state::retire(a_state),
                t_state,
                o_state,
            }
        },
        LifecycleState::Rented { a_state: _a, t_state: _t, o_state: _o, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
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
        LifecycleState::Rented { a_state, t_state, o_state, phase_start_ms, retiring } => {
            LifecycleState::Rented {
                a_state: asset_state::bid(a_state),
                t_state: tenant_state::demand(t_state, t, handover_countdown_expiry),
                o_state,
                phase_start_ms,
                retiring,
            }
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t, o_state: _o } => abort EInvariantViolation,
    }
}

/// Rented: Demand → Demand. Higher bid displaces pending; variant
/// stays Rented. Returns displaced Tenant for the caller to refund.
public(package) fun supersede_bid<Asset: key + store, CoinType>(
    s:                         LifecycleState<Asset, CoinType>,
    t:                         Tenant<CoinType>,
    handover_countdown_expiry: u64,
): (LifecycleState<Asset, CoinType>, Tenant<CoinType>) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, o_state, phase_start_ms, retiring } => {
            let (new_t_state, displaced) = tenant_state::redemand(t_state, t, handover_countdown_expiry);
            (
                LifecycleState::Rented {
                    a_state,
                    t_state: new_t_state,
                    o_state,
                    phase_start_ms,
                    retiring,
                },
                displaced,
            )
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t, o_state: _o } => abort EInvariantViolation,
    }
}

/// Rented: Demand → Occupied. Countdown expires; t2 takes over from
/// t1. Variant stays Rented; owner's share extracted from t1's stake.
/// Returns (new state, departing Tenant with remainder stake).
public(package) fun accept_bid<Asset: key + store, CoinType>(
    s:                  LifecycleState<Asset, CoinType>,
    owner_amount:       u64,
    new_phase_start_ms: u64,
): (LifecycleState<Asset, CoinType>, Tenant<CoinType>) {
    match (s) {
        LifecycleState::Rented { a_state, t_state, o_state, phase_start_ms: _, retiring } => {
            let (new_t_state, departing) = tenant_state::reoccupy(t_state);
            let (departing, owner_balance) = tenant_state::split(departing, owner_amount);
            (
                LifecycleState::Rented {
                    a_state: asset_state::handover(a_state),
                    t_state: new_t_state,
                    o_state: owner_state::deposit(o_state, owner_balance),
                    phase_start_ms: new_phase_start_ms,
                    retiring,
                },
                departing,
            )
        },
        LifecycleState::NotRented { a_state: _a, t_state: _t, o_state: _o } => abort EInvariantViolation,
    }
}

/// Retired → (AssetState, TenantState, OwnerState). Decomposes the
/// terminal `NotRented` (Retired inner asset) into its three sub-states
/// for the caller: `asset_state::claim` for the asset,
/// `owner_state::withdraw` for earnings.
public(package) fun decompose_retired<Asset: key + store, CoinType>(
    s: LifecycleState<Asset, CoinType>,
): (AssetState<Asset>, TenantState<CoinType>, OwnerState<CoinType>) {
    match (s) {
        LifecycleState::NotRented { a_state, t_state, o_state } => (a_state, t_state, o_state),
        LifecycleState::Rented { a_state: _a, t_state: _t, o_state: _o, phase_start_ms: _, retiring: _ } => abort EInvariantViolation,
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
