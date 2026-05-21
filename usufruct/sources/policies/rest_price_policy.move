// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::rest_price_policy;

// === Imports ===

use usufruct::monetary::{Self, Price};

// === Errors ===

const EPriceZero: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum RestPricePolicy has copy, drop, store {
    Fixed { price: Price },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_fixed(price: Price): RestPricePolicy {
    assert!(monetary::price_mist(price) > 0, EPriceZero);
    RestPricePolicy::Fixed { price }
}

// === View Functions ===

public(package) fun proj_is_fixed(_policy: &RestPricePolicy): bool { true }

public(package) fun proj_fixed_price(policy: &RestPricePolicy): Option<Price> {
    match (policy) { RestPricePolicy::Fixed { price } => option::some(*price) }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun compute_floor_price(policy: &RestPricePolicy): Price {
    match (policy) { RestPricePolicy::Fixed { price } => *price }
}

public(package) fun compute_price(policy: &RestPricePolicy): Price {
    compute_floor_price(policy)
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(_policy: RestPricePolicy) {}

