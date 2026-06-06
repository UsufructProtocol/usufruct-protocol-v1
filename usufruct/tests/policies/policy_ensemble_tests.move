// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::config_tests;

use std::unit_test::assert_eq;
use sui::{
    event,
    test_scenario,
};
use usufruct::{
    policy_ensemble::{
        Self,
        PolicyEnsemble,
        PolicyEnsembleRegistered,
        EnsembleUpdated,
        EnsembleUpdateScheduled,
    },
    curve_shape_policy,
    auction_window_policy::{Self, AuctionWindowPolicy},
    escrow_identity,
    handover_policy::{Self, HandoverPolicy},
    math,
    rest_price_policy,
    tenure_extend_policy,
    tenure_duration_policy::{Self, TenureDurationPolicy},
    monetary,
    phases,
    price_escalation_policy,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

// Canonical V2 config values (used as baseline for single-field variation rows).
const V2_MIN_RENT_PRICE:  u64 = 1_000_000;
const V2_TENURE_CEILING:  u64 = 86_400_000;
const V2_HANDOVER_FLOOR:  u64 = 3_600_000;       // → Fixed
const V2_DESCENT_CEILING: u64 = 43_200_000;      // → Fixed

fun v2_handover(): HandoverPolicy { handover_policy::new_handover_fixed(phases::duration(V2_HANDOVER_FLOOR)) }
fun v2_descent():  AuctionWindowPolicy  { auction_window_policy::new_descent_fixed(phases::duration(V2_DESCENT_CEILING)) }

fun v2_config(): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)),
        tenure_extend_policy::new_single(),
        v2_handover(),
        v2_descent(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    )
}

// ─── §7.1 + §7.3 — Valid inputs + getter round-trip ───────────────────────────

// Case struct for the parametric loop. All twelve V-rows are encoded here.
// The loop both constructs the config and verifies each getter (§7.3 P5
// predicate). Policy fields are stored as the enum variants directly so the
// round-trip assertion compares structurally typed values, not raw u64s.
public struct Case has drop {
    min_rent_price: u64,
    tenure_ceiling: TenureDurationPolicy,
    handover:       HandoverPolicy,
    descent:        AuctionWindowPolicy,
    credit_shape:   curve_shape_policy::CurveShapePolicy,
    auction_shape:  curve_shape_policy::CurveShapePolicy,
    price_escalation_policy: price_escalation_policy::PriceEscalationPolicy,
}

#[test]
fun new_config_valid_inputs_and_getter_roundtrip() {
    let cases = vector[
        // V1 — minimal valid; HandoverPolicy::Off
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(1)),
            handover:       handover_policy::new_handover_off(),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(1)),
            credit_shape:   curve_shape_policy::new_linear(),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V2 — typical: 1h handover countdown in 24h tenure, 12h auction window
        Case {
            min_rent_price: 1_000_000,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(86_400_000)),
            handover:       handover_policy::new_handover_fixed(phases::duration(3_600_000)),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(43_200_000)),
            credit_shape:   curve_shape_policy::new_linear(),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V3 — Smoothstep curves
        Case {
            min_rent_price: 100,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(10_000)),
            handover:       handover_policy::new_handover_fixed(phases::duration(5_000)),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(10_000)),
            credit_shape:   curve_shape_policy::new_smoothstep(),
            auction_shape:  curve_shape_policy::new_smoothstep(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(10)),
        },
        // V4 — Instant handover (no bidding window); PowerLaw credit
        Case {
            min_rent_price: 50,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(100_000)),
            handover:       handover_policy::new_handover_off(),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(50_000)),
            credit_shape:   curve_shape_policy::new_power_law(1, 2),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V5 — u64::MAX min_rent_price; mixed Exp curves
        Case {
            min_rent_price: 18_446_744_073_709_551_615,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_fixed(phases::duration(500)),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(1_000)),
            credit_shape:   curve_shape_policy::new_exponential(3, false),
            auction_shape:  curve_shape_policy::new_exponential(3, true),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V6 — no upper bound on time params; Fixed(u64::MAX)
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(18_446_744_073_709_551_615)),
            handover:       handover_policy::new_handover_fixed(phases::duration(1)),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(18_446_744_073_709_551_615)),
            credit_shape:   curve_shape_policy::new_logistic(),
            auction_shape:  curve_shape_policy::new_logistic(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V7 — CompoundDelta price function: 5% + 100 base units per cycle
        Case {
            min_rent_price: 1_000,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(86_400_000)),
            handover:       handover_policy::new_handover_fixed(phases::duration(3_600_000)),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(43_200_000)),
            credit_shape:   curve_shape_policy::new_linear(),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_compound_delta(math::bps(500), monetary::price(100)),
        },
        // V8 — HandoverPolicy::FullTenure
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_full_tenure(),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(1)),
            credit_shape:   curve_shape_policy::new_linear(),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V9 — FullTenure at u64-extreme tenure_ceiling (independent of magnitude)
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(18_446_744_073_709_551_615)),
            handover:       handover_policy::new_handover_full_tenure(),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(1)),
            credit_shape:   curve_shape_policy::new_linear(),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V10 — PowerLaw inputs requiring gcd normalization
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_off(),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(1)),
            credit_shape:   curve_shape_policy::new_power_law(2, 4),
            auction_shape:  curve_shape_policy::new_power_law(6, 3),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
        // V11 — extreme α values (min convex, max concave) + minimum CompoundDelta
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_fixed(phases::duration(500)),
            descent:        auction_window_policy::new_descent_fixed(phases::duration(1)),
            credit_shape:   curve_shape_policy::new_exponential(1, false),
            auction_shape:  curve_shape_policy::new_exponential(8, true),
            price_escalation_policy: price_escalation_policy::new_compound_delta(math::bps(1), monetary::price(1)),
        },
        // V12 — AuctionWindowPolicy::Off ("DescentAuction unobservable" mode, M6b)
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_duration_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_off(),
            descent:        auction_window_policy::new_descent_off(),
            credit_shape:   curve_shape_policy::new_linear(),
            auction_shape:  curve_shape_policy::new_linear(),
            price_escalation_policy: price_escalation_policy::new_fixed_delta(monetary::price(1)),
        },
    ];

    cases.do_ref!(|c| {
        let ensemble = policy_ensemble::new_ensemble(
            rest_price_policy::new_fixed(monetary::price(c.min_rent_price)),
            c.tenure_ceiling,
            tenure_extend_policy::new_single(),
            c.handover,
            c.descent,
            c.credit_shape,
            c.auction_shape,
            c.price_escalation_policy,
        );
        // §7.3 P5 predicate: getter(new_config(..., f, ...)) == f for each field
        assert_eq!(monetary::price_mist(rest_price_policy::compute_floor_price(policy_ensemble::proj_rest_price(&ensemble))),  c.min_rent_price);
        assert_eq!(*policy_ensemble::proj_tenure_duration(&ensemble),  c.tenure_ceiling);
        assert_eq!(*policy_ensemble::proj_handover(&ensemble),        c.handover);
        assert_eq!(*policy_ensemble::proj_auction_window(&ensemble),         c.descent);
        assert_eq!(*policy_ensemble::proj_credit_shape(&ensemble),    c.credit_shape);
        assert_eq!(*policy_ensemble::proj_auction_shape(&ensemble),   c.auction_shape);
        assert_eq!(*policy_ensemble::proj_price_escalation(&ensemble), c.price_escalation_policy);
    });
}

// ─── §7.3 Explicit field pins (R1–R8) ─────────────────────────────────────────

// Each row holds all other fields at V2 canonical values; only the named field varies.

#[test]
fun getter_roundtrip_r1_min_rent_price_max() {
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(18_446_744_073_709_551_615)),
        tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(monetary::price_mist(rest_price_policy::compute_floor_price(policy_ensemble::proj_rest_price(&ensemble))), 18_446_744_073_709_551_615);
}

#[test]
fun getter_roundtrip_r2_tenure_ceiling_typical_ms() {
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(86_400_000)),
        tenure_extend_policy::new_single(),
        v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(tenure_duration_policy::proj_is_fixed(policy_ensemble::proj_tenure_duration(&ensemble)), true);
    assert_eq!(phases::duration_ms(*option::borrow(&tenure_duration_policy::proj_fixed_ceiling(policy_ensemble::proj_tenure_duration(&ensemble)))), 86_400_000);
}

#[test]
fun getter_roundtrip_r3_handover_instant() {
    let h   = handover_policy::new_handover_off();
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)),
        tenure_extend_policy::new_single(),
        h,
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_handover(&ensemble), h);
}

#[test]
fun getter_roundtrip_r3b_handover_full_tenure() {
    // Companion to R3 covering the upper-saturation variant.
    let h   = handover_policy::new_handover_full_tenure();
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)),
        tenure_extend_policy::new_single(),
        h,
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_handover(&ensemble), h);
}

#[test]
fun getter_roundtrip_r4_descent_window_one() {
    let d   = auction_window_policy::new_descent_fixed(phases::duration(1));
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(),
        d,
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_auction_window(&ensemble), d);
}

#[test]
fun getter_roundtrip_r4b_descent_skipped() {
    // Companion to R4 covering the auction-skipped variant.
    let d   = auction_window_policy::new_descent_off();
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(),
        d,
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_auction_window(&ensemble), d);
}

#[test]
fun getter_roundtrip_r5_credit_shape_power_law_gcd_normalized() {
    // new_power_law(2,4) normalizes to stored PowerLaw{1,2}.
    // Getter returns the reduced form — normalization is upstream in curve_shape_state.
    let raw = curve_shape_policy::new_power_law(2, 4);
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(), v2_descent(),
        raw,
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_credit_shape(&ensemble), raw);
}

#[test]
fun getter_roundtrip_r6_auction_shape_logistic() {
    let g = curve_shape_policy::new_logistic();
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(),
        g,
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_auction_shape(&ensemble), g);
}

#[test]
fun getter_roundtrip_r7_price_function_state_compound_delta() {
    let pf = price_escalation_policy::new_compound_delta(math::bps(500), monetary::price(100));
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        pf,
    );
    assert_eq!(*policy_ensemble::proj_price_escalation(&ensemble), pf);
}

// ─── §7.2 — Invalid inputs (one function each) ────────────────────────────────

#[test, expected_failure(abort_code = rest_price_policy::EPriceZero, location = usufruct::rest_price_policy)]
fun new_config_rejects_min_rent_price_zero() {
    // Validation moved to RestPricePolicy constructor; new_fixed(0) aborts before new_config.
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(0)),
        tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = tenure_duration_policy::EDurationZero, location = usufruct::tenure_duration_policy)]
fun new_config_rejects_tenure_ceiling_zero() {
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(0)),
        tenure_extend_policy::new_single(),
        v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_gt_tenure_ceiling() {
    // I3: Fixed(100) with tenure_ceiling=50
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(50)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_fixed(phases::duration(100)),
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_tenure_ceiling_plus_one() {
    // I4: smallest strictly-greater case — guards off-by-one on the < check
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(1_000)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_fixed(phases::duration(1_001)),
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_u64_max_tenure_ceiling_max_minus_one() {
    // I5: u64-saturated boundary; confirms plain unsigned compare (no arithmetic overflow)
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(18_446_744_073_709_551_614)), // u64::MAX - 1
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_fixed(phases::duration(18_446_744_073_709_551_615)), // u64::MAX
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_eq_tenure_ceiling() {
    // I6: equality with tenure_ceiling is FullTenure, not the upper edge of Fixed.
    // Constructor accepts Fixed(1_000) but new_config rejects when paired with
    // tenure_ceiling=1_000 — caller must use new_handover_full_tenure() instead.
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(1_000)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_fixed(phases::duration(1_000)),
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
}

// ─── §7.4 — emit_registration event tests ─────────────────────────────────────

// E1: full config snapshot is captured in the event; escrow_id matches.
#[test]
fun emit_registration_e1_full_snapshot() {
    let ensemble = v2_config();
    let ei       = escrow_identity::new(object::id_from_address(@0xE5C1));
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&ensemble, ei, phases::timestamp(0));
        let events = event::events_by_type<PolicyEnsembleRegistered>();
        assert_eq!(events.length(), 1);
        let e = &events[0];
        assert_eq!(policy_ensemble::registered_escrow_identity(e), escrow_identity::escrow_id(ei));
        assert_eq!(policy_ensemble::registered_rest_price_mist(e),          V2_MIN_RENT_PRICE);
        assert_eq!(policy_ensemble::registered_tenure_duration_ms(e),       V2_TENURE_CEILING);
        assert_eq!(policy_ensemble::registered_handover_policy(e),          b"Fixed".to_string());
        assert_eq!(policy_ensemble::registered_handover_floor_ms(e),        option::some(V2_HANDOVER_FLOOR));
        assert_eq!(policy_ensemble::registered_auction_window_policy(e),    b"Fixed".to_string());
        assert_eq!(policy_ensemble::registered_auction_window_ceiling_ms(e),option::some(V2_DESCENT_CEILING));
        assert_eq!(policy_ensemble::registered_credit_shape_policy(e),      b"Linear".to_string());
        assert_eq!(policy_ensemble::registered_credit_alpha_num(e),         option::none());
    };
    scenario.end();
}

// E2: PowerLaw gcd-normalized curves are stored in reduced form inside the event.
//     new_power_law(2,4) → GCD=2 → alpha_num=1, alpha_den=2.
//     new_power_law(6,3) → GCD=3 → alpha_num=2, alpha_den=1.
#[test]
fun emit_registration_e2_power_law_gcd_normalized_in_payload() {
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_duration_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_extend_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_power_law(2, 4),
        curve_shape_policy::new_power_law(6, 3),
        price_escalation_policy::new_fixed_delta(monetary::price(1)),
    );
    let ei = escrow_identity::new(object::id_from_address(@0xE5C1));
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&ensemble, ei, phases::timestamp(0));
        let events = event::events_by_type<PolicyEnsembleRegistered>();
        let e = &events[0];
        assert_eq!(policy_ensemble::registered_credit_alpha_num(e), option::some(1u8));
        assert_eq!(policy_ensemble::registered_credit_alpha_den(e), option::some(2u8));
        assert_eq!(policy_ensemble::registered_auction_alpha_num(e), option::some(2u8));
        assert_eq!(policy_ensemble::registered_auction_alpha_den(e), option::some(1u8));
    };
    scenario.end();
}

// E3: emit_registration is not idempotent at the event-count level.
//     Calling it twice in the same tx yields two identical events.
//     The single-emit contract is a caller contract (rental_escrow::integrate),
//     not a module-side guard.
#[test]
fun emit_registration_e3_not_idempotent_caller_contract() {
    let ensemble = v2_config();
    let ei       = escrow_identity::new(object::id_from_address(@0xE5C1));
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&ensemble, ei, phases::timestamp(0));
        policy_ensemble::emit_registration(&ensemble, ei, phases::timestamp(0));
        let events = event::events_by_type<PolicyEnsembleRegistered>();
        assert_eq!(events.length(), 2);
        assert_eq!(policy_ensemble::registered_rest_price_mist(&events[0]),    policy_ensemble::registered_rest_price_mist(&events[1]));
        assert_eq!(policy_ensemble::registered_escrow_identity(&events[0]),    policy_ensemble::registered_escrow_identity(&events[1]));
        assert_eq!(policy_ensemble::registered_auction_window_policy(&events[0]), policy_ensemble::registered_auction_window_policy(&events[1]));
    };
    scenario.end();
}

// ─── §7.5 — Full 23-field payload pin: all three emitters ─────────────────────
//
// Fixture: credit=PowerLaw(3,2), auction=Exponential(5,true), CompoundDelta, Multi.
// This combination makes every optional field take a distinct Some/None value so
// a transposition between any two fields (num↔den, credit↔auction, abs↔neg,
// bps↔delta) produces a distinguishable wrong value.

const MX_REST_PRICE:  u64 = 5_000_000;
const MX_TENURE_MS:   u64 = 48_000_000;
const MX_HANDOVER_MS: u64 = 2_000_000;
const MX_WINDOW_MS:   u64 = 12_000_000;
const MX_ESCAL_DELTA: u64 = 200;
const MX_ESCAL_BPS:   u64 = 750;

fun mixed_config(): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(MX_REST_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(MX_TENURE_MS)),
        tenure_extend_policy::new_multi(),
        handover_policy::new_handover_fixed(phases::duration(MX_HANDOVER_MS)),
        auction_window_policy::new_descent_fixed(phases::duration(MX_WINDOW_MS)),
        curve_shape_policy::new_power_law(3, 2),
        curve_shape_policy::new_exponential(5, true),
        price_escalation_policy::new_compound_delta(math::bps(MX_ESCAL_BPS), monetary::price(MX_ESCAL_DELTA)),
    )
}

// E4: emit_registration — full 23-field pin with mixed variants.
#[test]
fun emit_registration_e4_full_payload_mixed_variants() {
    let ensemble = mixed_config();
    let ei       = escrow_identity::new(object::id_from_address(@0xEC01));
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&ensemble, ei, phases::timestamp(12_345));
        let events = event::events_by_type<PolicyEnsembleRegistered>();
        assert_eq!(events.length(), 1);
        let e = &events[0];
        assert_eq!(policy_ensemble::registered_escrow_identity(e),             escrow_identity::escrow_id(ei));
        assert_eq!(policy_ensemble::registered_timestamp_ms(e),               12_345);
        assert_eq!(policy_ensemble::registered_rest_price_policy(e),           b"Fixed".to_string());
        assert_eq!(policy_ensemble::registered_rest_price_mist(e),             MX_REST_PRICE);
        assert_eq!(policy_ensemble::registered_tenure_duration_policy(e),      b"Fixed".to_string());
        assert_eq!(policy_ensemble::registered_tenure_duration_ms(e),          MX_TENURE_MS);
        assert_eq!(policy_ensemble::registered_tenure_extend_policy(e),        b"Multi".to_string());
        assert_eq!(policy_ensemble::registered_handover_policy(e),             b"Fixed".to_string());
        assert_eq!(policy_ensemble::registered_handover_floor_ms(e),           option::some(MX_HANDOVER_MS));
        assert_eq!(policy_ensemble::registered_auction_window_policy(e),       b"Fixed".to_string());
        assert_eq!(policy_ensemble::registered_auction_window_ceiling_ms(e),   option::some(MX_WINDOW_MS));
        assert_eq!(policy_ensemble::registered_credit_shape_policy(e),         b"PowerLaw".to_string());
        assert_eq!(policy_ensemble::registered_credit_alpha_num(e),            option::some(3u8));
        assert_eq!(policy_ensemble::registered_credit_alpha_den(e),            option::some(2u8));
        assert_eq!(policy_ensemble::registered_credit_alpha_abs(e),            option::none());
        assert_eq!(policy_ensemble::registered_credit_alpha_neg(e),            option::none());
        assert_eq!(policy_ensemble::registered_auction_shape_policy(e),        b"Exponential".to_string());
        assert_eq!(policy_ensemble::registered_auction_alpha_num(e),           option::none());
        assert_eq!(policy_ensemble::registered_auction_alpha_den(e),           option::none());
        assert_eq!(policy_ensemble::registered_auction_alpha_abs(e),           option::some(5u8));
        assert_eq!(policy_ensemble::registered_auction_alpha_neg(e),           option::some(true));
        assert_eq!(policy_ensemble::registered_price_escalation_policy(e),     b"CompoundDelta".to_string());
        assert_eq!(policy_ensemble::registered_price_escalation_delta(e),      MX_ESCAL_DELTA);
        assert_eq!(policy_ensemble::registered_price_escalation_bps(e),        option::some(MX_ESCAL_BPS));
    };
    scenario.end();
}

// EU1: emit_ensemble_updated — full 23-field pin with mixed variants.
#[test]
fun emit_ensemble_updated_eu1_full_payload_mixed_variants() {
    let ensemble  = mixed_config();
    let ei        = escrow_identity::new(object::id_from_address(@0xEC02));
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_ensemble_updated(&ensemble, ei, phases::timestamp(23_456));
        let events = event::events_by_type<EnsembleUpdated>();
        assert_eq!(events.length(), 1);
        let e = &events[0];
        assert_eq!(policy_ensemble::ensemble_updated_escrow_id(e),                  escrow_identity::escrow_id(ei));
        assert_eq!(policy_ensemble::ensemble_updated_timestamp_ms(e),               23_456);
        assert_eq!(policy_ensemble::ensemble_updated_rest_price_policy(e),           b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_rest_price_mist(e),             MX_REST_PRICE);
        assert_eq!(policy_ensemble::ensemble_updated_tenure_duration_policy(e),      b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_tenure_duration_ms(e),          MX_TENURE_MS);
        assert_eq!(policy_ensemble::ensemble_updated_tenure_extend_policy(e),        b"Multi".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_handover_policy(e),             b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_handover_floor_ms(e),           option::some(MX_HANDOVER_MS));
        assert_eq!(policy_ensemble::ensemble_updated_auction_window_policy(e),       b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_auction_window_ceiling_ms(e),   option::some(MX_WINDOW_MS));
        assert_eq!(policy_ensemble::ensemble_updated_credit_shape_policy(e),         b"PowerLaw".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_credit_alpha_num(e),            option::some(3u8));
        assert_eq!(policy_ensemble::ensemble_updated_credit_alpha_den(e),            option::some(2u8));
        assert_eq!(policy_ensemble::ensemble_updated_credit_alpha_abs(e),            option::none());
        assert_eq!(policy_ensemble::ensemble_updated_credit_alpha_neg(e),            option::none());
        assert_eq!(policy_ensemble::ensemble_updated_auction_shape_policy(e),        b"Exponential".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_auction_alpha_num(e),           option::none());
        assert_eq!(policy_ensemble::ensemble_updated_auction_alpha_den(e),           option::none());
        assert_eq!(policy_ensemble::ensemble_updated_auction_alpha_abs(e),           option::some(5u8));
        assert_eq!(policy_ensemble::ensemble_updated_auction_alpha_neg(e),           option::some(true));
        assert_eq!(policy_ensemble::ensemble_updated_price_escalation_policy(e),     b"CompoundDelta".to_string());
        assert_eq!(policy_ensemble::ensemble_updated_price_escalation_delta(e),      MX_ESCAL_DELTA);
        assert_eq!(policy_ensemble::ensemble_updated_price_escalation_bps(e),        option::some(MX_ESCAL_BPS));
    };
    scenario.end();
}

// EUS1: emit_ensemble_update_scheduled — full 23-field pin with mixed variants.
#[test]
fun emit_ensemble_update_scheduled_eus1_full_payload_mixed_variants() {
    let ensemble  = mixed_config();
    let ei        = escrow_identity::new(object::id_from_address(@0xEC03));
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_ensemble_update_scheduled(&ensemble, ei, phases::timestamp(34_567));
        let events = event::events_by_type<EnsembleUpdateScheduled>();
        assert_eq!(events.length(), 1);
        let e = &events[0];
        assert_eq!(policy_ensemble::ensemble_update_scheduled_escrow_id(e),                  escrow_identity::escrow_id(ei));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_timestamp_ms(e),               34_567);
        assert_eq!(policy_ensemble::ensemble_update_scheduled_rest_price_policy(e),           b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_rest_price_mist(e),             MX_REST_PRICE);
        assert_eq!(policy_ensemble::ensemble_update_scheduled_tenure_duration_policy(e),      b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_tenure_duration_ms(e),          MX_TENURE_MS);
        assert_eq!(policy_ensemble::ensemble_update_scheduled_tenure_extend_policy(e),        b"Multi".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_handover_policy(e),             b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_handover_floor_ms(e),           option::some(MX_HANDOVER_MS));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_window_policy(e),       b"Fixed".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_window_ceiling_ms(e),   option::some(MX_WINDOW_MS));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_credit_shape_policy(e),         b"PowerLaw".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_credit_alpha_num(e),            option::some(3u8));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_credit_alpha_den(e),            option::some(2u8));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_credit_alpha_abs(e),            option::none());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_credit_alpha_neg(e),            option::none());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_shape_policy(e),        b"Exponential".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_alpha_num(e),           option::none());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_alpha_den(e),           option::none());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_alpha_abs(e),           option::some(5u8));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_auction_alpha_neg(e),           option::some(true));
        assert_eq!(policy_ensemble::ensemble_update_scheduled_price_escalation_policy(e),     b"CompoundDelta".to_string());
        assert_eq!(policy_ensemble::ensemble_update_scheduled_price_escalation_delta(e),      MX_ESCAL_DELTA);
        assert_eq!(policy_ensemble::ensemble_update_scheduled_price_escalation_bps(e),        option::some(MX_ESCAL_BPS));
    };
    scenario.end();
}
