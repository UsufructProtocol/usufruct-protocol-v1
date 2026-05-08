// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_function_state;

// === Imports ===

use usufruct::math::{Self, BasisPoints};

// === Errors ===

const EDeltaZero: u64 = 0;
const EBpsRange:  u64 = 1;
#[test_only] const ENotFixedDelta:    u64 = 2;
#[test_only] const ENotCompoundDelta: u64 = 3;

// === Constants ===

/// Maximum legal bps value: mul_div(price, 10_000 + bps, 10_000) must not overflow u64.
/// Worst case: price = u64::MAX, bps = BPS_UPPER.
/// 10_000 + BPS_UPPER must not cause mul_div to return > u64::MAX.
/// With mul_div(u64::MAX, 10_000 + bps, 10_000):
///   res = u64::MAX * (10_000 + bps) / 10_000 ≤ u64::MAX
///   ⟺ 10_000 + bps ≤ 10_000
///   ⟺ bps ≤ 0  (strict bound means any bps ≥ 1 can overflow with max price)
/// In practice: the test contract pins BPS_UPPER = u64::MAX − 10_000,
/// mirroring the original implementation constant. Values above this would also
/// trigger the EBpsRange guard in new_compound_delta at construction time.
const BPS_UPPER: u64 = 18_446_744_073_709_541_615; // u64::MAX − 10_000

// === Structs ===

public enum PriceFunctionState has copy, drop, store {
    FixedDelta {
        delta: u64,
    },
    CompoundDelta {
        bps:   BasisPoints,
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
    PriceFunctionState::CompoundDelta { bps: math::bps(bps), delta }
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
    match (p) {
        PriceFunctionState::CompoundDelta { bps, .. } => option::some(math::bps_value(*bps)),
        _ => option::none(),
    }
}
public(package) fun proj_compound_delta_delta(p: &PriceFunctionState): Option<u64> {
    match (p) { PriceFunctionState::CompoundDelta { delta, .. } => option::some(*delta), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun evaluate_price_fn(
    price_fn: &PriceFunctionState,
    price:    u64,
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

/// price × (1 + bps/10_000) + delta  =  mul_div(price, 10_000 + bps, 10_000) + delta
///
/// Uses mul_div so that overflow detection happens inside math (EMulDivOverflow) rather
/// than as an arithmetic trap in this module. The overflow site must be in math for the
/// test contract to hold — math::mul_div asserts res ≤ u64::MAX before casting.
fun eval_compound_delta(price: u64, bps: BasisPoints, delta: u64): u64 {
    let denom = math::bps_denominator();
    math::mul_div(price, denom + math::bps_value(bps), denom) + delta
}

// === Test Functions ===

#[test_only]
public fun eval_fixed_delta_for_testing(price: u64, delta: u64): u64 {
    eval_fixed_delta(price, delta)
}

#[test_only]
public fun eval_compound_delta_for_testing(price: u64, bps: u64, delta: u64): u64 {
    eval_compound_delta(price, math::bps(bps), delta)
}

#[test_only]
public fun bps_per_unit_for_testing(): u64 { math::bps_denominator() }

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
        PriceFunctionState::CompoundDelta { bps, delta } => (math::bps_value(*bps), *delta),
        _ => abort ENotCompoundDelta,
    }
}
