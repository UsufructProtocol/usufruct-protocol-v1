// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::fee_message_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    coin,
    event,
    object,
    test_scenario::{Self, Scenario},
    transfer,
};
use usufruct::{
    fee_message::{Self, FeeMessage, FeeMessageSent, FeeMessageCollected},
    protocol_fee_inbox::{Self, ProtocolFeeInbox},
};

// ─── Actors ────────────────────────────────────────────────────────────────

const DEPLOYER: address = @0xD1;
const ALICE:    address = @0xA1;
const BOB:      address = @0xB0;
const ADMIN:    address = @0xAD;

// ─── Test-only coin witness ─────────────────────────────────────────────────

public struct FAKE_USDC has drop {}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Sets up a ProtocolFeeInbox owned by ADMIN.
fun setup(): Scenario {
    let mut scenario = test_scenario::begin(DEPLOYER);
    {
        protocol_fee_inbox::init_for_testing(scenario.ctx());
    };
    scenario.next_tx(DEPLOYER);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, ADMIN);
    };
    scenario
}

fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }
fun fake_inbox_id():  ID { object::id_from_address(@0x1B) }

// Convenience: post to real inbox owned by ADMIN, returns the msg_id from the Sent event.
// Caller must be in ADMIN's tx context.
fun post_to_real_inbox(
    inbox:    &mut ProtocolFeeInbox,
    amount:   u64,
    tenant:   address,
    scenario: &mut Scenario,
): ID {
    let fee_inbox_id = object::id(inbox);
    fee_message::post<sui::sui::SUI>(
        balance::create_for_testing(amount),
        fake_escrow_id(),
        tenant,
        fee_inbox_id,
        scenario.ctx(),
    );
    // Return the sent event's fee_message_id so callers can build a receiving ticket.
    // Because post was just called, events_by_type returns all Sent events in this tx.
    // The last element is the one we just posted.
    let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
    fee_message::sent_fee_message_id(&sent[sent.length() - 1])
}

// ─── S — post ──────────────────────────────────────────────────────────────

#[test]
fun s1_post_creates_child_with_correct_fields() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(1_000),
            fake_escrow_id(),
            ALICE,
            fake_inbox_id(),
            scenario.ctx(),
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_fee_inbox_id(&sent[0]), fake_inbox_id());
        assert_eq!(fee_message::sent_escrow_id(&sent[0]),    fake_escrow_id());
        assert_eq!(fee_message::sent_amount(&sent[0]),        1_000);
        assert_eq!(fee_message::sent_tenant(&sent[0]),        ALICE);
    };
    scenario.end();
}

#[test]
fun s2_post_with_zero_balance_does_not_abort() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(0),
            fake_escrow_id(),
            ALICE,
            fake_inbox_id(),
            scenario.ctx(),
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_amount(&sent[0]), 0);
    };
    scenario.end();
}

#[test]
fun s3_post_twice_creates_two_distinct_messages() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        let escrow_id    = fake_escrow_id();
        let fee_inbox_id = fake_inbox_id();
        fee_message::post<sui::sui::SUI>(balance::create_for_testing(500), escrow_id, ALICE, fee_inbox_id, scenario.ctx());
        fee_message::post<sui::sui::SUI>(balance::create_for_testing(300), escrow_id, BOB,   fee_inbox_id, scenario.ctx());
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 2);
        assert!(fee_message::sent_fee_message_id(&sent[0]) != fee_message::sent_fee_message_id(&sent[1]));
        assert_eq!(fee_message::sent_tenant(&sent[0]), ALICE);
        assert_eq!(fee_message::sent_tenant(&sent[1]), BOB);
    };
    scenario.end();
}

#[test]
fun s4_post_sui_and_fake_usdc_no_conflict() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        let fee_inbox_id = fake_inbox_id();
        fee_message::post<sui::sui::SUI>(balance::create_for_testing(100), fake_escrow_id(), ALICE, fee_inbox_id, scenario.ctx());
        fee_message::post<FAKE_USDC>(balance::create_for_testing(200), fake_escrow_id(), ALICE, fee_inbox_id, scenario.ctx());
    };
    scenario.next_tx(ADMIN);
    {
        assert_eq!(event::events_by_type<FeeMessageSent<sui::sui::SUI>>().length(), 1);
        assert_eq!(event::events_by_type<FeeMessageSent<FAKE_USDC>>().length(),     1);
    };
    scenario.end();
}

#[test]
fun s5_tenant_is_declarative_not_sender() {
    let mut scenario = setup();
    // Sender is ALICE but tenant argument is BOB
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(100), fake_escrow_id(), BOB, fake_inbox_id(), scenario.ctx()
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(fee_message::sent_tenant(&sent[0]), BOB);
    };
    scenario.end();
}

#[test]
fun s6_tenant_zero_address_allowed() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(1), fake_escrow_id(), @0x0, fake_inbox_id(), scenario.ctx()
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(fee_message::sent_tenant(&sent[0]), @0x0);
    };
    scenario.end();
}

#[test]
fun s7_escrow_id_is_declarative() {
    let mut scenario = setup();
    let synthetic = object::id_from_address(@0xDEAD);
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(1), synthetic, ALICE, fake_inbox_id(), scenario.ctx()
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(fee_message::sent_escrow_id(&sent[0]), synthetic);
    };
    scenario.end();
}

#[test]
fun s9_post_with_max_u64_balance() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(18_446_744_073_709_551_615),
            fake_escrow_id(), ALICE, fake_inbox_id(), scenario.ctx(),
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(fee_message::sent_amount(&sent[0]), 18_446_744_073_709_551_615);
    };
    scenario.end();
}

// ─── R — receive_message ───────────────────────────────────────────────────

#[test]
fun r1_receive_message_returns_correct_balance() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let msg_id       = post_to_real_inbox(&mut inbox, 777, ALICE, &mut scenario);
        let ticket       = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let msg          = fee_message::receive_message_for_testing(&mut inbox, ticket);
        // Verify balance by consuming — receive delivers the correct FeeMessage
        let bal = fee_message::consume_message_for_testing(msg, object::id(&inbox), ADMIN);
        assert_eq!(balance::value(&bal), 777);
        balance::destroy_for_testing(bal);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── C — consume_message ───────────────────────────────────────────────────

#[test]
fun c1_consume_message_returns_balance_and_emits_collected_event() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);
        let msg_id       = post_to_real_inbox(&mut inbox, 500, ALICE, &mut scenario);
        let ticket       = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let msg          = fee_message::receive_message_for_testing(&mut inbox, ticket);
        let bal          = fee_message::consume_message_for_testing(msg, fee_inbox_id, ADMIN);
        assert_eq!(balance::value(&bal), 500);
        balance::destroy_for_testing(bal);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 1);
        assert_eq!(fee_message::collected_fee_message_id(&coll[0]), msg_id);
        assert_eq!(fee_message::collected_fee_inbox_id(&coll[0]),   fee_inbox_id);
        assert_eq!(fee_message::collected_escrow_id(&coll[0]),      fake_escrow_id());
        assert_eq!(fee_message::collected_amount(&coll[0]),          500);
        assert_eq!(fee_message::collected_collector(&coll[0]),       ADMIN);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun c2_consume_message_with_arbitrary_scalar_metadata() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let msg_id       = post_to_real_inbox(&mut inbox, 1, ALICE, &mut scenario);
        let ticket       = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let msg          = fee_message::receive_message_for_testing(&mut inbox, ticket);

        let arbitrary_inbox_id = object::id_from_address(@0xAB);
        let bal = fee_message::consume_message_for_testing(msg, arbitrary_inbox_id, @0xDEAD);
        balance::destroy_for_testing(bal);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(fee_message::collected_fee_inbox_id(&coll[0]), arbitrary_inbox_id);
        assert_eq!(fee_message::collected_collector(&coll[0]),    @0xDEAD);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun c3_consume_zero_balance_message() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);
        let msg_id       = post_to_real_inbox(&mut inbox, 0, ALICE, &mut scenario);
        let ticket       = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let msg          = fee_message::receive_message_for_testing(&mut inbox, ticket);
        let bal          = fee_message::consume_message_for_testing(msg, fee_inbox_id, ADMIN);
        assert_eq!(balance::value(&bal), 0);
        balance::destroy_for_testing(bal);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(fee_message::collected_amount(&coll[0]), 0);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── D — collect_fee_messages ──────────────────────────────────────────────

#[test]
fun d1_collect_empty_vector_returns_zero_coin() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[], scenario.ctx()
        );
        assert_eq!(coin::value(&coin), 0);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun d2_collect_one_ticket() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let msg_id    = post_to_real_inbox(&mut inbox, 999, ALICE, &mut scenario);
        let ticket    = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin      = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[ticket], scenario.ctx()
        );
        assert_eq!(coin::value(&coin), 999);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun d3_collect_n_tickets_sums_balances() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let id1 = post_to_real_inbox(&mut inbox, 100, ALICE, &mut scenario);
        let id2 = post_to_real_inbox(&mut inbox, 200, ALICE, &mut scenario);
        let id3 = post_to_real_inbox(&mut inbox, 300, ALICE, &mut scenario);
        let tickets = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id3),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 600);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun d4_collect_sui_and_fake_usdc_same_inbox() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);

        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(111), fake_escrow_id(), ALICE, fee_inbox_id, scenario.ctx()
        );
        fee_message::post<FAKE_USDC>(
            balance::create_for_testing(222), fake_escrow_id(), ALICE, fee_inbox_id, scenario.ctx()
        );

        let sui_id  = fee_message::sent_fee_message_id(&event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]);
        let usdc_id = fee_message::sent_fee_message_id(&event::events_by_type<FeeMessageSent<FAKE_USDC>>()[0]);

        let sui_coin = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox,
            vector[test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(sui_id)],
            scenario.ctx(),
        );
        let usdc_coin = fee_message::collect_fee_messages<FAKE_USDC>(
            &mut inbox,
            vector[test_scenario::receiving_ticket_by_id<FeeMessage<FAKE_USDC>>(usdc_id)],
            scenario.ctx(),
        );
        assert_eq!(coin::value(&sui_coin),  111);
        assert_eq!(coin::value(&usdc_coin), 222);

        transfer::public_transfer(sui_coin,  ADMIN);
        transfer::public_transfer(usdc_coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun d6_distinct_escrow_ids_preserved_per_collected_event() {
    let mut scenario = setup();
    let esc1 = object::id_from_address(@0xEC1);
    let esc2 = object::id_from_address(@0xEC2);
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);

        fee_message::post<sui::sui::SUI>(balance::create_for_testing(10), esc1, ALICE, fee_inbox_id, scenario.ctx());
        fee_message::post<sui::sui::SUI>(balance::create_for_testing(20), esc2, BOB,   fee_inbox_id, scenario.ctx());

        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        let tickets = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(fee_message::sent_fee_message_id(&sent[0])),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(fee_message::sent_fee_message_id(&sent[1])),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 30);
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 2);
        assert_eq!(fee_message::collected_fee_inbox_id(&coll[0]), fee_inbox_id);
        assert_eq!(fee_message::collected_fee_inbox_id(&coll[1]), fee_inbox_id);
        assert_eq!(fee_message::collected_collector(&coll[0]),    ADMIN);
        assert_eq!(fee_message::collected_collector(&coll[1]),    ADMIN);
        assert!(fee_message::collected_escrow_id(&coll[0]) != fee_message::collected_escrow_id(&coll[1]));

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun d7_collector_follows_inbox_custody() {
    let mut scenario = setup();
    // Post with ADMIN's inbox, then transfer it to ALICE who drains
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(50), fake_escrow_id(), ALICE, fee_inbox_id, scenario.ctx()
        );
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let sent      = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        let ticket    = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(
            fee_message::sent_fee_message_id(&sent[0])
        );
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[ticket], scenario.ctx()
        );
        assert_eq!(coin::value(&coin), 50);
        transfer::public_transfer(coin, ALICE);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(fee_message::collected_collector(&coll[0]), ALICE);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── I — Balance invariant ─────────────────────────────────────────────────

#[test]
fun i1_total_drained_equals_total_sent() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);
        let amounts      = vector[100u64, 250u64, 50u64, 600u64];
        let mut i = 0;
        while (i < amounts.length()) {
            fee_message::post<sui::sui::SUI>(
                balance::create_for_testing(amounts[i]),
                fake_escrow_id(), ALICE, fee_inbox_id, scenario.ctx(),
            );
            i = i + 1;
        };
        let sent     = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        let tickets  = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(fee_message::sent_fee_message_id(&sent[0])),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(fee_message::sent_fee_message_id(&sent[1])),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(fee_message::sent_fee_message_id(&sent[2])),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(fee_message::sent_fee_message_id(&sent[3])),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 1_000);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── E — Events ────────────────────────────────────────────────────────────

#[test]
fun e1_fee_message_sent_fields_match_post_args() {
    let mut scenario = setup();
    let escrow_id    = fake_escrow_id();
    let fee_inbox_id = fake_inbox_id();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(42), escrow_id, ALICE, fee_inbox_id, scenario.ctx()
        );
    };
    scenario.next_tx(ADMIN);
    {
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_fee_inbox_id(&sent[0]), fee_inbox_id);
        assert_eq!(fee_message::sent_escrow_id(&sent[0]),    escrow_id);
        assert_eq!(fee_message::sent_amount(&sent[0]),        42);
        assert_eq!(fee_message::sent_tenant(&sent[0]),        ALICE);
    };
    scenario.end();
}

#[test]
fun e4_collect_n_messages_emits_n_collected_events() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);
        let id1 = post_to_real_inbox(&mut inbox, 10, ALICE, &mut scenario);
        let id2 = post_to_real_inbox(&mut inbox, 20, ALICE, &mut scenario);
        let id3 = post_to_real_inbox(&mut inbox, 30, ALICE, &mut scenario);
        let tickets = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id3),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 3);
        let mut k = 0;
        while (k < 3) {
            assert_eq!(fee_message::collected_fee_inbox_id(&coll[k]), fee_inbox_id);
            assert_eq!(fee_message::collected_collector(&coll[k]),    ADMIN);
            k = k + 1;
        };
        let total = fee_message::collected_amount(&coll[0])
            + fee_message::collected_amount(&coll[1])
            + fee_message::collected_amount(&coll[2]);
        assert_eq!(total, 60);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun e5_collect_empty_vector_no_collected_events() {
    let mut scenario = setup();
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[], scenario.ctx()
        );
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 0);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun e6_sent_collected_join_on_fee_message_id() {
    let mut scenario = setup();
    let escrow_id = fake_escrow_id();
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id = object::id(&inbox);

        fee_message::post<sui::sui::SUI>(
            balance::create_for_testing(77), escrow_id, ALICE, fee_inbox_id, scenario.ctx()
        );
        let sent   = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        let msg_id = fee_message::sent_fee_message_id(&sent[0]);
        let ticket = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin   = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[ticket], scenario.ctx()
        );
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        // JOIN key
        assert_eq!(fee_message::collected_fee_message_id(&coll[0]), msg_id);
        // Shared identity
        assert_eq!(fee_message::collected_fee_inbox_id(&coll[0]), fee_inbox_id);
        assert_eq!(fee_message::collected_escrow_id(&coll[0]),    escrow_id);
        assert_eq!(fee_message::collected_amount(&coll[0]),       77);
        // Non-overlapping address fields
        assert_eq!(fee_message::sent_tenant(&sent[0]),            ALICE);
        assert_eq!(fee_message::collected_collector(&coll[0]),    ADMIN);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}
