// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant;

// === Imports ===

use sui::balance::Balance;

// === Errors ===

const ENotAbsent:   u64 = 0;
const ENotOccupied: u64 = 1;
const ENotDemand:   u64 = 2;

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
        TenantState::Occupied { t1: _t1 }           => abort ENotAbsent,
        TenantState::Demand   { t1: _t1, t2: _t2 } => abort ENotAbsent,
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
        TenantState::Absence                       => abort ENotOccupied,
        TenantState::Demand { t1: _t1, t2: _t2 }   => abort ENotOccupied,
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
        TenantState::Absence              => abort ENotDemand,
        TenantState::Occupied { t1: _t1 } => abort ENotDemand,
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
        TenantState::Absence              => abort ENotDemand,
        TenantState::Occupied { t1: _t1 } => abort ENotDemand,
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
        TenantState::Absence                       => abort ENotOccupied,
        TenantState::Demand { t1: _t1, t2: _t2 }   => abort ENotOccupied,
    }
}

/// Destructure a `Tenant` into its three components. The caller
/// decides what to do with the Balance — refund whole, split between
/// owner_earnings / protocol fee / refund, etc. Tenant.move stays
/// agnostic to `Coin`, `transfer`, and `TxContext`.
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
