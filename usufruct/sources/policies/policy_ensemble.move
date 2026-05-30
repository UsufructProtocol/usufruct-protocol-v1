// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::policy_ensemble;

// === Imports ===

use std::string::String;
use sui::event;
use usufruct::{
    auction_window_policy::{Self, AuctionWindowPolicy},
    curve_shape_policy::{Self, CurveShapePolicy},
    escrow_identity::{Self, EscrowIdentity},
    handover_policy::{Self, HandoverPolicy},
    phases::{Self, Timestamp},
    price_escalation_policy::{Self, PriceEscalationPolicy},
    rest_price_policy::{Self, RestPricePolicy},
    tenure_duration_policy::{Self, TenureDurationPolicy},
    tenure_extend_policy::{Self, TenureExtendPolicy},
};

// === Errors ===

const EHandoverFloorExceedsTenure: u64 = 0;

// === Constants ===

// === Structs ===

public struct PolicyEnsemble has copy, drop, store {
    rest_price:        RestPricePolicy,
    tenure_duration:   TenureDurationPolicy,
    tenure_extend:     TenureExtendPolicy,
    handover:          HandoverPolicy,
    auction_window:    AuctionWindowPolicy,
    credit_shape:      CurveShapePolicy,
    auction_shape:     CurveShapePolicy,
    price_escalation:  PriceEscalationPolicy,
}

// === Events ===

public struct PolicyEnsembleRegistered has copy, drop {
    escrow_id:                 ID,
    timestamp_ms:              u64,
    rest_price_policy:         String,
    rest_price:                u64,
    tenure_duration_policy:    String,
    tenure_duration_ms:        u64,
    tenure_extend_policy:      String,
    handover_policy:           String,
    handover_floor_ms:         Option<u64>,
    auction_window_policy:     String,
    auction_window_ceiling_ms: Option<u64>,
    credit_shape_policy:       String,
    credit_alpha_num:          Option<u8>,
    credit_alpha_den:          Option<u8>,
    credit_alpha_abs:          Option<u8>,
    credit_alpha_neg:          Option<bool>,
    auction_shape_policy:      String,
    auction_alpha_num:         Option<u8>,
    auction_alpha_den:         Option<u8>,
    auction_alpha_abs:         Option<u8>,
    auction_alpha_neg:         Option<bool>,
    price_escalation_policy:   String,
    price_escalation_delta:    u64,
    price_escalation_bps:      Option<u64>,
}

public struct EnsembleUpdated has copy, drop {
    escrow_id:                 ID,
    timestamp_ms:              u64,
    rest_price_policy:         String,
    rest_price:                u64,
    tenure_duration_policy:    String,
    tenure_duration_ms:        u64,
    tenure_extend_policy:      String,
    handover_policy:           String,
    handover_floor_ms:         Option<u64>,
    auction_window_policy:     String,
    auction_window_ceiling_ms: Option<u64>,
    credit_shape_policy:       String,
    credit_alpha_num:          Option<u8>,
    credit_alpha_den:          Option<u8>,
    credit_alpha_abs:          Option<u8>,
    credit_alpha_neg:          Option<bool>,
    auction_shape_policy:      String,
    auction_alpha_num:         Option<u8>,
    auction_alpha_den:         Option<u8>,
    auction_alpha_abs:         Option<u8>,
    auction_alpha_neg:         Option<bool>,
    price_escalation_policy:   String,
    price_escalation_delta:    u64,
    price_escalation_bps:      Option<u64>,
}

public struct EnsembleUpdateScheduled has copy, drop {
    escrow_id:                 ID,
    timestamp_ms:              u64,
    rest_price_policy:         String,
    rest_price:                u64,
    tenure_duration_policy:    String,
    tenure_duration_ms:        u64,
    tenure_extend_policy:      String,
    handover_policy:           String,
    handover_floor_ms:         Option<u64>,
    auction_window_policy:     String,
    auction_window_ceiling_ms: Option<u64>,
    credit_shape_policy:       String,
    credit_alpha_num:          Option<u8>,
    credit_alpha_den:          Option<u8>,
    credit_alpha_abs:          Option<u8>,
    credit_alpha_neg:          Option<bool>,
    auction_shape_policy:      String,
    auction_alpha_num:         Option<u8>,
    auction_alpha_den:         Option<u8>,
    auction_alpha_abs:         Option<u8>,
    auction_alpha_neg:         Option<bool>,
    price_escalation_policy:   String,
    price_escalation_delta:    u64,
    price_escalation_bps:      Option<u64>,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_rest_price(ensemble: &PolicyEnsemble):      &RestPricePolicy      { &ensemble.rest_price }
public(package) fun proj_tenure_duration(ensemble: &PolicyEnsemble): &TenureDurationPolicy  { &ensemble.tenure_duration }
public(package) fun proj_tenure_extend(ensemble: &PolicyEnsemble):   &TenureExtendPolicy    { &ensemble.tenure_extend }
public(package) fun proj_handover(ensemble: &PolicyEnsemble):        &HandoverPolicy        { &ensemble.handover }
public(package) fun proj_auction_window(ensemble: &PolicyEnsemble):   &AuctionWindowPolicy   { &ensemble.auction_window }
public(package) fun proj_credit_shape(ensemble: &PolicyEnsemble):    &CurveShapePolicy      { &ensemble.credit_shape }
public(package) fun proj_auction_shape(ensemble: &PolicyEnsemble):   &CurveShapePolicy      { &ensemble.auction_shape }
public(package) fun proj_price_escalation(ensemble: &PolicyEnsemble): &PriceEscalationPolicy { &ensemble.price_escalation }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_ensemble(
    rest_price:       RestPricePolicy,
    tenure_duration:  TenureDurationPolicy,
    tenure_extend:    TenureExtendPolicy,
    handover:         HandoverPolicy,
    auction_window:   AuctionWindowPolicy,
    credit_shape:     CurveShapePolicy,
    auction_shape:    CurveShapePolicy,
    price_escalation: PriceEscalationPolicy,
): PolicyEnsemble {
    assert!(
        handover_policy::compute_countdown_floor_lt(&handover, tenure_duration_policy::proj_min_ceiling(&tenure_duration)),
        EHandoverFloorExceedsTenure,
    );
    PolicyEnsemble {
        rest_price,
        tenure_duration,
        tenure_extend,
        handover,
        auction_window,
        credit_shape,
        auction_shape,
        price_escalation,
    }
}

public(package) fun emit_registration(ensemble: &PolicyEnsemble, escrow_identity: EscrowIdentity, timestamp: Timestamp) {
    let rp  = proj_rest_price(ensemble);
    let td  = proj_tenure_duration(ensemble);
    let te  = proj_tenure_extend(ensemble);
    let hp  = proj_handover(ensemble);
    let aw  = proj_auction_window(ensemble);
    let cs  = proj_credit_shape(ensemble);
    let as_ = proj_auction_shape(ensemble);
    let pe  = proj_price_escalation(ensemble);
    event::emit(PolicyEnsembleRegistered {
        escrow_id:                 escrow_identity::escrow_id(escrow_identity),
        timestamp_ms:              phases::timestamp_ms(timestamp),
        rest_price_policy:         rest_price_policy::proj_rest_price_policy(rp),
        rest_price:                rest_price_policy::proj_rest_price_mist(rp),
        tenure_duration_policy:    tenure_duration_policy::proj_tenure_duration_policy(td),
        tenure_duration_ms:        tenure_duration_policy::proj_tenure_duration_ms(td),
        tenure_extend_policy:      tenure_extend_policy::proj_tenure_extend_policy(te),
        handover_policy:           handover_policy::proj_handover_policy(hp),
        handover_floor_ms:         handover_policy::proj_handover_floor_ms(hp),
        auction_window_policy:     auction_window_policy::proj_auction_window_policy(aw),
        auction_window_ceiling_ms: auction_window_policy::proj_auction_window_ceiling_ms(aw),
        credit_shape_policy:       curve_shape_policy::proj_curve_shape_policy(cs),
        credit_alpha_num:          curve_shape_policy::proj_power_law_alpha_num(cs),
        credit_alpha_den:          curve_shape_policy::proj_power_law_alpha_den(cs),
        credit_alpha_abs:          curve_shape_policy::proj_exponential_alpha_abs(cs),
        credit_alpha_neg:          curve_shape_policy::proj_exponential_alpha_neg(cs),
        auction_shape_policy:      curve_shape_policy::proj_curve_shape_policy(as_),
        auction_alpha_num:         curve_shape_policy::proj_power_law_alpha_num(as_),
        auction_alpha_den:         curve_shape_policy::proj_power_law_alpha_den(as_),
        auction_alpha_abs:         curve_shape_policy::proj_exponential_alpha_abs(as_),
        auction_alpha_neg:         curve_shape_policy::proj_exponential_alpha_neg(as_),
        price_escalation_policy:   price_escalation_policy::proj_price_escalation_policy(pe),
        price_escalation_delta:    price_escalation_policy::proj_price_escalation_delta_mist(pe),
        price_escalation_bps:      price_escalation_policy::proj_price_escalation_bps(pe),
    });
}

public(package) fun emit_ensemble_updated(ensemble: &PolicyEnsemble, escrow_identity: EscrowIdentity, timestamp: Timestamp) {
    let rp  = proj_rest_price(ensemble);
    let td  = proj_tenure_duration(ensemble);
    let te  = proj_tenure_extend(ensemble);
    let hp  = proj_handover(ensemble);
    let aw  = proj_auction_window(ensemble);
    let cs  = proj_credit_shape(ensemble);
    let as_ = proj_auction_shape(ensemble);
    let pe  = proj_price_escalation(ensemble);
    event::emit(EnsembleUpdated {
        escrow_id:                 escrow_identity::escrow_id(escrow_identity),
        timestamp_ms:              phases::timestamp_ms(timestamp),
        rest_price_policy:         rest_price_policy::proj_rest_price_policy(rp),
        rest_price:                rest_price_policy::proj_rest_price_mist(rp),
        tenure_duration_policy:    tenure_duration_policy::proj_tenure_duration_policy(td),
        tenure_duration_ms:        tenure_duration_policy::proj_tenure_duration_ms(td),
        tenure_extend_policy:      tenure_extend_policy::proj_tenure_extend_policy(te),
        handover_policy:           handover_policy::proj_handover_policy(hp),
        handover_floor_ms:         handover_policy::proj_handover_floor_ms(hp),
        auction_window_policy:     auction_window_policy::proj_auction_window_policy(aw),
        auction_window_ceiling_ms: auction_window_policy::proj_auction_window_ceiling_ms(aw),
        credit_shape_policy:       curve_shape_policy::proj_curve_shape_policy(cs),
        credit_alpha_num:          curve_shape_policy::proj_power_law_alpha_num(cs),
        credit_alpha_den:          curve_shape_policy::proj_power_law_alpha_den(cs),
        credit_alpha_abs:          curve_shape_policy::proj_exponential_alpha_abs(cs),
        credit_alpha_neg:          curve_shape_policy::proj_exponential_alpha_neg(cs),
        auction_shape_policy:      curve_shape_policy::proj_curve_shape_policy(as_),
        auction_alpha_num:         curve_shape_policy::proj_power_law_alpha_num(as_),
        auction_alpha_den:         curve_shape_policy::proj_power_law_alpha_den(as_),
        auction_alpha_abs:         curve_shape_policy::proj_exponential_alpha_abs(as_),
        auction_alpha_neg:         curve_shape_policy::proj_exponential_alpha_neg(as_),
        price_escalation_policy:   price_escalation_policy::proj_price_escalation_policy(pe),
        price_escalation_delta:    price_escalation_policy::proj_price_escalation_delta_mist(pe),
        price_escalation_bps:      price_escalation_policy::proj_price_escalation_bps(pe),
    });
}

public(package) fun emit_ensemble_update_scheduled(ensemble: &PolicyEnsemble, escrow_identity: EscrowIdentity, timestamp: Timestamp) {
    let rp  = proj_rest_price(ensemble);
    let td  = proj_tenure_duration(ensemble);
    let te  = proj_tenure_extend(ensemble);
    let hp  = proj_handover(ensemble);
    let aw  = proj_auction_window(ensemble);
    let cs  = proj_credit_shape(ensemble);
    let as_ = proj_auction_shape(ensemble);
    let pe  = proj_price_escalation(ensemble);
    event::emit(EnsembleUpdateScheduled {
        escrow_id:                 escrow_identity::escrow_id(escrow_identity),
        timestamp_ms:              phases::timestamp_ms(timestamp),
        rest_price_policy:         rest_price_policy::proj_rest_price_policy(rp),
        rest_price:                rest_price_policy::proj_rest_price_mist(rp),
        tenure_duration_policy:    tenure_duration_policy::proj_tenure_duration_policy(td),
        tenure_duration_ms:        tenure_duration_policy::proj_tenure_duration_ms(td),
        tenure_extend_policy:      tenure_extend_policy::proj_tenure_extend_policy(te),
        handover_policy:           handover_policy::proj_handover_policy(hp),
        handover_floor_ms:         handover_policy::proj_handover_floor_ms(hp),
        auction_window_policy:     auction_window_policy::proj_auction_window_policy(aw),
        auction_window_ceiling_ms: auction_window_policy::proj_auction_window_ceiling_ms(aw),
        credit_shape_policy:       curve_shape_policy::proj_curve_shape_policy(cs),
        credit_alpha_num:          curve_shape_policy::proj_power_law_alpha_num(cs),
        credit_alpha_den:          curve_shape_policy::proj_power_law_alpha_den(cs),
        credit_alpha_abs:          curve_shape_policy::proj_exponential_alpha_abs(cs),
        credit_alpha_neg:          curve_shape_policy::proj_exponential_alpha_neg(cs),
        auction_shape_policy:      curve_shape_policy::proj_curve_shape_policy(as_),
        auction_alpha_num:         curve_shape_policy::proj_power_law_alpha_num(as_),
        auction_alpha_den:         curve_shape_policy::proj_power_law_alpha_den(as_),
        auction_alpha_abs:         curve_shape_policy::proj_exponential_alpha_abs(as_),
        auction_alpha_neg:         curve_shape_policy::proj_exponential_alpha_neg(as_),
        price_escalation_policy:   price_escalation_policy::proj_price_escalation_policy(pe),
        price_escalation_delta:    price_escalation_policy::proj_price_escalation_delta_mist(pe),
        price_escalation_bps:      price_escalation_policy::proj_price_escalation_bps(pe),
    });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_identity(e: &PolicyEnsembleRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_rest_price_mist(e: &PolicyEnsembleRegistered): u64 { e.rest_price }
#[test_only]
public fun registered_tenure_duration_ms(e: &PolicyEnsembleRegistered): u64 { e.tenure_duration_ms }
#[test_only]
public fun registered_handover_policy(e: &PolicyEnsembleRegistered): String { e.handover_policy }
#[test_only]
public fun registered_handover_floor_ms(e: &PolicyEnsembleRegistered): Option<u64> { e.handover_floor_ms }
#[test_only]
public fun registered_auction_window_policy(e: &PolicyEnsembleRegistered): String { e.auction_window_policy }
#[test_only]
public fun registered_auction_window_ceiling_ms(e: &PolicyEnsembleRegistered): Option<u64> { e.auction_window_ceiling_ms }
#[test_only]
public fun registered_credit_shape_policy(e: &PolicyEnsembleRegistered): String { e.credit_shape_policy }
#[test_only]
public fun registered_credit_alpha_num(e: &PolicyEnsembleRegistered): Option<u8> { e.credit_alpha_num }
#[test_only]
public fun registered_credit_alpha_den(e: &PolicyEnsembleRegistered): Option<u8> { e.credit_alpha_den }
#[test_only]
public fun registered_auction_shape_policy(e: &PolicyEnsembleRegistered): String { e.auction_shape_policy }
#[test_only]
public fun registered_auction_alpha_num(e: &PolicyEnsembleRegistered): Option<u8> { e.auction_alpha_num }
#[test_only]
public fun registered_auction_alpha_den(e: &PolicyEnsembleRegistered): Option<u8> { e.auction_alpha_den }

#[test_only]
public fun ensemble_updated_escrow_id(e: &EnsembleUpdated): ID { e.escrow_id }
#[test_only]
public fun ensemble_updated_rest_price_mist(e: &EnsembleUpdated): u64 { e.rest_price }
#[test_only]
public fun ensemble_updated_auction_window_policy(e: &EnsembleUpdated): String { e.auction_window_policy }
#[test_only]
public fun ensemble_updated_auction_window_ceiling_ms(e: &EnsembleUpdated): Option<u64> { e.auction_window_ceiling_ms }
#[test_only]
public fun ensemble_updated_handover_policy(e: &EnsembleUpdated): String { e.handover_policy }
#[test_only]
public fun ensemble_updated_handover_floor_ms(e: &EnsembleUpdated): Option<u64> { e.handover_floor_ms }

#[test_only]
public fun ensemble_update_scheduled_escrow_id(e: &EnsembleUpdateScheduled): ID { e.escrow_id }
#[test_only]
public fun ensemble_update_scheduled_rest_price_mist(e: &EnsembleUpdateScheduled): u64 { e.rest_price }

// PolicyEnsembleRegistered — missing fields
#[test_only]
public fun registered_rest_price_policy(e: &PolicyEnsembleRegistered): String { e.rest_price_policy }
#[test_only]
public fun registered_tenure_duration_policy(e: &PolicyEnsembleRegistered): String { e.tenure_duration_policy }
#[test_only]
public fun registered_tenure_extend_policy(e: &PolicyEnsembleRegistered): String { e.tenure_extend_policy }
#[test_only]
public fun registered_credit_alpha_abs(e: &PolicyEnsembleRegistered): Option<u8>   { e.credit_alpha_abs }
#[test_only]
public fun registered_credit_alpha_neg(e: &PolicyEnsembleRegistered): Option<bool> { e.credit_alpha_neg }
#[test_only]
public fun registered_auction_alpha_abs(e: &PolicyEnsembleRegistered): Option<u8>   { e.auction_alpha_abs }
#[test_only]
public fun registered_auction_alpha_neg(e: &PolicyEnsembleRegistered): Option<bool> { e.auction_alpha_neg }
#[test_only]
public fun registered_price_escalation_policy(e: &PolicyEnsembleRegistered): String     { e.price_escalation_policy }
#[test_only]
public fun registered_price_escalation_delta(e: &PolicyEnsembleRegistered): u64         { e.price_escalation_delta }
#[test_only]
public fun registered_price_escalation_bps(e: &PolicyEnsembleRegistered): Option<u64>  { e.price_escalation_bps }

// EnsembleUpdated — missing fields
#[test_only]
public fun ensemble_updated_rest_price_policy(e: &EnsembleUpdated): String     { e.rest_price_policy }
#[test_only]
public fun ensemble_updated_tenure_duration_policy(e: &EnsembleUpdated): String { e.tenure_duration_policy }
#[test_only]
public fun ensemble_updated_tenure_duration_ms(e: &EnsembleUpdated): u64       { e.tenure_duration_ms }
#[test_only]
public fun ensemble_updated_tenure_extend_policy(e: &EnsembleUpdated): String  { e.tenure_extend_policy }
#[test_only]
public fun ensemble_updated_credit_shape_policy(e: &EnsembleUpdated): String   { e.credit_shape_policy }
#[test_only]
public fun ensemble_updated_credit_alpha_num(e: &EnsembleUpdated): Option<u8>  { e.credit_alpha_num }
#[test_only]
public fun ensemble_updated_credit_alpha_den(e: &EnsembleUpdated): Option<u8>  { e.credit_alpha_den }
#[test_only]
public fun ensemble_updated_credit_alpha_abs(e: &EnsembleUpdated): Option<u8>   { e.credit_alpha_abs }
#[test_only]
public fun ensemble_updated_credit_alpha_neg(e: &EnsembleUpdated): Option<bool> { e.credit_alpha_neg }
#[test_only]
public fun ensemble_updated_auction_shape_policy(e: &EnsembleUpdated): String   { e.auction_shape_policy }
#[test_only]
public fun ensemble_updated_auction_alpha_num(e: &EnsembleUpdated): Option<u8>  { e.auction_alpha_num }
#[test_only]
public fun ensemble_updated_auction_alpha_den(e: &EnsembleUpdated): Option<u8>  { e.auction_alpha_den }
#[test_only]
public fun ensemble_updated_auction_alpha_abs(e: &EnsembleUpdated): Option<u8>   { e.auction_alpha_abs }
#[test_only]
public fun ensemble_updated_auction_alpha_neg(e: &EnsembleUpdated): Option<bool> { e.auction_alpha_neg }
#[test_only]
public fun ensemble_updated_price_escalation_policy(e: &EnsembleUpdated): String    { e.price_escalation_policy }
#[test_only]
public fun ensemble_updated_price_escalation_delta(e: &EnsembleUpdated): u64        { e.price_escalation_delta }
#[test_only]
public fun ensemble_updated_price_escalation_bps(e: &EnsembleUpdated): Option<u64> { e.price_escalation_bps }

// EnsembleUpdateScheduled — missing fields
#[test_only]
public fun ensemble_update_scheduled_rest_price_policy(e: &EnsembleUpdateScheduled): String     { e.rest_price_policy }
#[test_only]
public fun ensemble_update_scheduled_tenure_duration_policy(e: &EnsembleUpdateScheduled): String { e.tenure_duration_policy }
#[test_only]
public fun ensemble_update_scheduled_tenure_duration_ms(e: &EnsembleUpdateScheduled): u64       { e.tenure_duration_ms }
#[test_only]
public fun ensemble_update_scheduled_tenure_extend_policy(e: &EnsembleUpdateScheduled): String  { e.tenure_extend_policy }
#[test_only]
public fun ensemble_update_scheduled_handover_policy(e: &EnsembleUpdateScheduled): String       { e.handover_policy }
#[test_only]
public fun ensemble_update_scheduled_handover_floor_ms(e: &EnsembleUpdateScheduled): Option<u64> { e.handover_floor_ms }
#[test_only]
public fun ensemble_update_scheduled_auction_window_policy(e: &EnsembleUpdateScheduled): String     { e.auction_window_policy }
#[test_only]
public fun ensemble_update_scheduled_auction_window_ceiling_ms(e: &EnsembleUpdateScheduled): Option<u64> { e.auction_window_ceiling_ms }
#[test_only]
public fun ensemble_update_scheduled_credit_shape_policy(e: &EnsembleUpdateScheduled): String   { e.credit_shape_policy }
#[test_only]
public fun ensemble_update_scheduled_credit_alpha_num(e: &EnsembleUpdateScheduled): Option<u8>  { e.credit_alpha_num }
#[test_only]
public fun ensemble_update_scheduled_credit_alpha_den(e: &EnsembleUpdateScheduled): Option<u8>  { e.credit_alpha_den }
#[test_only]
public fun ensemble_update_scheduled_credit_alpha_abs(e: &EnsembleUpdateScheduled): Option<u8>   { e.credit_alpha_abs }
#[test_only]
public fun ensemble_update_scheduled_credit_alpha_neg(e: &EnsembleUpdateScheduled): Option<bool> { e.credit_alpha_neg }
#[test_only]
public fun ensemble_update_scheduled_auction_shape_policy(e: &EnsembleUpdateScheduled): String   { e.auction_shape_policy }
#[test_only]
public fun ensemble_update_scheduled_auction_alpha_num(e: &EnsembleUpdateScheduled): Option<u8>  { e.auction_alpha_num }
#[test_only]
public fun ensemble_update_scheduled_auction_alpha_den(e: &EnsembleUpdateScheduled): Option<u8>  { e.auction_alpha_den }
#[test_only]
public fun ensemble_update_scheduled_auction_alpha_abs(e: &EnsembleUpdateScheduled): Option<u8>   { e.auction_alpha_abs }
#[test_only]
public fun ensemble_update_scheduled_auction_alpha_neg(e: &EnsembleUpdateScheduled): Option<bool> { e.auction_alpha_neg }
#[test_only]
public fun ensemble_update_scheduled_price_escalation_policy(e: &EnsembleUpdateScheduled): String    { e.price_escalation_policy }
#[test_only]
public fun ensemble_update_scheduled_price_escalation_delta(e: &EnsembleUpdateScheduled): u64        { e.price_escalation_delta }
#[test_only]
public fun ensemble_update_scheduled_price_escalation_bps(e: &EnsembleUpdateScheduled): Option<u64> { e.price_escalation_bps }

#[test_only]
public fun registered_timestamp_ms(e: &PolicyEnsembleRegistered): u64 { e.timestamp_ms }
#[test_only]
public fun ensemble_updated_timestamp_ms(e: &EnsembleUpdated): u64 { e.timestamp_ms }
#[test_only]
public fun ensemble_update_scheduled_timestamp_ms(e: &EnsembleUpdateScheduled): u64 { e.timestamp_ms }
