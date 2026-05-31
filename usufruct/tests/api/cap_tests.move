// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::cap_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    clock,
    coin,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    cap,
    ensemble_commitment_policy,
    retire_commitment_policy,
    escrow::{Self, Escrow},
    escrow_corpus,
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    tenures,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER:       address = @0x07;
const TENANT_ADDR: address = @0xA1;
const STAKE:       u64     = 10_000_000_000;

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

// ─── CT — cap::tenant_cap_escrow_id ───────────────────────────────────────────

// CT1: tenant_cap_escrow_id returns the escrow ID after rent.
#[test]
fun ct1_tenant_cap_escrow_id_matches_escrow() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble  = escrow_corpus::by_tag(0); // handover=off, descent=off
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
    let escrow_id  = object::id(&escrow);
    let fee_ref2   = sc.take_immutable<ProtocolFeeRef>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = mk_payment(STAKE, sc.ctx());

    let tenant_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, tenures::tenures(1), &clk2, sc.ctx(),
    );

    assert_eq!(cap::tenant_cap_escrow_id(&tenant_cap), escrow_id);

    test_scenario::return_shared(escrow);
    test_scenario::return_immutable(fee_ref2);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(tenant_cap, TENANT_ADDR);
    transfer::public_transfer(owner_cap, OWNER);
    sc.end();
}

// CT2: tenant cap points at the shared escrow it was minted against.
#[test]
fun ct2_tenant_cap_matches_escrow_object() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble  = escrow_corpus::by_tag(0);
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
    let escrow_id  = object::id(&escrow);
    let fee_ref2   = sc.take_immutable<ProtocolFeeRef>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = mk_payment(STAKE, sc.ctx());

    let tenant_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, tenures::tenures(1), &clk2, sc.ctx(),
    );

    assert_eq!(cap::tenant_cap_escrow_id(&tenant_cap), escrow_id);

    test_scenario::return_shared(escrow);
    test_scenario::return_immutable(fee_ref2);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(tenant_cap, TENANT_ADDR);
    transfer::public_transfer(owner_cap, OWNER);
    sc.end();
}
