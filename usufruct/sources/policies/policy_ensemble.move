// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::policy_ensemble;

// === Imports ===

use sui::event;
use usufruct::{
    curve_shape_policy::CurveShapePolicy,
    descent_policy::DescentPolicy,
    handover_policy::{Self, HandoverPolicy},
    floor_price_policy::FloorPricePolicy,
    tenure_policy::{Self as tenure_policy, TenurePolicy},
    tenures_policy::TenuresPolicy,
    price_function_policy::PriceFunctionPolicy,
};

// === Errors ===

const EHandoverFloorExceedsTenure: u64 = 2;

// === Constants ===

// === Structs ===

public struct PolicyEnsemble has copy, drop, store {
    min_rent_price:   FloorPricePolicy,
    tenure_ceiling:   TenurePolicy,
    tenures:    TenuresPolicy,
    handover:         HandoverPolicy,
    descent:          DescentPolicy,
    credit_curve:     CurveShapePolicy,
    descent_curve:    CurveShapePolicy,
    price_function_policy: PriceFunctionPolicy,
}

// === Events ===

public struct PolicyEnsembleRegistered has copy, drop {
    escrow_id: ID,
    ensemble: PolicyEnsemble,
}

// === Method Aliases ===

// === Public Functions ===

public fun new_ensemble(
    min_rent_price:  FloorPricePolicy,
    tenure_ceiling:  TenurePolicy,
    tenures:   TenuresPolicy,
    handover:        HandoverPolicy,
    descent:         DescentPolicy,
    credit_curve:    CurveShapePolicy,
    descent_curve:   CurveShapePolicy,
    price_function_policy: PriceFunctionPolicy,
): PolicyEnsemble {
    assert!(
        handover_policy::countdown_floor_lt(&handover, tenure_policy::min_ceiling(&tenure_ceiling)),
        EHandoverFloorExceedsTenure,
    );
    PolicyEnsemble {
        min_rent_price,
        tenure_ceiling,
        tenures,
        handover,
        descent,
        credit_curve,
        descent_curve,
        price_function_policy,
    }
}

// === View Functions ===

public(package) fun proj_min_rent_price(cfg: &PolicyEnsemble):        &FloorPricePolicy      { &cfg.min_rent_price }
public(package) fun proj_tenure_ceiling(cfg: &PolicyEnsemble):         &TenurePolicy          { &cfg.tenure_ceiling }
public(package) fun proj_tenures(cfg: &PolicyEnsemble):          &TenuresPolicy    { &cfg.tenures }
public(package) fun proj_handover(cfg: &PolicyEnsemble):               &HandoverPolicy         { &cfg.handover }
public(package) fun proj_descent(cfg: &PolicyEnsemble):               &DescentPolicy   { &cfg.descent }
public(package) fun proj_credit_curve(cfg: &PolicyEnsemble):          &CurveShapePolicy      { &cfg.credit_curve }
public(package) fun proj_descent_curve(cfg: &PolicyEnsemble):         &CurveShapePolicy      { &cfg.descent_curve }
public(package) fun proj_price_function_policy(cfg: &PolicyEnsemble): &PriceFunctionPolicy   { &cfg.price_function_policy }

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(cfg: &PolicyEnsemble, escrow_id: ID) {
    event::emit(PolicyEnsembleRegistered { escrow_id, ensemble: *cfg });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_id(e: &PolicyEnsembleRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_ensemble(e: &PolicyEnsembleRegistered): PolicyEnsemble { e.ensemble }

