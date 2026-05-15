// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::handover_policy_state;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EHandoverFloorZero: u64 = 0;
const EMinNotLtMax:       u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum HandoverPolicyState has copy, drop, store {
    Instant,
    FixedTime,
    Countdown      { floor: Duration },
    RandomInRange  { min: Duration, max: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_handover_instant():    HandoverPolicyState { HandoverPolicyState::Instant }
public fun new_handover_fixed_time(): HandoverPolicyState { HandoverPolicyState::FixedTime }

public fun new_handover_countdown(floor: Duration): HandoverPolicyState {
    assert!(phases::duration_ms(floor) > 0, EHandoverFloorZero);
    HandoverPolicyState::Countdown { floor }
}

public fun new_handover_random_in_range(min: Duration, max: Duration): HandoverPolicyState {
    assert!(phases::duration_ms(min) > 0, EHandoverFloorZero);
    assert!(phases::duration_ms(min) < phases::duration_ms(max), EMinNotLtMax);
    HandoverPolicyState::RandomInRange { min, max }
}

// === View Functions ===

public(package) fun proj_is_instant(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::Instant => true, _ => false }
}
public(package) fun proj_is_fixed_time(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::FixedTime => true, _ => false }
}
public(package) fun proj_is_countdown(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::Countdown { .. } => true, _ => false }
}
public(package) fun proj_is_random_in_range(policy: &HandoverPolicyState): bool {
    match (policy) { HandoverPolicyState::RandomInRange { .. } => true, _ => false }
}
public(package) fun proj_countdown_floor_ms(policy: &HandoverPolicyState): Option<Duration> {
    match (policy) {
        HandoverPolicyState::Countdown { floor } => option::some(*floor),
        _ => option::none(),
    }
}
public(package) fun proj_range_min(policy: &HandoverPolicyState): Option<Duration> {
    match (policy) {
        HandoverPolicyState::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}
public(package) fun proj_range_max(policy: &HandoverPolicyState): Option<Duration> {
    match (policy) {
        HandoverPolicyState::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun countdown_floor_lt(policy: &HandoverPolicyState, ceiling: Duration): bool {
    match (policy) {
        HandoverPolicyState::Countdown { floor }       => phases::duration_ms(*floor) < phases::duration_ms(ceiling),
        HandoverPolicyState::RandomInRange { max, .. } => phases::duration_ms(*max)   < phases::duration_ms(ceiling),
        HandoverPolicyState::Instant | HandoverPolicyState::FixedTime => true,
    }
}

public(package) fun resolve(
    policy:    &HandoverPolicyState,
    ceiling:   Duration,
    generator: &mut RandomGenerator,
): Duration {
    match (policy) {
        HandoverPolicyState::Instant                    => phases::zero(),
        HandoverPolicyState::FixedTime                  => ceiling,
        HandoverPolicyState::Countdown { floor }        => *floor,
        HandoverPolicyState::RandomInRange { min, max } => phases::duration(
            generator.generate_u64_in_range(
                phases::duration_ms(*min),
                phases::duration_ms(*max),
            )
        ),
    }
}

public(package) fun has_expired(
    resolved_floor:   Duration,
    resolved_ceiling: Duration,
    bid_time:         Timestamp,
    phase_start:      Timestamp,
    now:              Timestamp,
): Boundary {
    phases::check_boundary(
        phases::earliest(
            phases::boundary_at(bid_time,    resolved_floor),
            phases::boundary_at(phase_start, resolved_ceiling),
        ),
        phases::zero(),
        now,
    )
}

public(package) fun expiry_at(
    resolved_floor:   Duration,
    resolved_ceiling: Duration,
    bid_time:         Timestamp,
    phase_start:      Timestamp,
): Timestamp {
    phases::earliest(
        phases::boundary_at(bid_time,    resolved_floor),
        phases::boundary_at(phase_start, resolved_ceiling),
    )
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_handover_floor_zero(): u64 { EHandoverFloorZero }
#[test_only]
public fun e_min_not_lt_max(): u64 { EMinNotLtMax }

