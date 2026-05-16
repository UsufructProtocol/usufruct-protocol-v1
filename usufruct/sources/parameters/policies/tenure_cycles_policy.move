// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenure_cycles_policy;

// === Imports ===

use usufruct::cycles::{Self, Cycles};

// === Errors ===

const EMultiCycleNotAllowed: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum TenureCyclesPolicy has copy, drop, store {
    Single,
    Multi,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_single(): TenureCyclesPolicy { TenureCyclesPolicy::Single }
public fun new_multi():  TenureCyclesPolicy { TenureCyclesPolicy::Multi  }

// === View Functions ===

public(package) fun proj_is_single(policy: &TenureCyclesPolicy): bool {
    match (policy) { TenureCyclesPolicy::Single => true, _ => false }
}

public(package) fun proj_is_multi(policy: &TenureCyclesPolicy): bool {
    match (policy) { TenureCyclesPolicy::Multi => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun validate(policy: &TenureCyclesPolicy, cycles: Cycles) {
    match (policy) {
        TenureCyclesPolicy::Single => assert!(cycles::is_single(cycles), EMultiCycleNotAllowed),
        TenureCyclesPolicy::Multi  => (),
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_multi_cycle_not_allowed(): u64 { EMultiCycleNotAllowed }

