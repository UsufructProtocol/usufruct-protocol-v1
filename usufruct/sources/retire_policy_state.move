// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::retire_policy_state;

// === Imports ===

use usufruct::phases;

// === Errors ===

const ERetireFloorZero: u64 = 0;

// === Structs ===

public enum RetirePolicyState has copy, drop, store {
    Immediate,
    Deferred { floor_ms: u64 },
}

// === Public Functions ===

public fun new_retire_immediate(): RetirePolicyState { RetirePolicyState::Immediate }

public fun new_retire_deferred(floor_ms: u64): RetirePolicyState {
    assert!(floor_ms > 0, ERetireFloorZero);
    RetirePolicyState::Deferred { floor_ms }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_immediate(policy: &RetirePolicyState): bool {
    match (policy) { RetirePolicyState::Immediate => true, _ => false }
}
public(package) fun proj_is_deferred(policy: &RetirePolicyState): bool {
    match (policy) { RetirePolicyState::Deferred { .. } => true, _ => false }
}
public(package) fun proj_floor_ms(policy: &RetirePolicyState): Option<u64> {
    match (policy) {
        RetirePolicyState::Deferred { floor_ms } => option::some(*floor_ms),
        RetirePolicyState::Immediate             => option::none(),
    }
}

// === Package Functions ===

/// Absolute timestamp at which `retire()` becomes available.
///   Immediate             → integrated_at_ms (unlocked from creation)
///   Deferred { floor_ms } → integrated_at_ms + floor_ms
public(package) fun unlock_at_ms(
    policy:           &RetirePolicyState,
    integrated_at_ms: u64,
): u64 {
    match (policy) {
        RetirePolicyState::Immediate             => phases::boundary_at(integrated_at_ms, 0),
        RetirePolicyState::Deferred { floor_ms } => phases::boundary_at(integrated_at_ms, *floor_ms),
    }
}

/// True iff `retire()` may proceed.
///   - Immediate is always unlocked.
///   - Deferred unlocks when `floor_ms` elapses since
///     `integrated_at_ms`.
public(package) fun is_unlocked(
    policy:           &RetirePolicyState,
    integrated_at_ms: u64,
    now_ms:           u64,
): bool {
    match (policy) {
        // Immediate unlocks from `integrated_at_ms` onward: zero floor
        // means the gate opens at integration, not vacuously before.
        // Defensive monotonicity — every variant gates through the time
        // layer (`phases::has_passed`); none are vacuous. In production,
        // clock-monotone makes this equivalent to `=> true`.
        RetirePolicyState::Immediate             =>
            phases::has_passed(integrated_at_ms, 0, now_ms),
        RetirePolicyState::Deferred { floor_ms } =>
            phases::has_passed(integrated_at_ms, *floor_ms, now_ms),
    }
}
