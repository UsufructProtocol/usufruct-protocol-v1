// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::descent_policy_state;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EDescentCeilingZero:     u64 = 0;
const EMinNotLtMax:            u64 = 2;
#[test_only] const EDescentSkippedNoWindow: u64 = 1;

// === Structs ===

public enum DescentPolicyState has copy, drop, store {
    Skipped,
    Window        { ceiling: Duration },
    RandomInRange { min: Duration, max: Duration },
}

// === Public Functions ===

public fun new_descent_skipped(): DescentPolicyState { DescentPolicyState::Skipped }

public fun new_descent_window(ceiling: Duration): DescentPolicyState {
    assert!(phases::duration_ms(ceiling) > 0, EDescentCeilingZero);
    DescentPolicyState::Window { ceiling }
}

public fun new_descent_random_in_range(min: Duration, max: Duration): DescentPolicyState {
    assert!(phases::duration_ms(min) > 0, EDescentCeilingZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    DescentPolicyState::RandomInRange { min, max }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_skipped(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Skipped => true, _ => false }
}
public(package) fun proj_is_window(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Window { .. } => true, _ => false }
}
public(package) fun proj_is_random_in_range(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::RandomInRange { .. } => true, _ => false }
}
public(package) fun proj_window_ceiling(policy: &DescentPolicyState): Option<Duration> {
    match (policy) {
        DescentPolicyState::Window { ceiling } => option::some(*ceiling),
        _ => option::none(),
    }
}
public(package) fun proj_range_min(policy: &DescentPolicyState): Option<Duration> {
    match (policy) {
        DescentPolicyState::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}
public(package) fun proj_range_max(policy: &DescentPolicyState): Option<Duration> {
    match (policy) {
        DescentPolicyState::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Package Functions ===

/// Resolve the policy to a concrete Duration (the descent window).
///   Skipped         → Duration(0)      collapses immediately at phase_start
///   Window          → ceiling          collapses at phase_start + ceiling
///   RandomInRange   → draw[min, max]   collapses at phase_start + draw
public(package) fun resolve(policy: &DescentPolicyState, generator: &mut RandomGenerator): Duration {
    match (policy) {
        DescentPolicyState::Skipped                    => phases::zero(),
        DescentPolicyState::Window { ceiling }         => *ceiling,
        DescentPolicyState::RandomInRange { min, max } => phases::duration(
            generator.generate_u64_in_range(phases::duration_ms(*min), phases::duration_ms(*max))
        ),
    }
}

/// Whether the descent window has expired — called with the resolved window Duration.
public(package) fun has_expired(
    resolved:    Duration,
    phase_start: Timestamp,
    now:         Timestamp,
): Boundary {
    phases::check_boundary(phase_start, resolved, now)
}

/// Canonical auction-collapse boundary — called with the resolved window Duration.
public(package) fun expiry_at(
    resolved:    Duration,
    phase_start: Timestamp,
): Timestamp {
    phases::boundary_at(phase_start, resolved)
}


// === Test Functions ===

#[test_only]
public fun e_descent_ceiling_zero(): u64 { EDescentCeilingZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }

/// Width of the descent window. Aborts on Skipped and RandomInRange —
/// only valid for the Window variant. Test-only; production uses
/// `proj_window_ceiling` which returns `Option<Duration>` instead.
#[test_only]
public fun window_ceiling(policy: &DescentPolicyState): Duration {
    match (policy) {
        DescentPolicyState::Window { ceiling }        => *ceiling,
        DescentPolicyState::Skipped
        | DescentPolicyState::RandomInRange { .. }    => abort EDescentSkippedNoWindow,
    }
}
