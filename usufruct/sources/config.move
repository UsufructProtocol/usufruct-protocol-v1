// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::config;

// === Imports ===

use usufruct::{
    curve_shape::CurveShape,
    price_function::PriceFunction,
};

// === Errors ===

const EMinRentPriceZero:           u64 = 0;
const ETenureCeilingZero:          u64 = 1;
const EHandoverFloorExceedsTenure: u64 = 2;

// === Constants ===

// === Structs ===

public struct IntegrationConfig has copy, drop, store {
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover_floor:  u64,
    descent_ceiling: u64,
    retire_floor:    u64,
    credit_curve:    CurveShape,
    descent_curve:   CurveShape,
    price_function:  PriceFunction,
}

// === Events ===

public struct IntegrationConfigRegistered has copy, drop {
    escrow_id: ID,
    config:    IntegrationConfig,
}

// === Method Aliases ===

// === Public Functions ===

public fun new_config(
    _min_rent_price:  u64,
    _tenure_ceiling:  u64,
    _handover_floor:  u64,
    _descent_ceiling: u64,
    _retire_floor:    u64,
    _credit_curve:    CurveShape,
    _descent_curve:   CurveShape,
    _price_function:  PriceFunction,
): IntegrationConfig {
    abort 0
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(_cfg: &IntegrationConfig, _escrow_id: ID) {
    abort 0
}

public(package) fun min_rent_price(_cfg: &IntegrationConfig): u64 { abort 0 }
public(package) fun tenure_ceiling(_cfg: &IntegrationConfig): u64 { abort 0 }
public(package) fun handover_floor(_cfg: &IntegrationConfig): u64 { abort 0 }
public(package) fun descent_ceiling(_cfg: &IntegrationConfig): u64 { abort 0 }
public(package) fun retire_floor(_cfg: &IntegrationConfig): u64 { abort 0 }
public(package) fun credit_curve(_cfg: &IntegrationConfig): &CurveShape { abort 0 }
public(package) fun descent_curve(_cfg: &IntegrationConfig): &CurveShape { abort 0 }
public(package) fun price_function(_cfg: &IntegrationConfig): &PriceFunction { abort 0 }

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_id(e: &IntegrationConfigRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_config(e: &IntegrationConfigRegistered): IntegrationConfig { e.config }
