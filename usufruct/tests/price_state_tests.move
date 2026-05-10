// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::price_state_tests;

use usufruct::{
    config,
    curve_shape_state,
    descent_policy_state,
    handover_policy_state,
    math,
    min_rent_price_state,
    tenure_ceiling_state,
    monetary,
    phases,
    price_function_state,
    price_state,
    retire_policy_state,
};

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const MIN:    u64 = 10_000_000_000; // 10 SUI
const TENURE: u64 = 100_000;        // 100 s
const STAKE:  u64 = 15_000_000_000; // 15 SUI (above MIN, sets Ascending input)
const LAST:   u64 = 20_000_000_000; // 20 SUI (last_acq_price, starts Descending)
const T0:     u64 = 1_000_000;      // arbitrary phase_start_ms

fun base_cfg(descent: bool): config::IntegrationConfig {
    config::new_config(
        min_rent_price_state::new_fixed(monetary::price(MIN)), tenure_ceiling_state::new_fixed(phases::duration(TENURE)),
        handover_policy_state::new_handover_instant(),
        if (descent) { descent_policy_state::new_descent_window(phases::duration(TENURE)) }
        else         { descent_policy_state::new_descent_skipped()       },
        retire_policy_state::new_retire_immediate(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(monetary::price(MIN)),
    )
}

// ─── §1. Rest ─────────────────────────────────────────────────────────────────

#[test]
fun rest_returns_min_rent_price_regardless_of_time() {
    let cfg = base_cfg(false);
    let ps  = price_state::rest();
    // P1 — time-independent
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(0)))        == MIN, 0);
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(T0)))       == MIN, 0);
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(T0 + 999))) == MIN, 0);
}

#[test]
fun rest_predicate() {
    let ps = price_state::rest();
    assert!(price_state::proj_is_rest(&ps),      0);
    assert!(!price_state::proj_is_ascending(&ps), 1);
    assert!(!price_state::proj_is_descending(&ps), 2);
}

// ─── §2. Ascending ────────────────────────────────────────────────────────────

#[test]
fun ascending_is_time_independent() {
    let cfg = base_cfg(false);
    let ps  = price_state::ascending(monetary::stake(STAKE));
    // P2 — same floor_price at t=0 and t=tenure boundary
    let p0 = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(0)));
    let p1 = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(T0 + TENURE)));
    assert!(p0 == p1, 0);
}

#[test]
fun ascending_agrees_with_price_function_state() {
    // floor_price(Ascending { stake }, cfg, _) == evaluate_price_fn(pf, stake)
    // Spec-derived relation, not impl-mirroring.
    let cfg      = base_cfg(false);
    let ps       = price_state::ascending(monetary::stake(STAKE));
    let expected = monetary::price_mist(price_function_state::evaluate_price_fn(config::proj_price_function_state(&cfg), monetary::price(STAKE)));
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(0))) == expected, 0);
}

#[test]
fun ascending_fixed_delta_adds_delta() {
    // FixedDelta(δ): next_price = stake + δ.
    // P: floor > stake (price escalates).
    let delta = MIN;
    let cfg   = config::new_config(
        min_rent_price_state::new_fixed(monetary::price(MIN)), tenure_ceiling_state::new_fixed(phases::duration(TENURE)),
        handover_policy_state::new_handover_instant(),
        descent_policy_state::new_descent_skipped(),
        retire_policy_state::new_retire_immediate(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(monetary::price(delta)),
    );
    let ps = price_state::ascending(monetary::stake(STAKE));
    let floor = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(0)));
    assert!(floor > STAKE, 0);
    assert!(floor == STAKE + delta, 1);
}

#[test]
fun ascending_compound_delta_raises_price() {
    // CompoundDelta(bps, δ): next_price = stake + bps*stake/10000 + δ > stake.
    let cfg = config::new_config(
        min_rent_price_state::new_fixed(monetary::price(MIN)), tenure_ceiling_state::new_fixed(phases::duration(TENURE)),
        handover_policy_state::new_handover_instant(),
        descent_policy_state::new_descent_skipped(),
        retire_policy_state::new_retire_immediate(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_compound_delta(math::bps(1_000), monetary::price(1)), // 10% + 1 mist
    );
    let ps = price_state::ascending(monetary::stake(STAKE));
    let floor = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(0)));
    assert!(floor > STAKE, 0);
}

#[test]
fun ascending_predicate() {
    let ps = price_state::ascending(monetary::stake(STAKE));
    assert!(!price_state::proj_is_rest(&ps),      0);
    assert!(price_state::proj_is_ascending(&ps),  1);
    assert!(!price_state::proj_is_descending(&ps), 2);
}

// ─── §3. Descending ───────────────────────────────────────────────────────────

#[test]
fun descending_at_phase_start_returns_last_acq_price() {
    // P3a — at t = phase_start_ms, elapsed = 0, h = 0 → no descent yet.
    let cfg = base_cfg(true);
    let ps  = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(T0))) == LAST, 0);
}

#[test]
fun descending_at_window_end_returns_min_rent_price() {
    // P3b — at t = phase_start_ms + window_ceiling, h = SCALE → spread fully consumed.
    // Holds for ALL curve shapes (evaluate_curve short-circuits to SCALE at t >= t_max).
    let cfg      = base_cfg(true);
    let ps       = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
    let boundary = T0 + TENURE; // window_ceiling == TENURE in base_cfg
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(boundary))) == MIN, 0);
}

#[test]
fun descending_price_is_monotone_decreasing() {
    // P3c — price at t1 >= price at t2 when t1 <= t2.
    let cfg  = base_cfg(true);
    let ps   = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
    let mid  = T0 + TENURE / 2;
    let late = T0 + TENURE * 3 / 4;
    let p_mid  = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(mid)));
    let p_late = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(late)));
    assert!(p_mid  >= p_late, 0);   // monotone non-increasing
    assert!(p_mid  <= LAST,   1);   // capped above by last_acq
    assert!(p_late >= MIN,    2);   // floored below by min_rent_price
}

#[test]
fun descending_mid_window_is_between_bounds() {
    // P3d — at any t strictly between phase_start and boundary,
    // price ∈ (min_rent_price, last_acq_price) for curves that are
    // strictly between 0 and SCALE in the interior.
    let cfg = base_cfg(true);
    let ps  = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
    let mid = T0 + TENURE / 2;
    let p   = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(mid)));
    assert!(p > MIN,  0);
    assert!(p < LAST, 1);
}

#[test]
fun descending_saturates_past_window() {
    // P3e — price does not go below min_rent_price past the window.
    let cfg  = base_cfg(true);
    let ps   = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
    let past = T0 + TENURE * 2;
    assert!(monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(past))) == MIN, 0);
}

#[test]
fun descending_various_curves_respect_bounds() {
    // Sweep curve shapes: for all e in [0..6], floor_price is in [MIN, LAST].
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
            min_rent_price_state::new_fixed(monetary::price(MIN)), tenure_ceiling_state::new_fixed(phases::duration(TENURE)),
            handover_policy_state::new_handover_instant(),
            descent_policy_state::new_descent_window(phases::duration(TENURE)),
            retire_policy_state::new_retire_immediate(),
            curve_shape_state::new_linear(), // credit_curve unused here
            curve,
            price_function_state::new_fixed_delta(monetary::price(MIN)),
        );
        let ps = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
        let p  = monetary::price_mist(price_state::floor_price(&ps, &cfg, phases::timestamp(mid)));
        assert!(p >= MIN,  (i as u64));
        assert!(p <= LAST, (i as u64) + 100);
        i = i + 1;
    };
}

#[test]
fun descending_predicate() {
    let ps = price_state::descending(monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE));
    assert!(!price_state::proj_is_rest(&ps),       0);
    assert!(!price_state::proj_is_ascending(&ps),  1);
    assert!(price_state::proj_is_descending(&ps),  2);
}
