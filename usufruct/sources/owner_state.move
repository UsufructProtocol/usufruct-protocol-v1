// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_state;

// === Imports ===

use sui::balance::{Self, Balance};

// === Errors ===

/// Sentinel for caller-contract violations: the caller invoked a
/// transition or operation from a state machine position the function
/// did not expect.
const EInvariantViolation: u64 = 0xDEADC0DE;

// === Constants ===

// === Structs ===

public enum OwnerState<phantom CoinType> has store {
    StopFlow { balance: Balance<CoinType> },
    CashFlow { balance: Balance<CoinType> },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Construct the initial OwnerState — StopFlow with zero balance.
/// Only entry point — the state rotates between StopFlow and CashFlow
/// in lockstep with TenantState (StopFlow when Absence; CashFlow when
/// Occupied or Demand).
public(package) fun new<CoinType>(): OwnerState<CoinType> {
    OwnerState::StopFlow { balance: balance::zero<CoinType>() }
}

/// Transition StopFlow → CashFlow. Opens the deposit gate; aborts if
/// already in CashFlow.
public(package) fun cash_flow<CoinType>(
    s: OwnerState<CoinType>,
): OwnerState<CoinType> {
    match (s) {
        OwnerState::StopFlow { balance } =>
            OwnerState::CashFlow { balance },
        OwnerState::CashFlow { balance: _b } => abort EInvariantViolation,
    }
}

/// Transition CashFlow → StopFlow. Closes the deposit gate; aborts
/// if already in StopFlow.
public(package) fun stop_flow<CoinType>(
    s: OwnerState<CoinType>,
): OwnerState<CoinType> {
    match (s) {
        OwnerState::CashFlow { balance } =>
            OwnerState::StopFlow { balance },
        OwnerState::StopFlow { balance: _b } => abort EInvariantViolation,
    }
}

/// Deposit `incoming` into the earnings. Allowed only in CashFlow.
/// Depositing during StopFlow is a caller-contract violation.
public(package) fun deposit<CoinType>(
    s:        OwnerState<CoinType>,
    incoming: Balance<CoinType>,
): OwnerState<CoinType> {
    match (s) {
        OwnerState::CashFlow { mut balance } => {
            balance.join(incoming);
            OwnerState::CashFlow { balance }
        },
        OwnerState::StopFlow { balance: _b } => abort EInvariantViolation,
    }
}

/// Drain all earnings as a separated Balance. State is preserved
/// (StopFlow stays StopFlow, CashFlow stays CashFlow); only the
/// inner balance is replaced with a fresh zero. Allowed in both
/// states — the owner pulls everything regardless of rental activity.
public(package) fun withdraw<CoinType>(
    s: OwnerState<CoinType>,
): (OwnerState<CoinType>, Balance<CoinType>) {
    match (s) {
        OwnerState::StopFlow { balance } =>
            (OwnerState::StopFlow { balance: balance::zero<CoinType>() }, balance),
        OwnerState::CashFlow { balance } =>
            (OwnerState::CashFlow { balance: balance::zero<CoinType>() }, balance),
    }
}

/// Read the current balance value. State-agnostic.
public(package) fun value<CoinType>(s: &OwnerState<CoinType>): u64 {
    match (s) {
        OwnerState::StopFlow { balance } => balance.value(),
        OwnerState::CashFlow { balance } => balance.value(),
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_stop_flow<CoinType>(s: &OwnerState<CoinType>): bool {
    match (s) {
        OwnerState::StopFlow { balance: _b } => true,
        OwnerState::CashFlow { balance: _b } => false,
    }
}

#[test_only]
public fun is_cash_flow<CoinType>(s: &OwnerState<CoinType>): bool {
    match (s) {
        OwnerState::CashFlow { balance: _b } => true,
        OwnerState::StopFlow { balance: _b } => false,
    }
}

/// Destroy any OwnerState at the end of a test, releasing its
/// balance via `balance::destroy_for_testing`. State-agnostic.
#[test_only]
public fun destroy_for_testing<CoinType>(s: OwnerState<CoinType>) {
    let b = match (s) {
        OwnerState::StopFlow { balance } => balance,
        OwnerState::CashFlow { balance } => balance,
    };
    balance::destroy_for_testing(b);
}
