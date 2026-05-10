// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::credit_context_state_tests;

use usufruct::{
    config,
    credit_context_state::{Self as credit_state},
    curve_shape_state,
    descent_policy_state,
    handover_policy_state,
    floor_price_policy_state,
    tenure_cycles_policy_state,
    tenure_policy_state,
    monetary,
    phases,
    price_function_state,
    retire_policy_state,
};

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const MIN:    u64 = 10_000_000_000;
const TENURE: u64 = 100_000;
const STAKE:  u64 = 30_000_000_000; // 30 SUI
const T0:     u64 = 1_000_000;      // phase_start_ms
const EXPIRY: u64 = T0 + 25_000;    // handover countdown expiry

fun base_cfg(): config::IntegrationConfig {
    config::new_config(
        floor_price_policy_state::new_fixed(monetary::price(MIN)),
        tenure_policy_state::new_fixed(phases::duration(TENURE)),
        tenure_cycles_policy_state::new_single(),
        handover_policy_state::new_handover_instant(),
        descent_policy_state::new_descent_skipped(),
        retire_policy_state::new_retire_immediate(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(monetary::price(MIN)),
    )
}

// ─── §1. Accruing ─────────────────────────────────────────────────────────────

#[test]
fun accruing_at_phase_start_returns_zero() {
    // P1 — at t = phase_start_ms, elapsed = 0, g = 0 → no credit consumed yet.
    let cfg = base_cfg();
    let cs  = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    assert!(monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(T0))) == 0, 0);
}

#[test]
fun accruing_at_tenure_ceiling_returns_full_stake() {
    // P2 — at t = phase_start_ms + tenure_ceiling, evaluate_curve
    // short-circuits to SCALE → credit = stake.
    let cfg      = base_cfg();
    let cs       = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    let boundary = T0 + TENURE;
    assert!(monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(boundary))) == STAKE, 0);
}

#[test]
fun accruing_past_tenure_saturates_at_stake() {
    // P3 — credit never exceeds stake (evaluate_curve ≤ SCALE always).
    let cfg  = base_cfg();
    let cs   = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    let past = T0 + TENURE * 3;
    assert!(monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(past))) == STAKE, 0);
}

#[test]
fun accruing_mid_tenure_is_between_zero_and_stake() {
    // P4 — strictly interior for linear curve.
    let cfg  = base_cfg();
    let cs   = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    let mid  = T0 + TENURE / 2;
    let c    = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(mid)));
    assert!(c > 0,     0);
    assert!(c < STAKE, 1);
}

#[test]
fun accruing_is_monotone_non_decreasing() {
    // P5 — credit at t1 <= credit at t2 when t1 <= t2.
    let cfg   = base_cfg();
    let cs    = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    let early = T0 + TENURE / 4;
    let late  = T0 + TENURE * 3 / 4;
    let c_early = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(early)));
    let c_late  = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(late)));
    assert!(c_early <= c_late, 0);
}

#[test]
fun accruing_various_curves_stay_in_bounds() {
    // Sweep all curve shapes: used_credit ∈ [0, STAKE] at mid-tenure.
    let curves = vector[
        curve_shape_state::new_linear(),
        curve_shape_state::new_smoothstep(),
        curve_shape_state::new_logistic(),
        curve_shape_state::new_power_law(1, 2),
        curve_shape_state::new_power_law(2, 1),
        curve_shape_state::new_exponential(2, true),
        curve_shape_state::new_exponential(2, false),
    ];
    let mid = T0 + TENURE / 2;
    let mut i = 0;
    while (i < curves.length()) {
        let curve = *curves.borrow(i);
        let cfg = config::new_config(
            floor_price_policy_state::new_fixed(monetary::price(MIN)),
            tenure_policy_state::new_fixed(phases::duration(TENURE)),
            tenure_cycles_policy_state::new_single(),
            handover_policy_state::new_handover_instant(),
            descent_policy_state::new_descent_skipped(),
            retire_policy_state::new_retire_immediate(),
            curve,
            curve_shape_state::new_linear(), // descent_curve unused here
            price_function_state::new_fixed_delta(monetary::price(MIN)),
        );
        let cs = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
        let c  = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(mid)));
        assert!(c >= 0,     (i as u64));
        assert!(c <= STAKE, (i as u64) + 100);
        i = i + 1;
    };
}

#[test]
fun accruing_predicate() {
    let cs = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    assert!(credit_state::proj_is_accruing(&cs), 0);
    assert!(!credit_state::proj_is_capped(&cs),  1);
}

// ─── §2. Capped ───────────────────────────────────────────────────────────────

#[test]
fun capped_at_phase_start_returns_zero() {
    let cfg = base_cfg();
    let cs  = credit_state::capped(monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY));
    assert!(monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(T0))) == 0, 0);
}

#[test]
fun capped_before_expiry_matches_accruing() {
    // P6 — before the countdown fires, Capped ≡ Accruing.
    let cfg    = base_cfg();
    let capped   = credit_state::capped(monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY));
    let accruing = credit_state::accruing(monetary::stake(STAKE), phases::timestamp(T0));
    let before   = EXPIRY - 1;
    assert!(
        monetary::stake_mist(credit_state::used_credit(&capped,   &cfg, phases::duration(TENURE), phases::timestamp(before))) ==
        monetary::stake_mist(credit_state::used_credit(&accruing, &cfg, phases::duration(TENURE), phases::timestamp(before))),
        0,
    );
}

#[test]
fun capped_saturates_past_expiry() {
    // P7 — used_credit(t > expiry) == used_credit(t = expiry).
    // After the countdown boundary, accrual is frozen.
    let cfg    = base_cfg();
    let cs     = credit_state::capped(monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY));
    let at_exp = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(EXPIRY)));
    let past   = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(EXPIRY + 50_000)));
    assert!(at_exp == past, 0);
}

#[test]
fun capped_saturation_is_less_than_full_stake() {
    // P8 — expiry fires before tenure_ceiling, so credit at expiry < stake.
    // (expiry = T0 + 25_000; tenure_ceiling = 100_000 → expiry < boundary)
    let cfg    = base_cfg();
    let cs     = credit_state::capped(monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY));
    let at_exp = monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(EXPIRY)));
    assert!(at_exp < STAKE, 0);
    assert!(at_exp > 0,     1); // some credit was consumed before expiry
}

#[test]
fun capped_at_tenure_boundary_returns_full_stake_when_expiry_past_ceiling() {
    // P9 — if expiry_ms > phase_start_ms + tenure_ceiling, the cap never binds:
    // Capped behaves identically to Accruing and saturates at STAKE.
    let late_expiry = T0 + TENURE + 10_000; // beyond tenure_ceiling
    let cfg = base_cfg();
    let cs  = credit_state::capped(monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(late_expiry));
    let boundary = T0 + TENURE;
    assert!(monetary::stake_mist(credit_state::used_credit(&cs, &cfg, phases::duration(TENURE), phases::timestamp(boundary))) == STAKE, 0);
}

#[test]
fun capped_predicate() {
    let cs = credit_state::capped(monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY));
    assert!(!credit_state::proj_is_accruing(&cs), 0);
    assert!(credit_state::proj_is_capped(&cs),    1);
}
