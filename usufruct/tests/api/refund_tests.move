// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::refund_tests;

use std::unit_test::assert_eq;
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
    escrow::{Self, Escrow},
    escrow_corpus,
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    refund,
    refund_address,
    tenures,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER:        address = @0x07;
const TENANT_ADDR:  address = @0xA1;
const NEW_REFUND:   address = @0xCAFE;
const STAKE:        u64     = 10_000_000_000;

public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

fun mk_payment(amount: u64, ctx: &mut TxContext): coin::Coin<SUI> {
    coin::from_balance(balance::create_for_testing<SUI>(amount), ctx)
}

fun setup(): Scenario {
    let mut sc = test_scenario::begin(@0x0);
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

// ─── R — refund::refund_address ───────────────────────────────────────────────

// R1: the public wrapper roundtrips the input address — proves the value-type
// boundary is intact (no accidental rewriting of the field during the delegation).
#[test]
fun r1_refund_address_roundtrips_input() {
    let r = refund::refund_address(NEW_REFUND);
    assert_eq!(refund_address::addr(r), NEW_REFUND);
}

// R2: the wrapper output is accepted by escrow::update_tenant_refund_address —
// the real reason this module exists: to expose a PTB-reachable constructor
// for the typed argument that the public api consumes.
#[test]
fun r2_refund_address_feeds_update_tenant_refund_address() {
    let mut sc = setup();
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

    sc.next_tx(TENANT_ADDR);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = mk_payment(STAKE, sc.ctx());
    let tenant_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, tenures::tenures(1), &clk2, sc.ctx(),
    );

    // The whole point: the wrapper output is the typed argument the api consumes.
    escrow::update_tenant_refund_address(
        &mut escrow, &tenant_cap, refund::refund_address(NEW_REFUND), &clk2, sc.ctx(),
    );

    // The seat now reflects the redirected address.
    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(), NEW_REFUND);

    transfer::public_transfer(tenant_cap, TENANT_ADDR);
    test_scenario::return_shared(escrow);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(owner_cap, OWNER);
    sc.end();
}

// R3: the wrapper output is accepted on the pending seat too — mirrors R2 for
// the Demand → bid.pending branch of the dispatch. The active address stays
// pinned, confirming branch isolation when the call goes through the wrapper.
#[test]
fun r3_refund_address_feeds_update_on_pending_seat() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    // c=1 (Fixed handover) — keeps the bid pending instead of resolving handover.
    let ensemble  = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());
    let (owner_cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(TENANT_ADDR);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let clk2       = clock::create_for_testing(sc.ctx());

    let payment1 = mk_payment(STAKE, sc.ctx());
    let cap_t1   = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment1, tenures::tenures(1), &clk2, sc.ctx(),
    );
    let payment2 = mk_payment(STAKE * 2, sc.ctx());
    let cap_t2   = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment2, tenures::tenures(1), &clk2, sc.ctx(),
    );
    assert!(escrow::is_demand(&escrow), 0);

    let active_before = *escrow::active_tenant_addr(&escrow).borrow();

    escrow::update_tenant_refund_address(
        &mut escrow, &cap_t2, refund::refund_address(NEW_REFUND), &clk2, sc.ctx(),
    );

    assert_eq!(*escrow::pending_tenant_addr(&escrow).borrow(), NEW_REFUND);
    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(),  active_before);

    transfer::public_transfer(cap_t1, TENANT_ADDR);
    transfer::public_transfer(cap_t2, TENANT_ADDR);
    test_scenario::return_shared(escrow);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(owner_cap, OWNER);
    sc.end();
}
