// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::ensemble_tests;

use sui::{
    balance,
    clock,
    coin,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    ensemble_commitment_policy,
    retire_commitment_policy,
    ensemble,
    math,
    escrow::{Self, Escrow},
    escrow_corpus,
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

// V1: duration is accepted by policy constructors that take Duration.
#[test]
fun v1_duration_feeds_policy_constructors() {
    let _ = ensemble::new_descent_fixed(ensemble::duration(60_000));
    let _ = ensemble::new_handover_fixed(ensemble::duration(30_000));
    let _ = ensemble::new_tenure_duration_fixed(ensemble::duration(100_000));
    let _ = ensemble::new_retire_commitment_deferred(ensemble::duration(10_000_000));
}

// V2: tenures is accepted by rent.
#[test]
fun v2_tenures_feeds_rent() {
    let mut sc    = setup();
    sc.next_tx(OWNER);

    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());
    let (owner_cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = coin::from_balance(balance::create_for_testing<SUI>(10_000_000_000), sc.ctx());
    let tenant_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, ensemble::tenures(1), &clk2, sc.ctx(),
    );
    clock::destroy_for_testing(clk2);
    test_scenario::return_shared(escrow);
    transfer::public_transfer(tenant_cap, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    sc.end();
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
        ensemble::new_tenure_duration_fixed(ensemble::duration(100_000)),
        ensemble::new_tenure_single(),
        ensemble::new_handover_off(),
        ensemble::new_descent_off(),
        ensemble::new_linear(),
        ensemble::new_linear(),
        ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000)),
    );
    let commitment = ensemble::new_retire_commitment_immediate();

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(asset, ensemble, commitment, ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx());
    transfer::public_transfer(inbox, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    assert!(escrow::is_idle(&escrow), 0);
    test_scenario::return_shared(escrow);

    transfer::public_transfer(cap, OWNER);
    sc.end();
}

// E2: All seven curve shape variants are accepted as credit_shape/auction_shape.
#[test]
fun e2_all_curve_shapes_accepted_by_integrate() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let rp  = ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000));
    let td  = ensemble::new_tenure_duration_fixed(ensemble::duration(100_000));
    let hnd = ensemble::new_handover_off();
    let aw  = ensemble::new_descent_off();
    let pf  = ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000));
    let com = ensemble::new_retire_commitment_immediate();

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
        let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(asset, ens, com, ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx());
        transfer::public_transfer(inbox, OWNER);
        clock::destroy_for_testing(clk);
        transfer::public_transfer(cap, OWNER);
        sc.next_tx(OWNER);
        i = i + 1;
    };
    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E3: RetireCommitmentPolicy immediate and deferred both accepted by integrate.
#[test]
fun e3_retire_commitment_immediate_and_deferred_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ens     = escrow_corpus::by_tag(0);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();

    let clk   = clock::create_for_testing(sc.ctx());
    let asset = mk_demo_asset(sc.ctx());
    let (cap, inbox1) = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_retire_commitment_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox1, OWNER);
    clock::destroy_for_testing(clk);
    transfer::public_transfer(cap, OWNER);

    sc.next_tx(OWNER);
    let clk   = clock::create_for_testing(sc.ctx());
    let asset = mk_demo_asset(sc.ctx());
    let (cap, inbox2) = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_retire_commitment_deferred(ensemble::duration(10_000_000)), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox2, OWNER);
    clock::destroy_for_testing(clk);
    transfer::public_transfer(cap, OWNER);

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
        ensemble::new_tenure_duration_fixed(ensemble::duration(100_000)),
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
    let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_retire_commitment_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, OWNER);
    clock::destroy_for_testing(clk);
    transfer::public_transfer(cap, OWNER);
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
        ensemble::new_tenure_duration_fixed(ensemble::duration(100_000)),
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
    let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, ens, ensemble::new_retire_commitment_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, OWNER);
    clock::destroy_for_testing(clk);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    sc.end();
}

// E6: HandoverPolicy variants (off, fixed, full_tenure) all accepted.
#[test]
fun e6_all_handover_policies_accepted() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let rp   = ensemble::new_rest_price_fixed(ensemble::price(10_000_000_000));
    let td   = ensemble::new_tenure_duration_fixed(ensemble::duration(100_000));
    let te   = ensemble::new_tenure_single();
    let aw   = ensemble::new_descent_off();
    let cs   = ensemble::new_linear();
    let pf   = ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000));
    let com  = ensemble::new_retire_commitment_immediate();

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();

    let policies = vector[
        ensemble::new_handover_off(),
        ensemble::new_handover_fixed(ensemble::duration(25_000)),
        ensemble::new_handover_full_tenure(),
    ];

    let mut i = 0;
    while (i < policies.length()) {
        let ens  = ensemble::new_ensemble(rp, td, te, policies[i], aw, cs, cs, pf);
        let clk  = clock::create_for_testing(sc.ctx());
        let asset = mk_demo_asset(sc.ctx());
        let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(asset, ens, com, ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx());
        transfer::public_transfer(inbox, OWNER);
        clock::destroy_for_testing(clk);
        transfer::public_transfer(cap, OWNER);
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
    let td  = ensemble::new_tenure_duration_fixed(ensemble::duration(100_000));
    let te  = ensemble::new_tenure_single();
    let hnd = ensemble::new_handover_off();
    let cs  = ensemble::new_linear();
    let pf  = ensemble::new_price_fixed_delta(ensemble::price(10_000_000_000));
    let com = ensemble::new_retire_commitment_immediate();

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();

    let windows = vector[
        ensemble::new_descent_off(),
        ensemble::new_descent_fixed(ensemble::duration(100_000)),
    ];

    let mut i = 0;
    while (i < windows.length()) {
        let ens  = ensemble::new_ensemble(rp, td, te, hnd, windows[i], cs, cs, pf);
        let clk  = clock::create_for_testing(sc.ctx());
        let asset = mk_demo_asset(sc.ctx());
        let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(asset, ens, com, ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx());
        transfer::public_transfer(inbox, OWNER);
        clock::destroy_for_testing(clk);
        transfer::public_transfer(cap, OWNER);
        sc.next_tx(OWNER);
        i = i + 1;
    };
    test_scenario::return_immutable(fee_ref);
    sc.end();
}
