// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::earnings_message_tests;

use std::unit_test::assert_eq;
use std::string;
use std::type_name;
use sui::{
    balance,
    coin,
    event,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    earnings_inbox::{Self, EarningsInbox},
    earnings_message::{Self, EarningsMessage, EarningsMessagePosted, EarningsMessageCollected},
    escrow_identity,
    earnings_balance,
};

// ─── Actors ──────────────────────────────────────────────────────────────────

const ALICE: address = @0xA1;
const ADMIN: address = @0xAD;

public struct FAKE_USDC has drop {}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Mints an EarningsInbox owned by ADMIN.
fun setup(): Scenario {
    let mut scenario = test_scenario::begin(ADMIN);
    {
        let inbox = earnings_inbox::new_for_testing(scenario.ctx());
        transfer::public_transfer(inbox, ADMIN);
    };
    scenario.next_tx(ADMIN);
    scenario
}

fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }
fun fake_escrow_identity(): escrow_identity::EscrowIdentity { escrow_identity::new(fake_escrow_id()) }

fun earnings<C>(amount: u64): earnings_balance::EarningsBalance<C> {
    earnings_balance::new(balance::create_for_testing<C>(amount))
}

// ─── S — post ────────────────────────────────────────────────────────────────

// S1: post forwards escrow_id, amount, inbox_id to the Posted event.
#[test]
fun s1_post_forwards_fields_to_event() {
    let mut scenario = setup();
    {
        let inbox    = scenario.take_from_sender<EarningsInbox>();
        let inbox_id = object::id(&inbox);
        earnings_message::post<sui::sui::SUI>(
            earnings(99), earnings_inbox::identity(&inbox), fake_escrow_identity(), scenario.ctx(),
        );
        let posted = event::events_by_type<EarningsMessagePosted>();
        assert_eq!(posted.length(), 1);
        assert_eq!(earnings_message::posted_escrow_id(&posted[0]),        fake_escrow_id());
        assert_eq!(earnings_message::posted_earnings_inbox_id(&posted[0]), inbox_id);
        assert_eq!(earnings_message::posted_amount(&posted[0]),           99);
        assert_eq!(earnings_message::posted_coin_type(&posted[0]),
            string::from_ascii(type_name::into_string(type_name::with_defining_ids<sui::sui::SUI>())));
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// S2: post with zero balance does not abort; event amount == 0.
#[test]
fun s2_post_zero_balance_ok() {
    let mut scenario = setup();
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        earnings_message::post<sui::sui::SUI>(
            earnings(0), earnings_inbox::identity(&inbox), fake_escrow_identity(), scenario.ctx(),
        );
        assert_eq!(earnings_message::posted_amount(&event::events_by_type<EarningsMessagePosted>()[0]), 0);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// S3: two posts → two distinct message IDs.
#[test]
fun s3_two_posts_distinct_ids() {
    let mut scenario = setup();
    {
        let inbox    = scenario.take_from_sender<EarningsInbox>();
        let identity = earnings_inbox::identity(&inbox);
        earnings_message::post<sui::sui::SUI>(earnings(500), identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(300), identity, fake_escrow_identity(), scenario.ctx());
        let posted = event::events_by_type<EarningsMessagePosted>();
        assert_eq!(posted.length(), 2);
        assert!(earnings_message::posted_earnings_message_id(&posted[0])
              != earnings_message::posted_earnings_message_id(&posted[1]));
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// S4: SUI and FAKE_USDC posts coexist — distinguished by the coin_type field
//     (the event is non-generic; both share the EarningsMessagePosted type).
#[test]
fun s4_post_sui_and_usdc_coexist() {
    let mut scenario = setup();
    {
        let inbox    = scenario.take_from_sender<EarningsInbox>();
        let identity = earnings_inbox::identity(&inbox);
        earnings_message::post<sui::sui::SUI>(earnings(100), identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<FAKE_USDC>(earnings(200),     identity, fake_escrow_identity(), scenario.ctx());
        let posted = event::events_by_type<EarningsMessagePosted>();
        assert_eq!(posted.length(), 2);
        assert_eq!(earnings_message::posted_coin_type(&posted[0]),
            string::from_ascii(type_name::into_string(type_name::with_defining_ids<sui::sui::SUI>())));
        assert_eq!(earnings_message::posted_coin_type(&posted[1]),
            string::from_ascii(type_name::into_string(type_name::with_defining_ids<FAKE_USDC>())));
        assert_eq!(earnings_message::posted_amount(&posted[0]), 100);
        assert_eq!(earnings_message::posted_amount(&posted[1]), 200);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// S5: u64::MAX balance flows through without overflow.
#[test]
fun s5_post_max_u64() {
    let mut scenario = setup();
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        earnings_message::post<sui::sui::SUI>(
            earnings(18_446_744_073_709_551_615), earnings_inbox::identity(&inbox), fake_escrow_identity(), scenario.ctx(),
        );
        assert_eq!(earnings_message::posted_amount(&event::events_by_type<EarningsMessagePosted>()[0]),
            18_446_744_073_709_551_615);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── R/C — receive + consume ─────────────────────────────────────────────────

// R1: receive_message returns the message; consume returns its balance + event.
#[test]
fun r1_receive_consume_returns_balance_and_event() {
    let mut scenario = setup();
    let msg_id;
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        earnings_message::post<sui::sui::SUI>(
            earnings(777), earnings_inbox::identity(&inbox), fake_escrow_identity(), scenario.ctx(),
        );
        msg_id = earnings_message::posted_earnings_message_id(&event::events_by_type<EarningsMessagePosted>()[0]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let inbox_id  = object::id(&inbox);
        let ticket    = test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(msg_id);
        let msg       = earnings_message::receive_message_for_testing(&mut inbox, ticket);
        let bal       = earnings_message::consume_message_for_testing(msg, inbox_id, ADMIN);
        assert_eq!(balance::value(&bal), 777);
        balance::destroy_for_testing(bal);

        let coll = event::events_by_type<EarningsMessageCollected>();
        assert_eq!(earnings_message::collected_earnings_message_id(&coll[0]), msg_id);
        assert_eq!(earnings_message::collected_earnings_inbox_id(&coll[0]),   inbox_id);
        assert_eq!(earnings_message::collected_amount(&coll[0]),              777);
        assert_eq!(earnings_message::collected_collector(&coll[0]),           ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── D — collect_earnings_messages ───────────────────────────────────────────

// D1: empty vector → zero coin, no Collected events.
#[test]
fun d1_collect_empty_returns_zero() {
    let mut scenario = setup();
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let coin = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox, vector[], scenario.ctx());
        assert_eq!(coin::value(&coin), 0);
        assert_eq!(event::events_by_type<EarningsMessageCollected>().length(), 0);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// D2: N tickets → coin == sum of balances; N Collected events.
#[test]
fun d2_collect_n_sums_balances() {
    let mut scenario = setup();
    let id1; let id2; let id3;
    {
        let inbox    = scenario.take_from_sender<EarningsInbox>();
        let identity = earnings_inbox::identity(&inbox);
        earnings_message::post<sui::sui::SUI>(earnings(100), identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(200), identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(300), identity, fake_escrow_identity(), scenario.ctx());
        let posted = event::events_by_type<EarningsMessagePosted>();
        id1 = earnings_message::posted_earnings_message_id(&posted[0]);
        id2 = earnings_message::posted_earnings_message_id(&posted[1]);
        id3 = earnings_message::posted_earnings_message_id(&posted[2]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id3),
        ];
        let coin = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 600);
        assert_eq!(event::events_by_type<EarningsMessageCollected>().length(), 3);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// D3: collector follows custody — drain by ALICE yields collector == ALICE.
#[test]
fun d3_collector_follows_custody() {
    let mut scenario = setup();
    let msg_id;
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        earnings_message::post<sui::sui::SUI>(
            earnings(50), earnings_inbox::identity(&inbox), fake_escrow_identity(), scenario.ctx(),
        );
        msg_id = earnings_message::posted_earnings_message_id(&event::events_by_type<EarningsMessagePosted>()[0]);
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let ticket    = test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(msg_id);
        let coin      = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox, vector[ticket], scenario.ctx());
        assert_eq!(coin::value(&coin), 50);
        assert_eq!(earnings_message::collected_collector(&event::events_by_type<EarningsMessageCollected>()[0]), ALICE);
        transfer::public_transfer(coin, ALICE);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// D4: distinct escrow_ids are bound to distinct message_ids at post (EarningsMessagePosted),
//     and Collected preserves those distinct message_ids — escrow attribution survives by
//     joining Collected.earnings_message_id → Posted.escrow_id (star schema).
#[test]
fun d4_distinct_escrow_ids_preserved_via_posted_join_key() {
    let mut scenario = setup();
    let esc1 = object::id_from_address(@0xEC1);
    let esc2 = object::id_from_address(@0xEC2);
    let id1; let id2;
    {
        let inbox    = scenario.take_from_sender<EarningsInbox>();
        let identity = earnings_inbox::identity(&inbox);
        earnings_message::post<sui::sui::SUI>(earnings(10), identity, escrow_identity::new(esc1), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(20), identity, escrow_identity::new(esc2), scenario.ctx());
        let posted = event::events_by_type<EarningsMessagePosted>();
        id1 = earnings_message::posted_earnings_message_id(&posted[0]);
        id2 = earnings_message::posted_earnings_message_id(&posted[1]);
        // Source of truth: distinct escrow_ids bound to distinct message_ids at post.
        assert_eq!(earnings_message::posted_escrow_id(&posted[0]), esc1);
        assert_eq!(earnings_message::posted_escrow_id(&posted[1]), esc2);
        assert!(earnings_message::posted_escrow_id(&posted[0]) != earnings_message::posted_escrow_id(&posted[1]));
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id2),
        ];
        let coin = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 30);
        let coll = event::events_by_type<EarningsMessageCollected>();
        // Distinct join keys preserved → each joins back to its distinct posted escrow_id.
        assert!(earnings_message::collected_earnings_message_id(&coll[0]) != earnings_message::collected_earnings_message_id(&coll[1]));
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── P — security ────────────────────────────────────────────────────────────

// P1: a ticket for inbox A presented to inbox B aborts (transfer::receive parent check).
#[test, expected_failure]
fun p1_cross_inbox_ticket_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    {
        let inbox_a = earnings_inbox::new_for_testing(scenario.ctx());
        transfer::public_transfer(inbox_a, ADMIN);
    };
    scenario.next_tx(ADMIN);
    {
        let inbox_b = earnings_inbox::new_for_testing(scenario.ctx());
        transfer::public_transfer(inbox_b, ALICE);
    };
    let msg_id;
    scenario.next_tx(ADMIN);
    {
        let inbox_a = scenario.take_from_sender<EarningsInbox>();
        earnings_message::post<sui::sui::SUI>(
            earnings(1), earnings_inbox::identity(&inbox_a), fake_escrow_identity(), scenario.ctx(),
        );
        msg_id = earnings_message::posted_earnings_message_id(&event::events_by_type<EarningsMessagePosted>()[0]);
        scenario.return_to_sender(inbox_a);
    };
    scenario.next_tx(ALICE);
    {
        let mut inbox_b = scenario.take_from_sender<EarningsInbox>();
        let ticket = test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(msg_id);
        let coin = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox_b, vector[ticket], scenario.ctx());
        transfer::public_transfer(coin, ALICE);
        scenario.return_to_sender(inbox_b);
    };
    scenario.end();
}

// P2: message UID is deleted on drain.
#[test]
fun p2_uid_deleted_on_drain() {
    let mut scenario = setup();
    let msg_id;
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        earnings_message::post<sui::sui::SUI>(
            earnings(1), earnings_inbox::identity(&inbox), fake_escrow_identity(), scenario.ctx(),
        );
        msg_id = earnings_message::posted_earnings_message_id(&event::events_by_type<EarningsMessagePosted>()[0]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let ticket    = test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(msg_id);
        let coin = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox, vector[ticket], scenario.ctx());
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    let effects = scenario.end();
    assert!(effects.deleted().contains(&msg_id));
}

// ─── I — balance invariant ───────────────────────────────────────────────────

// I1: total drained == total posted across a mixed batch.
#[test]
fun i1_total_drained_equals_posted() {
    let mut scenario = setup();
    let id0; let id1; let id2; let id3;
    {
        let inbox    = scenario.take_from_sender<EarningsInbox>();
        let identity = earnings_inbox::identity(&inbox);
        earnings_message::post<sui::sui::SUI>(earnings(0),   identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(250), identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(50),  identity, fake_escrow_identity(), scenario.ctx());
        earnings_message::post<sui::sui::SUI>(earnings(700), identity, fake_escrow_identity(), scenario.ctx());
        let posted = event::events_by_type<EarningsMessagePosted>();
        id0 = earnings_message::posted_earnings_message_id(&posted[0]);
        id1 = earnings_message::posted_earnings_message_id(&posted[1]);
        id2 = earnings_message::posted_earnings_message_id(&posted[2]);
        id3 = earnings_message::posted_earnings_message_id(&posted[3]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<EarningsInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id0),
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<EarningsMessage<sui::sui::SUI>>(id3),
        ];
        let coin = earnings_message::collect_earnings_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 1_000);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}
