// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::descent_policy;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EDescentCeilingZero:     u64 = 0;
const EMinNotLtMax:            u64 = 2;
#[test_only] const EDescentSkippedNoWindow: u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum DescentPolicy has copy, drop, store {
    Skipped,
    Window        { ceiling: Duration },
    RandomInRange { min: Duration, max: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_descent_skipped(): DescentPolicy { DescentPolicy::Skipped }

public fun new_descent_window(ceiling: Duration): DescentPolicy {
    assert!(phases::duration_ms(ceiling) > 0, EDescentCeilingZero);
    DescentPolicy::Window { ceiling }
}

public fun new_descent_random_in_range(min: Duration, max: Duration): DescentPolicy {
    assert!(phases::duration_ms(min) > 0, EDescentCeilingZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    DescentPolicy::RandomInRange { min, max }
}

// === View Functions ===

public(package) fun proj_is_skipped(policy: &DescentPolicy): bool {
    match (policy) { DescentPolicy::Skipped => true, _ => false }
}
public(package) fun proj_is_window(policy: &DescentPolicy): bool {
    match (policy) { DescentPolicy::Window { .. } => true, _ => false }
}
public(package) fun proj_is_random_in_range(policy: &DescentPolicy): bool {
    match (policy) { DescentPolicy::RandomInRange { .. } => true, _ => false }
}
public(package) fun proj_window_ceiling(policy: &DescentPolicy): Option<Duration> {
    match (policy) {
        DescentPolicy::Window { ceiling } => option::some(*ceiling),
        _ => option::none(),
    }
}
public(package) fun proj_range_min(policy: &DescentPolicy): Option<Duration> {
    match (policy) {
        DescentPolicy::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}
public(package) fun proj_range_max(policy: &DescentPolicy): Option<Duration> {
    match (policy) {
        DescentPolicy::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun resolve(policy: &DescentPolicy, generator: &mut RandomGenerator): Duration {
    match (policy) {
        DescentPolicy::Skipped                    => phases::zero(),
        DescentPolicy::Window { ceiling }         => *ceiling,
        DescentPolicy::RandomInRange { min, max } => phases::duration(
            generator.generate_u64_in_range(phases::duration_ms(*min), phases::duration_ms(*max))
        ),
    }
}

public(package) fun has_expired(
    resolved:    Duration,
    phase_start: Timestamp,
    now:         Timestamp,
): Boundary {
    phases::check_boundary(phase_start, resolved, now)
}

public(package) fun expiry_at(
    resolved:    Duration,
    phase_start: Timestamp,
): Timestamp {
    phases::boundary_at(phase_start, resolved)
}


// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_descent_ceiling_zero(): u64 { EDescentCeilingZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }

#[test_only]
public fun window_ceiling(policy: &DescentPolicy): Duration {
    match (policy) {
        DescentPolicy::Window { ceiling }        => *ceiling,
        DescentPolicy::Skipped
        | DescentPolicy::RandomInRange { .. }    => abort EDescentSkippedNoWindow,
    }
}

