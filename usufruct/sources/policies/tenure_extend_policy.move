// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenure_extend_policy;

// === Imports ===

use usufruct::tenures::{Self, Tenures};

// === Errors ===

const EMultiCycleNotAllowed: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum TenureExtendPolicy has copy, drop, store {
    Single,
    Multi,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public(package) fun new_single(): TenureExtendPolicy { TenureExtendPolicy::Single }
public(package) fun new_multi():  TenureExtendPolicy { TenureExtendPolicy::Multi  }

// === View Functions ===

public(package) fun proj_is_single(policy: &TenureExtendPolicy): bool {
    match (policy) { TenureExtendPolicy::Single => true, _ => false }
}

public(package) fun proj_is_multi(policy: &TenureExtendPolicy): bool {
    match (policy) { TenureExtendPolicy::Multi => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun validate(policy: &TenureExtendPolicy, cycles: Tenures) {
    match (policy) {
        TenureExtendPolicy::Single => assert!(tenures::proj_is_single(cycles), EMultiCycleNotAllowed),
        TenureExtendPolicy::Multi  => (),
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_multi_cycle_not_allowed(): u64 { EMultiCycleNotAllowed }

