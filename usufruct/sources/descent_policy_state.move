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
    Window { ceiling_ms: u64 },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_descent_skipped(): DescentPolicyState { DescentPolicyState::Skipped }

public fun new_descent_window(ceiling_ms: u64): DescentPolicyState {
    assert!(ceiling_ms > 0, EDescentCeilingZero);
    DescentPolicyState::Window { ceiling_ms }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_skipped(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Skipped => true, _ => false }
}
public(package) fun proj_is_window(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Window { .. } => true, _ => false }
}
public(package) fun proj_window_ceiling(policy: &DescentPolicyState): Option<u64> {
    match (policy) {
        DescentPolicyState::Window { ceiling_ms } => option::some(*ceiling_ms),
        DescentPolicyState::Skipped               => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Whether the descent window has expired — the auction should collapse to `Idle`.
///   - Skipped collapses immediately at `phase_start` (zero window).
///   - Window expires when the ceiling elapses since `phase_start`.
public(package) fun has_expired(
    policy:      &DescentPolicyState,
    phase_start: Timestamp,
    now:         Timestamp,
): Boundary {
    match (policy) {
        DescentPolicyState::Skipped =>
            phases::check_boundary(phase_start, phases::zero(), now),
        DescentPolicyState::Window { ceiling_ms } =>
            phases::check_boundary(phase_start, phases::duration(*ceiling_ms), now),
    }
}

/// Canonical auction-collapse boundary — the moment `do_auction_expiry` fires.
/// Skipped collapses to `phase_start` itself.
public(package) fun expiry_at(
    policy:      &DescentPolicyState,
    phase_start: Timestamp,
): Timestamp {
    match (policy) {
        DescentPolicyState::Skipped               => phase_start,
        DescentPolicyState::Window { ceiling_ms } =>
            phases::boundary_at(phase_start, phases::duration(*ceiling_ms)),
    }
}

/// Width of the descent window. Aborts on `Skipped` — callers that
/// ask for this are only reachable under `Window`.
public(package) fun window_ceiling(policy: &DescentPolicyState): Duration {
    match (policy) {
        DescentPolicyState::Window { ceiling_ms } => phases::duration(*ceiling_ms),
        DescentPolicyState::Skipped               => abort EDescentSkippedNoWindow,
    }
}

// === Private Functions ===

// === Test Functions ===
