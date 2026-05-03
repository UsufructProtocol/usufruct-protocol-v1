// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::retire_policy;

// === Imports ===

use usufruct::phases;

// === Errors ===

const ERetireFloorZero: u64 = 0;

// === Structs ===

public enum RetirePolicy has copy, drop, store {
    Immediate,
    Deferred { floor_ms: u64 },
}

// === Public Functions ===

public fun new_retire_immediate(): RetirePolicy { RetirePolicy::Immediate }

public fun new_retire_deferred(floor_ms: u64): RetirePolicy {
    assert!(floor_ms > 0, ERetireFloorZero);
    RetirePolicy::Deferred { floor_ms }
}

// === Package Functions ===

/// True iff `retire()` may proceed.
///   - Immediate is always unlocked.
///   - Deferred unlocks when `floor_ms` elapses since
///     `integrated_at_ms`.
public(package) fun is_unlocked(
    policy:           &RetirePolicy,
    integrated_at_ms: u64,
    now_ms:           u64,
): bool {
    match (policy) {
        // Immediate unlocks from `integrated_at_ms` onward: zero floor
        // means the gate opens at integration, not vacuously before.
        // Defensive monotonicity — every variant gates through the time
        // layer (`phases::has_passed`); none are vacuous. In production,
        // clock-monotone makes this equivalent to `=> true`.
        RetirePolicy::Immediate             =>
            phases::has_passed(integrated_at_ms, 0, now_ms),
        RetirePolicy::Deferred { floor_ms } =>
            phases::has_passed(integrated_at_ms, *floor_ms, now_ms),
    }
}
