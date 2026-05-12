// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::phases;

// === Imports ===

use std::u64;
use sui::clock::{Self, Clock};

// === Errors ===

// === Constants ===

// === Structs ===

/// An absolute point in time (milliseconds since Unix epoch).
public struct Timestamp has copy, drop, store { ms: u64 }

/// A relative span of time (milliseconds offset — never an absolute point).
public struct Duration has copy, drop, store { ms: u64 }

// === Enums ===

/// Result of a boundary check.
///
///   · Pending — boundary not yet reached; `remaining` is time left.
///   · Crossed — boundary has been passed; `overdue` is time since crossing.
public enum Boundary has copy, drop {
    Pending { remaining: Duration },
    Crossed { overdue:   Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

/// Construct a `Timestamp` representing the current clock time.
public fun now(clock: &Clock): Timestamp {
    Timestamp { ms: clock::timestamp_ms(clock) }
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Construct a `Timestamp` from a stored millisecond value.
public(package) fun timestamp(ms: u64): Timestamp { Timestamp { ms } }

/// Construct a `Duration` from a millisecond offset.
public(package) fun duration(ms: u64): Duration { Duration { ms } }

/// Zero duration — used for instant boundaries.
public(package) fun zero(): Duration { Duration { ms: 0 } }

/// Raw millisecond value of a `Timestamp`.
public(package) fun timestamp_ms(t: Timestamp): u64 { t.ms }

/// Raw millisecond value of a `Duration`.
public(package) fun duration_ms(d: Duration): u64 { d.ms }

/// True iff the boundary has been crossed.
public(package) fun is_crossed(b: &Boundary): bool {
    match (b) { Boundary::Crossed { .. } => true, _ => false }
}

/// Check whether phase boundary `anchor + d` has been crossed at `now`.
public(package) fun check_boundary(anchor: Timestamp, d: Duration, now: Timestamp): Boundary {
    let boundary_ms = anchor.ms + d.ms;
    if (now.ms >= boundary_ms) {
        Boundary::Crossed { overdue: Duration { ms: now.ms - boundary_ms } }
    } else {
        Boundary::Pending { remaining: Duration { ms: boundary_ms - now.ms } }
    }
}

/// Elapsed time since `start`. Saturates to zero if `now` is before `start`.
public(package) fun elapsed_since(start: Timestamp, now: Timestamp): Duration {
    if (now.ms >= start.ms) Duration { ms: now.ms - start.ms } else Duration { ms: 0 }
}

/// The boundary timestamp `anchor + d`.
public(package) fun boundary_at(anchor: Timestamp, d: Duration): Timestamp {
    Timestamp { ms: anchor.ms + d.ms }
}

/// Earlier of two timestamps.
public(package) fun earliest(a: Timestamp, b: Timestamp): Timestamp {
    Timestamp { ms: u64::min(a.ms, b.ms) }
}

// === Private Functions ===

// === Test Functions ===
