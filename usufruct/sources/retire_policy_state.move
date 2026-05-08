// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::retire_policy_state;

// === Imports ===

use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const ERetireFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

public enum RetirePolicyState has copy, drop, store {
    Immediate,
    Deferred { floor: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_retire_immediate(): RetirePolicyState { RetirePolicyState::Immediate }

public fun new_retire_deferred(floor: Duration): RetirePolicyState {
    assert!(phases::duration_ms(floor) > 0, ERetireFloorZero);
    RetirePolicyState::Deferred { floor }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_immediate(policy: &RetirePolicyState): bool {
    match (policy) { RetirePolicyState::Immediate => true, _ => false }
}
public(package) fun proj_is_deferred(policy: &RetirePolicyState): bool {
    match (policy) { RetirePolicyState::Deferred { .. } => true, _ => false }
}
public(package) fun proj_floor_ms(policy: &RetirePolicyState): Option<Duration> {
    match (policy) {
        RetirePolicyState::Deferred { floor } => option::some(*floor),
        RetirePolicyState::Immediate             => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Absolute timestamp at which `retire()` becomes available.
public(package) fun unlock_at(
    policy: &RetirePolicyState,
    at:     Timestamp,
): Timestamp {
    match (policy) {
        RetirePolicyState::Immediate             => phases::boundary_at(at, phases::zero()),
        RetirePolicyState::Deferred { floor } => phases::boundary_at(at, *floor),
    }
}

/// Whether `retire()` may proceed.
public(package) fun is_unlocked(
    policy: &RetirePolicyState,
    at:     Timestamp,
    now:    Timestamp,
): Boundary {
    match (policy) {
        RetirePolicyState::Immediate             =>
            phases::check_boundary(at, phases::zero(), now),
        RetirePolicyState::Deferred { floor } =>
            phases::check_boundary(at, *floor, now),
    }
}

// === Private Functions ===

// === Test Functions ===
