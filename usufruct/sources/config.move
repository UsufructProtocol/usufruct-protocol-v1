// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::config;

// === Imports ===

use sui::event;
use usufruct::{
    curve_shape_state::CurveShapeState,
    descent_policy_state::DescentPolicyState,
    handover_policy_state::{Self, HandoverPolicyState},
    price_function_state::PriceFunctionState,
    retire_policy_state::RetirePolicyState,
};

// === Errors ===

const EMinRentPriceZero:           u64 = 0;
const ETenureCeilingZero:          u64 = 1;
const EHandoverFloorExceedsTenure: u64 = 2;   // Countdown.floor_ms >= tenure_ceiling

// === Constants ===

// === Structs ===

public struct IntegrationConfig has copy, drop, store {
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover:        HandoverPolicyState,
    descent:         DescentPolicyState,
    retire:          RetirePolicyState,
    credit_curve:    CurveShapeState,
    descent_curve:   CurveShapeState,
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
    min_rent_price: u64,
    tenure_ceiling: u64,
    handover:       HandoverPolicyState,
    descent:        DescentPolicyState,
    retire:         RetirePolicyState,
    credit_curve:   CurveShapeState,
    descent_curve:  CurveShapeState,
    price_function_state: PriceFunctionState,
): IntegrationConfig {
    assert!(min_rent_price > 0, EMinRentPriceZero);
    assert!(tenure_ceiling > 0, ETenureCeilingZero);
    // Cross-field validation: Countdown.floor_ms < tenure_ceiling.
    // Equality is the FixedTime variant. Intra-variant invariants
    // (e.g. floor_ms > 0) are owned by the policy module's
    // constructors. The variant-level check is encapsulated in
    // `handover_policy_state::countdown_floor_lt` since pattern-matching
    // on an enum variant is restricted to the defining module.
    assert!(
        handover_policy_state::countdown_floor_lt(&handover, tenure_ceiling),
        EHandoverFloorExceedsTenure,
    );
    IntegrationConfig {
        min_rent_price,
        tenure_ceiling,
        handover,
        descent,
        retire,
        credit_curve,
        descent_curve,
        price_function_state,
    }
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID) {
    event::emit(IntegrationConfigRegistered { escrow_id, config: *cfg });
}

// --- IntegrationConfig getters ---

public(package) fun min_rent_price(cfg: &IntegrationConfig):    u64               { cfg.min_rent_price }
public(package) fun tenure_ceiling(cfg: &IntegrationConfig):    u64               { cfg.tenure_ceiling }
public(package) fun handover(cfg: &IntegrationConfig):          &HandoverPolicyState   { &cfg.handover }
public(package) fun descent(cfg: &IntegrationConfig):           &DescentPolicyState    { &cfg.descent }
public(package) fun retire(cfg: &IntegrationConfig):            &RetirePolicyState     { &cfg.retire }
public(package) fun credit_curve(cfg: &IntegrationConfig):      &CurveShapeState       { &cfg.credit_curve }
public(package) fun descent_curve(cfg: &IntegrationConfig):     &CurveShapeState       { &cfg.descent_curve }
public(package) fun price_function_state(cfg: &IntegrationConfig):    &PriceFunctionState    { &cfg.price_function_state }

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_id(e: &IntegrationConfigRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_config(e: &IntegrationConfigRegistered): IntegrationConfig { e.config }
