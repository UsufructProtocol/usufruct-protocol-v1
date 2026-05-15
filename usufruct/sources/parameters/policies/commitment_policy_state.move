// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::commitment_policy_state;

// === Imports ===

use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const ECommitmentFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

public enum CommitmentPolicyState has copy, drop, store {
    Immediate,
    Deferred { floor: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_immediate(): CommitmentPolicyState { CommitmentPolicyState::Immediate }

public fun new_deferred(floor: Duration): CommitmentPolicyState {
    assert!(phases::duration_ms(floor) > 0, ECommitmentFloorZero);
    CommitmentPolicyState::Deferred { floor }
}

// === View Functions ===

public(package) fun proj_is_immediate(policy: &CommitmentPolicyState): bool {
    match (policy) { CommitmentPolicyState::Immediate => true, _ => false }
}
public(package) fun proj_is_deferred(policy: &CommitmentPolicyState): bool {
    match (policy) { CommitmentPolicyState::Deferred { .. } => true, _ => false }
}
public(package) fun proj_floor_ms(policy: &CommitmentPolicyState): Option<Duration> {
    match (policy) {
        CommitmentPolicyState::Deferred { floor } => option::some(*floor),
        CommitmentPolicyState::Immediate          => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun resolve(policy: &CommitmentPolicyState): Duration {
    match (policy) {
        CommitmentPolicyState::Immediate          => phases::zero(),
        CommitmentPolicyState::Deferred { floor } => *floor,
    }
}

public(package) fun unlock_at(resolved: Duration, at: Timestamp): Timestamp {
    phases::boundary_at(at, resolved)
}

public(package) fun is_unlocked(resolved: Duration, at: Timestamp, now: Timestamp): Boundary {
    phases::check_boundary(at, resolved, now)
}

// === Private Functions ===

// === Test Functions ===

