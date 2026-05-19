// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::handover_policy;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EHandoverFloorZero: u64 = 0;
const EMinNotLtMax:       u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum HandoverPolicy has copy, drop, store {
    Instant,
    FullTenure,
    Countdown      { floor: Duration },
    RandomInRange  { min: Duration, max: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_handover_instant():    HandoverPolicy { HandoverPolicy::Instant }
public fun new_handover_full_tenure(): HandoverPolicy { HandoverPolicy::FullTenure }

public fun new_handover_countdown(floor: Duration): HandoverPolicy {
    assert!(phases::duration_ms(floor) > 0, EHandoverFloorZero);
    HandoverPolicy::Countdown { floor }
}

public fun new_handover_random_in_range(min: Duration, max: Duration): HandoverPolicy {
    assert!(phases::duration_ms(min) > 0, EHandoverFloorZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    HandoverPolicy::RandomInRange { min, max }
}

// === View Functions ===

public(package) fun proj_is_instant(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::Instant => true, _ => false }
}
public(package) fun proj_is_full_tenure(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::FullTenure => true, _ => false }
}
public(package) fun proj_is_countdown(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::Countdown { .. } => true, _ => false }
}
public(package) fun proj_is_random_in_range(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::RandomInRange { .. } => true, _ => false }
}
public(package) fun proj_countdown_floor_ms(policy: &HandoverPolicy): Option<Duration> {
    match (policy) {
        HandoverPolicy::Countdown { floor } => option::some(*floor),
        _ => option::none(),
    }
}
public(package) fun proj_range_min(policy: &HandoverPolicy): Option<Duration> {
    match (policy) {
        HandoverPolicy::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}
public(package) fun proj_range_max(policy: &HandoverPolicy): Option<Duration> {
    match (policy) {
        HandoverPolicy::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun compute_countdown_floor_lt(policy: &HandoverPolicy, ceiling: Duration): bool {
    match (policy) {
        HandoverPolicy::Countdown { floor }       => phases::duration_ms(*floor) < phases::duration_ms(ceiling),
        HandoverPolicy::RandomInRange { max, .. } => phases::duration_ms(*max)   < phases::duration_ms(ceiling),
        HandoverPolicy::Instant | HandoverPolicy::FullTenure => true,
    }
}

public(package) fun compute_duration(
    policy:    &HandoverPolicy,
    ceiling:   Duration,
    generator: &mut RandomGenerator,
): Duration {
    match (policy) {
        HandoverPolicy::Instant                    => phases::zero(),
        HandoverPolicy::FullTenure                  => ceiling,
        HandoverPolicy::Countdown { floor }        => *floor,
        HandoverPolicy::RandomInRange { min, max } => phases::duration(
            generator.generate_u64_in_range(
                phases::duration_ms(*min),
                phases::duration_ms(*max),
            )
        ),
    }
}

public(package) fun compute_expiry_boundary(
    resolved_floor:   Duration,
    resolved_ceiling: Duration,
    bid_time:         Timestamp,
    phase_start:      Timestamp,
    now:              Timestamp,
): Boundary {
    phases::compute_boundary(
        phases::compute_earliest(
            phases::compute_boundary_at(bid_time,    resolved_floor),
            phases::compute_boundary_at(phase_start, resolved_ceiling),
        ),
        phases::zero(),
        now,
    )
}

public(package) fun compute_expiry_at(
    resolved_floor:   Duration,
    resolved_ceiling: Duration,
    bid_time:         Timestamp,
    phase_start:      Timestamp,
): Timestamp {
    phases::compute_earliest(
        phases::compute_boundary_at(bid_time,    resolved_floor),
        phases::compute_boundary_at(phase_start, resolved_ceiling),
    )
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_handover_floor_zero(): u64 { EHandoverFloorZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }

