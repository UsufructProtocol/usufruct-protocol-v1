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

public fun tenures(n: u64): Tenures {
    assert!(n > 0, ETenuresZero);
    Tenures { count: n }
}

public fun tenures_count(c: Tenures): u64 { c.count }

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun is_single(c: Tenures): bool { c.count == 1 }

public(package) fun total_price(floor: Price, c: Tenures): Price {
    monetary::price(monetary::price_mist(floor) * c.count)
}

public(package) fun per_tenure_stake(stake: Stake, c: Tenures): Stake {
    monetary::stake(monetary::stake_mist(stake) / c.count)
}

public(package) fun total_duration(d: Duration, c: Tenures): Duration {
    phases::duration(phases::duration_ms(d) * c.count)
}

public(package) fun rescale_duration(d: Duration, from: Tenures, to: Tenures): Duration {
    phases::duration(math::mul_div(phases::duration_ms(d), to.count, from.count))
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun e_tenures_zero(): u64 { ETenuresZero }

