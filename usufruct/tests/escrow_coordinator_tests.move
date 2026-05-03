// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_coordinator_tests;

use std::unit_test::assert_eq;
use sui::{
    clock,
    sui::SUI,
    test_scenario,
};
use usufruct::{
    escrow_coordinator::{Self, EscrowCoordinator},
    escrow_corpus,
    owner_cap,
    protocol_fee_inbox::{Self, ProtocolFeeRef},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER: address = @0x07;

/// Test asset — minimal key+store object that satisfies the
/// `Asset` bound on `EscrowCoordinator`.
public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

/// Initialise the protocol-fee singletons. Returns a scenario whose
/// next-tx state has the `ProtocolFeeRef` frozen and the
/// `ProtocolFeeInbox` owned by `OWNER`.
fun setup(): test_scenario::Scenario {
    let mut sc = test_scenario::begin(OWNER);
    {
        protocol_fee_inbox::init_for_testing(sc.ctx());
    };
    sc
}

/// Asserts the projected state is `Idle`, using `breadcrumb` (typically
/// the corpus τ2 tag) as the abort code on mismatch.
fun assert_tag_idle<Asset: key + store, CoinType>(
    escrow:    &EscrowCoordinator<Asset, CoinType>,
    breadcrumb: u64,
) {
    let actual = escrow_coordinator::state_tag(escrow);
    assert!(escrow_coordinator::is_tag_idle(&actual), breadcrumb);
}

// ─── §1. integrate — happy path (single-config smoke) ─────────────────────────

#[test]
fun integrate_creates_idle_escrow_smoke() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let cfg     = escrow_corpus::by_tag(0); // c=0 instant, d=0 fixed, e=0 linear, h=0 skipped, f=0 immediate
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap = escrow_coordinator::integrate<DemoAsset, SUI>(
        asset, cfg, &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::escrow_id(&cap);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);
    assert_tag_idle(&escrow, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §2. integrate — corpus projection ───────────────────────────────────────

/// §10.1 — integrate is universally applicable. Sweeps the C axis
/// (HandoverPolicy ∈ {Instant, Countdown, FixedTime}) — three
/// behaviorally distinct handover modes — at fixed (d=0, e=0, h=0, f=0).
/// Verifies the post-condition `state_tag == Idle` for each.
///
/// The full 168-config corpus is unnecessary here: integrate does not
/// branch on policy / curve / price values; it only stores the cfg.
/// A C-axis sweep is the minimum projection that exercises the named
/// protocol modes (per the corpus operational rule: "Default to the
/// minimum projection, not all_configs()"). Cross-axis sweeps belong
/// in commits where the behavior actually depends on those axes
/// (curve sweeps in C2 views; descent sweeps in C4 boundary handlers).
#[test]
fun integrate_idle_across_handover_modes() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let mut c: u8 = 0;
    while (c <= 2) {
        let tag = escrow_corpus::tag(c, 0, 0, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);

        let fee_ref = sc.take_immutable<ProtocolFeeRef>();
        let clk     = clock::create_for_testing(sc.ctx());
        let asset   = mk_demo_asset(sc.ctx());

        let cap = escrow_coordinator::integrate<DemoAsset, SUI>(
            asset, cfg, &fee_ref, &clk, sc.ctx(),
        );
        let escrow_id = owner_cap::escrow_id(&cap);

        clock::destroy_for_testing(clk);
        test_scenario::return_immutable(fee_ref);
        owner_cap::burn(cap, OWNER);

        sc.next_tx(OWNER);
        let escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);
        assert_tag_idle(&escrow, tag);
        test_scenario::return_shared(escrow);

        c = c + 1;
    };
    sc.end();
}

// ─── §3. take/put discipline ─────────────────────────────────────────────────

/// The take_state/put_state hot-potato cycle is a no-op on the state
/// (round-trips the `Option<LifecycleState>` value). Verifies the
/// `StateReceipt` discipline mechanically: take produces a receipt;
/// put consumes it; state_tag is unchanged after the cycle.
#[test]
fun take_put_no_op_preserves_state_tag() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let cfg     = escrow_corpus::by_tag(0);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap       = escrow_coordinator::integrate<DemoAsset, SUI>(asset, cfg, &fee_ref, &clk, sc.ctx());
    let escrow_id = owner_cap::escrow_id(&cap);

    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);

    assert_tag_idle(&escrow, 0);
    escrow_coordinator::take_put_no_op_for_testing(&mut escrow);
    assert_tag_idle(&escrow, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §4. split_fee — pure 90/10 split ─────────────────────────────────────────

#[test]
fun split_fee_partitions_into_owner_share_plus_protocol_fee() {
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(10_000_000_000);
    // 10 SUI * 10% protocol fee = 1 SUI fee, 9 SUI owner.
    assert_eq!(fee_amt,   1_000_000_000);
    assert_eq!(owner_amt, 9_000_000_000);
}

#[test]
fun split_fee_floors_to_zero_below_threshold() {
    // Below 10 base units, mul_div(amount, 1000, 10000) = 0.
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(9);
    assert_eq!(fee_amt,   0);
    assert_eq!(owner_amt, 9);
}

#[test]
fun split_fee_zero_in_zero_out() {
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(0);
    assert_eq!(fee_amt,   0);
    assert_eq!(owner_amt, 0);
}

#[test]
fun split_fee_exact_threshold_yields_one_fee() {
    // mul_div(10, 1000, 10000) = 1.
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(10);
    assert_eq!(fee_amt,   1);
    assert_eq!(owner_amt, 9);
}
