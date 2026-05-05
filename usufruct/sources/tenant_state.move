// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_state;

// === Imports ===

use usufruct::tenant::Tenant;
use usufruct::unreachable;

// === Errors ===

// === Constants ===

// === Structs ===

public enum TenantState<phantom CoinType> has store {
    Absence,
    Occupied { t1: Tenant<CoinType> },
    Demand   { t1: Tenant<CoinType>, t2: Tenant<CoinType>, handover_countdown_expiry: u64 },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff the slot currently holds a pending bidder (t2). Consumed
/// by `lifecycle_state::is_t_state_demand` and APT's handover check.
public(package) fun is_demand<CoinType>(s: &TenantState<CoinType>): bool {
    match (s) {
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => true,
        TenantState::Absence                       => false,
        TenantState::Occupied { t1: _t1 }          => false,
    }
}

/// Borrow the current tenant (t1). Aborts if Absence — consumer is
/// expected to gate via `is_occupied` or `is_demand` first.
public(package) fun current<CoinType>(s: &TenantState<CoinType>): &Tenant<CoinType> {
    match (s) {
        TenantState::Occupied { t1 }                 => t1,
        TenantState::Demand   { t1, t2: _, handover_countdown_expiry: _ } => t1,
        TenantState::Absence                          => abort unreachable::unreachable(),
    }
}

/// Borrow the pending tenant (t2). Aborts unless Demand.
public(package) fun pending<CoinType>(s: &TenantState<CoinType>): &Tenant<CoinType> {
    match (s) {
        TenantState::Demand { t1: _, t2, handover_countdown_expiry: _ } => t2,
        TenantState::Absence                              => abort unreachable::unreachable(),
        TenantState::Occupied { t1: _t1 }                 => abort unreachable::unreachable(),
    }
}

/// Read the handover-countdown expiry (absolute timestamp at which the
/// pending bid auto-wins). Aborts unless Demand. Consumed by APT's
/// Check 1 and `compute_used_credit`.
public(package) fun demand_expiry_ms<CoinType>(s: &TenantState<CoinType>): u64 {
    match (s) {
        TenantState::Demand { t1: _, t2: _, handover_countdown_expiry } => *handover_countdown_expiry,
        TenantState::Absence                              => abort unreachable::unreachable(),
        TenantState::Occupied { t1: _t1 }                 => abort unreachable::unreachable(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Drop an Absence state. Aborts if the state is not Absence — sanity
/// check that the caller reached the expected terminal position. Used
/// by `escrow_coordinator::claim_asset` after `decompose_retired` to
/// release the `TenantState` field; previously test-only, promoted
/// because the production claim path needs to consume the state.
public(package) fun consume_absence<CoinType>(s: TenantState<CoinType>) {
    match (s) {
        TenantState::Absence                       => (),
        TenantState::Occupied { t1: _t1 }          => abort unreachable::unreachable(),
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => abort unreachable::unreachable(),
    }
}

/// Construct the initial `TenantState`. Only entry point — once
/// active, the slot rotates through `occupy` / `demand` / `redemand`
/// / `reoccupy` / `vacate`.
public(package) fun absence<CoinType>(): TenantState<CoinType> {
    TenantState::Absence
}

/// Transition Absence → Occupied.
public(package) fun occupy<CoinType>(
    state: TenantState<CoinType>,
    t:     Tenant<CoinType>,
): TenantState<CoinType> {
    match (state) {
        TenantState::Absence =>
            TenantState::Occupied { t1: t },
        TenantState::Occupied { t1: _t1 }           => abort unreachable::unreachable(),
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => abort unreachable::unreachable(),
    }
}

/// Transition Occupied → Demand. The new tenant joins as the second
/// (pending) party of the slot. `handover_countdown_expiry` is the
/// absolute timestamp at which the pending bid auto-wins.
public(package) fun demand<CoinType>(
    state:                     TenantState<CoinType>,
    t:                         Tenant<CoinType>,
    handover_countdown_expiry: u64,
): TenantState<CoinType> {
    match (state) {
        TenantState::Occupied { t1 } =>
            TenantState::Demand { t1, t2: t, handover_countdown_expiry },
        TenantState::Absence                                              => abort unreachable::unreachable(),
        TenantState::Demand { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => abort unreachable::unreachable(),
    }
}

/// Transition Demand → Demand. A new bid replaces the existing pending
/// tenant; the displaced t2 is returned to the caller for refund.
/// `handover_countdown_expiry` resets to the new bid's deadline.
public(package) fun redemand<CoinType>(
    state:                     TenantState<CoinType>,
    t:                         Tenant<CoinType>,
    handover_countdown_expiry: u64,
): (TenantState<CoinType>, Tenant<CoinType>) {
    match (state) {
        TenantState::Demand { t1, t2, handover_countdown_expiry: _ } =>
            (TenantState::Demand { t1, t2: t, handover_countdown_expiry }, t2),
        TenantState::Absence              => abort unreachable::unreachable(),
        TenantState::Occupied { t1: _t1 } => abort unreachable::unreachable(),
    }
}

/// Transition Demand → Occupied. The pending tenant (t2) is promoted
/// to current (t1); the displaced incumbent is returned to the caller
/// for stake disassembly.
public(package) fun reoccupy<CoinType>(
    state: TenantState<CoinType>,
): (TenantState<CoinType>, Tenant<CoinType>) {
    match (state) {
        TenantState::Demand { t1, t2, handover_countdown_expiry: _ } =>
            (TenantState::Occupied { t1: t2 }, t1),
        TenantState::Absence              => abort unreachable::unreachable(),
        TenantState::Occupied { t1: _t1 } => abort unreachable::unreachable(),
    }
}

/// Transition Occupied → Absence. Returns the departing tenant so the
/// caller can disassemble its stake.
public(package) fun vacate<CoinType>(
    state: TenantState<CoinType>,
): (TenantState<CoinType>, Tenant<CoinType>) {
    match (state) {
        TenantState::Occupied { t1 } =>
            (TenantState::Absence, t1),
        TenantState::Absence                       => abort unreachable::unreachable(),
        TenantState::Demand { t1: _t1, t2: _t2, handover_countdown_expiry: _ }   => abort unreachable::unreachable(),
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_absence<CoinType>(s: &TenantState<CoinType>): bool {
    match (s) {
        TenantState::Absence                       => true,
        TenantState::Occupied { t1: _t1 }          => false,
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => false,
    }
}

#[test_only]
public fun is_occupied<CoinType>(s: &TenantState<CoinType>): bool {
    match (s) {
        TenantState::Occupied { t1: _t1 }          => true,
        TenantState::Absence                       => false,
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => false,
    }
}
