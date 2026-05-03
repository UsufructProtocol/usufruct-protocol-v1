// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_state;

// === Imports ===

use usufruct::tenant::Tenant;

// === Errors ===

/// Sentinel for caller-contract violations: the caller invoked a
/// transition (or `consume_absence`) from a state machine position
/// that the function did not expect. Distinguishes programming bugs
/// from legitimate runtime errors in logs and explorer UIs.
const EInvariantViolation: u64 = 0xDEADC0DE;

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
        TenantState::Occupied { t1: _t1 }          => abort EInvariantViolation,
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => abort EInvariantViolation,
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
        TenantState::Occupied { t1: _t1 }           => abort EInvariantViolation,
        TenantState::Demand   { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => abort EInvariantViolation,
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
        TenantState::Absence                                              => abort EInvariantViolation,
        TenantState::Demand { t1: _t1, t2: _t2, handover_countdown_expiry: _ } => abort EInvariantViolation,
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
        TenantState::Absence              => abort EInvariantViolation,
        TenantState::Occupied { t1: _t1 } => abort EInvariantViolation,
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
        TenantState::Absence              => abort EInvariantViolation,
        TenantState::Occupied { t1: _t1 } => abort EInvariantViolation,
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
        TenantState::Absence                       => abort EInvariantViolation,
        TenantState::Demand { t1: _t1, t2: _t2, handover_countdown_expiry: _ }   => abort EInvariantViolation,
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
