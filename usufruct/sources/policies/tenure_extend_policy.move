// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenure_extend_policy;

// === Imports ===

use std::string::String;
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

// === View Functions ===

public(package) fun proj_is_single(policy: &TenureExtendPolicy): bool {
    match (policy) { TenureExtendPolicy::Single => true, _ => false }
}

public(package) fun proj_is_multi(policy: &TenureExtendPolicy): bool {
    match (policy) { TenureExtendPolicy::Multi => true, _ => false }
}

public(package) fun proj_tenure_extend_policy(policy: &TenureExtendPolicy): String {
    match (policy) {
        TenureExtendPolicy::Single => b"Single".to_string(),
        TenureExtendPolicy::Multi  => b"Multi".to_string(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_single(): TenureExtendPolicy { TenureExtendPolicy::Single }
public(package) fun new_multi():  TenureExtendPolicy { TenureExtendPolicy::Multi  }

public(package) fun validate(policy: &TenureExtendPolicy, cycles: Tenures) {
    match (policy) {
        TenureExtendPolicy::Single => assert!(tenures::proj_is_single(cycles), EMultiCycleNotAllowed),
        TenureExtendPolicy::Multi  => (),
    }
}

// === Private Functions ===

// === Test Functions ===



