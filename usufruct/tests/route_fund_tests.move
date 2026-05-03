// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

// Cross-block deferred initialisation requires `mut` even for single-assignment
// variables. Move's compiler warns W09012 (unused mut) in these cases — suppressed
// here because the mut is syntactically required, not stylistically optional.
#[allow(unused_let_mut)]
#[test_only]
module usufruct::route_fund_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    coin,
    event,
    test_scenario,
};
use usufruct::{
    fee_message::{Self, FeeMessage, FeeMessageSent},
    protocol_fee_inbox::{Self, ProtocolFeeInbox},
    route_fund,
    tenant_state,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

/// Tenant identity constants — fixed across all tests for cross-test legibility.
const DEPLOYER:    address = @0xD1;
const ADMIN:       address = @0xAD;
const TENANT_ADDR: address = @0xA1;
const CALLER:      address = @0xCA;

fun cap_id():         ID { object::id_from_address(@0xC1) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }
fun fake_inbox_id():  ID { object::id_from_address(@0x1B) }

/// Build a `Tenant` with the given stake. Pure — no ctx required.
fun tenant(stake: u64): tenant_state::Tenant<TEST_COIN> {
    tenant_state::new_tenant(cap_id(), TENANT_ADDR, balance::create_for_testing(stake))
}

// ─── §1. Return value identity ─────────────────────────────────────────────────
// route must return the Tenant's original identity unchanged.
// The caller uses (cap_id, addr) to emit lifecycle events; corruption here
// silently mislabels every downstream event.

#[test]
fun i1_returned_cap_id_matches_tenant() {
    let mut sc = test_scenario::begin(CALLER);
    let (returned_cap, _) = route_fund::route(
        tenant(1_000), 300, fake_escrow_id(), fake_inbox_id(), sc.ctx(),
    );
    assert_eq!(returned_cap, cap_id());
    sc.end();
}

#[test]
fun i2_returned_addr_matches_tenant() {
    let mut sc = test_scenario::begin(CALLER);
    let (_, returned_addr) = route_fund::route(
        tenant(1_000), 300, fake_escrow_id(), fake_inbox_id(), sc.ctx(),
    );
    assert_eq!(returned_addr, TENANT_ADDR);
    sc.end();
}

// ─── §2. Fee routing ───────────────────────────────────────────────────────────
// The fee_amount must arrive at the inbox exactly as posted.
// Under-posting deprives the protocol; over-posting steals from the tenant.

#[test]
fun f1_fee_amount_matches_sent_event() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(1_000), 300, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_amount(&sent[0]), 300);
    };
    sc.end();
}

#[test]
fun f3_fee_inbox_id_preserved_in_event() {
    let mut sc = test_scenario::begin(CALLER);
    let inbox_id = fake_inbox_id();
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(500), 100, fake_escrow_id(), inbox_id, sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        assert_eq!(fee_message::sent_fee_inbox_id(&sent[0]), inbox_id);
    };
    sc.end();
}

#[test]
fun f4_escrow_id_preserved_in_event() {
    let mut sc = test_scenario::begin(CALLER);
    let escrow_id = fake_escrow_id();
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(500), 100, escrow_id, fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        assert_eq!(fee_message::sent_escrow_id(&sent[0]), escrow_id);
    };
    sc.end();
}

#[test]
fun f5_exactly_one_fee_event_per_route_call() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(1_000), 400, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        assert_eq!(event::events_by_type<FeeMessageSent<TEST_COIN>>().length(), 1);
    };
    sc.end();
}

// ─── §3. Refund routing ────────────────────────────────────────────────────────
// The remainder after the fee split must arrive at the tenant's address as a Coin.
// A routing error here is a direct loss for the tenant.

#[test]
fun r1_refund_coin_arrives_at_tenant_address() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(1_000), 300, fake_escrow_id(), fake_inbox_id(), sc.ctx());
    };
    sc.next_tx(TENANT_ADDR);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), 700);
        transfer::public_transfer(coin, TENANT_ADDR);
    };
    sc.end();
}

#[test]
fun r2_refund_value_equals_stake_minus_fee() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(2_000), 800, fake_escrow_id(), fake_inbox_id(), sc.ctx());
    };
    sc.next_tx(TENANT_ADDR);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), 1_200);
        transfer::public_transfer(coin, TENANT_ADDR);
    };
    sc.end();
}

// ─── §4. Balance conservation ──────────────────────────────────────────────────
// fee_posted + refund_received == original_stake.
// This invariant must hold regardless of how the split is parameterised —
// no satoshi is created or destroyed in transit.

#[test]
fun c1_fee_plus_refund_equals_stake() {
    let stake: u64 = 3_000;
    let fee:   u64 = 900;
    let mut sc = test_scenario::begin(CALLER);
    let mut fee_actual: u64;
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(stake), fee, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        fee_actual = fee_message::sent_amount(&sent[0]);
    };
    sc.next_tx(TENANT_ADDR);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        let refund_actual = coin::value(&coin);
        assert_eq!(fee_actual + refund_actual, stake);
        transfer::public_transfer(coin, TENANT_ADDR);
    };
    sc.end();
}

#[test]
fun c2_conservation_holds_at_boundary_amounts() {
    // stake = u64::MAX / 2 to avoid overflow in fee + refund assertion.
    let stake: u64 = 9_223_372_036_854_775_807;
    let fee:   u64 = 1_000_000;
    let mut sc = test_scenario::begin(CALLER);
    let mut fee_actual: u64;
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(stake), fee, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        fee_actual = fee_message::sent_amount(&sent[0]);
    };
    sc.next_tx(TENANT_ADDR);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(fee_actual + coin::value(&coin), stake);
        transfer::public_transfer(coin, TENANT_ADDR);
    };
    sc.end();
}

// ─── §5. Edge cases — expire_tenure vs accept_bid symmetry ────────────────────

// Zero fee: models a protocol-fee waiver. Full stake refunded; a zero-amount
// FeeMessage is still posted so the event log remains complete.
#[test]
fun e1_zero_fee_full_refund_fee_message_still_posted() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(1_000), 0, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_amount(&sent[0]), 0);
    };
    sc.next_tx(TENANT_ADDR);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), 1_000);
        transfer::public_transfer(coin, TENANT_ADDR);
    };
    sc.end();
}

// Full fee: models expire_tenure where the tenant exhausted their credit.
// fee == stake → refund = 0 → no Coin is created or transferred to the tenant.
// Sending a zero Coin would be a dust object on-chain and a gas waste.
#[test]
fun e2_full_fee_zero_refund_no_coin_transferred() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(1_000), 1_000, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        assert_eq!(fee_message::sent_amount(&sent[0]), 1_000);
    };
    sc.next_tx(TENANT_ADDR);
    {
        // No Coin must exist at TENANT_ADDR — the zero guard must have fired.
        assert!(!sc.has_most_recent_for_sender<coin::Coin<TEST_COIN>>());
    };
    sc.end();
}

// Zero stake, zero fee: degenerate case — nothing flows in either direction.
// Both routes carry zero. No Coin transferred; one zero-amount FeeMessage posted.
#[test]
fun e3_zero_stake_zero_fee_no_coin_transferred() {
    let mut sc = test_scenario::begin(CALLER);
    sc.next_tx(CALLER);
    {
        route_fund::route(tenant(0), 0, fake_escrow_id(), fake_inbox_id(), sc.ctx());
        let sent = event::events_by_type<FeeMessageSent<TEST_COIN>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_amount(&sent[0]), 0);
    };
    sc.next_tx(TENANT_ADDR);
    {
        assert!(!sc.has_most_recent_for_sender<coin::Coin<TEST_COIN>>());
    };
    sc.end();
}

// ─── §6. Abort paths ───────────────────────────────────────────────────────────

// fee_amount > stake: balance::split rejects amounts exceeding the balance.
// This guards against the caller over-charging the fee and silently
// zeroing out the tenant's refund.
#[test]
#[expected_failure]
fun a1_fee_exceeds_stake_aborts() {
    let mut sc = test_scenario::begin(CALLER);
    route_fund::route(
        tenant(500),
        501,
        fake_escrow_id(),
        fake_inbox_id(),
        sc.ctx(),
    );
    sc.end();
}

// fee_amount == stake + 1 at the u64 boundary.
#[test]
#[expected_failure]
fun a2_fee_one_above_max_u64_stake_aborts() {
    let mut sc = test_scenario::begin(CALLER);
    // stake = 0, fee = 1 → split(0, 1) must abort
    route_fund::route(
        tenant(0),
        1,
        fake_escrow_id(),
        fake_inbox_id(),
        sc.ctx(),
    );
    sc.end();
}

// ─── §7. End-to-end — live inbox + tenant Coin ─────────────────────────────────
// Closes the object-level verification gap: proves the FeeMessage is physically
// receivable from the inbox, not just that the event was emitted.
// Also verifies the refund Coin in the same flow — both routes confirmed
// at the object level in one test.

#[test]
fun x1_fee_message_receivable_from_live_inbox_and_refund_arrives_at_tenant() {
    // ── Setup: create a live ProtocolFeeInbox, hand it to ADMIN ──
    let mut sc = test_scenario::begin(DEPLOYER);
    {
        protocol_fee_inbox::init_for_testing(sc.ctx());
    };
    sc.next_tx(DEPLOYER);
    {
        let inbox = sc.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, ADMIN);
    };

    // ── route: use the real inbox ID ──
    // stake=1_000, fee=300 → refund=700
    let mut msg_id: ID;
    sc.next_tx(ADMIN);
    {
        let inbox        = sc.take_from_sender<ProtocolFeeInbox>();
        let real_inbox_id = object::id(&inbox);
        route_fund::route(
            tenant(1_000),
            300,
            fake_escrow_id(),
            real_inbox_id,
            sc.ctx(),
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<TEST_COIN>>()[0]
        );
        sc.return_to_sender(inbox);
    };

    // ── Tenant receives refund Coin ──
    sc.next_tx(TENANT_ADDR);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), 700);
        transfer::public_transfer(coin, TENANT_ADDR);
    };

    // ── Inbox receives FeeMessage — receivable and carries correct balance ──
    sc.next_tx(ADMIN);
    {
        let mut inbox    = sc.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);
        let ticket       = test_scenario::receiving_ticket_by_id<FeeMessage<TEST_COIN>>(msg_id);
        let msg          = fee_message::receive_message_for_testing(&mut inbox, ticket);
        let bal          = fee_message::consume_message_for_testing(msg, fee_inbox_id, ADMIN);
        assert_eq!(balance::value(&bal), 300);
        balance::destroy_for_testing(bal);
        sc.return_to_sender(inbox);
    };
    sc.end();
}
