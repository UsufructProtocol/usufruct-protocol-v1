// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant;

// === Imports ===

use sui::balance::Balance;

// === Errors ===

/// Sentinel for caller-contract violations: the caller invoked a
/// transition (or `consume_absence`) from a state machine position
/// that the function did not expect. Distinguishes programming bugs
/// from legitimate runtime errors in logs and explorer UIs.
const EInvariantViolation: u64 = 0xDEADC0DE;

// === Constants ===

// === Structs ===

public struct Tenant<phantom CoinType> has store {
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
}

public enum TenantState<phantom CoinType> has store {
    Absence,
    Occupied { t1: Tenant<CoinType> },
    Demand   { t1: Tenant<CoinType>, t2: Tenant<CoinType> },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Construct the initial `TenantState`. Only entry point — once
/// active, the slot rotates through `occupy` / `demand` / `redemand`
/// / `reoccupy` / `vacate`.
public(package) fun absence<CoinType>(): TenantState<CoinType> {
    TenantState::Absence
}

/// Transition Absence → Occupied.
public(package) fun occupy<CoinType>(
    state:   TenantState<CoinType>,
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
): TenantState<CoinType> {
    match (state) {
        TenantState::Absence =>
            TenantState::Occupied { t1: Tenant { cap_id, address, stake } },
        TenantState::Occupied { t1: _t1 }           => abort EInvariantViolation,
        TenantState::Demand   { t1: _t1, t2: _t2 } => abort EInvariantViolation,
    }
}

/// Transition Occupied → Demand. The new tenant joins as the second
/// (pending) party of the slot.
public(package) fun demand<CoinType>(
    state:   TenantState<CoinType>,
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
): TenantState<CoinType> {
    match (state) {
        TenantState::Occupied { t1 } =>
            TenantState::Demand { t1, t2: Tenant { cap_id, address, stake } },
        TenantState::Absence                       => abort EInvariantViolation,
        TenantState::Demand { t1: _t1, t2: _t2 }   => abort EInvariantViolation,
    }
}

/// Transition Demand → Demand. A new bid replaces the existing pending
/// tenant; the displaced t2 is returned to the caller for refund.
public(package) fun redemand<CoinType>(
    state:   TenantState<CoinType>,
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
): (TenantState<CoinType>, Tenant<CoinType>) {
    match (state) {
        TenantState::Demand { t1, t2 } =>
            (TenantState::Demand { t1, t2: Tenant { cap_id, address, stake } }, t2),
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
        TenantState::Demand { t1, t2 } =>
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
        TenantState::Demand { t1: _t1, t2: _t2 }   => abort EInvariantViolation,
    }
}

/// Split `amount` off the Tenant's stake. Returns the (reduced)
/// Tenant and the separated Balance. The caller decides where the
/// split portion goes (owner_earnings / fee_inbox / etc.). Aborts if
/// `amount > stake.value` via `balance::split`.
public(package) fun split<CoinType>(
    t:      Tenant<CoinType>,
    amount: u64,
): (Tenant<CoinType>, Balance<CoinType>) {
    let Tenant { cap_id, address, mut stake } = t;
    let separated = stake.split(amount);
    (Tenant { cap_id, address, stake }, separated)
}

/// Destructure a `Tenant` into its three components. The caller
/// decides what to do with the Balance — refund whole, route to
/// owner_earnings / fee_inbox after upstream `split` calls, etc.
/// Tenant.move stays agnostic to `Coin`, `transfer`, and `TxContext`.
public(package) fun unbundle<CoinType>(
    tenant: Tenant<CoinType>,
): (ID, address, Balance<CoinType>) {
    let Tenant { cap_id, address, stake } = tenant;
    (cap_id, address, stake)
}

public(package) fun cap_id<CoinType>(t: &Tenant<CoinType>):      ID      { t.cap_id }
public(package) fun addr<CoinType>(t: &Tenant<CoinType>):        address { t.address }
public(package) fun stake_value<CoinType>(t: &Tenant<CoinType>): u64     { t.stake.value() }

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_absence<CoinType>(s: &TenantState<CoinType>): bool {
    match (s) {
        TenantState::Absence                       => true,
        TenantState::Occupied { t1: _t1 }          => false,
        TenantState::Demand   { t1: _t1, t2: _t2 } => false,
    }
}

#[test_only]
public fun is_occupied<CoinType>(s: &TenantState<CoinType>): bool {
    match (s) {
        TenantState::Occupied { t1: _t1 }          => true,
        TenantState::Absence                       => false,
        TenantState::Demand   { t1: _t1, t2: _t2 } => false,
    }
}

#[test_only]
public fun is_demand<CoinType>(s: &TenantState<CoinType>): bool {
    match (s) {
        TenantState::Demand   { t1: _t1, t2: _t2 } => true,
        TenantState::Absence                       => false,
        TenantState::Occupied { t1: _t1 }          => false,
    }
}

/// Drop an Absence state at the end of a test. Aborts if the state is
/// not Absence — sanity check that the test reached the expected
/// terminal position.
#[test_only]
public fun consume_absence<CoinType>(s: TenantState<CoinType>) {
    match (s) {
        TenantState::Absence                       => (),
        TenantState::Occupied { t1: _t1 }          => abort EInvariantViolation,
        TenantState::Demand   { t1: _t1, t2: _t2 } => abort EInvariantViolation,
    }
}
