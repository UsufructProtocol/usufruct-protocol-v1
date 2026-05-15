// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::config;

// === Imports ===

use sui::event;
use usufruct::{
    curve_shape_state::CurveShapeState,
    descent_policy_state::DescentPolicyState,
    handover_policy_state::{Self, HandoverPolicyState},
    floor_price_policy_state::FloorPricePolicyState,
    tenure_policy_state::{Self as tenure_policy_state, TenurePolicyState},
    tenure_cycles_policy_state::TenureCyclesPolicyState,
    price_function_state::PriceFunctionState,
};

// === Errors ===

const EHandoverFloorExceedsTenure: u64 = 2;

// === Constants ===

// === Structs ===

public struct IntegrationConfig has copy, drop, store {
    min_rent_price:   FloorPricePolicyState,
    tenure_ceiling:   TenurePolicyState,
    tenure_cycles:    TenureCyclesPolicyState,
    handover:         HandoverPolicyState,
    descent:          DescentPolicyState,
    credit_curve:     CurveShapeState,
    descent_curve:    CurveShapeState,
    price_function_state:  PriceFunctionState,
}

// === Events ===

public struct IntegrationConfigRegistered has copy, drop {
    escrow_id: ID,
    config:    IntegrationConfig,
}

// === Method Aliases ===

// === Public Functions ===

public fun new_config(
    min_rent_price:  FloorPricePolicyState,
    tenure_ceiling:  TenurePolicyState,
    tenure_cycles:   TenureCyclesPolicyState,
    handover:        HandoverPolicyState,
    descent:         DescentPolicyState,
    credit_curve:    CurveShapeState,
    descent_curve:   CurveShapeState,
    price_function_state: PriceFunctionState,
): IntegrationConfig {
    assert!(
        handover_policy_state::countdown_floor_lt(&handover, tenure_policy_state::min_ceiling(&tenure_ceiling)),
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
        price_function_state,
    }
}

// === View Functions ===

public(package) fun proj_min_rent_price(cfg: &IntegrationConfig):        &FloorPricePolicyState      { &cfg.min_rent_price }
public(package) fun proj_tenure_ceiling(cfg: &IntegrationConfig):         &TenurePolicyState          { &cfg.tenure_ceiling }
public(package) fun proj_tenure_cycles(cfg: &IntegrationConfig):          &TenureCyclesPolicyState    { &cfg.tenure_cycles }
public(package) fun proj_handover(cfg: &IntegrationConfig):               &HandoverPolicyState         { &cfg.handover }
public(package) fun proj_descent(cfg: &IntegrationConfig):               &DescentPolicyState   { &cfg.descent }
public(package) fun proj_credit_curve(cfg: &IntegrationConfig):          &CurveShapeState      { &cfg.credit_curve }
public(package) fun proj_descent_curve(cfg: &IntegrationConfig):         &CurveShapeState      { &cfg.descent_curve }
public(package) fun proj_price_function_state(cfg: &IntegrationConfig):  &PriceFunctionState   { &cfg.price_function_state }

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

