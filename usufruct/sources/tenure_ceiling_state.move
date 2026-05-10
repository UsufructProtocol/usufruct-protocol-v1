// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::tenure_ceiling_state;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Duration};

// === Errors ===

const EDurationZero: u64 = 0;
const EMinNotLtMax:  u64 = 1;

// === Structs ===

public enum TenureCeilingState has copy, drop, store {
    Fixed { ceiling: Duration },
    RandomInRange { min: Duration, max: Duration },
}

// === Public Functions ===

public fun new_fixed(ceiling: Duration): TenureCeilingState {
    assert!(phases::duration_ms(ceiling) > 0, EDurationZero);
    TenureCeilingState::Fixed { ceiling }
}

public fun new_random_in_range(min: Duration, max: Duration): TenureCeilingState {
    assert!(phases::duration_ms(min) > 0, EDurationZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    TenureCeilingState::RandomInRange { min, max }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_fixed(policy: &TenureCeilingState): bool {
    match (policy) { TenureCeilingState::Fixed { .. } => true, _ => false }
}

public(package) fun proj_is_random_in_range(policy: &TenureCeilingState): bool {
    match (policy) { TenureCeilingState::RandomInRange { .. } => true, _ => false }
}

public(package) fun proj_fixed_ceiling(policy: &TenureCeilingState): Option<Duration> {
    match (policy) {
        TenureCeilingState::Fixed { ceiling } => option::some(*ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_range_min(policy: &TenureCeilingState): Option<Duration> {
    match (policy) {
        TenureCeilingState::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}

public(package) fun proj_range_max(policy: &TenureCeilingState): Option<Duration> {
    match (policy) {
        TenureCeilingState::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Package Functions ===

/// Returns the minimum possible ceiling for SDK views and cross-field validation.
/// Fixed: the fixed ceiling. RandomInRange: the minimum of the range (conservative).
/// Countdown handover floor must be < min_ceiling to hold for all draws.
public(package) fun min_ceiling(policy: &TenureCeilingState): Duration {
    match (policy) {
        TenureCeilingState::Fixed { ceiling }           => *ceiling,
        TenureCeilingState::RandomInRange { min, .. }   => *min,
    }
}

/// Resolves the policy to a concrete Duration.
/// Fixed: returns the fixed ceiling (generator unused).
/// RandomInRange: draws uniformly from [min, max].
public(package) fun resolve(policy: &TenureCeilingState, generator: &mut RandomGenerator): Duration {
    match (policy) {
        TenureCeilingState::Fixed { ceiling } => *ceiling,
        TenureCeilingState::RandomInRange { min, max } => {
            let value = generator.generate_u64_in_range(
                phases::duration_ms(*min),
                phases::duration_ms(*max),
            );
            phases::duration(value)
        },
    }
}

// === Test Functions ===

#[test_only]
public fun e_duration_zero(): u64 { EDurationZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }
