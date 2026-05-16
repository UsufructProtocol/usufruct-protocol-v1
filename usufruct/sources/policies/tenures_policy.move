// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenures_policy;

// === Imports ===

use usufruct::tenures::{Self, Tenures};

// === Errors ===

const EMultiCycleNotAllowed: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum TenuresPolicy has copy, drop, store {
    Single,
    Multi,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_single(): TenuresPolicy { TenuresPolicy::Single }
public fun new_multi():  TenuresPolicy { TenuresPolicy::Multi  }

// === View Functions ===

public(package) fun proj_is_single(policy: &TenuresPolicy): bool {
    match (policy) { TenuresPolicy::Single => true, _ => false }
}

public(package) fun proj_is_multi(policy: &TenuresPolicy): bool {
    match (policy) { TenuresPolicy::Multi => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun validate(policy: &TenuresPolicy, cycles: Tenures) {
    match (policy) {
        TenuresPolicy::Single => assert!(tenures::is_single(cycles), EMultiCycleNotAllowed),
        TenuresPolicy::Multi  => (),
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_multi_cycle_not_allowed(): u64 { EMultiCycleNotAllowed }

