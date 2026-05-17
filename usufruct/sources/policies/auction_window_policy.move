// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::auction_window_policy;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EDescentCeilingZero:     u64 = 0;
const EMinNotLtMax:            u64 = 2;
#[test_only] const EDescentSkippedNoWindow: u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum AuctionWindowPolicy has copy, drop, store {
    Skipped,
    Window        { ceiling: Duration },
    RandomInRange { min: Duration, max: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_descent_skipped(): AuctionWindowPolicy { AuctionWindowPolicy::Skipped }

public fun new_descent_window(ceiling: Duration): AuctionWindowPolicy {
    assert!(phases::duration_ms(ceiling) > 0, EDescentCeilingZero);
    AuctionWindowPolicy::Window { ceiling }
}

public fun new_descent_random_in_range(min: Duration, max: Duration): AuctionWindowPolicy {
    assert!(phases::duration_ms(min) > 0, EDescentCeilingZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    AuctionWindowPolicy::RandomInRange { min, max }
}

// === View Functions ===

public(package) fun proj_is_skipped(policy: &AuctionWindowPolicy): bool {
    match (policy) { AuctionWindowPolicy::Skipped => true, _ => false }
}
public(package) fun proj_is_window(policy: &AuctionWindowPolicy): bool {
    match (policy) { AuctionWindowPolicy::Window { .. } => true, _ => false }
}
public(package) fun proj_is_random_in_range(policy: &AuctionWindowPolicy): bool {
    match (policy) { AuctionWindowPolicy::RandomInRange { .. } => true, _ => false }
}
public(package) fun proj_window_ceiling(policy: &AuctionWindowPolicy): Option<Duration> {
    match (policy) {
        AuctionWindowPolicy::Window { ceiling } => option::some(*ceiling),
        _ => option::none(),
    }
}
public(package) fun proj_range_min(policy: &AuctionWindowPolicy): Option<Duration> {
    match (policy) {
        AuctionWindowPolicy::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}
public(package) fun proj_range_max(policy: &AuctionWindowPolicy): Option<Duration> {
    match (policy) {
        AuctionWindowPolicy::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun compute_duration(policy: &AuctionWindowPolicy, generator: &mut RandomGenerator): Duration {
    match (policy) {
        AuctionWindowPolicy::Skipped                    => phases::zero(),
        AuctionWindowPolicy::Window { ceiling }         => *ceiling,
        AuctionWindowPolicy::RandomInRange { min, max } => phases::duration(
            generator.generate_u64_in_range(phases::duration_ms(*min), phases::duration_ms(*max))
        ),
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
public fun e_descent_ceiling_zero(): u64 { EDescentCeilingZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }

#[test_only]
public fun window_ceiling(policy: &AuctionWindowPolicy): Duration {
    match (policy) {
        AuctionWindowPolicy::Window { ceiling }        => *ceiling,
        AuctionWindowPolicy::Skipped
        | AuctionWindowPolicy::RandomInRange { .. }    => abort EDescentSkippedNoWindow,
    }
}

