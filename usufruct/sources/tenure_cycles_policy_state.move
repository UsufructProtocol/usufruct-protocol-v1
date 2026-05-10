// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenure_cycles_policy_state;

// === Imports ===

use usufruct::cycles::{Self, Cycles};

// === Errors ===

const EMultiCycleNotAllowed: u64 = 0;

// === Constants ===

// === Structs ===

public enum TenureCyclesPolicyState has copy, drop, store {
    Single,
    Multi,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_single(): TenureCyclesPolicyState { TenureCyclesPolicyState::Single }
public fun new_multi():  TenureCyclesPolicyState { TenureCyclesPolicyState::Multi  }

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_single(policy: &TenureCyclesPolicyState): bool {
    match (policy) { TenureCyclesPolicyState::Single => true, _ => false }
}

public(package) fun proj_is_multi(policy: &TenureCyclesPolicyState): bool {
    match (policy) { TenureCyclesPolicyState::Multi => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

/// Aborts if the owner only allows single-cycle tenancy and `cycles` > 1.
public(package) fun validate(policy: &TenureCyclesPolicyState, cycles: Cycles) {
    match (policy) {
        TenureCyclesPolicyState::Single => assert!(cycles::is_single(cycles), EMultiCycleNotAllowed),
        TenureCyclesPolicyState::Multi  => (),
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_multi_cycle_not_allowed(): u64 { EMultiCycleNotAllowed }
