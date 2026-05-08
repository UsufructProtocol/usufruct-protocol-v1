// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_function_state;

// === Imports ===

use std::u64;
use usufruct::{
    math::{Self, BasisPoints},
    monetary::{Self, Price},
};

// === Errors ===

const EDeltaZero: u64 = 0;
const EBpsRange:  u64 = 1;
#[test_only] const ENotFixedDelta:    u64 = 2;
#[test_only] const ENotCompoundDelta: u64 = 3;

// === Constants ===

// === Structs ===

public enum PriceFunctionState has copy, drop, store {
    FixedDelta {
        delta: Price,
    },
    CompoundDelta {
        bps:   BasisPoints,
        delta: Price,
    },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_fixed_delta(delta: u64): PriceFunctionState {
    assert!(delta > 0, EDeltaZero);
    PriceFunctionState::FixedDelta { delta: monetary::price(delta) }
}

public fun new_compound_delta(bps: u64, delta: u64): PriceFunctionState {
    assert!(bps >= 1 && bps <= bps_upper(), EBpsRange);
    assert!(delta > 0, EDeltaZero);
    PriceFunctionState::CompoundDelta { bps: math::bps(bps), delta: monetary::price(delta) }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_fixed_delta(p: &PriceFunctionState): bool {
    match (p) { PriceFunctionState::FixedDelta { .. } => true, _ => false }
}
public(package) fun proj_is_compound_delta(p: &PriceFunctionState): bool {
    match (p) { PriceFunctionState::CompoundDelta { .. } => true, _ => false }
}
public(package) fun proj_fixed_delta(p: &PriceFunctionState): Option<u64> {
    match (p) { PriceFunctionState::FixedDelta { delta } => option::some(monetary::price_mist(*delta)), _ => option::none() }
}
public(package) fun proj_compound_delta_bps(p: &PriceFunctionState): Option<u64> {
    match (p) {
        PriceFunctionState::CompoundDelta { bps, .. } => option::some(math::bps_value(*bps)),
        _ => option::none(),
    }
}
public(package) fun proj_compound_delta_delta(p: &PriceFunctionState): Option<u64> {
    match (p) { PriceFunctionState::CompoundDelta { delta, .. } => option::some(monetary::price_mist(*delta)), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun evaluate_price_fn(
    price_fn: &PriceFunctionState,
    price:    Price,
): Price {
    match (price_fn) {
        PriceFunctionState::FixedDelta    { delta }      => eval_fixed_delta(price, *delta),
        PriceFunctionState::CompoundDelta { bps, delta } => eval_compound_delta(price, *bps, *delta),
    }
}

// === Private Functions ===

/// Guards against EMulDivOverflow: mul_div(price, denom + bps, denom) overflows
/// when price = u64::MAX and bps ≥ 1. Upper bound = u64::MAX − BPS_DENOMINATOR.
fun bps_upper(): u64 { u64::max_value!() - math::bps_denominator() }

fun eval_fixed_delta(price: Price, delta: Price): Price {
    monetary::price_add(price, delta)
}

/// price × (1 + bps/10_000) + delta  =  mul_div(price, 10_000 + bps, 10_000) + delta
///
/// Uses mul_div so that overflow detection happens inside math (EMulDivOverflow) rather
/// than as an arithmetic trap in this module. The overflow site must be in math for the
/// test contract to hold — math::mul_div asserts res ≤ u64::MAX before casting.
fun eval_compound_delta(price: Price, bps: BasisPoints, delta: Price): Price {
    let denom = math::bps_denominator();
    let scaled = math::mul_div(monetary::price_mist(price), denom + math::bps_value(bps), denom);
    monetary::price(scaled + monetary::price_mist(delta))
}

// === Test Functions ===

#[test_only]
public fun eval_fixed_delta_for_testing(price: u64, delta: u64): u64 {
    monetary::price_mist(eval_fixed_delta(monetary::price(price), monetary::price(delta)))
}

#[test_only]
public fun eval_compound_delta_for_testing(price: u64, bps: u64, delta: u64): u64 {
    monetary::price_mist(eval_compound_delta(monetary::price(price), math::bps(bps), monetary::price(delta)))
}

#[test_only]
public fun bps_per_unit_for_testing(): u64 { math::bps_denominator() }

#[test_only]
public fun fixed_delta_fields_for_testing(price_fn: &PriceFunctionState): u64 {
    match (price_fn) {
        PriceFunctionState::FixedDelta { delta } => monetary::price_mist(*delta),
        _ => abort ENotFixedDelta,
    }
}

#[test_only]
public fun compound_delta_fields_for_testing(price_fn: &PriceFunctionState): (u64, u64) {
    match (price_fn) {
        PriceFunctionState::CompoundDelta { bps, delta } => (math::bps_value(*bps), monetary::price_mist(*delta)),
        _ => abort ENotCompoundDelta,
    }
}
