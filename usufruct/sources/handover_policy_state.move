// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::handover_policy_state;

// === Imports ===

use usufruct::phases;

// === Errors ===

const EHandoverFloorZero: u64 = 0;

// === Structs ===

public enum HandoverPolicyState has copy, drop, store {
    Instant,
    Countdown { floor_ms: u64 },
    FixedTime,
}

// === Public Functions ===

public fun new_handover_instant():    HandoverPolicyState { HandoverPolicyState::Instant }
public fun new_handover_fixed_time(): HandoverPolicyState { HandoverPolicyState::FixedTime }

public fun new_handover_countdown(floor_ms: u64): HandoverPolicyState {
    assert!(floor_ms > 0, EHandoverFloorZero);
    HandoverPolicyState::Countdown { floor_ms }
}

// === Package Functions ===

/// True iff the handover countdown has expired — the protocol should
/// finalize the pending bid.
///   - Instant   collapses to true (no countdown to wait).
///   - FixedTime expires when `phase_start_ms + tenure_ceiling` is
///               reached.
///   - Countdown expires when either the countdown floor elapses
///               since `bid_time_ms`, or the tenure ceiling is
///               reached — whichever comes first. The saturation
///               rule of spec §5.1, expressed as a disjunction:
///               `clock >= min(A, B)  ⇔  clock >= A  ∨  clock >= B`.
public(package) fun has_expired(
    policy:         &HandoverPolicyState,
    bid_time_ms:    u64,
    phase_start_ms: u64,
    tenure_ceiling: u64,
    now_ms:         u64,
): bool {
    match (policy) {
        // Instant fires from `bid_time_ms` onward: zero countdown means
        // the gate opens at the moment of the bid, not vacuously before.
        // Defensive monotonicity — preserves the sister identity
        // `has_expired ⇔ now >= expiry_at` unconditionally (Instant's
        // expiry_at is bid_time_ms). In production, clock-monotone makes
        // this equivalent to `=> true`.
        HandoverPolicyState::Instant   => phases::has_passed(bid_time_ms,    0,              now_ms),
        HandoverPolicyState::FixedTime => phases::has_passed(phase_start_ms, tenure_ceiling, now_ms),
        HandoverPolicyState::Countdown { floor_ms } =>
            phases::has_passed(bid_time_ms,    *floor_ms,      now_ms) ||
            phases::has_passed(phase_start_ms, tenure_ceiling, now_ms),
    }
}

/// True iff a `Countdown` variant's `floor_ms` is strictly less than
/// the given ceiling. `Instant` and `FixedTime` carry no floor and
/// satisfy the predicate vacuously. Used by `config::new_config` to
/// enforce the cross-field constraint `Countdown.floor_ms <
/// tenure_ceiling` (equality is the FixedTime variant).
public(package) fun countdown_floor_lt(policy: &HandoverPolicyState, ceiling: u64): bool {
    match (policy) {
        HandoverPolicyState::Countdown { floor_ms }            => *floor_ms < ceiling,
        HandoverPolicyState::Instant | HandoverPolicyState::FixedTime => true,
    }
}

/// Optional countdown floor for display purposes.
///   Countdown { floor_ms } → Some(floor_ms)
///   Instant | FixedTime    → None (no configurable countdown floor)
public(package) fun countdown_floor_ms_opt(policy: &HandoverPolicyState): Option<u64> {
    match (policy) {
        HandoverPolicyState::Countdown { floor_ms }               => option::some(*floor_ms),
        HandoverPolicyState::Instant | HandoverPolicyState::FixedTime  => option::none(),
    }
}

/// True iff the policy is `Instant` — a bid immediately triggers handover
/// with no protection window for the current tenant.
public(package) fun is_instant(policy: &HandoverPolicyState): bool {
    match (policy) {
        HandoverPolicyState::Instant => true,
        _                       => false,
    }
}

/// True iff the policy is `FixedTime` — the handover fires at the end of
/// the current tenure regardless of when the bid was placed.
public(package) fun is_fixed_time(policy: &HandoverPolicyState): bool {
    match (policy) {
        HandoverPolicyState::FixedTime => true,
        _                         => false,
    }
}

/// Canonical handover boundary timestamp — the moment at which the
/// pending bid finalizes. Sister view of `has_expired`: the bool
/// dispatcher answers "did we cross the boundary?", this one names
/// the boundary itself for downstream consumers (credit clamp, event
/// payload, `do_handover` cascade).
///
/// Saturation rule (spec §5.1): Countdown clamps to the tenure
/// boundary via `min`; FixedTime is the boundary itself; Instant
/// collapses to `bid_time_ms` (boundary trivially reached, gate fires
/// on the next APT iteration).
public(package) fun expiry_at(
    policy:         &HandoverPolicyState,
    bid_time_ms:    u64,
    phase_start_ms: u64,
    tenure_ceiling: u64,
): u64 {
    match (policy) {
        HandoverPolicyState::Instant   => bid_time_ms,
        HandoverPolicyState::FixedTime => phases::boundary_at(phase_start_ms, tenure_ceiling),
        HandoverPolicyState::Countdown { floor_ms } =>
            phases::earliest(
                phases::boundary_at(bid_time_ms,    *floor_ms),
                phases::boundary_at(phase_start_ms, tenure_ceiling),
            ),
    }
}
