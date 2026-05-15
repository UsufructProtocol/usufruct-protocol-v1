// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::floor_price_policy_state;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::monetary::{Self, Price};

// === Errors ===

const EPriceZero:   u64 = 0;
const EMinNotLtMax: u64 = 1;

// === Constants ===

// === Structs ===

// === Enums ===

public enum FloorPricePolicyState has copy, drop, store {
    Fixed { price: Price },
    RandomInRange { min: Price, max: Price },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_fixed(price: Price): FloorPricePolicyState {
    assert!(monetary::price_mist(price) > 0, EPriceZero);
    FloorPricePolicyState::Fixed { price }
}

public fun new_random_in_range(min: Price, max: Price): FloorPricePolicyState {
    assert!(monetary::price_mist(min) > 0, EPriceZero);
    assert!(monetary::price_mist(min) < monetary::price_mist(max), EMinNotLtMax);
    FloorPricePolicyState::RandomInRange { min, max }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_fixed(policy: &FloorPricePolicyState): bool {
    match (policy) { FloorPricePolicyState::Fixed { .. } => true, _ => false }
}

public(package) fun proj_is_random_in_range(policy: &FloorPricePolicyState): bool {
    match (policy) { FloorPricePolicyState::RandomInRange { .. } => true, _ => false }
}

public(package) fun proj_fixed_price(policy: &FloorPricePolicyState): Option<Price> {
    match (policy) {
        FloorPricePolicyState::Fixed { price } => option::some(*price),
        _ => option::none(),
    }
}

public(package) fun proj_range_min(policy: &FloorPricePolicyState): Option<Price> {
    match (policy) {
        FloorPricePolicyState::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}

public(package) fun proj_range_max(policy: &FloorPricePolicyState): Option<Price> {
    match (policy) {
        FloorPricePolicyState::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Returns the floor price for SDK views and Dutch auction descent bottom.
/// Fixed: the fixed price. RandomInRange: the minimum of the range (conservative).
public(package) fun floor_for_view(policy: &FloorPricePolicyState): Price {
    match (policy) {
        FloorPricePolicyState::Fixed { price }           => *price,
        FloorPricePolicyState::RandomInRange { min, .. } => *min,
    }
}

/// Resolves the policy to a concrete Price.
/// Fixed: returns the fixed price (generator unused).
/// RandomInRange: draws uniformly from [min, max].
public(package) fun resolve(policy: &FloorPricePolicyState, generator: &mut RandomGenerator): Price {
    match (policy) {
        FloorPricePolicyState::Fixed { price } => *price,
        FloorPricePolicyState::RandomInRange { min, max } => {
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
public fun destroy_for_testing(_policy: FloorPricePolicyState) {}
