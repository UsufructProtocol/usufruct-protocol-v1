// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_function_state;

// === Imports ===

use usufruct::math;

// === Errors ===

const EDeltaZero:        u64 = 0;
const EBpsRange:         u64 = 1;
#[test_only] const ENotFixedDelta:    u64 = 2;
#[test_only] const ENotCompoundDelta: u64 = 3;

// === Constants ===

const BPS_PER_UNIT: u64 = 10_000;
const BPS_UPPER:    u64 = 18_446_744_073_709_551_615 - BPS_PER_UNIT; // u64::MAX - BPS_PER_UNIT

// === Structs ===

public enum PriceFunctionState has copy, drop, store {
    FixedDelta {
        delta: u64,
    },
    CompoundDelta {
        bps:   u64,
        delta: u64,
    },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_fixed_delta(delta: u64): PriceFunctionState {
    assert!(delta > 0, EDeltaZero);
    PriceFunctionState::FixedDelta { delta }
}

public fun new_compound_delta(bps: u64, delta: u64): PriceFunctionState {
    assert!(bps >= 1 && bps <= BPS_UPPER, EBpsRange);
    assert!(delta > 0, EDeltaZero);
    PriceFunctionState::CompoundDelta { bps, delta }
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
    match (p) { PriceFunctionState::FixedDelta { delta } => option::some(*delta), _ => option::none() }
}
public(package) fun proj_compound_delta_bps(p: &PriceFunctionState): Option<u64> {
    match (p) { PriceFunctionState::CompoundDelta { bps, .. } => option::some(*bps), _ => option::none() }
}
public(package) fun proj_compound_delta_delta(p: &PriceFunctionState): Option<u64> {
    match (p) { PriceFunctionState::CompoundDelta { delta, .. } => option::some(*delta), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun evaluate_price_fn(
    price_fn:        &PriceFunctionState,
    price: u64,
): u64 {
    match (price_fn) {
        PriceFunctionState::FixedDelta    { delta }      => eval_fixed_delta(price, *delta),
        PriceFunctionState::CompoundDelta { bps, delta } => eval_compound_delta(price, *bps, *delta),
    }
}

// === Private Functions ===

fun eval_fixed_delta(price: u64, delta: u64): u64 {
    price + delta
}

fun eval_compound_delta(price: u64, bps: u64, delta: u64): u64 {
    math::mul_div(price, BPS_PER_UNIT + bps, BPS_PER_UNIT) + delta
}

// === Test Functions ===

#[test_only]
public fun eval_fixed_delta_for_testing(price: u64, delta: u64): u64 {
    eval_fixed_delta(price, delta)
}

#[test_only]
public fun eval_compound_delta_for_testing(price: u64, bps: u64, delta: u64): u64 {
    eval_compound_delta(price, bps, delta)
}

#[test_only]
public fun bps_per_unit_for_testing(): u64 { BPS_PER_UNIT }

#[test_only]
public fun fixed_delta_fields_for_testing(price_fn: &PriceFunctionState): u64 {
    match (price_fn) {
        PriceFunctionState::FixedDelta { delta } => *delta,
        _ => abort ENotFixedDelta,
    }
}

#[test_only]
public fun compound_delta_fields_for_testing(price_fn: &PriceFunctionState): (u64, u64) {
    match (price_fn) {
        PriceFunctionState::CompoundDelta { bps, delta } => (*bps, *delta),
        _ => abort ENotCompoundDelta,
    }
}
