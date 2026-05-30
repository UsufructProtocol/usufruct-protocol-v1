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
    owner_cap,
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

// ─── CA — cap::owner_cap_escrow_id ────────────────────────────────────────────

// CA1: owner_cap_escrow_id returns the same ID as the internal projector.
#[test]
fun ca1_owner_cap_escrow_id_matches_internal_projector() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble  = escrow_corpus::by_tag(0);
    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());

    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );

    assert_eq!(cap::owner_cap_escrow_id(&cap), owner_cap::proj_escrow_id(&cap));

    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// CA2: owner_cap_escrow_id matches the shared Escrow object ID.
#[test]
fun ca2_owner_cap_escrow_id_matches_escrow_object() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble  = escrow_corpus::by_tag(0);
    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());

    let cap       = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = cap::owner_cap_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    assert_eq!(escrow::asset_id(&escrow), escrow::asset_id(&escrow)); // escrow is reachable by cap ID

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
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

    let owner_cap = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(TENANT_ADDR);
    let mut escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
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
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

// CT2: owner and tenant caps both point to the same escrow.
#[test]
fun ct2_owner_and_tenant_caps_share_escrow_id() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble  = escrow_corpus::by_tag(0);
    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());

    let owner_cap = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = cap::owner_cap_escrow_id(&owner_cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(TENANT_ADDR);
    let mut escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    let fee_ref2   = sc.take_immutable<ProtocolFeeRef>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = mk_payment(STAKE, sc.ctx());

    let tenant_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, tenures::tenures(1), &clk2, sc.ctx(),
    );

    assert_eq!(
        cap::tenant_cap_escrow_id(&tenant_cap),
        cap::owner_cap_escrow_id(&owner_cap),
    );

    test_scenario::return_shared(escrow);
    test_scenario::return_immutable(fee_ref2);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(tenant_cap, TENANT_ADDR);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

// CT3: Two independent escrows produce distinct IDs from their respective caps.
#[test]
fun ct3_two_escrows_produce_distinct_cap_ids() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble = escrow_corpus::by_tag(0);
    let fee_ref  = sc.take_immutable<ProtocolFeeRef>();

    let clk1  = clock::create_for_testing(sc.ctx());
    let asset1 = mk_demo_asset(sc.ctx());
    let cap1   = escrow::integrate<DemoAsset, SUI>(
        asset1, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk1, sc.ctx(),
    );
    clock::destroy_for_testing(clk1);

    let clk2  = clock::create_for_testing(sc.ctx());
    let asset2 = mk_demo_asset(sc.ctx());
    let cap2   = escrow::integrate<DemoAsset, SUI>(
        asset2, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk2, sc.ctx(),
    );
    clock::destroy_for_testing(clk2);

    assert!(cap::owner_cap_escrow_id(&cap1) != cap::owner_cap_escrow_id(&cap2), 0);

    test_scenario::return_immutable(fee_ref);
    owner_cap::burn(cap1, OWNER);
    owner_cap::burn(cap2, OWNER);
    sc.end();
}
