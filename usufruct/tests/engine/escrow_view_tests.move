// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_view_tests;

use std::unit_test::assert_eq;
use sui::random::{Self, Random};
use sui::{
    clock,
    test_scenario::{Self, Scenario},
    sui::SUI,
};
use usufruct::{
    commitment_policy::{Self, CommitmentPolicy},
    config::IntegrationConfig,
    escrow::{Self, Escrow},
    escrow_corpus,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER: address = @0x07;

public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

fun setup(): Scenario {
    let mut sc = test_scenario::begin(@0x0);
    { random::create_for_testing(sc.ctx()); };
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

fun build_escrow(cfg: IntegrationConfig, sc: &mut Scenario): (Escrow<DemoAsset, SUI>, OwnerCap) {
    build_escrow_with_commitment(cfg, commitment_policy::new_immediate(), sc)
}

fun build_escrow_with_commitment(
    cfg:        IntegrationConfig,
    commitment: CommitmentPolicy,
    sc:         &mut Scenario,
): (Escrow<DemoAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let random  = sc.take_shared<Random>();
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, cfg, commitment, &fee_ref, &random, &clk, sc.ctx(),
    );
    test_scenario::return_shared(random);
    let escrow_id = owner_cap::proj_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    (escrow, cap)
}

fun dispose(escrow: Escrow<DemoAsset, SUI>, cap: OwnerCap) {
    test_scenario::return_shared(escrow);
    transfer::public_transfer(cap, OWNER);
}

// ─── tenure_ceiling views ─────────────────────────────────────────────────────

#[test]
fun tenure_ceiling_views_match_variants() {
    let mut sc = setup();

    // Fixed (default in corpus)
    let cfg_fixed = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(cfg_fixed, &mut sc);
    assert!(escrow::tenure_ceiling_is_fixed(&escrow));
    assert!(!escrow::tenure_ceiling_is_random_in_range(&escrow));
    assert_eq!(escrow::tenure_ceiling_fixed_ms(&escrow).destroy_some(), escrow_corpus::tenure_ceiling_const());
    assert!(escrow::tenure_ceiling_range_min_ms(&escrow).is_none());
    assert!(escrow::tenure_ceiling_range_max_ms(&escrow).is_none());
    dispose(escrow, cap);

    // RandomInRange (custom override)
    let cfg_random = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0)),
        50_000,
        150_000,
    );
    let (escrow, cap) = build_escrow(cfg_random, &mut sc);
    assert!(!escrow::tenure_ceiling_is_fixed(&escrow));
    assert!(escrow::tenure_ceiling_is_random_in_range(&escrow));
    assert!(escrow::tenure_ceiling_fixed_ms(&escrow).is_none());
    assert_eq!(escrow::tenure_ceiling_range_min_ms(&escrow).destroy_some(), 50_000);
    assert_eq!(escrow::tenure_ceiling_range_max_ms(&escrow).destroy_some(), 150_000);
    dispose(escrow, cap);

    sc.end();
}

// ─── min_rent_price views ─────────────────────────────────────────────────────

#[test]
fun min_rent_price_views_match_variants() {
    let mut sc = setup();

    let cfg_fixed = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(cfg_fixed, &mut sc);
    assert!(escrow::min_rent_price_is_fixed(&escrow));
    assert!(!escrow::min_rent_price_is_random_in_range(&escrow));
    assert_eq!(escrow::min_rent_price_fixed_mist(&escrow).destroy_some(), escrow_corpus::min_rent_price_const());
    assert!(escrow::min_rent_price_range_min_mist(&escrow).is_none());
    assert!(escrow::min_rent_price_range_max_mist(&escrow).is_none());
    dispose(escrow, cap);

    let cfg_random = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0)),
        5_000_000_000,
        20_000_000_000,
    );
    let (escrow, cap) = build_escrow(cfg_random, &mut sc);
    assert!(!escrow::min_rent_price_is_fixed(&escrow));
    assert!(escrow::min_rent_price_is_random_in_range(&escrow));
    assert!(escrow::min_rent_price_fixed_mist(&escrow).is_none());
    assert_eq!(escrow::min_rent_price_range_min_mist(&escrow).destroy_some(), 5_000_000_000);
    assert_eq!(escrow::min_rent_price_range_max_mist(&escrow).destroy_some(), 20_000_000_000);
    dispose(escrow, cap);

    sc.end();
}

// ─── handover views ───────────────────────────────────────────────────────────

#[test]
fun handover_views_match_variants() {
    let mut sc = setup();
    let mut c: u8 = 0;
    while (c <= 3) {
        let cfg = escrow_corpus::by_tag(escrow_corpus::tag(c, 0, 0, 0, 0));
        let (escrow, cap) = build_escrow(cfg, &mut sc);

        assert_eq!(escrow::is_handover_instant(&escrow),     c == 0);
        assert_eq!(escrow::is_handover_countdown(&escrow),   c == 1);
        assert_eq!(escrow::is_handover_fixed_time(&escrow),  c == 2);

        // Countdown floor: only present on c=1
        if (c == 1) {
            assert_eq!(escrow::handover_countdown_floor_ms(&escrow).destroy_some(), escrow_corpus::handover_countdown_c1_const());
        } else {
            assert!(escrow::handover_countdown_floor_ms(&escrow).is_none());
        };

        dispose(escrow, cap);
        c = c + 1;
    };
    sc.end();
}

// ─── descent views ────────────────────────────────────────────────────────────

#[test]
fun descent_views_match_variants() {
    let mut sc = setup();
    let mut h: u8 = 0;
    while (h <= 2) {
        let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, h, 0));
        let (escrow, cap) = build_escrow(cfg, &mut sc);

        assert_eq!(escrow::is_descent_skipped(&escrow), h == 0);
        assert_eq!(escrow::is_descent_window(&escrow),  h == 1);

        // dutch_auction_ceiling_ms wraps proj_window_ceiling — Some only on Window
        if (h == 1) {
            assert_eq!(escrow::dutch_auction_ceiling_ms(&escrow).destroy_some(), escrow_corpus::descent_window_h1_const());
        } else {
            assert!(escrow::dutch_auction_ceiling_ms(&escrow).is_none());
        };

        dispose(escrow, cap);
        h = h + 1;
    };
    sc.end();
}

// ─── credit_curve and descent_curve views (corpus uses same e for both) ──────

#[test]
fun curve_views_match_variants() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, e, 0, 0));
        let (escrow, cap) = build_escrow(cfg, &mut sc);

        assert_eq!(escrow::credit_curve_is_linear(&escrow),      e == 0);
        assert_eq!(escrow::credit_curve_is_smoothstep(&escrow),  e == 1);
        assert_eq!(escrow::credit_curve_is_logistic(&escrow),    e == 2);
        assert_eq!(escrow::credit_curve_is_power_law(&escrow),   e == 3 || e == 4);
        assert_eq!(escrow::credit_curve_is_exponential(&escrow), e == 5 || e == 6);

        assert_eq!(escrow::descent_curve_is_linear(&escrow),      e == 0);
        assert_eq!(escrow::descent_curve_is_smoothstep(&escrow),  e == 1);
        assert_eq!(escrow::descent_curve_is_logistic(&escrow),    e == 2);
        assert_eq!(escrow::descent_curve_is_power_law(&escrow),   e == 3 || e == 4);
        assert_eq!(escrow::descent_curve_is_exponential(&escrow), e == 5 || e == 6);

        // Field projectors per variant — see escrow_corpus::make_curve for the mapping
        // e=3 → PowerLaw(1,2), e=4 → PowerLaw(2,1)
        // e=5 → Exponential(2,true), e=6 → Exponential(2,false)
        if (e == 3) {
            assert_eq!(escrow::credit_curve_power_law_alpha_num(&escrow).destroy_some(), 1);
            assert_eq!(escrow::credit_curve_power_law_alpha_den(&escrow).destroy_some(), 2);
            assert_eq!(escrow::descent_curve_power_law_alpha_num(&escrow).destroy_some(), 1);
            assert_eq!(escrow::descent_curve_power_law_alpha_den(&escrow).destroy_some(), 2);
            assert!(escrow::credit_curve_exponential_alpha_abs(&escrow).is_none());
            assert!(escrow::descent_curve_exponential_alpha_abs(&escrow).is_none());
        } else if (e == 4) {
            assert_eq!(escrow::credit_curve_power_law_alpha_num(&escrow).destroy_some(), 2);
            assert_eq!(escrow::credit_curve_power_law_alpha_den(&escrow).destroy_some(), 1);
            assert_eq!(escrow::descent_curve_power_law_alpha_num(&escrow).destroy_some(), 2);
            assert_eq!(escrow::descent_curve_power_law_alpha_den(&escrow).destroy_some(), 1);
        } else if (e == 5) {
            assert!(escrow::credit_curve_power_law_alpha_num(&escrow).is_none());
            assert!(escrow::descent_curve_power_law_alpha_num(&escrow).is_none());
            assert_eq!(escrow::credit_curve_exponential_alpha_abs(&escrow).destroy_some(), 2);
            assert_eq!(escrow::credit_curve_exponential_alpha_neg(&escrow).destroy_some(), true);
            assert_eq!(escrow::descent_curve_exponential_alpha_abs(&escrow).destroy_some(), 2);
            assert_eq!(escrow::descent_curve_exponential_alpha_neg(&escrow).destroy_some(), true);
        } else if (e == 6) {
            assert_eq!(escrow::credit_curve_exponential_alpha_abs(&escrow).destroy_some(), 2);
            assert_eq!(escrow::credit_curve_exponential_alpha_neg(&escrow).destroy_some(), false);
            assert_eq!(escrow::descent_curve_exponential_alpha_abs(&escrow).destroy_some(), 2);
            assert_eq!(escrow::descent_curve_exponential_alpha_neg(&escrow).destroy_some(), false);
        } else {
            // Linear, Smoothstep, Logistic — no fields on either curve
            assert!(escrow::credit_curve_power_law_alpha_num(&escrow).is_none());
            assert!(escrow::credit_curve_power_law_alpha_den(&escrow).is_none());
            assert!(escrow::credit_curve_exponential_alpha_abs(&escrow).is_none());
            assert!(escrow::credit_curve_exponential_alpha_neg(&escrow).is_none());
            assert!(escrow::descent_curve_power_law_alpha_num(&escrow).is_none());
            assert!(escrow::descent_curve_power_law_alpha_den(&escrow).is_none());
            assert!(escrow::descent_curve_exponential_alpha_abs(&escrow).is_none());
            assert!(escrow::descent_curve_exponential_alpha_neg(&escrow).is_none());
        };

        dispose(escrow, cap);
        e = e + 1;
    };
    sc.end();
}

// ─── price_function views ─────────────────────────────────────────────────────

#[test]
fun price_function_views_match_variants() {
    let mut sc = setup();

    // d=0 — FixedDelta
    let cfg_fixed = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(cfg_fixed, &mut sc);
    assert!(escrow::price_fn_is_fixed_delta(&escrow));
    assert!(!escrow::price_fn_is_compound_delta(&escrow));
    assert_eq!(escrow::price_fn_fixed_delta(&escrow).destroy_some(), escrow_corpus::fixed_delta_value_const());
    assert!(escrow::price_fn_compound_delta_bps(&escrow).is_none());
    assert!(escrow::price_fn_compound_delta_delta(&escrow).is_none());
    dispose(escrow, cap);

    // d=1 — CompoundDelta
    let cfg_compound = escrow_corpus::by_tag(escrow_corpus::tag(0, 1, 0, 0, 0));
    let (escrow, cap) = build_escrow(cfg_compound, &mut sc);
    assert!(!escrow::price_fn_is_fixed_delta(&escrow));
    assert!(escrow::price_fn_is_compound_delta(&escrow));
    assert!(escrow::price_fn_fixed_delta(&escrow).is_none());
    assert_eq!(escrow::price_fn_compound_delta_bps(&escrow).destroy_some(), escrow_corpus::compound_delta_bps_const());
    assert_eq!(escrow::price_fn_compound_delta_delta(&escrow).destroy_some(), escrow_corpus::compound_delta_value_const());
    dispose(escrow, cap);

    sc.end();
}

// ─── commitment_policy views ──────────────────────────────────────────────────

#[test]
fun commitment_policy_views_match_variants() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));

    // Immediate
    let (escrow, cap) = build_escrow_with_commitment(cfg, commitment_policy::new_immediate(), &mut sc);
    assert!(escrow::is_commitment_immediate(&escrow));
    assert!(!escrow::is_commitment_deferred(&escrow));
    assert!(escrow::commitment_floor_ms(&escrow).is_none());
    dispose(escrow, cap);

    // Deferred — use the corpus default deferred floor
    let deferred_floor = escrow_corpus::retire_deferred_f1_const();
    let commitment = commitment_policy::new_deferred(usufruct::phases::duration(deferred_floor));
    let (escrow, cap) = build_escrow_with_commitment(cfg, commitment, &mut sc);
    assert!(!escrow::is_commitment_immediate(&escrow));
    assert!(escrow::is_commitment_deferred(&escrow));
    assert_eq!(escrow::commitment_floor_ms(&escrow).destroy_some(), deferred_floor);

    // commitment_remaining_ms — exercise both branches of the now<unlocks
    // vs now>=unlocks guard. Deferred puts unlocks strictly in the future,
    // so both branches are reachable from the same escrow.
    let unlocks = escrow::commitment_unlocks_at_ms(&escrow);
    assert!(unlocks > 0);
    assert_eq!(escrow::commitment_remaining_ms(&escrow, 0),           unlocks);
    assert_eq!(escrow::commitment_remaining_ms(&escrow, unlocks),     0);
    assert_eq!(escrow::commitment_remaining_ms(&escrow, unlocks + 1), 0);
    dispose(escrow, cap);

    sc.end();
}

// ─── whole-struct view getters ────────────────────────────────────────────────

#[test]
fun whole_struct_view_getters_return_configured_objects() {
    // The SDK rarely uses these (it prefers the discriminator + accessor API
    // already covered above) but they are part of the public surface for
    // callers that want to round-trip the full enum.
    let mut sc = setup();
    // e=0 → Linear curves on both credit and descent; d=0 → FixedDelta price fn.
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(cfg, &mut sc);

    assert_eq!(escrow::credit_curve(&escrow),  usufruct::curve_shape_policy::new_linear());
    assert_eq!(escrow::descent_curve(&escrow), usufruct::curve_shape_policy::new_linear());
    assert_eq!(
        escrow::ascending_price_function_state(&escrow),
        usufruct::price_function_policy::new_fixed_delta(usufruct::monetary::price(escrow_corpus::fixed_delta_value_const())),
    );

    dispose(escrow, cap);
    sc.end();
}

// ─── global constants ────────────────────────────────────────────────────────

#[test]
fun protocol_fee_bps_and_bps_denominator_are_reachable() {
    // No Escrow needed — these are nullary views. Just assert they return
    // documented constants (bps_denominator is the canonical 10_000 in math).
    assert_eq!(escrow::bps_denominator(), 10_000);
    // protocol_fee_bps is a protocol-wide constant; assert it's non-zero
    // and strictly below the denominator so the fee split is well-defined.
    let fee = escrow::protocol_fee_bps();
    assert!(fee > 0 && fee < 10_000);
}
