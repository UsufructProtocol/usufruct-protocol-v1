// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::config;

// === Imports ===

use sui::event;
use usufruct::{
    curve_shape_policy::CurveShapePolicy,
    descent_policy::DescentPolicy,
    handover_policy::{Self, HandoverPolicy},
    floor_price_policy::FloorPricePolicy,
    tenure_policy::{Self as tenure_policy, TenurePolicy},
    tenure_cycles_policy::TenureCyclesPolicy,
    price_function_policy::PriceFunctionPolicy,
};

// === Errors ===

const EHandoverFloorExceedsTenure: u64 = 2;

// === Constants ===

// === Structs ===

public struct IntegrationConfig has copy, drop, store {
    min_rent_price:   FloorPricePolicy,
    tenure_ceiling:   TenurePolicy,
    tenure_cycles:    TenureCyclesPolicy,
    handover:         HandoverPolicy,
    descent:          DescentPolicy,
    credit_curve:     CurveShapePolicy,
    descent_curve:    CurveShapePolicy,
    price_function_policy: PriceFunctionPolicy,
}

// === Events ===

public struct IntegrationConfigRegistered has copy, drop {
    escrow_id: ID,
    config:    IntegrationConfig,
}

// === Method Aliases ===

// === Public Functions ===

public fun new_config(
    min_rent_price:  FloorPricePolicy,
    tenure_ceiling:  TenurePolicy,
    tenure_cycles:   TenureCyclesPolicy,
    handover:        HandoverPolicy,
    descent:         DescentPolicy,
    credit_curve:    CurveShapePolicy,
    descent_curve:   CurveShapePolicy,
    price_function_policy: PriceFunctionPolicy,
): IntegrationConfig {
    assert!(
        handover_policy::countdown_floor_lt(&handover, tenure_policy::min_ceiling(&tenure_ceiling)),
        EHandoverFloorExceedsTenure,
    );
    IntegrationConfig {
        min_rent_price,
        tenure_ceiling,
        tenure_cycles,
        handover,
        descent,
        credit_curve,
        descent_curve,
        price_function_policy: price_function_policy,
    }
}

// === View Functions ===

public(package) fun proj_min_rent_price(cfg: &IntegrationConfig):        &FloorPricePolicy      { &cfg.min_rent_price }
public(package) fun proj_tenure_ceiling(cfg: &IntegrationConfig):         &TenurePolicy          { &cfg.tenure_ceiling }
public(package) fun proj_tenure_cycles(cfg: &IntegrationConfig):          &TenureCyclesPolicy    { &cfg.tenure_cycles }
public(package) fun proj_handover(cfg: &IntegrationConfig):               &HandoverPolicy         { &cfg.handover }
public(package) fun proj_descent(cfg: &IntegrationConfig):               &DescentPolicy   { &cfg.descent }
public(package) fun proj_credit_curve(cfg: &IntegrationConfig):          &CurveShapePolicy      { &cfg.credit_curve }
public(package) fun proj_descent_curve(cfg: &IntegrationConfig):         &CurveShapePolicy      { &cfg.descent_curve }
public(package) fun proj_price_function_policy(cfg: &IntegrationConfig): &PriceFunctionPolicy   { &cfg.price_function_policy }

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID) {
    event::emit(IntegrationConfigRegistered { escrow_id, config: *cfg });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_id(e: &IntegrationConfigRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_config(e: &IntegrationConfigRegistered): IntegrationConfig { e.config }

