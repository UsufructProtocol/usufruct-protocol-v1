// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::ensemble_commitment_policy;

// === Imports ===

use std::string::String;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EEnsembleCommitmentFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

public enum EnsembleCommitmentPolicy has copy, drop, store {
    Immediate,
    Deferred { floor: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_immediate(policy: &EnsembleCommitmentPolicy): bool {
    match (policy) { EnsembleCommitmentPolicy::Immediate => true, _ => false }
}
public(package) fun proj_is_deferred(policy: &EnsembleCommitmentPolicy): bool {
    match (policy) { EnsembleCommitmentPolicy::Deferred { .. } => true, _ => false }
}
public(package) fun proj_floor_ms(policy: &EnsembleCommitmentPolicy): Option<Duration> {
    match (policy) {
        EnsembleCommitmentPolicy::Deferred { floor } => option::some(*floor),
        EnsembleCommitmentPolicy::Immediate          => option::none(),
    }
}

public(package) fun proj_ensemble_commitment_policy(policy: &EnsembleCommitmentPolicy): String {
    match (policy) {
        EnsembleCommitmentPolicy::Immediate    => b"Immediate".to_string(),
        EnsembleCommitmentPolicy::Deferred {..} => b"Deferred".to_string(),
    }
}
public(package) fun proj_ensemble_commitment_floor_ms(policy: &EnsembleCommitmentPolicy): Option<u64> {
    match (policy) {
        EnsembleCommitmentPolicy::Deferred { floor } => option::some(phases::duration_ms(*floor)),
        EnsembleCommitmentPolicy::Immediate          => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_immediate(): EnsembleCommitmentPolicy { EnsembleCommitmentPolicy::Immediate }

public(package) fun new_deferred(floor: Duration): EnsembleCommitmentPolicy {
    assert!(phases::duration_ms(floor) > 0, EEnsembleCommitmentFloorZero);
    EnsembleCommitmentPolicy::Deferred { floor }
}

public(package) fun compute_duration(policy: &EnsembleCommitmentPolicy): Duration {
    match (policy) {
        EnsembleCommitmentPolicy::Immediate          => phases::zero(),
        EnsembleCommitmentPolicy::Deferred { floor } => *floor,
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
