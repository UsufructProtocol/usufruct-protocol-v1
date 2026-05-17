// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::floor_price_policy;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::monetary::{Self, Price};

// === Errors ===

const EPriceZero:   u64 = 0;
const EMinNotLtMax: u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum FloorPricePolicy has copy, drop, store {
    Fixed { price: Price },
    RandomInRange { min: Price, max: Price },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_fixed(price: Price): FloorPricePolicy {
    assert!(monetary::price_mist(price) > 0, EPriceZero);
    FloorPricePolicy::Fixed { price }
}

public fun new_random_in_range(min: Price, max: Price): FloorPricePolicy {
    assert!(monetary::price_mist(min) > 0, EPriceZero);
    assert!(monetary::price_mist(min) < monetary::price_mist(max), EMinNotLtMax);
    FloorPricePolicy::RandomInRange { min, max }
}

// === View Functions ===

public(package) fun proj_is_fixed(policy: &FloorPricePolicy): bool {
    match (policy) { FloorPricePolicy::Fixed { .. } => true, _ => false }
}

public(package) fun proj_is_random_in_range(policy: &FloorPricePolicy): bool {
    match (policy) { FloorPricePolicy::RandomInRange { .. } => true, _ => false }
}

public(package) fun proj_fixed_price(policy: &FloorPricePolicy): Option<Price> {
    match (policy) {
        FloorPricePolicy::Fixed { price } => option::some(*price),
        _ => option::none(),
    }
}

public(package) fun proj_range_min(policy: &FloorPricePolicy): Option<Price> {
    match (policy) {
        FloorPricePolicy::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}

public(package) fun proj_range_max(policy: &FloorPricePolicy): Option<Price> {
    match (policy) {
        FloorPricePolicy::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun floor_price(policy: &FloorPricePolicy): Price {
    match (policy) {
        FloorPricePolicy::Fixed { price }           => *price,
        FloorPricePolicy::RandomInRange { min, .. } => *min,
    }
}

public(package) fun resolve(policy: &FloorPricePolicy, generator: &mut RandomGenerator): Price {
    match (policy) {
        FloorPricePolicy::Fixed { price } => *price,
        FloorPricePolicy::RandomInRange { min, max } => {
            let value = generator.generate_u64_in_range(
                monetary::price_mist(*min),
                monetary::price_mist(*max),
            );
            monetary::price(value)
        },
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(_policy: FloorPricePolicy) {}

