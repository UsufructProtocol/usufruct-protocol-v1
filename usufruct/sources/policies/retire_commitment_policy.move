// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::retire_commitment_policy;

// === Imports ===

use std::string::String;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const ERetireCommitmentFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

public enum RetireCommitmentPolicy has copy, drop, store {
    Immediate,
    Deferred { floor: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_immediate(policy: &RetireCommitmentPolicy): bool {
    match (policy) { RetireCommitmentPolicy::Immediate => true, _ => false }
}
public(package) fun proj_is_deferred(policy: &RetireCommitmentPolicy): bool {
    match (policy) { RetireCommitmentPolicy::Deferred { .. } => true, _ => false }
}
public(package) fun proj_floor_ms(policy: &RetireCommitmentPolicy): Option<Duration> {
    match (policy) {
        RetireCommitmentPolicy::Deferred { floor } => option::some(*floor),
        RetireCommitmentPolicy::Immediate          => option::none(),
    }
}

public(package) fun proj_retire_commitment_policy(policy: &RetireCommitmentPolicy): String {
    match (policy) {
        RetireCommitmentPolicy::Immediate    => b"Immediate".to_string(),
        RetireCommitmentPolicy::Deferred {..} => b"Deferred".to_string(),
    }
}
public(package) fun proj_retire_commitment_floor_ms(policy: &RetireCommitmentPolicy): Option<u64> {
    match (policy) {
        RetireCommitmentPolicy::Deferred { floor } => option::some(phases::duration_ms(*floor)),
        RetireCommitmentPolicy::Immediate          => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_immediate(): RetireCommitmentPolicy { RetireCommitmentPolicy::Immediate }

public(package) fun new_deferred(floor: Duration): RetireCommitmentPolicy {
    assert!(phases::duration_ms(floor) > 0, ERetireCommitmentFloorZero);
    RetireCommitmentPolicy::Deferred { floor }
}

public(package) fun compute_duration(policy: &RetireCommitmentPolicy): Duration {
    match (policy) {
        RetireCommitmentPolicy::Immediate          => phases::zero(),
        RetireCommitmentPolicy::Deferred { floor } => *floor,
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
