// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::tenure_duration_policy;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Duration};

// === Errors ===

const EDurationZero: u64 = 0;
const EMinNotLtMax:  u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum TenureDurationPolicy has copy, drop, store {
    Fixed { ceiling: Duration },
    RandomInRange { min: Duration, max: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_fixed(ceiling: Duration): TenureDurationPolicy {
    assert!(phases::duration_ms(ceiling) > 0, EDurationZero);
    TenureDurationPolicy::Fixed { ceiling }
}

public fun new_random_in_range(min: Duration, max: Duration): TenureDurationPolicy {
    assert!(phases::duration_ms(min) > 0, EDurationZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    TenureDurationPolicy::RandomInRange { min, max }
}

// === View Functions ===

public(package) fun proj_is_fixed(policy: &TenureDurationPolicy): bool {
    match (policy) { TenureDurationPolicy::Fixed { .. } => true, _ => false }
}

public(package) fun proj_is_random_in_range(policy: &TenureDurationPolicy): bool {
    match (policy) { TenureDurationPolicy::RandomInRange { .. } => true, _ => false }
}

public(package) fun proj_fixed_ceiling(policy: &TenureDurationPolicy): Option<Duration> {
    match (policy) {
        TenureDurationPolicy::Fixed { ceiling } => option::some(*ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_range_min(policy: &TenureDurationPolicy): Option<Duration> {
    match (policy) {
        TenureDurationPolicy::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}

public(package) fun proj_range_max(policy: &TenureDurationPolicy): Option<Duration> {
    match (policy) {
        TenureDurationPolicy::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun proj_min_ceiling(policy: &TenureDurationPolicy): Duration {
    match (policy) {
        TenureDurationPolicy::Fixed { ceiling }           => *ceiling,
        TenureDurationPolicy::RandomInRange { min, .. }   => *min,
    }
}

public(package) fun resolve(policy: &TenureDurationPolicy, generator: &mut RandomGenerator): Duration {
    match (policy) {
        TenureDurationPolicy::Fixed { ceiling } => *ceiling,
        TenureDurationPolicy::RandomInRange { min, max } => {
            let value = generator.generate_u64_in_range(
                phases::duration_ms(*min),
                phases::duration_ms(*max),
            );
            phases::duration(value)
        },
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_duration_zero(): u64 { EDurationZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }

