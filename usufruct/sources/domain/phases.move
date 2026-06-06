// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::phases;

// === Imports ===

use std::u64;
use sui::clock::{Self, Clock};

// === Errors ===

// === Constants ===

// === Structs ===

public struct Timestamp has copy, drop, store { ms: u64 }

public struct Duration has copy, drop, store { ms: u64 }

public struct Elapsed has copy, drop { ms: u64 }

// === Enums ===

public enum Boundary has copy, drop {
    Pending { remaining: Duration },
    Crossed { overdue:   Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun now(clock: &Clock): Timestamp {
    Timestamp { ms: clock::timestamp_ms(clock) }
}

public(package) fun duration(ms: u64): Duration { Duration { ms } }

public(package) fun timestamp(ms: u64): Timestamp { Timestamp { ms } }

public(package) fun zero(): Duration { Duration { ms: 0 } }

public(package) fun timestamp_ms(t: Timestamp): u64 { t.ms }

public(package) fun duration_ms(d: Duration): u64 { d.ms }

public(package) fun proj_is_crossed(b: &Boundary): bool {
    match (b) { Boundary::Crossed { .. } => true, _ => false }
}

public(package) fun compute_boundary(anchor: Timestamp, d: Duration, now: Timestamp): Boundary {
    let boundary_ms = anchor.ms + d.ms;
    if (now.ms >= boundary_ms) {
        Boundary::Crossed { overdue: Duration { ms: now.ms - boundary_ms } }
    } else {
        Boundary::Pending { remaining: Duration { ms: boundary_ms - now.ms } }
    }
}

public(package) fun compute_elapsed(start: Timestamp, now: Timestamp): Elapsed {
    if (now.ms >= start.ms) Elapsed { ms: now.ms - start.ms } else Elapsed { ms: 0 }
}

public(package) fun elapsed_ms(e: Elapsed): u64 { e.ms }

public(package) fun compute_boundary_at(anchor: Timestamp, d: Duration): Timestamp {
    Timestamp { ms: anchor.ms + d.ms }
}

public(package) fun compute_earliest(a: Timestamp, b: Timestamp): Timestamp {
    Timestamp { ms: u64::min(a.ms, b.ms) }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun elapsed_for_testing(ms: u64): Elapsed { Elapsed { ms } }

