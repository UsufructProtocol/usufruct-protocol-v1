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

public fun new_fixed_delta(_delta: u64): PriceFunction { abort 0 }

public fun new_compound_delta(_bps: u64, _delta: u64): PriceFunction { abort 0 }

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun evaluate_price_fn(
    _price_fn:        &PriceFunction,
    _last_rent_price: u64,
): u64 { abort 0 }

// === Private Functions ===

fun eval_fixed_delta(_last_rent_price: u64, _delta: u64): u64 { abort 0 }

fun eval_compound_delta(_last_rent_price: u64, _bps: u64, _delta: u64): u64 { abort 0 }

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
