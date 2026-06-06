// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::auction_window_policy;

// === Imports ===

use std::string::String;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EDescentCeilingZero: u64 = 0;
#[test_only] const EDescentOffNoFixed: u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum AuctionWindowPolicy has copy, drop, store {
    Off,
    Fixed { ceiling: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_off(policy: &AuctionWindowPolicy): bool {
    match (policy) { AuctionWindowPolicy::Off => true, _ => false }
}
public(package) fun proj_is_fixed(policy: &AuctionWindowPolicy): bool {
    match (policy) { AuctionWindowPolicy::Fixed { .. } => true, _ => false }
}
public(package) fun proj_fixed_ceiling(policy: &AuctionWindowPolicy): Option<Duration> {
    match (policy) {
        AuctionWindowPolicy::Fixed { ceiling } => option::some(*ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_auction_window_policy(policy: &AuctionWindowPolicy): String {
    match (policy) {
        AuctionWindowPolicy::Off          => b"Off".to_string(),
        AuctionWindowPolicy::Fixed { .. } => b"Fixed".to_string(),
    }
}
public(package) fun proj_auction_window_ceiling_ms(policy: &AuctionWindowPolicy): Option<u64> {
    match (policy) {
        AuctionWindowPolicy::Fixed { ceiling } => option::some(phases::duration_ms(*ceiling)),
        _                                       => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_descent_off(): AuctionWindowPolicy { AuctionWindowPolicy::Off }

public(package) fun new_descent_fixed(ceiling: Duration): AuctionWindowPolicy {
    assert!(phases::duration_ms(ceiling) > 0, EDescentCeilingZero);
    AuctionWindowPolicy::Fixed { ceiling }
}

public(package) fun compute_duration(policy: &AuctionWindowPolicy): Duration {
    match (policy) {
        AuctionWindowPolicy::Off             => phases::zero(),
        AuctionWindowPolicy::Fixed { ceiling } => *ceiling,
    }
}

public(package) fun compute_expiry_boundary(
    resolved:    Duration,
    phase_start: Timestamp,
    now:         Timestamp,
): Boundary {
    phases::compute_boundary(phase_start, resolved, now)
}

public(package) fun compute_expiry_at(
    resolved:    Duration,
    phase_start: Timestamp,
): Timestamp {
    phases::compute_boundary_at(phase_start, resolved)
}


// === Private Functions ===

// === Test Functions ===

#[test_only]
public(package) fun fixed_ceiling(policy: &AuctionWindowPolicy): Duration {
    match (policy) {
        AuctionWindowPolicy::Fixed { ceiling } => *ceiling,
        AuctionWindowPolicy::Off               => abort EDescentOffNoFixed,
    }
}

