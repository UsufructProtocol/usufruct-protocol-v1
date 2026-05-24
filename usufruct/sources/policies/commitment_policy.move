// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::commitment_policy;

// === Imports ===

use std::string::String;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const ECommitmentFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

public enum CommitmentPolicy has copy, drop, store {
    Immediate,
    Deferred { floor: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_immediate(policy: &CommitmentPolicy): bool {
    match (policy) { CommitmentPolicy::Immediate => true, _ => false }
}
public(package) fun proj_is_deferred(policy: &CommitmentPolicy): bool {
    match (policy) { CommitmentPolicy::Deferred { .. } => true, _ => false }
}
public(package) fun proj_floor_ms(policy: &CommitmentPolicy): Option<Duration> {
    match (policy) {
        CommitmentPolicy::Deferred { floor } => option::some(*floor),
        CommitmentPolicy::Immediate          => option::none(),
    }
}

public(package) fun proj_commitment_policy(policy: &CommitmentPolicy): String {
    match (policy) {
        CommitmentPolicy::Immediate    => b"Immediate".to_string(),
        CommitmentPolicy::Deferred {..} => b"Deferred".to_string(),
    }
}
public(package) fun proj_commitment_floor_ms(policy: &CommitmentPolicy): Option<u64> {
    match (policy) {
        CommitmentPolicy::Deferred { floor } => option::some(phases::duration_ms(*floor)),
        CommitmentPolicy::Immediate          => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_immediate(): CommitmentPolicy { CommitmentPolicy::Immediate }

public(package) fun new_deferred(floor: Duration): CommitmentPolicy {
    assert!(phases::duration_ms(floor) > 0, ECommitmentFloorZero);
    CommitmentPolicy::Deferred { floor }
}

public(package) fun compute_duration(policy: &CommitmentPolicy): Duration {
    match (policy) {
        CommitmentPolicy::Immediate          => phases::zero(),
        CommitmentPolicy::Deferred { floor } => *floor,
    }
}

public(package) fun compute_unlock_at(resolved: Duration, at: Timestamp): Timestamp {
    phases::compute_boundary_at(at, resolved)
}

public(package) fun compute_unlock_boundary(resolved: Duration, at: Timestamp, now: Timestamp): Boundary {
    phases::compute_boundary(at, resolved, now)
}

// === Private Functions ===

// === Test Functions ===

