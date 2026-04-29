// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::config;

// === Imports ===

use sui::event;
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
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover_floor:  u64,
    descent_ceiling: u64,
    retire_floor:    u64,
    credit_curve:    CurveShape,
    descent_curve:   CurveShape,
    price_function:  PriceFunction,
): IntegrationConfig {
    assert!(min_rent_price > 0,              EMinRentPriceZero);
    assert!(tenure_ceiling > 0,              ETenureCeilingZero);
    assert!(handover_floor <= tenure_ceiling, EHandoverFloorExceedsTenure);
    IntegrationConfig {
        min_rent_price,
        tenure_ceiling,
        handover_floor,
        descent_ceiling,
        retire_floor,
        credit_curve,
        descent_curve,
        price_function,
    }
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID) {
    event::emit(IntegrationConfigRegistered { escrow_id, config: *cfg });
}

public(package) fun min_rent_price(cfg: &IntegrationConfig): u64          { cfg.min_rent_price }
public(package) fun tenure_ceiling(cfg: &IntegrationConfig): u64          { cfg.tenure_ceiling }
public(package) fun handover_floor(cfg: &IntegrationConfig): u64          { cfg.handover_floor }
public(package) fun descent_ceiling(cfg: &IntegrationConfig): u64         { cfg.descent_ceiling }
public(package) fun retire_floor(cfg: &IntegrationConfig): u64            { cfg.retire_floor }
public(package) fun credit_curve(cfg: &IntegrationConfig): &CurveShape    { &cfg.credit_curve }
public(package) fun descent_curve(cfg: &IntegrationConfig): &CurveShape   { &cfg.descent_curve }
public(package) fun price_function(cfg: &IntegrationConfig): &PriceFunction { &cfg.price_function }

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_id(e: &IntegrationConfigRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_config(e: &IntegrationConfigRegistered): IntegrationConfig { e.config }
