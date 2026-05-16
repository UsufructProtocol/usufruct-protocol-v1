// Copyright (c) 2026 Antonio Jiménez
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
    },
    curve_shape_policy,
    descent_policy::{Self, DescentPolicy},
    handover_policy::{Self, HandoverPolicy},
    math,
    floor_price_policy,
    tenure_cycles_policy,
    tenure_policy::{Self, TenurePolicy},
    monetary,
    phases,
    price_function_policy,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

// Canonical V2 config values (used as baseline for single-field variation rows).
const V2_MIN_RENT_PRICE:  u64 = 1_000_000;
const V2_TENURE_CEILING:  u64 = 86_400_000;
const V2_HANDOVER_FLOOR:  u64 = 3_600_000;       // → Countdown
const V2_DESCENT_CEILING: u64 = 43_200_000;      // → Window

fun v2_handover(): HandoverPolicy { handover_policy::new_handover_countdown(phases::duration(V2_HANDOVER_FLOOR)) }
fun v2_descent():  DescentPolicy  { descent_policy::new_descent_window(phases::duration(V2_DESCENT_CEILING)) }

fun v2_config(): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)),
        tenure_cycles_policy::new_single(),
        v2_handover(),
        v2_descent(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    )
}

// ─── §7.1 + §7.3 — Valid inputs + getter round-trip ───────────────────────────

// Case struct for the parametric loop. All twelve V-rows are encoded here.
// The loop both constructs the config and verifies each getter (§7.3 P5
// predicate). Policy fields are stored as the enum variants directly so the
// round-trip assertion compares structurally typed values, not raw u64s.
public struct Case has drop {
    min_rent_price: u64,
    tenure_ceiling: TenurePolicy,
    handover:       HandoverPolicy,
    descent:        DescentPolicy,
    credit_curve:   curve_shape_policy::CurveShapePolicy,
    descent_curve:  curve_shape_policy::CurveShapePolicy,
    price_function_policy: price_function_policy::PriceFunctionPolicy,
}

#[test]
fun new_config_valid_inputs_and_getter_roundtrip() {
    let cases = vector[
        // V1 — minimal valid; HandoverPolicy::Instant
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(1)),
            handover:       handover_policy::new_handover_instant(),
            descent:        descent_policy::new_descent_window(phases::duration(1)),
            credit_curve:   curve_shape_policy::new_linear(),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V2 — typical: 1h handover countdown in 24h tenure, 12h auction window
        Case {
            min_rent_price: 1_000_000,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(86_400_000)),
            handover:       handover_policy::new_handover_countdown(phases::duration(3_600_000)),
            descent:        descent_policy::new_descent_window(phases::duration(43_200_000)),
            credit_curve:   curve_shape_policy::new_linear(),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V3 — Smoothstep curves
        Case {
            min_rent_price: 100,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(10_000)),
            handover:       handover_policy::new_handover_countdown(phases::duration(5_000)),
            descent:        descent_policy::new_descent_window(phases::duration(10_000)),
            credit_curve:   curve_shape_policy::new_smoothstep(),
            descent_curve:  curve_shape_policy::new_smoothstep(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(10)),
        },
        // V4 — Instant handover (no bidding window); PowerLaw credit
        Case {
            min_rent_price: 50,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(100_000)),
            handover:       handover_policy::new_handover_instant(),
            descent:        descent_policy::new_descent_window(phases::duration(50_000)),
            credit_curve:   curve_shape_policy::new_power_law(1, 2),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V5 — u64::MAX min_rent_price; mixed Exp curves
        Case {
            min_rent_price: 18_446_744_073_709_551_615,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_countdown(phases::duration(500)),
            descent:        descent_policy::new_descent_window(phases::duration(1_000)),
            credit_curve:   curve_shape_policy::new_exponential(3, false),
            descent_curve:  curve_shape_policy::new_exponential(3, true),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V6 — no upper bound on time params; Window(u64::MAX)
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(18_446_744_073_709_551_615)),
            handover:       handover_policy::new_handover_countdown(phases::duration(1)),
            descent:        descent_policy::new_descent_window(phases::duration(18_446_744_073_709_551_615)),
            credit_curve:   curve_shape_policy::new_logistic(),
            descent_curve:  curve_shape_policy::new_logistic(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V7 — CompoundDelta price function: 5% + 100 base units per cycle
        Case {
            min_rent_price: 1_000,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(86_400_000)),
            handover:       handover_policy::new_handover_countdown(phases::duration(3_600_000)),
            descent:        descent_policy::new_descent_window(phases::duration(43_200_000)),
            credit_curve:   curve_shape_policy::new_linear(),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_compound_delta(math::bps(500), monetary::price(100)),
        },
        // V8 — HandoverPolicy::FixedTime
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_fixed_time(),
            descent:        descent_policy::new_descent_window(phases::duration(1)),
            credit_curve:   curve_shape_policy::new_linear(),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V9 — FixedTime at u64-extreme tenure_ceiling (independent of magnitude)
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(18_446_744_073_709_551_615)),
            handover:       handover_policy::new_handover_fixed_time(),
            descent:        descent_policy::new_descent_window(phases::duration(1)),
            credit_curve:   curve_shape_policy::new_linear(),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V10 — PowerLaw inputs requiring gcd normalization
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_instant(),
            descent:        descent_policy::new_descent_window(phases::duration(1)),
            credit_curve:   curve_shape_policy::new_power_law(2, 4),
            descent_curve:  curve_shape_policy::new_power_law(6, 3),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
        // V11 — extreme α values (min convex, max concave) + minimum CompoundDelta
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_countdown(phases::duration(500)),
            descent:        descent_policy::new_descent_window(phases::duration(1)),
            credit_curve:   curve_shape_policy::new_exponential(1, false),
            descent_curve:  curve_shape_policy::new_exponential(8, true),
            price_function_policy: price_function_policy::new_compound_delta(math::bps(1), monetary::price(1)),
        },
        // V12 — DescentPolicy::Skipped ("AtDutchAuction unobservable" mode, M6b)
        Case {
            min_rent_price: 1,
            tenure_ceiling: tenure_policy::new_fixed(phases::duration(1_000)),
            handover:       handover_policy::new_handover_instant(),
            descent:        descent_policy::new_descent_skipped(),
            credit_curve:   curve_shape_policy::new_linear(),
            descent_curve:  curve_shape_policy::new_linear(),
            price_function_policy: price_function_policy::new_fixed_delta(monetary::price(1)),
        },
    ];

    cases.do_ref!(|c| {
        let cfg = policy_ensemble::new_ensemble(
            floor_price_policy::new_fixed(monetary::price(c.min_rent_price)),
            c.tenure_ceiling,
            tenure_cycles_policy::new_single(),
            c.handover,
            c.descent,
            c.credit_curve,
            c.descent_curve,
            c.price_function_policy,
        );
        // §7.3 P5 predicate: getter(new_config(..., f, ...)) == f for each field
        assert_eq!(monetary::price_mist(floor_price_policy::floor_for_view(policy_ensemble::proj_min_rent_price(&cfg))),  c.min_rent_price);
        assert_eq!(*policy_ensemble::proj_tenure_ceiling(&cfg),  c.tenure_ceiling);
        assert_eq!(*policy_ensemble::proj_handover(&cfg),        c.handover);
        assert_eq!(*policy_ensemble::proj_descent(&cfg),         c.descent);
        assert_eq!(*policy_ensemble::proj_credit_curve(&cfg),    c.credit_curve);
        assert_eq!(*policy_ensemble::proj_descent_curve(&cfg),   c.descent_curve);
        assert_eq!(*policy_ensemble::proj_price_function_policy(&cfg), c.price_function_policy);
    });
}

// ─── §7.3 Explicit field pins (R1–R8) ─────────────────────────────────────────

// Each row holds all other fields at V2 canonical values; only the named field varies.

#[test]
fun getter_roundtrip_r1_min_rent_price_max() {
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(18_446_744_073_709_551_615)),
        tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(monetary::price_mist(floor_price_policy::floor_for_view(policy_ensemble::proj_min_rent_price(&cfg))), 18_446_744_073_709_551_615);
}

#[test]
fun getter_roundtrip_r2_tenure_ceiling_typical_ms() {
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(86_400_000)),
        tenure_cycles_policy::new_single(),
        v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(tenure_policy::proj_is_fixed(policy_ensemble::proj_tenure_ceiling(&cfg)), true);
    assert_eq!(phases::duration_ms(*option::borrow(&tenure_policy::proj_fixed_ceiling(policy_ensemble::proj_tenure_ceiling(&cfg)))), 86_400_000);
}

#[test]
fun getter_roundtrip_r3_handover_instant() {
    let h   = handover_policy::new_handover_instant();
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)),
        tenure_cycles_policy::new_single(),
        h,
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_handover(&cfg), h);
}

#[test]
fun getter_roundtrip_r3b_handover_fixed_time() {
    // Companion to R3 covering the upper-saturation variant.
    let h   = handover_policy::new_handover_fixed_time();
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)),
        tenure_cycles_policy::new_single(),
        h,
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_handover(&cfg), h);
}

#[test]
fun getter_roundtrip_r4_descent_window_one() {
    let d   = descent_policy::new_descent_window(phases::duration(1));
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(),
        d,
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_descent(&cfg), d);
}

#[test]
fun getter_roundtrip_r4b_descent_skipped() {
    // Companion to R4 covering the auction-skipped variant.
    let d   = descent_policy::new_descent_skipped();
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(),
        d,
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_descent(&cfg), d);
}

#[test]
fun getter_roundtrip_r5_credit_curve_power_law_gcd_normalized() {
    // new_power_law(2,4) normalizes to stored PowerLaw{1,2}.
    // Getter returns the reduced form — normalization is upstream in curve_shape_state.
    let raw = curve_shape_policy::new_power_law(2, 4);
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(), v2_descent(),
        raw,
        curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_credit_curve(&cfg), raw);
}

#[test]
fun getter_roundtrip_r6_descent_curve_logistic() {
    let g = curve_shape_policy::new_logistic();
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(),
        g,
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    assert_eq!(*policy_ensemble::proj_descent_curve(&cfg), g);
}

#[test]
fun getter_roundtrip_r7_price_function_state_compound_delta() {
    let pf = price_function_policy::new_compound_delta(math::bps(500), monetary::price(100));
    let cfg = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        pf,
    );
    assert_eq!(*policy_ensemble::proj_price_function_policy(&cfg), pf);
}

// ─── §7.2 — Invalid inputs (one function each) ────────────────────────────────

#[test, expected_failure(abort_code = floor_price_policy::EPriceZero, location = usufruct::floor_price_policy)]
fun new_config_rejects_min_rent_price_zero() {
    // Validation moved to FloorPricePolicy constructor; new_fixed(0) aborts before new_config.
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(0)),
        tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = 0, location = usufruct::tenure_policy)]
fun new_config_rejects_tenure_ceiling_zero() {
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(0)),
        tenure_cycles_policy::new_single(),
        v2_handover(), v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_gt_tenure_ceiling() {
    // I3: Countdown(100) with tenure_ceiling=50
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(50)),
        tenure_cycles_policy::new_single(),
        handover_policy::new_handover_countdown(phases::duration(100)),
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_tenure_ceiling_plus_one() {
    // I4: smallest strictly-greater case — guards off-by-one on the < check
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(1_000)),
        tenure_cycles_policy::new_single(),
        handover_policy::new_handover_countdown(phases::duration(1_001)),
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_u64_max_tenure_ceiling_max_minus_one() {
    // I5: u64-saturated boundary; confirms plain unsigned compare (no arithmetic overflow)
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(18_446_744_073_709_551_614)), // u64::MAX - 1
        tenure_cycles_policy::new_single(),
        handover_policy::new_handover_countdown(phases::duration(18_446_744_073_709_551_615)), // u64::MAX
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
}

#[test, expected_failure(abort_code = policy_ensemble::EHandoverFloorExceedsTenure, location = usufruct::policy_ensemble)]
fun new_config_rejects_countdown_floor_eq_tenure_ceiling() {
    // I6: equality with tenure_ceiling is FixedTime, not the upper edge of Countdown.
    // Constructor accepts Countdown(1_000) but new_config rejects when paired with
    // tenure_ceiling=1_000 — caller must use new_handover_fixed_time() instead.
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)),
        tenure_policy::new_fixed(phases::duration(1_000)),
        tenure_cycles_policy::new_single(),
        handover_policy::new_handover_countdown(phases::duration(1_000)),
        v2_descent(),
        curve_shape_policy::new_linear(), curve_shape_policy::new_linear(),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
}

// ─── §7.4 — emit_registration event tests ─────────────────────────────────────

// E1: full config snapshot is captured in the event; escrow_id matches.
#[test]
fun emit_registration_e1_full_snapshot() {
    let cfg        = v2_config();
    let escrow_id  = object::id_from_address(@0xE5C1);
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&cfg, escrow_id);
        let events = event::events_by_type<PolicyEnsembleRegistered>();
        assert_eq!(events.length(), 1);
        assert_eq!(policy_ensemble::registered_escrow_id(&events[0]), escrow_id);
        assert_eq!(policy_ensemble::registered_ensemble(&events[0]),    cfg);
    };
    scenario.end();
}

// E2: PowerLaw gcd-normalized curves are stored in reduced form inside the event.
#[test]
fun emit_registration_e2_power_law_gcd_normalized_in_payload() {
    // new_power_law(2,4) → stored PowerLaw{1,2}; getter returns the reduced form.
    let cfg       = policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(V2_MIN_RENT_PRICE)), tenure_policy::new_fixed(phases::duration(V2_TENURE_CEILING)), tenure_cycles_policy::new_single(), v2_handover(), v2_descent(),
        curve_shape_policy::new_power_law(2, 4),
        curve_shape_policy::new_power_law(6, 3),
        price_function_policy::new_fixed_delta(monetary::price(1)),
    );
    let escrow_id = object::id_from_address(@0xE5C1);
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&cfg, escrow_id);
        let events  = event::events_by_type<PolicyEnsembleRegistered>();
        let payload = policy_ensemble::registered_ensemble(&events[0]);
        // stored values are the reduced (gcd-normalized) forms
        assert_eq!(*policy_ensemble::proj_credit_curve(&payload),  curve_shape_policy::new_power_law(2, 4));
        assert_eq!(*policy_ensemble::proj_descent_curve(&payload), curve_shape_policy::new_power_law(6, 3));
    };
    scenario.end();
}

// E3: emit_registration is not idempotent at the event-count level.
//     Calling it twice in the same tx yields two identical events.
//     The single-emit contract is a caller contract (rental_escrow::integrate),
//     not a module-side guard.
#[test]
fun emit_registration_e3_not_idempotent_caller_contract() {
    let cfg        = v2_config();
    let escrow_id  = object::id_from_address(@0xE5C1);
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        policy_ensemble::emit_registration(&cfg, escrow_id);
        policy_ensemble::emit_registration(&cfg, escrow_id);
        let events = event::events_by_type<PolicyEnsembleRegistered>();
        assert_eq!(events.length(), 2);
        assert_eq!(policy_ensemble::registered_ensemble(&events[0]), policy_ensemble::registered_ensemble(&events[1]));
        assert_eq!(policy_ensemble::registered_escrow_id(&events[0]), policy_ensemble::registered_escrow_id(&events[1]));
    };
    scenario.end();
}
