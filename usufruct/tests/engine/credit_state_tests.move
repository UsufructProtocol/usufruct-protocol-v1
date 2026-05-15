// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::credit_context_state_tests;

use usufruct::{
    asset_state,
    config,
    curve_shape_state,
    descent_policy_state,
    handover_policy_state,
    floor_price_policy_state,
    tenure_cycles_policy_state,
    tenure_policy_state,
    monetary,
    phases,
    price_function_state,
};

const MIN:    u64 = 10_000_000_000;
const TENURE: u64 = 100_000;
const STAKE:  u64 = 30_000_000_000;
const T0:     u64 = 1_000_000;
const EXPIRY: u64 = T0 + 25_000;

fun base_cfg(): config::IntegrationConfig {
    config::new_config(
        floor_price_policy_state::new_fixed(monetary::price(MIN)),
        tenure_policy_state::new_fixed(phases::duration(TENURE)),
        tenure_cycles_policy_state::new_single(),
        handover_policy_state::new_handover_instant(),
        descent_policy_state::new_descent_skipped(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(monetary::price(MIN)),
    )
}

#[test]
fun accruing_at_phase_start_returns_zero() {
    let cfg = base_cfg();
    assert!(monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(T0)
    )) == 0, 0);
}

#[test]
fun accruing_at_tenure_ceiling_returns_full_stake() {
    let cfg = base_cfg();
    assert!(monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(T0 + TENURE)
    )) == STAKE, 0);
}

#[test]
fun accruing_past_tenure_saturates_at_stake() {
    let cfg = base_cfg();
    assert!(monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(T0 + TENURE * 3)
    )) == STAKE, 0);
}

#[test]
fun accruing_mid_tenure_is_between_zero_and_stake() {
    let cfg = base_cfg();
    let c   = monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(T0 + TENURE / 2)
    ));
    assert!(c > 0,     0);
    assert!(c < STAKE, 1);
}

#[test]
fun accruing_is_monotone_non_decreasing() {
    let cfg     = base_cfg();
    let c_early = monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(T0 + TENURE / 4)
    ));
    let c_late  = monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(T0 + TENURE * 3 / 4)
    ));
    assert!(c_early <= c_late, 0);
}

#[test]
fun accruing_various_curves_stay_in_bounds() {
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
            curve,
            curve_shape_state::new_linear(),
            price_function_state::new_fixed_delta(monetary::price(MIN)),
        );
        let c = monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
            monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), phases::timestamp(mid)
        ));
        assert!(c >= 0,     (i as u64));
        assert!(c <= STAKE, (i as u64) + 100);
        i = i + 1;
    };
}

#[test]
fun capped_at_phase_start_returns_zero() {
    let cfg = base_cfg();
    assert!(monetary::stake_mist(asset_state::capped_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY),
        &cfg, phases::duration(TENURE), phases::timestamp(T0)
    )) == 0, 0);
}

#[test]
fun capped_before_expiry_matches_accruing() {
    let cfg    = base_cfg();
    let before = phases::timestamp(EXPIRY - 1);
    let accruing = monetary::stake_mist(asset_state::accruing_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), &cfg, phases::duration(TENURE), before
    ));
    let capped = monetary::stake_mist(asset_state::capped_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY),
        &cfg, phases::duration(TENURE), before
    ));
    assert!(accruing == capped, 0);
}

#[test]
fun capped_saturates_past_expiry() {
    let cfg    = base_cfg();
    let at_exp = monetary::stake_mist(asset_state::capped_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY),
        &cfg, phases::duration(TENURE), phases::timestamp(EXPIRY)
    ));
    let past   = monetary::stake_mist(asset_state::capped_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY),
        &cfg, phases::duration(TENURE), phases::timestamp(EXPIRY + 50_000)
    ));
    assert!(at_exp == past, 0);
}

#[test]
fun capped_saturation_is_less_than_full_stake() {
    let cfg    = base_cfg();
    let at_exp = monetary::stake_mist(asset_state::capped_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(EXPIRY),
        &cfg, phases::duration(TENURE), phases::timestamp(EXPIRY)
    ));
    assert!(at_exp < STAKE, 0);
    assert!(at_exp > 0,     1);
}

#[test]
fun capped_at_tenure_boundary_returns_full_stake_when_expiry_past_ceiling() {
    let late_expiry = T0 + TENURE + 10_000;
    let cfg         = base_cfg();
    assert!(monetary::stake_mist(asset_state::capped_used_credit_for_testing(
        monetary::stake(STAKE), phases::timestamp(T0), phases::timestamp(late_expiry),
        &cfg, phases::duration(TENURE), phases::timestamp(T0 + TENURE)
    )) == STAKE, 0);
}
