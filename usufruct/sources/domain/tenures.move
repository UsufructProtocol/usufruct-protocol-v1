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

public struct StakePerTenure has copy, drop, store { mist: u64 }

public struct TotalDue has copy, drop, store { mist: u64 }

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun tenures(n: u64): Tenures {
    assert!(n > 0, ETenuresZero);
    Tenures { count: n }
}

public(package) fun tenures_count(c: Tenures): u64 { c.count }

public(package) fun proj_is_single(c: Tenures): bool { c.count == 1 }

public(package) fun compute_total_price(floor: Price, c: Tenures): TotalDue {
    TotalDue { mist: math::compute_mul_div(monetary::price_mist(floor), c.count, 1) }
}

public(package) fun total_due_mist(t: TotalDue): u64 { t.mist }

public(package) fun stake_per_tenure(stake: Stake, c: Tenures): StakePerTenure {
    StakePerTenure { mist: math::compute_mul_div(monetary::stake_mist(stake), 1, c.count) }
}

public(package) fun stake_per_tenure_mist(s: StakePerTenure): u64 { s.mist }

public(package) fun stake_per_tenure_as_price(s: StakePerTenure): Price { monetary::price(s.mist) }

public(package) fun compute_total_duration(d: Duration, c: Tenures): Duration {
    phases::duration(math::compute_mul_div(phases::duration_ms(d), c.count, 1))
}

public(package) fun compute_rescaled_duration(d: Duration, from: Tenures, to: Tenures): Duration {
    phases::duration(math::compute_mul_div(phases::duration_ms(d), to.count, from.count))
}

// === Private Functions ===

// === Test Functions ===


