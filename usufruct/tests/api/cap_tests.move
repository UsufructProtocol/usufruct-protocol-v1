// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::cap_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    clock,
    coin,
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    cap,
    ensemble_commitment_policy,
    retire_commitment_policy,
    escrow::{Self, Escrow},
    escrow_corpus,
    governance_cap::{Self, GovernanceCapBurned},
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    tenures,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const GOVERNOR:       address = @0x07;
const USUFRUCTUARY_ADDR: address = @0xA1;
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
    sc.next_tx(GOVERNOR);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

// ─── CT — cap::usufruct_cap_escrow_id ───────────────────────────────────────────

// CT1: usufruct_cap_escrow_id returns the escrow ID after rent.
#[test]
fun ct1_usufruct_cap_escrow_id_matches_escrow() {
    let mut sc = setup();
    sc.next_tx(GOVERNOR);

    let ensemble  = escrow_corpus::by_tag(0); // handover=off, descent=off
    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());

    let (governance_cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, GOVERNOR);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let escrow_id  = object::id(&escrow);
    let fee_ref2   = sc.take_immutable<ProtocolFeeRef>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = mk_payment(STAKE, sc.ctx());

    let usufruct_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, tenures::tenures(1), &clk2, sc.ctx(),
    );

    assert_eq!(cap::usufruct_cap_escrow_id(&usufruct_cap), escrow_id);

    test_scenario::return_shared(escrow);
    test_scenario::return_immutable(fee_ref2);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(usufruct_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(governance_cap, GOVERNOR);
    sc.end();
}

// ─── RG — cap::renounce_governance ────────────────────────────────────────────

// RG1: renounce_governance consumes the GovernanceCap and emits one GovernanceCapBurned
//      recording the cap's id and the sender (the renouncing governor). After this
//      tx the cap no longer exists — retire/update_ensemble/claim_asset over its
//      escrows are forever unreachable (the call cannot even be constructed).
#[test]
fun rg1_renounce_governance_burns_cap_and_emits() {
    let mut sc = setup();
    sc.next_tx(GOVERNOR);

    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let (governance_cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        mk_demo_asset(sc.ctx()), escrow_corpus::by_tag(0),
        retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(),
        &fee_ref, &clk, sc.ctx(),
    );
    let cap_id = object::id(&governance_cap);
    transfer::public_transfer(inbox, GOVERNOR);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(GOVERNOR);
    cap::renounce_governance(governance_cap, sc.ctx());

    let events = event::events_by_type<GovernanceCapBurned>();
    assert_eq!(events.length(), 1);
    assert_eq!(governance_cap::burned_governance_cap_id(&events[0]),  cap_id);
    assert_eq!(governance_cap::burned_governor_address(&events[0]), GOVERNOR);
    sc.end();
}

// CT2: usufructuary cap points at the shared escrow it was minted against.
#[test]
fun ct2_usufruct_cap_matches_escrow_object() {
    let mut sc = setup();
    sc.next_tx(GOVERNOR);

    let ensemble  = escrow_corpus::by_tag(0);
    let fee_ref   = sc.take_immutable<ProtocolFeeRef>();
    let clk       = clock::create_for_testing(sc.ctx());
    let asset     = mk_demo_asset(sc.ctx());

    let (governance_cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, GOVERNOR);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let escrow_id  = object::id(&escrow);
    let fee_ref2   = sc.take_immutable<ProtocolFeeRef>();
    let clk2       = clock::create_for_testing(sc.ctx());
    let payment    = mk_payment(STAKE, sc.ctx());

    let usufruct_cap = escrow::rent<DemoAsset, SUI>(
        &mut escrow, payment, tenures::tenures(1), &clk2, sc.ctx(),
    );

    assert_eq!(cap::usufruct_cap_escrow_id(&usufruct_cap), escrow_id);

    test_scenario::return_shared(escrow);
    test_scenario::return_immutable(fee_ref2);
    clock::destroy_for_testing(clk2);
    transfer::public_transfer(usufruct_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(governance_cap, GOVERNOR);
    sc.end();
}
