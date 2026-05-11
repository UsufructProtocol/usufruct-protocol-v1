// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::cycles;

// === Imports ===

use usufruct::math;
use usufruct::monetary::{Self, Price, Stake};
use usufruct::phases::{Self, Duration};

// === Errors ===

const ECyclesZero: u64 = 0;

// === Constants ===

// === Structs ===

public struct Cycles has copy, drop, store { count: u64 }

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun cycles(n: u64): Cycles {
    assert!(n > 0, ECyclesZero);
    Cycles { count: n }
}

/// Extractor — SDK boundary only.
public fun cycles_count(c: Cycles): u64 { c.count }

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun is_single(c: Cycles): bool { c.count == 1 }

/// Total payment required: floor_price × cycles.
public(package) fun total_price(floor: Price, c: Cycles): Price {
    monetary::price(monetary::price_mist(floor) * c.count)
}

/// Per-cycle stake rate: total_stake / cycles.
/// Used by floor_price_at_for_tenancy — the market competes on rate, not total.
public(package) fun per_cycle_stake(stake: Stake, c: Cycles): Stake {
    monetary::stake(monetary::stake_mist(stake) / c.count)
}

/// Scale a Duration by cycles — analogous to total_price.
/// do_install: extended = base × cycles.
public(package) fun total_duration(d: Duration, c: Cycles): Duration {
    phases::duration(phases::duration_ms(d) * c.count)
}

/// Re-scale a Duration from one cycle count to another.
/// do_handover: new = old × (bidding / committed), via mul_div for precision.
public(package) fun rescale_duration(d: Duration, from: Cycles, to: Cycles): Duration {
    phases::duration(math::mul_div(phases::duration_ms(d), to.count, from.count))
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_cycles_zero(): u64 { ECyclesZero }
