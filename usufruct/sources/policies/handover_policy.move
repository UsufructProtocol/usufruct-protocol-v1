// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::handover_policy;

// === Imports ===

use std::string::String;
use usufruct::phases::{Self, Timestamp, Duration, Boundary};

// === Errors ===

const EHandoverFloorZero: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum HandoverPolicy has copy, drop, store {
    Off,
    FullTenure,
    Fixed { floor: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_off(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::Off => true, _ => false }
}
public(package) fun proj_is_full_tenure(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::FullTenure => true, _ => false }
}
public(package) fun proj_is_fixed(policy: &HandoverPolicy): bool {
    match (policy) { HandoverPolicy::Fixed { .. } => true, _ => false }
}
public(package) fun proj_fixed_floor_ms(policy: &HandoverPolicy): Option<Duration> {
    match (policy) {
        HandoverPolicy::Fixed { floor } => option::some(*floor),
        _ => option::none(),
    }
}

public(package) fun proj_handover_policy(policy: &HandoverPolicy): String {
    match (policy) {
        HandoverPolicy::Off          => b"Off".to_string(),
        HandoverPolicy::FullTenure   => b"FullTenure".to_string(),
        HandoverPolicy::Fixed { .. } => b"Fixed".to_string(),
    }
}
public(package) fun proj_handover_floor_ms(policy: &HandoverPolicy): Option<u64> {
    match (policy) {
        HandoverPolicy::Fixed { floor } => option::some(phases::duration_ms(*floor)),
        _                               => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_handover_off():    HandoverPolicy { HandoverPolicy::Off }
public(package) fun new_handover_full_tenure(): HandoverPolicy { HandoverPolicy::FullTenure }

public(package) fun new_handover_fixed(floor: Duration): HandoverPolicy {
    assert!(phases::duration_ms(floor) > 0, EHandoverFloorZero);
    HandoverPolicy::Fixed { floor }
}

public(package) fun compute_countdown_floor_lt(policy: &HandoverPolicy, ceiling: Duration): bool {
    match (policy) {
        HandoverPolicy::Fixed { floor }          => phases::duration_ms(*floor) < phases::duration_ms(ceiling),
        HandoverPolicy::Off | HandoverPolicy::FullTenure => true,
    }
}

public(package) fun compute_duration(policy: &HandoverPolicy, ceiling: Duration): Duration {
    match (policy) {
        HandoverPolicy::Off            => phases::zero(),
        HandoverPolicy::FullTenure     => ceiling,
        HandoverPolicy::Fixed { floor } => *floor,
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



