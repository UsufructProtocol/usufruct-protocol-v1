// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_escalation_policy;

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

public enum PriceEscalationPolicy has copy, drop, store {
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

public(package) fun new_fixed_delta(delta: Price): PriceEscalationPolicy {
    assert!(monetary::price_mist(delta) > 0, EDeltaZero);
    PriceEscalationPolicy::FixedDelta { delta }
}

public(package) fun new_compound_delta(bps: BasisPoints, delta: Price): PriceEscalationPolicy {
    let bps_val = math::bps_value(bps);
    assert!(bps_val >= 1 && bps_val <= bps_upper(), EBpsRange);
    assert!(monetary::price_mist(delta) > 0, EDeltaZero);
    PriceEscalationPolicy::CompoundDelta { bps, delta }
}

// === View Functions ===

public(package) fun proj_is_fixed_delta(p: &PriceEscalationPolicy): bool {
    match (p) { PriceEscalationPolicy::FixedDelta { .. } => true, _ => false }
}
public(package) fun proj_is_compound_delta(p: &PriceEscalationPolicy): bool {
    match (p) { PriceEscalationPolicy::CompoundDelta { .. } => true, _ => false }
}
public(package) fun proj_fixed_delta(p: &PriceEscalationPolicy): Option<Price> {
    match (p) { PriceEscalationPolicy::FixedDelta { delta } => option::some(*delta), _ => option::none() }
}
public(package) fun proj_compound_delta_bps(p: &PriceEscalationPolicy): Option<BasisPoints> {
    match (p) {
        PriceEscalationPolicy::CompoundDelta { bps, .. } => option::some(*bps),
        _ => option::none(),
    }
}
public(package) fun proj_compound_delta_delta(p: &PriceEscalationPolicy): Option<Price> {
    match (p) { PriceEscalationPolicy::CompoundDelta { delta, .. } => option::some(*delta), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun compute_next_price(
    price_fn: &PriceEscalationPolicy,
    price:    Price,
): Price {
    match (price_fn) {
        PriceEscalationPolicy::FixedDelta    { delta }      => eval_fixed_delta(price, *delta),
        PriceEscalationPolicy::CompoundDelta { bps, delta } => eval_compound_delta(price, *bps, *delta),
    }
}

// === Private Functions ===

fun bps_upper(): u64 { u64::max_value!() - math::bps_denominator() }

fun eval_fixed_delta(price: Price, delta: Price): Price {
    monetary::compute_price_add(price, delta)
}

fun eval_compound_delta(price: Price, bps: BasisPoints, delta: Price): Price {
    let denom = math::bps_denominator();
    let scaled = math::compute_mul_div(monetary::price_mist(price), denom + math::bps_value(bps), denom);
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
public fun fixed_delta_fields_for_testing(price_fn: &PriceEscalationPolicy): u64 {
    match (price_fn) {
        PriceEscalationPolicy::FixedDelta { delta } => monetary::price_mist(*delta),
        _ => abort ENotFixedDelta,
    }
}

#[test_only]
public fun compound_delta_fields_for_testing(price_fn: &PriceEscalationPolicy): (u64, u64) {
    match (price_fn) {
        PriceEscalationPolicy::CompoundDelta { bps, delta } => (math::bps_value(*bps), monetary::price_mist(*delta)),
        _ => abort ENotCompoundDelta,
    }
}

