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
    config::{
        Self,
        IntegrationConfig,
        IntegrationConfigRegistered,
    },
    curve_shape_state,
    descent_policy_state::{Self, DescentPolicyState},
    handover_policy_state::{Self, HandoverPolicyState},
    phases,
    price_function_state,
    retire_policy_state::{Self, RetirePolicyState},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

// Canonical V2 config values (used as baseline for single-field variation rows).
const V2_MIN_RENT_PRICE:  u64 = 1_000_000;
const V2_TENURE_CEILING:  u64 = 86_400_000;
const V2_HANDOVER_FLOOR:  u64 = 3_600_000;       // → Countdown
const V2_DESCENT_CEILING: u64 = 43_200_000;      // → Window
// V2_RETIRE_FLOOR == 0 (Immediate) inlined below where used.

fun v2_handover(): HandoverPolicyState { handover_policy_state::new_handover_countdown(V2_HANDOVER_FLOOR) }
fun v2_descent():  DescentPolicyState  { descent_policy_state::new_descent_window(V2_DESCENT_CEILING) }
fun v2_retire():   RetirePolicyState   { retire_policy_state::new_retire_immediate() }

fun v2_config(): IntegrationConfig {
    config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(V2_TENURE_CEILING),
        v2_handover(),
        v2_descent(),
        v2_retire(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    )
}

// ─── §7.1 + §7.3 — Valid inputs + getter round-trip ───────────────────────────

// Case struct for the parametric loop. All twelve V-rows are encoded here.
// The loop both constructs the config and verifies each getter (§7.3 P5
// predicate). Policy fields are stored as the enum variants directly so the
// round-trip assertion compares structurally typed values, not raw u64s.
public struct Case has drop {
    min_rent_price: u64,
    tenure_ceiling: u64,
    handover:       HandoverPolicyState,
    descent:        DescentPolicyState,
    retire:         RetirePolicyState,
    credit_curve:   curve_shape_state::CurveShapeState,
    descent_curve:  curve_shape_state::CurveShapeState,
    price_function_state: price_function_state::PriceFunctionState,
}

#[test]
fun new_config_valid_inputs_and_getter_roundtrip() {
    let cases = vector[
        // V1 — minimal valid; HandoverPolicyState::Instant
        Case {
            min_rent_price: 1,
            tenure_ceiling: 1,
            handover:       handover_policy_state::new_handover_instant(),
            descent:        descent_policy_state::new_descent_window(1),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_linear(),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V2 — typical: 1h handover countdown in 24h tenure, 12h auction window
        Case {
            min_rent_price: 1_000_000,
            tenure_ceiling: 86_400_000,
            handover:       handover_policy_state::new_handover_countdown(3_600_000),
            descent:        descent_policy_state::new_descent_window(43_200_000),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_linear(),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V3 — Deferred(2h) retire policy; Smoothstep curves
        Case {
            min_rent_price: 100,
            tenure_ceiling: 10_000,
            handover:       handover_policy_state::new_handover_countdown(5_000),
            descent:        descent_policy_state::new_descent_window(10_000),
            retire:         retire_policy_state::new_retire_deferred(7_200_000),
            credit_curve:   curve_shape_state::new_smoothstep(),
            descent_curve:  curve_shape_state::new_smoothstep(),
            price_function_state: price_function_state::new_fixed_delta(10),
        },
        // V4 — Instant handover (no bidding window); PowerLaw credit
        Case {
            min_rent_price: 50,
            tenure_ceiling: 100_000,
            handover:       handover_policy_state::new_handover_instant(),
            descent:        descent_policy_state::new_descent_window(50_000),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_power_law(1, 2),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V5 — u64::MAX min_rent_price; mixed Exp curves
        Case {
            min_rent_price: 18_446_744_073_709_551_615,
            tenure_ceiling: 1_000,
            handover:       handover_policy_state::new_handover_countdown(500),
            descent:        descent_policy_state::new_descent_window(1_000),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_exponential(3, false),
            descent_curve:  curve_shape_state::new_exponential(3, true),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V6 — no upper bound on time params; Deferred(u64::MAX); Window(u64::MAX)
        Case {
            min_rent_price: 1,
            tenure_ceiling: 18_446_744_073_709_551_615,
            handover:       handover_policy_state::new_handover_countdown(1),
            descent:        descent_policy_state::new_descent_window(18_446_744_073_709_551_615),
            retire:         retire_policy_state::new_retire_deferred(18_446_744_073_709_551_615),
            credit_curve:   curve_shape_state::new_logistic(),
            descent_curve:  curve_shape_state::new_logistic(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V7 — CompoundDelta price function: 5% + 100 base units per cycle
        Case {
            min_rent_price: 1_000,
            tenure_ceiling: 86_400_000,
            handover:       handover_policy_state::new_handover_countdown(3_600_000),
            descent:        descent_policy_state::new_descent_window(43_200_000),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_linear(),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_compound_delta(500, 100),
        },
        // V8 — HandoverPolicyState::FixedTime (was: handover_floor == tenure_ceiling
        //      under the u64 representation; now its own variant)
        Case {
            min_rent_price: 1,
            tenure_ceiling: 1_000,
            handover:       handover_policy_state::new_handover_fixed_time(),
            descent:        descent_policy_state::new_descent_window(1),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_linear(),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V9 — FixedTime at u64-extreme tenure_ceiling (independent of magnitude)
        Case {
            min_rent_price: 1,
            tenure_ceiling: 18_446_744_073_709_551_615,
            handover:       handover_policy_state::new_handover_fixed_time(),
            descent:        descent_policy_state::new_descent_window(1),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_linear(),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V10 — PowerLaw inputs requiring gcd normalization
        //        credit_curve: new_power_law(2,4) → stored as PowerLaw{1,2}
        //        descent_curve: new_power_law(6,3) → stored as PowerLaw{2,1}
        Case {
            min_rent_price: 1,
            tenure_ceiling: 1_000,
            handover:       handover_policy_state::new_handover_instant(),
            descent:        descent_policy_state::new_descent_window(1),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_power_law(2, 4),
            descent_curve:  curve_shape_state::new_power_law(6, 3),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
        // V11 — extreme α values (min convex, max concave) + minimum CompoundDelta
        Case {
            min_rent_price: 1,
            tenure_ceiling: 1_000,
            handover:       handover_policy_state::new_handover_countdown(500),
            descent:        descent_policy_state::new_descent_window(1),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_exponential(1, false),
            descent_curve:  curve_shape_state::new_exponential(8, true),
            price_function_state: price_function_state::new_compound_delta(1, 1),
        },
        // V12 — DescentPolicyState::Skipped ("AtDutchAuction unobservable" mode, M6b)
        Case {
            min_rent_price: 1,
            tenure_ceiling: 1_000,
            handover:       handover_policy_state::new_handover_instant(),
            descent:        descent_policy_state::new_descent_skipped(),
            retire:         retire_policy_state::new_retire_immediate(),
            credit_curve:   curve_shape_state::new_linear(),
            descent_curve:  curve_shape_state::new_linear(),
            price_function_state: price_function_state::new_fixed_delta(1),
        },
    ];

    let mut i = 0;
    while (i < cases.length()) {
        let c = &cases[i];
        let cfg = config::new_config(
            c.min_rent_price,
            phases::duration(c.tenure_ceiling),
            c.handover,
            c.descent,
            c.retire,
            c.credit_curve,
            c.descent_curve,
            c.price_function_state,
        );
        // §7.3 P5 predicate: getter(new_config(..., f, ...)) == f for each field
        assert_eq!(config::proj_min_rent_price(&cfg),  c.min_rent_price);
        assert_eq!(phases::duration_ms(config::proj_tenure_ceiling(&cfg)),  c.tenure_ceiling);
        assert_eq!(*config::proj_handover(&cfg),       c.handover);
        assert_eq!(*config::proj_descent(&cfg),        c.descent);
        assert_eq!(*config::proj_retire(&cfg),         c.retire);
        assert_eq!(*config::proj_credit_curve(&cfg),   c.credit_curve);
        assert_eq!(*config::proj_descent_curve(&cfg),  c.descent_curve);
        assert_eq!(*config::proj_price_function_state(&cfg), c.price_function_state);
        i = i + 1;
    };
}

// ─── §7.3 Explicit field pins (R1–R8) ─────────────────────────────────────────

// Each row holds all other fields at V2 canonical values; only the named field varies.

#[test]
fun getter_roundtrip_r1_min_rent_price_max() {
    let cfg = config::new_config(
        18_446_744_073_709_551_615,
        phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(config::proj_min_rent_price(&cfg), 18_446_744_073_709_551_615);
}

#[test]
fun getter_roundtrip_r2_tenure_ceiling_typical_ms() {
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(86_400_000),
        v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(phases::duration_ms(config::proj_tenure_ceiling(&cfg)), 86_400_000);
}

#[test]
fun getter_roundtrip_r3_handover_instant() {
    let h   = handover_policy_state::new_handover_instant();
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING),
        h,
        v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_handover(&cfg), h);
}

#[test]
fun getter_roundtrip_r3b_handover_fixed_time() {
    // Companion to R3 covering the upper-saturation variant.
    let h   = handover_policy_state::new_handover_fixed_time();
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING),
        h,
        v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_handover(&cfg), h);
}

#[test]
fun getter_roundtrip_r4_descent_window_one() {
    let d   = descent_policy_state::new_descent_window(1);
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(),
        d,
        v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_descent(&cfg), d);
}

#[test]
fun getter_roundtrip_r4b_descent_skipped() {
    // Companion to R4 covering the auction-skipped variant.
    let d   = descent_policy_state::new_descent_skipped();
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(),
        d,
        v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_descent(&cfg), d);
}

#[test]
fun getter_roundtrip_r5_retire_deferred_max() {
    let r   = retire_policy_state::new_retire_deferred(18_446_744_073_709_551_615);
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(),
        r,
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_retire(&cfg), r);
}

#[test]
fun getter_roundtrip_r6_credit_curve_power_law_gcd_normalized() {
    // new_power_law(2,4) normalizes to stored PowerLaw{1,2}.
    // Getter returns the reduced form — normalization is upstream in curve_shape_state.
    let raw = curve_shape_state::new_power_law(2, 4);
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(), v2_retire(),
        raw,
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_credit_curve(&cfg), raw);
}

#[test]
fun getter_roundtrip_r7_descent_curve_logistic() {
    let g = curve_shape_state::new_logistic();
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_linear(),
        g,
        price_function_state::new_fixed_delta(1),
    );
    assert_eq!(*config::proj_descent_curve(&cfg), g);
}

#[test]
fun getter_roundtrip_r8_price_function_state_compound_delta() {
    let pf = price_function_state::new_compound_delta(500, 100);
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        pf,
    );
    assert_eq!(*config::proj_price_function_state(&cfg), pf);
}

// ─── §7.2 — Invalid inputs (one function each) ────────────────────────────────

#[test]
#[expected_failure(abort_code = config::EMinRentPriceZero, location = usufruct::config)]
fun new_config_rejects_min_rent_price_zero() {
    config::new_config(
        0,
        phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::ETenureCeilingZero, location = usufruct::config)]
fun new_config_rejects_tenure_ceiling_zero() {
    config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(0),
        v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_countdown_floor_gt_tenure_ceiling() {
    // I3: Countdown(100) with tenure_ceiling=50
    config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(50),
        handover_policy_state::new_handover_countdown(100),
        v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_countdown_floor_tenure_ceiling_plus_one() {
    // I4: smallest strictly-greater case — guards off-by-one on the < check
    config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(1_000),
        handover_policy_state::new_handover_countdown(1_001),
        v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_countdown_floor_u64_max_tenure_ceiling_max_minus_one() {
    // I5: u64-saturated boundary; confirms plain unsigned compare (no arithmetic overflow)
    config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(18_446_744_073_709_551_614), // u64::MAX - 1
        handover_policy_state::new_handover_countdown(18_446_744_073_709_551_615), // u64::MAX
        v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_countdown_floor_eq_tenure_ceiling() {
    // I6: equality with tenure_ceiling is FixedTime, not the upper edge of Countdown.
    // Constructor accepts Countdown(1_000) but new_config rejects when paired with
    // tenure_ceiling=1_000 — caller must use new_handover_fixed_time() instead.
    config::new_config(
        V2_MIN_RENT_PRICE,
        phases::duration(1_000),
        handover_policy_state::new_handover_countdown(1_000),
        v2_descent(), v2_retire(),
        curve_shape_state::new_linear(), curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(1),
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
        config::emit_registration(&cfg, escrow_id);
        let events = event::events_by_type<IntegrationConfigRegistered>();
        assert_eq!(events.length(), 1);
        assert_eq!(config::registered_escrow_id(&events[0]), escrow_id);
        assert_eq!(config::registered_config(&events[0]),    cfg);
    };
    scenario.end();
}

// E2: PowerLaw gcd-normalized curves are stored in reduced form inside the event.
#[test]
fun emit_registration_e2_power_law_gcd_normalized_in_payload() {
    // new_power_law(2,4) → stored PowerLaw{1,2}; getter returns the reduced form.
    let cfg       = config::new_config(
        V2_MIN_RENT_PRICE, phases::duration(V2_TENURE_CEILING), v2_handover(), v2_descent(), v2_retire(),
        curve_shape_state::new_power_law(2, 4),
        curve_shape_state::new_power_law(6, 3),
        price_function_state::new_fixed_delta(1),
    );
    let escrow_id = object::id_from_address(@0xE5C1);
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        config::emit_registration(&cfg, escrow_id);
        let events  = event::events_by_type<IntegrationConfigRegistered>();
        let payload = config::registered_config(&events[0]);
        // stored values are the reduced (gcd-normalized) forms
        assert_eq!(*config::proj_credit_curve(&payload),  curve_shape_state::new_power_law(2, 4));
        assert_eq!(*config::proj_descent_curve(&payload), curve_shape_state::new_power_law(6, 3));
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
        config::emit_registration(&cfg, escrow_id);
        config::emit_registration(&cfg, escrow_id);
        let events = event::events_by_type<IntegrationConfigRegistered>();
        assert_eq!(events.length(), 2);
        assert_eq!(config::registered_config(&events[0]), config::registered_config(&events[1]));
        assert_eq!(config::registered_escrow_id(&events[0]), config::registered_escrow_id(&events[1]));
    };
    scenario.end();
}
