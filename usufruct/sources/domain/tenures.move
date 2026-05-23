// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenures;

// === Imports ===

use usufruct::math;
use usufruct::monetary::{Self, Price, Stake};
use usufruct::phases::{Self, Duration};

// === Errors ===

const ETenuresZero: u64 = 0;

// === Constants ===

// === Structs ===

public struct Tenures has copy, drop, store { count: u64 }

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public(package) fun tenures(n: u64): Tenures {
    assert!(n > 0, ETenuresZero);
    Tenures { count: n }
}

public(package) fun tenures_count(c: Tenures): u64 { c.count }

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun proj_is_single(c: Tenures): bool { c.count == 1 }

public(package) fun compute_total_price(floor: Price, c: Tenures): Price {
    monetary::price(math::compute_mul_div(monetary::price_mist(floor), c.count, 1))
}

public(package) fun compute_per_tenure_stake(stake: Stake, c: Tenures): Stake {
    monetary::stake(math::compute_mul_div(monetary::stake_mist(stake), 1, c.count))
}

public(package) fun compute_total_duration(d: Duration, c: Tenures): Duration {
    phases::duration(math::compute_mul_div(phases::duration_ms(d), c.count, 1))
}

public(package) fun compute_rescaled_duration(d: Duration, from: Tenures, to: Tenures): Duration {
    phases::duration(math::compute_mul_div(phases::duration_ms(d), to.count, from.count))
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_tenures_zero(): u64 { ETenuresZero }

