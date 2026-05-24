// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::ensemble_tests;

use std::unit_test::assert_eq;
use sui::{
    clock,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    ensemble,
    math,
    escrow::{Self, Escrow},
    escrow_corpus,
    owner_cap,
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
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

// ─── V — Value type constructors ───────────────────────────────────────────────

// V1: price/price_mist are inverses.
#[test]
fun v1_price_price_mist_roundtrip() {
    assert_eq!(ensemble::price_mist(ensemble::price(0)),                         0);
    assert_eq!(ensemble::price_mist(ensemble::price(12_345)),                    12_345);
    assert_eq!(ensemble::price_mist(ensemble::price(18_446_744_073_709_551_615)), 18_446_744_073_709_551_615);
}

// V2: duration_ms is accepted by policy constructors that take Duration.
#[test]
fun v2_duration_ms_feeds_policy_constructors() {
    let _ = ensemble::new_descent_fixed(ensemble::duration_ms(60_000));
    let _ = ensemble::new_handover_fixed(ensemble::duration_ms(30_000));
    let _ = ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000));
    let _ = ensemble::new_commitment_deferred(ensemble::duration_ms(10_000_000));
}

// V3: tenures/tenures_count are inverses.
#[test]
fun v3_tenures_count_roundtrip() {
    assert_eq!(ensemble::tenures_count(ensemble::tenures(1)),   1);
    assert_eq!(ensemble::tenures_count(ensemble::tenures(7)),   7);
    assert_eq!(ensemble::tenures_count(ensemble::tenures(100)), 100);
}

// ─── E — PTB chain integration ─────────────────────────────────────────────────

// E1: Build a complete ensemble using ONLY ensemble::* and integrate.
// This is the canonical PTB chain test: value types → policies → ensemble → integrate.
#[test]
fun e1_full_ptb_chain_from_api_produces_idle_escrow() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble = ensemble::new_ensemble(
        ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000)),
        ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000)),
        ensemble::new_tenure_single(),
        ensemble::new_handover_off(),
        ensemble::new_descent_off(),
        ensemble::new_linear(),
        ensemble::new_linear(),
        ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000)),
    );
    let commitment = ensemble::new_commitment_immediate();

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap       = escrow::integrate<DemoAsset, SUI>(asset, ensemble, commitment, &fee_ref, &clk, sc.ctx());
    let escrow_id = owner_cap::proj_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    assert!(escrow::is_idle(&escrow), 0);
    test_scenario::return_shared(escrow);

    owner_cap::burn(cap, OWNER);
    sc.end();
}

// E2: All seven curve shape variants are accepted as credit_shape/auction_shape.
#[test]
fun e2_all_curve_shapes_accepted_by_integrate() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let rp  = ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000));
    let td  = ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000));
    let hnd = ensemble::new_handover_off();
    let aw  = ensemble::new_descent_off();
    let pf  = ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000));
    let com = ensemble::new_commitment_immediate();

    let curves = vector[
        ensemble::new_linear(),
        ensemble::new_smoothstep(),
        ensemble::new_logistic(),
        ensemble::new_power_law(1, 2),
        ensemble::new_power_law(2, 1),
        ensemble::new_exponential(2, true),
        ensemble::new_exponential(2, false),
    ];

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let mut i = 0;
    while (i < curves.length()) {
        let curve = curves[i];
        let ens   = ensemble::new_ensemble(rp, td, ensemble::new_tenure_single(), hnd, aw, curve, curve, pf);
        let clk   = clock::create_for_testing(sc.ctx());
        let asset = mk_demo_asset(sc.ctx());
        let cap   = escrow::integrate<DemoAsset, SUI>(asset, ens, com, &fee_ref, &clk, sc.ctx());
        clock::destroy_for_testing(clk);
        owner_cap::burn(cap, OWNER);
        sc.next_tx(OWNER);
        i = i + 1;
    };
    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E3: CommitmentPolicy immediate and deferred both accepted by integrate.
#[test]
fun e3_commitment_immediate_and_deferred_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ens     = escrow_corpus::by_tag(0);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();

    let clk   = clock::create_for_testing(sc.ctx());
    let asset = mk_demo_asset(sc.ctx());
    let cap   = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_commitment_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    clock::destroy_for_testing(clk);
    owner_cap::burn(cap, OWNER);

    sc.next_tx(OWNER);
    let clk   = clock::create_for_testing(sc.ctx());
    let asset = mk_demo_asset(sc.ctx());
    let cap   = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_commitment_deferred(ensemble::duration_ms(10_000_000)), &fee_ref, &clk, sc.ctx(),
    );
    clock::destroy_for_testing(clk);
    owner_cap::burn(cap, OWNER);

    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E4: Compound-delta price escalation accepted by integrate.
#[test]
fun e4_compound_delta_price_escalation_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ens = ensemble::new_ensemble(
        ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000)),
        ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000)),
        ensemble::new_tenure_single(),
        ensemble::new_handover_off(),
        ensemble::new_descent_off(),
        ensemble::new_linear(),
        ensemble::new_linear(),
        ensemble::new_price_compound_delta(math::bps(1_000), ensemble::price(1)),
    );
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let cap     = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_commitment_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    clock::destroy_for_testing(clk);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E5: Multi-tenure extend policy accepted by integrate.
#[test]
fun e5_multi_tenure_extend_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ens = ensemble::new_ensemble(
        ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000)),
        ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000)),
        ensemble::new_tenure_multi(),
        ensemble::new_handover_off(),
        ensemble::new_descent_off(),
        ensemble::new_linear(),
        ensemble::new_linear(),
        ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000)),
    );
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let cap     = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_commitment_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    clock::destroy_for_testing(clk);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E6: HandoverPolicy variants (off, fixed, full_tenure) all accepted.
#[test]
fun e6_all_handover_policies_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let rp   = ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000));
    let td   = ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000));
    let te   = ensemble::new_tenure_single();
    let aw   = ensemble::new_descent_off();
    let cs   = ensemble::new_linear();
    let pf   = ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000));
    let com  = ensemble::new_commitment_immediate();

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();

    let policies = vector[
        ensemble::new_handover_off(),
        ensemble::new_handover_fixed(ensemble::duration_ms(25_000)),
        ensemble::new_handover_full_tenure(),
    ];

    let mut i = 0;
    while (i < policies.length()) {
        let ens  = ensemble::new_ensemble(rp, td, te, policies[i], aw, cs, cs, pf);
        let clk  = clock::create_for_testing(sc.ctx());
        let asset = mk_demo_asset(sc.ctx());
        let cap  = escrow::integrate<DemoAsset, SUI>(asset, ens, com, &fee_ref, &clk, sc.ctx());
        clock::destroy_for_testing(clk);
        owner_cap::burn(cap, OWNER);
        sc.next_tx(OWNER);
        i = i + 1;
    };
    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E7: AuctionWindowPolicy off and fixed both accepted.
#[test]
fun e7_auction_window_policies_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let rp  = ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000));
    let td  = ensemble::new_tenure_duration_fixed(ensemble::duration_ms(100_000));
    let te  = ensemble::new_tenure_single();
    let hnd = ensemble::new_handover_off();
    let cs  = ensemble::new_linear();
    let pf  = ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000));
    let com = ensemble::new_commitment_immediate();

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();

    let windows = vector[
        ensemble::new_descent_off(),
        ensemble::new_descent_fixed(ensemble::duration_ms(100_000)),
    ];

    let mut i = 0;
    while (i < windows.length()) {
        let ens  = ensemble::new_ensemble(rp, td, te, hnd, windows[i], cs, cs, pf);
        let clk  = clock::create_for_testing(sc.ctx());
        let asset = mk_demo_asset(sc.ctx());
        let cap  = escrow::integrate<DemoAsset, SUI>(asset, ens, com, &fee_ref, &clk, sc.ctx());
        clock::destroy_for_testing(clk);
        owner_cap::burn(cap, OWNER);
        sc.next_tx(OWNER);
        i = i + 1;
    };
    test_scenario::return_immutable(fee_ref);
    sc.end();
}
