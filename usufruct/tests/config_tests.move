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
    config::{Self, IntegrationConfig, IntegrationConfigRegistered},
    curve_shape,
    price_function,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

// Canonical V2 config values (used as baseline for single-field variation rows).
const V2_MIN_RENT_PRICE:  u64 = 1_000_000;
const V2_TENURE_CEILING:  u64 = 86_400_000;
const V2_HANDOVER_FLOOR:  u64 = 3_600_000;
const V2_DESCENT_CEILING: u64 = 43_200_000;
const V2_RETIRE_FLOOR:    u64 = 0;

fun v2_config(): IntegrationConfig {
    config::new_config(
        V2_MIN_RENT_PRICE,
        V2_TENURE_CEILING,
        V2_HANDOVER_FLOOR,
        V2_DESCENT_CEILING,
        V2_RETIRE_FLOOR,
        curve_shape::new_linear(),
        curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    )
}

// ─── §7.1 + §7.3 — Valid inputs + getter round-trip ───────────────────────────

// Case struct for the parametric loop. All twelve V-rows are encoded here.
// The loop both constructs the config and verifies each getter (§7.3 P5 predicate).
public struct Case has drop {
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover_floor:  u64,
    descent_ceiling: u64,
    retire_floor:    u64,
    credit_curve:    curve_shape::CurveShape,
    descent_curve:   curve_shape::CurveShape,
    price_function:  price_function::PriceFunction,
}

#[test]
fun new_config_valid_inputs_and_getter_roundtrip() {
    let cases = vector[
        // V1 — minimal valid; handover_floor = 0 (immediate handover)
        Case {
            min_rent_price:  1,
            tenure_ceiling:  1,
            handover_floor:  0,
            descent_ceiling: 1,
            retire_floor:    0,
            credit_curve:    curve_shape::new_linear(),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V2 — typical: 1h handover in 24h tenure, 12h auction, no retire floor
        Case {
            min_rent_price:  1_000_000,
            tenure_ceiling:  86_400_000,
            handover_floor:  3_600_000,
            descent_ceiling: 43_200_000,
            retire_floor:    0,
            credit_curve:    curve_shape::new_linear(),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V3 — retire_floor = 2h; Smoothstep curves
        Case {
            min_rent_price:  100,
            tenure_ceiling:  10_000,
            handover_floor:  5_000,
            descent_ceiling: 10_000,
            retire_floor:    7_200_000,
            credit_curve:    curve_shape::new_smoothstep(),
            descent_curve:   curve_shape::new_smoothstep(),
            price_function:  price_function::new_fixed_delta(10),
        },
        // V4 — handover_floor = 0 (no bidding window); PowerLaw credit
        Case {
            min_rent_price:  50,
            tenure_ceiling:  100_000,
            handover_floor:  0,
            descent_ceiling: 50_000,
            retire_floor:    0,
            credit_curve:    curve_shape::new_power_law(1, 2),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V5 — u64::MAX min_rent_price; mixed Exp curves
        Case {
            min_rent_price:  18_446_744_073_709_551_615,
            tenure_ceiling:  1_000,
            handover_floor:  500,
            descent_ceiling: 1_000,
            retire_floor:    0,
            credit_curve:    curve_shape::new_exponential(3, false),
            descent_curve:   curve_shape::new_exponential(3, true),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V6 — no upper bound on time params; retire_floor = u64::MAX
        Case {
            min_rent_price:  1,
            tenure_ceiling:  18_446_744_073_709_551_615,
            handover_floor:  1,
            descent_ceiling: 18_446_744_073_709_551_615,
            retire_floor:    18_446_744_073_709_551_615,
            credit_curve:    curve_shape::new_logistic(),
            descent_curve:   curve_shape::new_logistic(),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V7 — CompoundDelta price function: 5% + 100 base units per cycle
        Case {
            min_rent_price:  1_000,
            tenure_ceiling:  86_400_000,
            handover_floor:  3_600_000,
            descent_ceiling: 43_200_000,
            retire_floor:    0,
            credit_curve:    curve_shape::new_linear(),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_compound_delta(500, 100),
        },
        // V8 — handover_floor == tenure_ceiling (upper boundary of P3)
        Case {
            min_rent_price:  1,
            tenure_ceiling:  1_000,
            handover_floor:  1_000,
            descent_ceiling: 1,
            retire_floor:    0,
            credit_curve:    curve_shape::new_linear(),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V9 — P3 boundary at u64 extreme; both values saturated together
        Case {
            min_rent_price:  1,
            tenure_ceiling:  18_446_744_073_709_551_615,
            handover_floor:  18_446_744_073_709_551_615,
            descent_ceiling: 1,
            retire_floor:    0,
            credit_curve:    curve_shape::new_linear(),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V10 — PowerLaw inputs requiring gcd normalization
        //        credit_curve: new_power_law(2,4) → stored as PowerLaw{1,2}
        //        descent_curve: new_power_law(6,3) → stored as PowerLaw{2,1}
        Case {
            min_rent_price:  1,
            tenure_ceiling:  1_000,
            handover_floor:  0,
            descent_ceiling: 1,
            retire_floor:    0,
            credit_curve:    curve_shape::new_power_law(2, 4),
            descent_curve:   curve_shape::new_power_law(6, 3),
            price_function:  price_function::new_fixed_delta(1),
        },
        // V11 — extreme α values (min convex, max concave) + minimum CompoundDelta
        Case {
            min_rent_price:  1,
            tenure_ceiling:  1_000,
            handover_floor:  500,
            descent_ceiling: 1,
            retire_floor:    0,
            credit_curve:    curve_shape::new_exponential(1, false),
            descent_curve:   curve_shape::new_exponential(8, true),
            price_function:  price_function::new_compound_delta(1, 1),
        },
        // V12 — descent_ceiling = 0 ("no price memory" variant)
        Case {
            min_rent_price:  1,
            tenure_ceiling:  1_000,
            handover_floor:  0,
            descent_ceiling: 0,
            retire_floor:    0,
            credit_curve:    curve_shape::new_linear(),
            descent_curve:   curve_shape::new_linear(),
            price_function:  price_function::new_fixed_delta(1),
        },
    ];

    let mut i = 0;
    while (i < cases.length()) {
        let c = &cases[i];
        let cfg = config::new_config(
            c.min_rent_price,
            c.tenure_ceiling,
            c.handover_floor,
            c.descent_ceiling,
            c.retire_floor,
            c.credit_curve,
            c.descent_curve,
            c.price_function,
        );
        // §7.3 P5 predicate: getter(new_config(..., f, ...)) == f for each field
        assert_eq!(config::min_rent_price(&cfg),  c.min_rent_price);
        assert_eq!(config::tenure_ceiling(&cfg),  c.tenure_ceiling);
        assert_eq!(config::handover_floor(&cfg),  c.handover_floor);
        assert_eq!(config::descent_ceiling(&cfg), c.descent_ceiling);
        assert_eq!(config::retire_floor(&cfg),    c.retire_floor);
        assert_eq!(*config::credit_curve(&cfg),   c.credit_curve);
        assert_eq!(*config::descent_curve(&cfg),  c.descent_curve);
        assert_eq!(*config::price_function(&cfg), c.price_function);
        i = i + 1;
    };
}

// ─── §7.3 Explicit field pins (R1–R8) ─────────────────────────────────────────

// Each row holds all other fields at V2 canonical values; only the named field varies.

#[test]
fun getter_roundtrip_r1_min_rent_price_max() {
    let cfg = config::new_config(
        18_446_744_073_709_551_615,
        V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
    assert_eq!(config::min_rent_price(&cfg), 18_446_744_073_709_551_615);
}

#[test]
fun getter_roundtrip_r2_tenure_ceiling_typical_ms() {
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE,
        86_400_000,
        V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
    assert_eq!(config::tenure_ceiling(&cfg), 86_400_000);
}

#[test]
fun getter_roundtrip_r3_handover_floor_zero() {
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING,
        0,
        V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
    assert_eq!(config::handover_floor(&cfg), 0);
}

#[test]
fun getter_roundtrip_r4_descent_ceiling_one() {
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING, V2_HANDOVER_FLOOR,
        1,
        V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
    assert_eq!(config::descent_ceiling(&cfg), 1);
}

#[test]
fun getter_roundtrip_r5_retire_floor_max() {
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING,
        18_446_744_073_709_551_615,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
    assert_eq!(config::retire_floor(&cfg), 18_446_744_073_709_551_615);
}

#[test]
fun getter_roundtrip_r6_credit_curve_power_law_gcd_normalized() {
    // new_power_law(2,4) normalizes to stored PowerLaw{1,2}.
    // Getter returns the reduced form — normalization is upstream in curve_shape.
    let raw = curve_shape::new_power_law(2, 4);
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        raw,
        curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
    assert_eq!(*config::credit_curve(&cfg), raw);
}

#[test]
fun getter_roundtrip_r7_descent_curve_logistic() {
    let g = curve_shape::new_logistic();
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(),
        g,
        price_function::new_fixed_delta(1),
    );
    assert_eq!(*config::descent_curve(&cfg), g);
}

#[test]
fun getter_roundtrip_r8_price_function_compound_delta() {
    let pf = price_function::new_compound_delta(500, 100);
    let cfg = config::new_config(
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        pf,
    );
    assert_eq!(*config::price_function(&cfg), pf);
}

// ─── §7.2 — Invalid inputs (one function each) ────────────────────────────────

#[test]
#[expected_failure(abort_code = config::EMinRentPriceZero, location = usufruct::config)]
fun new_config_rejects_min_rent_price_zero() {
    config::new_config(
        0,
        V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::ETenureCeilingZero, location = usufruct::config)]
fun new_config_rejects_tenure_ceiling_zero() {
    config::new_config(
        V2_MIN_RENT_PRICE,
        0,
        V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_handover_floor_gt_tenure_ceiling() {
    // I3: handover_floor=100, tenure_ceiling=50
    config::new_config(
        V2_MIN_RENT_PRICE,
        50,
        100,
        V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_handover_floor_tenure_ceiling_plus_one() {
    // I4: smallest strictly-greater case — guards off-by-one on the <= check
    config::new_config(
        V2_MIN_RENT_PRICE,
        1_000,
        1_001,
        V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
    );
}

#[test]
#[expected_failure(abort_code = config::EHandoverFloorExceedsTenure, location = usufruct::config)]
fun new_config_rejects_handover_floor_u64_max_tenure_ceiling_max_minus_one() {
    // I5: u64-saturated boundary; confirms plain unsigned compare (no arithmetic overflow)
    config::new_config(
        V2_MIN_RENT_PRICE,
        18_446_744_073_709_551_614, // u64::MAX - 1
        18_446_744_073_709_551_615, // u64::MAX
        V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_linear(), curve_shape::new_linear(),
        price_function::new_fixed_delta(1),
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
        V2_MIN_RENT_PRICE, V2_TENURE_CEILING, V2_HANDOVER_FLOOR, V2_DESCENT_CEILING, V2_RETIRE_FLOOR,
        curve_shape::new_power_law(2, 4),
        curve_shape::new_power_law(6, 3),
        price_function::new_fixed_delta(1),
    );
    let escrow_id = object::id_from_address(@0xE5C1);
    let mut scenario = test_scenario::begin(@0xA);
    scenario.next_tx(@0xA);
    {
        config::emit_registration(&cfg, escrow_id);
        let events  = event::events_by_type<IntegrationConfigRegistered>();
        let payload = config::registered_config(&events[0]);
        // stored values are the reduced (gcd-normalized) forms
        assert_eq!(*config::credit_curve(&payload),  curve_shape::new_power_law(2, 4));
        assert_eq!(*config::descent_curve(&payload), curve_shape::new_power_law(6, 3));
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
