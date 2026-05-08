// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::handover_policy_state;

// === Imports ===

use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EHandoverFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

public enum HandoverPolicyState has copy, drop, store {
    Instant,
    Countdown { floor_ms: u64 },
    FixedTime,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_handover_instant():    HandoverPolicyState { HandoverPolicyState::Instant }
public fun new_handover_fixed_time(): HandoverPolicyState { HandoverPolicyState::FixedTime }

public fun new_handover_countdown(floor_ms: u64): HandoverPolicyState {
    assert!(floor_ms > 0, EHandoverFloorZero);
    HandoverPolicyState::Countdown { floor_ms }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_instant(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::Instant => true, _ => false }
}
public(package) fun proj_is_fixed_time(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::FixedTime => true, _ => false }
}
public(package) fun proj_is_countdown(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::Countdown { .. } => true, _ => false }
}
public(package) fun proj_countdown_floor_ms(policy: &HandoverPolicyState): Option<Duration> {
    match (policy) {
        HandoverPolicyState::Countdown { floor_ms } => option::some(phases::duration(*floor_ms)),
        HandoverPolicyState::Instant | HandoverPolicyState::FixedTime => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Whether the handover countdown has expired — the pending bid should finalize.
///   - Instant   fires at `bid_time` (zero countdown).
///   - FixedTime fires at `phase_start + tenure_ceiling`.
///   - Countdown fires at `min(bid_time + floor, phase_start + tenure_ceiling)` —
///               whichever of the two boundaries is crossed first.
public(package) fun has_expired(
    policy:         &HandoverPolicyState,
    bid_time:       Timestamp,
    phase_start:    Timestamp,
    tenure_ceiling: Duration,
    now:            Timestamp,
): Boundary {
    match (policy) {
        HandoverPolicyState::Instant   =>
            phases::check_boundary(bid_time, phases::zero(), now),
        HandoverPolicyState::FixedTime =>
            phases::check_boundary(phase_start, tenure_ceiling, now),
        // Crosses when either boundary is reached; equivalent to
        // `check_boundary(min(A,B), zero(), now)` by min identity.
        HandoverPolicyState::Countdown { floor_ms } =>
            phases::check_boundary(
                phases::earliest(
                    phases::boundary_at(bid_time,    phases::duration(*floor_ms)),
                    phases::boundary_at(phase_start, tenure_ceiling),
                ),
                phases::zero(),
                now,
            ),
    }
}

/// True iff a `Countdown` variant's `floor_ms` is strictly less than the
/// given ceiling. Used by `config::new_config` to enforce the cross-field
/// constraint `Countdown.floor_ms < tenure_ceiling`.
public(package) fun countdown_floor_lt(policy: &HandoverPolicyState, ceiling: Duration): bool {
    match (policy) {
        HandoverPolicyState::Countdown { floor_ms }            => *floor_ms < phases::duration_ms(ceiling),
        HandoverPolicyState::Instant | HandoverPolicyState::FixedTime => true,
    }
}

/// Canonical handover boundary timestamp — the moment the pending bid finalizes.
public(package) fun expiry_at(
    policy:         &HandoverPolicyState,
    bid_time:       Timestamp,
    phase_start:    Timestamp,
    tenure_ceiling: Duration,
): Timestamp {
    match (policy) {
        HandoverPolicyState::Instant   => bid_time,
        HandoverPolicyState::FixedTime => phases::boundary_at(phase_start, tenure_ceiling),
        HandoverPolicyState::Countdown { floor_ms } =>
            phases::earliest(
                phases::boundary_at(bid_time,    phases::duration(*floor_ms)),
                phases::boundary_at(phase_start, tenure_ceiling),
            ),
    }
}

// === Private Functions ===

// === Test Functions ===
