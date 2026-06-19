// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_state_price_tests;

use usufruct::{
    asset_state,
    escrow,
    policy_ensemble,
    curve_shape_policy,
    auction_window_policy,
    handover_policy,
    math,
    rest_price_policy,
    tenure_extend_policy,
    monetary,
    phases,
    price_escalation_policy,
    tenure_duration_policy,
    tenures,
};

const MIN:    u64 = 10_000_000_000;
const TENURE: u64 = 100_000;
const STAKE:  u64 = 15_000_000_000;
const LAST:   u64 = 20_000_000_000;
const T0:     u64 = 1_000_000;

fun base_ensemble(descent: bool): policy_ensemble::PolicyEnsemble {
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(MIN)), tenure_duration_policy::new_fixed(phases::duration(TENURE)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_off(),
        if (descent) { auction_window_policy::new_descent_fixed(phases::duration(TENURE)) }
        else         { auction_window_policy::new_descent_off()       },
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(MIN)),
    )
}

#[test]
fun ascending_is_time_independent() {
    let ensemble = base_ensemble(false);
    let p0 = monetary::price_mist(asset_state::ascending_floor_price_for_testing(tenures::stake_per_tenure(monetary::stake(STAKE), tenures::tenures(1)), &ensemble));
    let p1 = monetary::price_mist(asset_state::ascending_floor_price_for_testing(tenures::stake_per_tenure(monetary::stake(STAKE), tenures::tenures(1)), &ensemble));
    assert!(p0 == p1, 0);
}

#[test]
fun ascending_agrees_with_price_function_state() {
    let ensemble      = base_ensemble(false);
    let expected = monetary::price_mist(price_escalation_policy::compute_next_price(policy_ensemble::proj_price_escalation(&ensemble), monetary::price(STAKE)));
    assert!(monetary::price_mist(asset_state::ascending_floor_price_for_testing(tenures::stake_per_tenure(monetary::stake(STAKE), tenures::tenures(1)), &ensemble)) == expected, 0);
}

#[test]
fun ascending_fixed_delta_adds_delta() {
    let delta = MIN;
    let ensemble   = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(MIN)), tenure_duration_policy::new_fixed(phases::duration(TENURE)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_off(),
        auction_window_policy::new_descent_off(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(delta)),
    );
    let floor = monetary::price_mist(asset_state::ascending_floor_price_for_testing(tenures::stake_per_tenure(monetary::stake(STAKE), tenures::tenures(1)), &ensemble));
    assert!(floor > STAKE, 0);
    assert!(floor == STAKE + delta, 1);
}

#[test]
fun ascending_compound_delta_raises_price() {
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(MIN)), tenure_duration_policy::new_fixed(phases::duration(TENURE)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_off(),
        auction_window_policy::new_descent_off(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_compound_delta(math::bps(1_000), monetary::price(1)),
    );
    let floor = monetary::price_mist(asset_state::ascending_floor_price_for_testing(tenures::stake_per_tenure(monetary::stake(STAKE), tenures::tenures(1)), &ensemble));
    assert!(floor > STAKE, 0);
}

#[test]
fun descending_at_phase_start_returns_last_acq_price() {
    let ensemble = base_ensemble(true);
    let p   = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        &ensemble, phases::timestamp(T0),
    ));
    assert!(p == LAST, 0);
}

#[test]
fun descending_at_window_end_returns_min_rent_price() {
    let ensemble      = base_ensemble(true);
    let boundary = T0 + TENURE;
    let p        = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        &ensemble, phases::timestamp(boundary),
    ));
    assert!(p == MIN, 0);
}

#[test]
fun descending_price_is_monotone_decreasing() {
    let ensemble  = base_ensemble(true);
    let mid  = T0 + TENURE / 2;
    let late = T0 + TENURE * 3 / 4;
    let p_mid  = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        &ensemble, phases::timestamp(mid),
    ));
    let p_late = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        &ensemble, phases::timestamp(late),
    ));
    assert!(p_mid  >= p_late, 0);
    assert!(p_mid  <= LAST,   1);
    assert!(p_late >= MIN,    2);
}

#[test]
fun descending_mid_window_is_between_bounds() {
    let ensemble = base_ensemble(true);
    let mid = T0 + TENURE / 2;
    let p   = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        &ensemble, phases::timestamp(mid),
    ));
    assert!(p > MIN,  0);
    assert!(p < LAST, 1);
}

#[test]
fun descending_saturates_past_window() {
    let ensemble  = base_ensemble(true);
    let past = T0 + TENURE * 2;
    let p    = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        &ensemble, phases::timestamp(past),
    ));
    assert!(p == MIN, 0);
}

#[test]
fun descending_various_curves_respect_bounds() {
    let curves = vector[
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_smoothstep(),
        curve_shape_policy::new_logistic(),
        curve_shape_policy::new_power_law(1, 2),
        curve_shape_policy::new_power_law(2, 1),
        curve_shape_policy::new_exponential(2, true),
        curve_shape_policy::new_exponential(2, false),
    ];
    let mid = T0 + TENURE / 2;
    let mut i = 0;
    while (i < curves.length()) {
        let curve = *curves.borrow(i);
        let ensemble = policy_ensemble::new_ensemble(
            rest_price_policy::new_fixed(monetary::price(MIN)), tenure_duration_policy::new_fixed(phases::duration(TENURE)),
            tenure_extend_policy::new_single(),
            handover_policy::new_handover_off(),
            auction_window_policy::new_descent_fixed(phases::duration(TENURE)),
            curve_shape_policy::new_linear(),
            curve,
            price_escalation_policy::new_fixed_delta(monetary::price(MIN)),
        );
        let p = monetary::price_mist(asset_state::descending_floor_price_for_testing(
            monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
            &ensemble, phases::timestamp(mid),
        ));
        assert!(p >= MIN,  (i as u64));
        assert!(p <= LAST, (i as u64) + 100);
        i = i + 1;
    };
}

// The parameterized public views (escrow::descent_floor_at / used_credit_at /
// ascending_floor_with) must reproduce the canonical engine math EXACTLY for every shape
// and escalation — the drift-zero guarantee for historical curve reconstruction. The view
// is fed the policy enum by reference (the SDK constructs it on-chain via the existing
// public ensemble::new_* facade), not a primitive descriptor.

fun ensemble_with_shapes(
    credit_shape:  curve_shape_policy::CurveShapePolicy,
    auction_shape: curve_shape_policy::CurveShapePolicy,
): policy_ensemble::PolicyEnsemble {
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(MIN)), tenure_duration_policy::new_fixed(phases::duration(TENURE)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_off(),
        auction_window_policy::new_descent_fixed(phases::duration(TENURE)),
        credit_shape,
        auction_shape,
        price_escalation_policy::new_fixed_delta(monetary::price(MIN)),
    )
}

fun check_descent_at(shape: &curve_shape_policy::CurveShapePolicy, ensemble: &policy_ensemble::PolicyEnsemble, now: u64) {
    let via_view  = escrow::descent_floor_at(LAST, T0, MIN, TENURE, shape, now);
    let canonical = monetary::price_mist(asset_state::descending_floor_price_for_testing(
        monetary::price(LAST), phases::timestamp(T0), monetary::price(MIN), phases::duration(TENURE),
        ensemble, phases::timestamp(now),
    ));
    assert!(via_view == canonical, 0);
}

fun assert_descent_view_matches(auction_shape: curve_shape_policy::CurveShapePolicy) {
    let ensemble = ensemble_with_shapes(curve_shape_policy::new_linear(), auction_shape);
    check_descent_at(&auction_shape, &ensemble, T0);
    check_descent_at(&auction_shape, &ensemble, T0 + TENURE / 2);
    check_descent_at(&auction_shape, &ensemble, T0 + TENURE);
}

#[test]
fun descent_floor_at_view_matches_canonical_across_shapes() {
    assert_descent_view_matches(curve_shape_policy::new_linear());
    assert_descent_view_matches(curve_shape_policy::new_smoothstep());
    assert_descent_view_matches(curve_shape_policy::new_logistic());
    assert_descent_view_matches(curve_shape_policy::new_power_law(2, 1));
    assert_descent_view_matches(curve_shape_policy::new_exponential(4, false));
}

fun check_credit_at(shape: &curve_shape_policy::CurveShapePolicy, ensemble: &policy_ensemble::PolicyEnsemble, now: u64) {
    let via_view  = escrow::used_credit_at(STAKE, T0, TENURE, shape, now);
    let canonical = monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), ensemble, phases::duration(TENURE), phases::timestamp(now),
    ));
    assert!(via_view == canonical, 0);
}

fun assert_credit_view_matches(credit_shape: curve_shape_policy::CurveShapePolicy) {
    let ensemble = ensemble_with_shapes(credit_shape, curve_shape_policy::new_linear());
    check_credit_at(&credit_shape, &ensemble, T0);
    check_credit_at(&credit_shape, &ensemble, T0 + TENURE / 2);
    check_credit_at(&credit_shape, &ensemble, T0 + TENURE);
}

#[test]
fun used_credit_at_view_matches_canonical_across_shapes() {
    assert_credit_view_matches(curve_shape_policy::new_linear());
    assert_credit_view_matches(curve_shape_policy::new_smoothstep());
    assert_credit_view_matches(curve_shape_policy::new_logistic());
    assert_credit_view_matches(curve_shape_policy::new_power_law(2, 1));
    assert_credit_view_matches(curve_shape_policy::new_exponential(4, false));
}

fun assert_ascending_view_matches(escalation: price_escalation_policy::PriceEscalationPolicy) {
    let ensemble = policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(MIN)), tenure_duration_policy::new_fixed(phases::duration(TENURE)),
        tenure_extend_policy::new_single(),
        handover_policy::new_handover_off(),
        auction_window_policy::new_descent_off(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        escalation,
    );
    let via_view  = escrow::ascending_floor_with(STAKE, 1, &escalation);
    let canonical = monetary::price_mist(asset_state::ascending_floor_price_for_testing(
        tenures::stake_per_tenure(monetary::stake(STAKE), tenures::tenures(1)), &ensemble,
    ));
    assert!(via_view == canonical, 0);
}

#[test]
fun ascending_floor_with_view_matches_canonical() {
    assert_ascending_view_matches(price_escalation_policy::new_fixed_delta(monetary::price(MIN)));
    assert_ascending_view_matches(price_escalation_policy::new_compound_delta(math::bps(1_000), monetary::price(1)));
}
