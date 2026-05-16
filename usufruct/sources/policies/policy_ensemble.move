// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::policy_ensemble;

// === Imports ===

use sui::event;
use usufruct::{
    curve_shape_policy::CurveShapePolicy,
    descent_policy::DescentPolicy,
    escrow_identity::EscrowIdentity,
    handover_policy::{Self, HandoverPolicy},
    floor_price_policy::FloorPricePolicy,
    tenure_duration_policy::{Self as tenure_duration_policy, TenureDurationPolicy},
    tenure_extend_policy::TenureExtendPolicy,
    price_function_policy::PriceFunctionPolicy,
};

// === Errors ===

const EHandoverFloorExceedsTenure: u64 = 2;

// === Constants ===

// === Structs ===

public struct PolicyEnsemble has copy, drop, store {
    floor_price:      FloorPricePolicy,
    tenure_duration:  TenureDurationPolicy,
    tenure_extend:    TenureExtendPolicy,
    handover:         HandoverPolicy,
    descent:          DescentPolicy,
    credit_curve:     CurveShapePolicy,
    descent_curve:    CurveShapePolicy,
    price_function:   PriceFunctionPolicy,
}

// === Events ===

public struct PolicyEnsembleRegistered has copy, drop {
    escrow_identity: EscrowIdentity,
    ensemble:        PolicyEnsemble,
}

// === Method Aliases ===

// === Public Functions ===

public fun new_ensemble(
    floor_price:      FloorPricePolicy,
    tenure_duration:  TenureDurationPolicy,
    tenure_extend:    TenureExtendPolicy,
    handover:         HandoverPolicy,
    descent:          DescentPolicy,
    credit_curve:     CurveShapePolicy,
    descent_curve:    CurveShapePolicy,
    price_function:   PriceFunctionPolicy,
): PolicyEnsemble {
    assert!(
        handover_policy::countdown_floor_lt(&handover, tenure_duration_policy::min_ceiling(&tenure_duration)),
        EHandoverFloorExceedsTenure,
    );
    PolicyEnsemble {
        floor_price,
        tenure_duration,
        tenure_extend,
        handover,
        descent,
        credit_curve,
        descent_curve,
        price_function,
    }
}

// === View Functions ===

public(package) fun proj_floor_price(cfg: &PolicyEnsemble):     &FloorPricePolicy      { &cfg.floor_price }
public(package) fun proj_tenure_duration(cfg: &PolicyEnsemble): &TenureDurationPolicy  { &cfg.tenure_duration }
public(package) fun proj_tenure_extend(cfg: &PolicyEnsemble):   &TenureExtendPolicy    { &cfg.tenure_extend }
public(package) fun proj_handover(cfg: &PolicyEnsemble):        &HandoverPolicy        { &cfg.handover }
public(package) fun proj_descent(cfg: &PolicyEnsemble):         &DescentPolicy         { &cfg.descent }
public(package) fun proj_credit_curve(cfg: &PolicyEnsemble):    &CurveShapePolicy      { &cfg.credit_curve }
public(package) fun proj_descent_curve(cfg: &PolicyEnsemble):   &CurveShapePolicy      { &cfg.descent_curve }
public(package) fun proj_price_function(cfg: &PolicyEnsemble):  &PriceFunctionPolicy   { &cfg.price_function }

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(cfg: &PolicyEnsemble, escrow_identity: EscrowIdentity) {
    event::emit(PolicyEnsembleRegistered { escrow_identity, ensemble: *cfg });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_identity(e: &PolicyEnsembleRegistered): EscrowIdentity { e.escrow_identity }
#[test_only]
public fun registered_ensemble(e: &PolicyEnsembleRegistered): PolicyEnsemble { e.ensemble }

