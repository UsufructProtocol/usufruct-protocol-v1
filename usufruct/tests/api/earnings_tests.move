// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::earnings_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    clock,
    coin::{Self, Coin},
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    asset_state::{Self, AssetIntegrated},
    earnings,
    earnings_message::{Self, EarningsMessage, EarningsPosted, EarningsCollected},
    escrow::{Self, Escrow},
    escrow_corpus,
    ensemble_commitment_policy,
    retire_commitment_policy,
    tenures,
    phases,
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER: address = @0x07;

public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset { DemoAsset { id: object::new(ctx) } }

fun mk_payment(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::from_balance(balance::create_for_testing<SUI>(amount), ctx)
}

fun setup(): Scenario {
    let mut sc = test_scenario::begin(@0x0);
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

/// Rent one tenure at the rest-price floor, then force tenure expiry — the path
/// that settles the owner's 90% share to the inbox as an EarningsMessage.
/// Returns the message id posted (read from the EarningsPosted event).
fun rent_and_expire(escrow: &mut Escrow<DemoAsset, SUI>, sc: &mut Scenario): ID {
    let clk       = clock::create_for_testing(sc.ctx());
    let principal = escrow_corpus::min_rent_price_const();
    let cap_t1    = escrow::rent(escrow, mk_payment(principal, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::fire_do_tenure_expiry_for_testing(
        escrow, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );
    clock::destroy_for_testing(clk);
    transfer::public_transfer(cap_t1, OWNER);
    let posted = event::events_by_type<EarningsPosted<SUI>>();
    earnings_message::posted_earnings_message_id(&posted[posted.length() - 1])
}

fun owner_share(): u64 {
    let p = escrow_corpus::min_rent_price_const();
    p - p / 10
}

// ─── E1 — single escrow: settle → collect via the api wrapper ─────────────────

// The owner's tenure share is mailed to the inbox; collect_earnings_messages
// drains it into a coin of exactly that share, and the EarningsCollected event
// attributes the income to its source escrow (star schema).
#[test]
fun e1_collect_drains_owner_share_after_tenure() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        mk_demo_asset(sc.ctx()), escrow_corpus::by_tag(0),
        retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(),
        &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = asset_state::asset_integrated_escrow_id(&event::events_by_type<AssetIntegrated>()[0]);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let msg_id     = rent_and_expire(&mut escrow, &mut sc);
    test_scenario::return_shared(escrow);

    sc.next_tx(OWNER);
    let mut inbox = inbox;
    let ticket = test_scenario::receiving_ticket_by_id<EarningsMessage<SUI>>(msg_id);
    let coin   = earnings::collect_earnings_messages<SUI>(&mut inbox, vector[ticket], sc.ctx());
    assert_eq!(coin::value(&coin), owner_share());

    let collected = event::events_by_type<EarningsCollected<SUI>>();
    assert_eq!(collected.length(), 1);
    assert_eq!(earnings_message::collected_amount(&collected[0]),    owner_share());
    assert_eq!(earnings_message::collected_escrow_id(&collected[0]), escrow_id);
    assert_eq!(earnings_message::collected_collector(&collected[0]), OWNER);

    transfer::public_transfer(coin, OWNER);
    transfer::public_transfer(inbox, OWNER);
    transfer::public_transfer(cap, OWNER);
    sc.end();
}

// ─── E2 — portfolio: two escrows → one inbox → collect both ───────────────────

// Fleet consolidation: a second escrow joins the portfolio via
// integrate_into_portfolio, routing its income to the same inbox. After both
// settle, a single collect drains both messages into one coin == 2× share, and
// the two EarningsCollected events carry distinct source escrow ids.
#[test]
fun e2_portfolio_two_escrows_one_inbox_collect_both() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());

    let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        mk_demo_asset(sc.ctx()), escrow_corpus::by_tag(0),
        retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(),
        &fee_ref, &clk, sc.ctx(),
    );
    escrow::integrate_into_portfolio<DemoAsset, SUI>(
        mk_demo_asset(sc.ctx()), escrow_corpus::by_tag(0),
        retire_commitment_policy::new_immediate(), ensemble_commitment_policy::new_immediate(),
        &fee_ref, &cap, &inbox, &clk, sc.ctx(),
    );
    let integ = event::events_by_type<AssetIntegrated>();
    assert_eq!(integ.length(), 2);
    let id1 = asset_state::asset_integrated_escrow_id(&integ[0]);
    let id2 = asset_state::asset_integrated_escrow_id(&integ[1]);
    // Both escrows route income to the same inbox under the same cap.
    assert_eq!(asset_state::asset_integrated_earnings_inbox_id(&integ[1]), object::id(&inbox));
    assert_eq!(asset_state::asset_integrated_owner_cap_id(&integ[1]),      object::id(&cap));
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let mut e1  = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(id1);
    let msg1    = rent_and_expire(&mut e1, &mut sc);
    test_scenario::return_shared(e1);

    sc.next_tx(OWNER);
    let mut e2  = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(id2);
    let msg2    = rent_and_expire(&mut e2, &mut sc);
    test_scenario::return_shared(e2);

    sc.next_tx(OWNER);
    let mut inbox = inbox;
    let tickets = vector[
        test_scenario::receiving_ticket_by_id<EarningsMessage<SUI>>(msg1),
        test_scenario::receiving_ticket_by_id<EarningsMessage<SUI>>(msg2),
    ];
    let coin = earnings::collect_earnings_messages<SUI>(&mut inbox, tickets, sc.ctx());
    assert_eq!(coin::value(&coin), owner_share() * 2);

    let collected = event::events_by_type<EarningsCollected<SUI>>();
    assert_eq!(collected.length(), 2);
    assert!(earnings_message::collected_escrow_id(&collected[0])
          != earnings_message::collected_escrow_id(&collected[1]));

    transfer::public_transfer(coin, OWNER);
    transfer::public_transfer(inbox, OWNER);
    transfer::public_transfer(cap, OWNER);
    sc.end();
}
