// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_function;

// === Imports ===

use usufruct::math;

// === Errors ===

const EDeltaZero: u64 = 0;
const EBpsRange:  u64 = 1;

// === Constants ===

const BPS_PER_UNIT: u64 = 10_000;
const BPS_UPPER:    u64 = 18_446_744_073_709_551_615 - BPS_PER_UNIT; // u64::MAX - BPS_PER_UNIT

// === Structs ===

public enum PriceFunction has copy, drop, store {
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

public fun new_fixed_delta(delta: u64): PriceFunction {
    assert!(delta > 0, EDeltaZero);
    PriceFunction::FixedDelta { delta }
}

public fun new_compound_delta(bps: u64, delta: u64): PriceFunction {
    assert!(bps >= 1 && bps <= BPS_UPPER, EBpsRange);
    assert!(delta > 0, EDeltaZero);
    PriceFunction::CompoundDelta { bps, delta }
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun evaluate_price_fn(
    price_fn:        &PriceFunction,
    last_rent_price: u64,
): u64 {
    match (price_fn) {
        PriceFunction::FixedDelta    { delta }      => eval_fixed_delta(last_rent_price, *delta),
        PriceFunction::CompoundDelta { bps, delta } => eval_compound_delta(last_rent_price, *bps, *delta),
    }
}

// === Private Functions ===

fun eval_fixed_delta(last_rent_price: u64, delta: u64): u64 {
    last_rent_price + delta
}

fun eval_compound_delta(last_rent_price: u64, bps: u64, delta: u64): u64 {
    math::mul_div(last_rent_price, BPS_PER_UNIT + bps, BPS_PER_UNIT) + delta
}

// === Test Functions ===

#[test_only]
public fun eval_fixed_delta_for_testing(last_rent_price: u64, delta: u64): u64 {
    eval_fixed_delta(last_rent_price, delta)
}

#[test_only]
public fun eval_compound_delta_for_testing(last_rent_price: u64, bps: u64, delta: u64): u64 {
    eval_compound_delta(last_rent_price, bps, delta)
}

#[test_only]
public fun bps_per_unit_for_testing(): u64 { BPS_PER_UNIT }

#[test_only]
public fun fixed_delta_fields_for_testing(price_fn: &PriceFunction): u64 {
    match (price_fn) {
        PriceFunction::FixedDelta { delta } => *delta,
        _ => abort 0,
    }
}

#[test_only]
public fun compound_delta_fields_for_testing(price_fn: &PriceFunction): (u64, u64) {
    match (price_fn) {
        PriceFunction::CompoundDelta { bps, delta } => (*bps, *delta),
        _ => abort 0,
    }
}
