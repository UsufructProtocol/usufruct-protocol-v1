// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[allow(lint(public_random))]
module usufruct::min_rent_price_state;

// === Imports ===

use sui::random::RandomGenerator;
use usufruct::monetary::{Self, Price};

// === Errors ===

const EPriceZero:   u64 = 0;
const EMinNotLtMax: u64 = 1;

// === Structs ===

public enum MinRentPriceState has copy, drop, store {
    Fixed { price: Price },
    RandomInRange { min: Price, max: Price },
}

// === Public Functions ===

public fun new_fixed(price: Price): MinRentPriceState {
    assert!(monetary::price_mist(price) > 0, EPriceZero);
    MinRentPriceState::Fixed { price }
}

public fun new_random_in_range(min: Price, max: Price): MinRentPriceState {
    assert!(monetary::price_mist(min) > 0, EPriceZero);
    assert!(monetary::price_mist(min) < monetary::price_mist(max), EMinNotLtMax);
    MinRentPriceState::RandomInRange { min, max }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_fixed(policy: &MinRentPriceState): bool {
    match (policy) { MinRentPriceState::Fixed { .. } => true, _ => false }
}

public(package) fun proj_is_random_in_range(policy: &MinRentPriceState): bool {
    match (policy) { MinRentPriceState::RandomInRange { .. } => true, _ => false }
}

public(package) fun proj_fixed_price(policy: &MinRentPriceState): Option<Price> {
    match (policy) {
        MinRentPriceState::Fixed { price } => option::some(*price),
        _ => option::none(),
    }
}

public(package) fun proj_range_min(policy: &MinRentPriceState): Option<Price> {
    match (policy) {
        MinRentPriceState::RandomInRange { min, .. } => option::some(*min),
        _ => option::none(),
    }
}

public(package) fun proj_range_max(policy: &MinRentPriceState): Option<Price> {
    match (policy) {
        MinRentPriceState::RandomInRange { max, .. } => option::some(*max),
        _ => option::none(),
    }
}

// === Package Functions ===

/// Returns the floor price for SDK views and Dutch auction descent bottom.
/// Fixed: the fixed price. RandomInRange: the minimum of the range (conservative).
public(package) fun floor_for_view(policy: &MinRentPriceState): Price {
    match (policy) {
        MinRentPriceState::Fixed { price }           => *price,
        MinRentPriceState::RandomInRange { min, .. } => *min,
    }
}

/// Resolves the policy to a concrete Price.
/// Fixed: returns the fixed price (generator unused).
/// RandomInRange: draws uniformly from [min, max].
public(package) fun resolve(policy: &MinRentPriceState, generator: &mut RandomGenerator): Price {
    match (policy) {
        MinRentPriceState::Fixed { price } => *price,
        MinRentPriceState::RandomInRange { min, max } => {
            let value = generator.generate_u64_in_range(
                monetary::price_mist(*min),
                monetary::price_mist(*max),
            );
            monetary::price(value)
        },
    }
}

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(_policy: MinRentPriceState) {}
