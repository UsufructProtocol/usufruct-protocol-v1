// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenure_duration_policy;

// === Imports ===

use usufruct::phases::{Self, Duration};

// === Errors ===

const EDurationZero: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum TenureDurationPolicy has copy, drop, store {
    Fixed { ceiling: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public(package) fun new_fixed(ceiling: Duration): TenureDurationPolicy {
    assert!(phases::duration_ms(ceiling) > 0, EDurationZero);
    TenureDurationPolicy::Fixed { ceiling }
}

// === View Functions ===

public(package) fun proj_is_fixed(_policy: &TenureDurationPolicy): bool { true }

public(package) fun proj_fixed_ceiling(policy: &TenureDurationPolicy): Option<Duration> {
    match (policy) { TenureDurationPolicy::Fixed { ceiling } => option::some(*ceiling) }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun proj_min_ceiling(policy: &TenureDurationPolicy): Duration {
    match (policy) { TenureDurationPolicy::Fixed { ceiling } => *ceiling }
}

public(package) fun compute_duration(policy: &TenureDurationPolicy): Duration {
    match (policy) { TenureDurationPolicy::Fixed { ceiling } => *ceiling }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_duration_zero(): u64 { EDurationZero }

