// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::handover_policy;

// === Imports ===

use usufruct::phases;

// === Errors ===

const EHandoverFloorZero: u64 = 0;

// === Structs ===

public enum HandoverPolicy has copy, drop, store {
    Instant,
    Countdown { floor_ms: u64 },
    FixedTime,
}

// === Public Functions ===

public fun new_handover_instant():    HandoverPolicy { HandoverPolicy::Instant }
public fun new_handover_fixed_time(): HandoverPolicy { HandoverPolicy::FixedTime }

public fun new_handover_countdown(floor_ms: u64): HandoverPolicy {
    assert!(floor_ms > 0, EHandoverFloorZero);
    HandoverPolicy::Countdown { floor_ms }
}

// === Package Functions ===

/// True iff the handover countdown has expired — the protocol should
/// finalize the pending bid.
///   - Instant   collapses to true (no countdown to wait).
///   - FixedTime expires when `phase_start_ms + tenure_ceiling` is
///               reached.
///   - Countdown expires when either the countdown floor elapses
///               since `bid_time_ms`, or the tenure ceiling is
///               reached — whichever comes first. The saturation
///               rule of spec §5.1, expressed as a disjunction:
///               `clock >= min(A, B)  ⇔  clock >= A  ∨  clock >= B`.
public(package) fun has_expired(
    policy:         &HandoverPolicy,
    bid_time_ms:    u64,
    phase_start_ms: u64,
    tenure_ceiling: u64,
    now_ms:         u64,
): bool {
    match (policy) {
        HandoverPolicy::Instant   => true,
        HandoverPolicy::FixedTime => phases::has_passed(phase_start_ms, tenure_ceiling, now_ms),
        HandoverPolicy::Countdown { floor_ms } =>
            phases::has_passed(bid_time_ms,    *floor_ms,      now_ms) ||
            phases::has_passed(phase_start_ms, tenure_ceiling, now_ms),
    }
}
