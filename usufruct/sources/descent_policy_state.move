// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::descent_policy_state;

// === Imports ===

use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EDescentCeilingZero:     u64 = 0;
const EDescentSkippedNoWindow: u64 = 1;

// === Constants ===

// === Structs ===

public enum DescentPolicyState has copy, drop, store {
    Skipped,
    Window { ceiling: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_descent_skipped(): DescentPolicyState { DescentPolicyState::Skipped }

public fun new_descent_window(ceiling: Duration): DescentPolicyState {
    assert!(phases::duration_ms(ceiling) > 0, EDescentCeilingZero);
    DescentPolicyState::Window { ceiling }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_skipped(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Skipped => true, _ => false }
}
public(package) fun proj_is_window(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Window { .. } => true, _ => false }
}
public(package) fun proj_window_ceiling(policy: &DescentPolicyState): Option<Duration> {
    match (policy) {
        DescentPolicyState::Window { ceiling } => option::some(*ceiling),
        DescentPolicyState::Skipped               => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Resolve the policy to a concrete Duration (the descent window).
///   Skipped → Duration(0)      collapses immediately at phase_start
///   Window  → ceiling          collapses at phase_start + ceiling
public(package) fun resolve(policy: &DescentPolicyState): Duration {
    match (policy) {
        DescentPolicyState::Skipped                => phases::zero(),
        DescentPolicyState::Window { ceiling }     => *ceiling,
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

/// Width of the descent window. Aborts on `Skipped` — callers that
/// ask for this are only reachable under `Window`.
public(package) fun window_ceiling(policy: &DescentPolicyState): Duration {
    match (policy) {
        DescentPolicyState::Window { ceiling } => *ceiling,
        DescentPolicyState::Skipped               => abort EDescentSkippedNoWindow,
    }
}

// === Private Functions ===

// === Test Functions ===
