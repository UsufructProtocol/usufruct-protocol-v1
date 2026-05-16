// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::policy_ensemble;

// === Imports ===

use sui::event;
use usufruct::{
    curve_shape_policy::CurveShapePolicy,
    auction_window_policy::AuctionWindowPolicy,
    escrow_identity::EscrowIdentity,
    handover_policy::{Self, HandoverPolicy},
    floor_price_policy::FloorPricePolicy,
    tenure_duration_policy::{Self as tenure_duration_policy, TenureDurationPolicy},
    tenure_extend_policy::TenureExtendPolicy,
    price_escalation_policy::PriceEscalationPolicy,
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
    auction_window:   AuctionWindowPolicy,
    credit_shape:     CurveShapePolicy,
    auction_shape:    CurveShapePolicy,
    price_escalation: PriceEscalationPolicy,
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
    auction_window:   AuctionWindowPolicy,
    credit_shape:     CurveShapePolicy,
    auction_shape:    CurveShapePolicy,
    price_escalation: PriceEscalationPolicy,
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
        auction_window,
        credit_shape,
        auction_shape,
        price_escalation,
    }
}

// === View Functions ===

public(package) fun proj_floor_price(cfg: &PolicyEnsemble):     &FloorPricePolicy      { &cfg.floor_price }
public(package) fun proj_tenure_duration(cfg: &PolicyEnsemble): &TenureDurationPolicy  { &cfg.tenure_duration }
public(package) fun proj_tenure_extend(cfg: &PolicyEnsemble):   &TenureExtendPolicy    { &cfg.tenure_extend }
public(package) fun proj_handover(cfg: &PolicyEnsemble):        &HandoverPolicy        { &cfg.handover }
public(package) fun proj_auction_window(cfg: &PolicyEnsemble):   &AuctionWindowPolicy   { &cfg.auction_window }
public(package) fun proj_credit_shape(cfg: &PolicyEnsemble):    &CurveShapePolicy      { &cfg.credit_shape }
public(package) fun proj_auction_shape(cfg: &PolicyEnsemble):   &CurveShapePolicy      { &cfg.auction_shape }
public(package) fun proj_price_escalation(cfg: &PolicyEnsemble): &PriceEscalationPolicy { &cfg.price_escalation }

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

