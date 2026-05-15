// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

// Cross-block deferred initialization requires `mut` even for single-assignment
// variables. Move's compiler warns W09012 (unused mut) in these cases — suppressed
// here because the mut is syntactically required, not stylistically optional.
#[allow(unused_let_mut)]
#[test_only]
module usufruct::fee_message_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    coin,
    event,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    fee_message::{Self, FeeMessage, FeeMessageSent, FeeMessageCollected},
    monetary,
    protocol_fee_inbox::{Self, ProtocolFeeInbox},
    escrow_identity,
    protocol_fee_ref,
};

// ─── Actors ────────────────────────────────────────────────────────────────

const DEPLOYER: address = @0xD1;
const ALICE:    address = @0xA1;
const ADMIN:    address = @0xAD;

// ─── Test-only coin witness ─────────────────────────────────────────────────

public struct FAKE_USDC has drop {}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Sets up a `ProtocolFeeInbox` owned by ADMIN.
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
fun fake_escrow_identity(): escrow_identity::EscrowIdentity    { escrow_identity::new(fake_escrow_id()) }
fun fake_inbox_identity():  protocol_fee_ref::FeeInboxIdentity { protocol_fee_ref::fee_inbox_identity(fake_inbox_id()) }

// ─── N — new_share / share_value ───────────────────────────────────────────

// N1: share_value reflects the input Balance's value.
#[test]
fun n1_share_value_reflects_input_balance() {
    let mut scenario = test_scenario::begin(ALICE);
    scenario.next_tx(ALICE);
    {
        let s = fee_message::new_share<sui::sui::SUI>(
            balance::create_for_testing(1_234), fake_escrow_identity(),
        );
        assert_eq!(monetary::stake_mist(fee_message::proj_share_value(&s)), 1_234);
        fee_message::destroy_share_for_testing(s);
    };
    scenario.end();
}

// N2: share_escrow_id reflects the input escrow_id.
#[test]
fun n2_share_escrow_id_reflects_input() {
    let mut scenario = test_scenario::begin(ALICE);
    let synthetic = object::id_from_address(@0xC0FFEE);
    scenario.next_tx(ALICE);
    {
        let s = fee_message::new_share<sui::sui::SUI>(
            balance::create_for_testing(1), escrow_identity::new(synthetic),
        );
        assert_eq!(fee_message::share_escrow_id(&s), synthetic);
        fee_message::destroy_share_for_testing(s);
    };
    scenario.end();
}

// N3: zero-balance share is allowed; share_value == 0.
#[test]
fun n3_share_with_zero_balance_allowed() {
    let mut scenario = test_scenario::begin(ALICE);
    scenario.next_tx(ALICE);
    {
        let s = fee_message::new_share<sui::sui::SUI>(
            balance::create_for_testing(0), fake_escrow_identity(),
        );
        assert_eq!(monetary::stake_mist(fee_message::proj_share_value(&s)), 0);
        fee_message::destroy_share_for_testing(s);
    };
    scenario.end();
}

// N4: post consumes the share and forwards both escrow_id and amount to the event.
#[test]
fun n4_post_forwards_share_fields_to_event() {
    let mut scenario = setup();
    let escrow_id = object::id_from_address(@0xCAFEBABE);
    scenario.next_tx(ALICE);
    {
        let s = fee_message::new_share<sui::sui::SUI>(
            balance::create_for_testing(99), escrow_identity::new(escrow_id),
        );
        fee_message::post(s, fake_inbox_identity(), scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_escrow_id(&sent[0]), escrow_id);
        assert_eq!(fee_message::sent_amount(&sent[0]),    99);
    };
    scenario.end();
}

// ─── S — post ──────────────────────────────────────────────────────────────

// S1: post creates a FeeMessage; Sent event carries the post arguments.
// Event is read in the SAME transaction block as the post.
#[test]
fun s1_post_creates_child_with_correct_fields() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(1_000), fake_escrow_identity()),
            fake_inbox_identity(), scenario.ctx(),
        );
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_fee_inbox_id(&sent[0]), fake_inbox_id());
        assert_eq!(fee_message::sent_escrow_id(&sent[0]),    fake_escrow_id());
        assert_eq!(fee_message::sent_amount(&sent[0]),        1_000);
    };
    scenario.end();
}

// S2: post with balance == 0 does not abort; Sent event carries amount == 0.
#[test]
fun s2_post_with_zero_balance_does_not_abort() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(0), fake_escrow_identity()),
            fake_inbox_identity(), scenario.ctx(),
        );
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_amount(&sent[0]), 0);
    };
    scenario.end();
}

// S3: two posts yield two distinct fee_message_ids.
#[test]
fun s3_post_twice_creates_two_distinct_messages() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        let fee_inbox = fake_inbox_identity();
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(500), fake_escrow_identity()), fee_inbox, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(300), fake_escrow_identity()), fee_inbox, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 2);
        assert!(fee_message::sent_fee_message_id(&sent[0]) != fee_message::sent_fee_message_id(&sent[1]));
    };
    scenario.end();
}

// S4: SUI and FAKE_USDC posts coexist — each type yields its own Sent event.
#[test]
fun s4_post_sui_and_fake_usdc_no_conflict() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        let fee_inbox = fake_inbox_identity();
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(100), fake_escrow_identity()), fee_inbox, scenario.ctx());
        fee_message::post<FAKE_USDC>(fee_message::new_share(balance::create_for_testing(200),     fake_escrow_identity()), fee_inbox, scenario.ctx());
        assert_eq!(event::events_by_type<FeeMessageSent<sui::sui::SUI>>().length(), 1);
        assert_eq!(event::events_by_type<FeeMessageSent<FAKE_USDC>>().length(),     1);
    };
    scenario.end();
}

// S7: escrow_id is the argument; no live escrow required.
#[test]
fun s7_escrow_id_is_declarative() {
    let mut scenario = setup();
    let synthetic = object::id_from_address(@0xDEAD);
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(1), escrow_identity::new(synthetic)),
            fake_inbox_identity(), scenario.ctx()
        );
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(fee_message::sent_escrow_id(&sent[0]), synthetic);
    };
    scenario.end();
}

// S9: u64::MAX balance flows through without overflow.
#[test]
fun s9_post_with_max_u64_balance() {
    let mut scenario = setup();
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(18_446_744_073_709_551_615), fake_escrow_identity()),
            fake_inbox_identity(), scenario.ctx(),
        );
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(fee_message::sent_amount(&sent[0]), 18_446_744_073_709_551_615);
    };
    scenario.end();
}

// ─── R — receive_message ───────────────────────────────────────────────────

// R1: receive_message returns the FeeMessage with the correct balance.
//     Verified by consuming the received message and checking the Balance value.
//     Pattern: post + save msg_id in block 1; receive + consume in block 2.
#[test]
fun r1_receive_message_returns_correct_balance() {
    let mut scenario = setup();
    // events_by_type returns events of the current tx only; capture msg_id
    // in an outer variable to make it available in the next tx block.
    // receiving_ticket_by_id is a free function, not a method on Scenario.
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(777), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let ticket    = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let msg       = fee_message::receive_message_for_testing(&mut inbox, ticket);
        assert_eq!(fee_message::proj_escrow_id(&msg), fake_escrow_id());
        let bal       = fee_message::consume_message_for_testing(msg, object::id(&inbox), ADMIN);
        assert_eq!(balance::value(&bal), 777);
        balance::destroy_for_testing(bal);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── C — consume_message ───────────────────────────────────────────────────

// C1: consume_message returns the balance and emits FeeMessageCollected with the
//     declarative scalar arguments (fee_inbox_id, collector).
#[test]
fun c1_consume_message_returns_balance_and_emits_collected_event() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(500), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
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

// C2: consume_message with arbitrary scalar metadata passes through unchanged.
#[test]
fun c2_consume_message_with_arbitrary_scalar_metadata() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(1), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox          = scenario.take_from_sender<ProtocolFeeInbox>();
        let ticket             = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let msg                = fee_message::receive_message_for_testing(&mut inbox, ticket);
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

// C3: consume_message on a zero-balance message returns zero Balance; event amount == 0.
#[test]
fun c3_consume_zero_balance_message() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(0), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
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

// D1: empty vector returns Coin with value 0; no Collected events.
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

// D2: one ticket → Coin value == posted balance.
#[test]
fun d2_collect_one_ticket() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(999), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
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

// D3: N tickets → Coin == sum of balances; all objects deleted.
#[test]
fun d3_collect_n_tickets_sums_balances() {
    let mut scenario = setup();
    let mut id1: ID;
    let mut id2: ID;
    let mut id3: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(100), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(200), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(300), fake_escrow_identity()), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id1 = fee_message::sent_fee_message_id(&sent[0]);
        id2 = fee_message::sent_fee_message_id(&sent[1]);
        id3 = fee_message::sent_fee_message_id(&sent[2]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let tickets   = vector[
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

// D4: SUI and FAKE_USDC drained in the same tx sharing one &mut ProtocolFeeInbox.
#[test]
fun d4_collect_sui_and_fake_usdc_same_inbox() {
    let mut scenario = setup();
    let mut sui_id:  ID;
    let mut usdc_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(111), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<FAKE_USDC>(fee_message::new_share(balance::create_for_testing(222),     fake_escrow_identity()), inbox_identity, scenario.ctx());
        sui_id  = fee_message::sent_fee_message_id(&event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]);
        usdc_id = fee_message::sent_fee_message_id(&event::events_by_type<FeeMessageSent<FAKE_USDC>>()[0]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let sui_coin  = fee_message::collect_fee_messages<sui::sui::SUI>(
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

// D6: distinct escrow_ids are preserved per FeeMessageCollected event (P8).
#[test]
fun d6_distinct_escrow_ids_preserved_per_collected_event() {
    let mut scenario = setup();
    let esc1 = object::id_from_address(@0xEC1);
    let esc2 = object::id_from_address(@0xEC2);
    let mut id1: ID;
    let mut id2: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(10), escrow_identity::new(esc1)), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(20), escrow_identity::new(esc2)), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id1 = fee_message::sent_fee_message_id(&sent[0]);
        id2 = fee_message::sent_fee_message_id(&sent[1]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        let tickets      = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id2),
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

// D7: collector follows custody — drain by ALICE yields collector == ALICE.
#[test]
fun d7_collector_follows_inbox_custody() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(50), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let ticket    = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin      = fee_message::collect_fee_messages<sui::sui::SUI>(
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

// I1: total drained == total posted (sum-of-balances invariant).
#[test]
fun i1_total_drained_equals_total_sent() {
    let mut scenario = setup();
    let mut id0: ID;
    let mut id1: ID;
    let mut id2: ID;
    let mut id3: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(100), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(250), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(50),  fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(600), fake_escrow_identity()), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id0 = fee_message::sent_fee_message_id(&sent[0]);
        id1 = fee_message::sent_fee_message_id(&sent[1]);
        id2 = fee_message::sent_fee_message_id(&sent[2]);
        id3 = fee_message::sent_fee_message_id(&sent[3]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id0),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id3),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 1_000);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── E — Events ────────────────────────────────────────────────────────────

// E1: FeeMessageSent fields exactly match the post arguments.
#[test]
fun e1_fee_message_sent_fields_match_post_args() {
    let mut scenario = setup();
    let escrow_id    = fake_escrow_id();
    let fee_inbox_id = fake_inbox_id();
    let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
    scenario.next_tx(ALICE);
    {
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(42), escrow_identity::new(escrow_id)),
            inbox_identity, scenario.ctx()
        );
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 1);
        assert_eq!(fee_message::sent_fee_inbox_id(&sent[0]), fee_inbox_id);
        assert_eq!(fee_message::sent_escrow_id(&sent[0]),    escrow_id);
        assert_eq!(fee_message::sent_amount(&sent[0]),        42);
    };
    scenario.end();
}

// E4: drain of N messages emits exactly N FeeMessageCollected events,
//     all sharing fee_inbox_id and collector (drain-scope scalars hoisted once).
#[test]
fun e4_collect_n_messages_emits_n_collected_events() {
    let mut scenario = setup();
    let mut id1: ID;
    let mut id2: ID;
    let mut id3: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(10), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(20), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(30), fake_escrow_identity()), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id1 = fee_message::sent_fee_message_id(&sent[0]);
        id2 = fee_message::sent_fee_message_id(&sent[1]);
        id3 = fee_message::sent_fee_message_id(&sent[2]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        let tickets      = vector[
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

// E5: empty vector → no FeeMessageCollected events emitted.
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
        assert_eq!(event::events_by_type<FeeMessageCollected<sui::sui::SUI>>().length(), 0);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// E6: Sent↔Collected join on fee_message_id; shared identity fields match.
#[test]
fun e6_sent_collected_join_on_fee_message_id() {
    let mut scenario = setup();
    let escrow_id = fake_escrow_id();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(77), escrow_identity::new(escrow_id)),
            inbox_identity, scenario.ctx()
        );
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        msg_id   = fee_message::sent_fee_message_id(&sent[0]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox    = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        let ticket       = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin         = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[ticket], scenario.ctx()
        );
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        // JOIN key
        assert_eq!(fee_message::collected_fee_message_id(&coll[0]), msg_id);
        // Shared identity fields
        assert_eq!(fee_message::collected_fee_inbox_id(&coll[0]), fee_inbox_id);
        assert_eq!(fee_message::collected_escrow_id(&coll[0]),    escrow_id);
        assert_eq!(fee_message::collected_amount(&coll[0]),       77);
        // Collector field
        assert_eq!(fee_message::collected_collector(&coll[0]),    ADMIN);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── D5, D8, D8b, P3 — Security and stress ─────────────────────────────────

// D5: Ticket for a message posted to inbox A, presented to inbox B, aborts.
// Verifies P7: parent-relation enforcement is done by transfer::receive at the
// Sui runtime level — no Move-level assert needed or added.
#[test, expected_failure]
fun d5_cross_inbox_ticket_rejected() {
    // Create inbox A → hand to ADMIN; inbox B → stays with DEPLOYER.
    let mut scenario = test_scenario::begin(DEPLOYER);
    {
        protocol_fee_inbox::init_for_testing(scenario.ctx());
    };
    scenario.next_tx(DEPLOYER);
    {
        let inbox_a = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox_a, ADMIN);
    };
    scenario.next_tx(DEPLOYER);
    {
        protocol_fee_inbox::init_for_testing(scenario.ctx());
    };
    // Post to inbox A; save msg_id.
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox_a        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox_a);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(1), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox_a);
    };
    // Drain from inbox B with a ticket that belongs to inbox A → must abort.
    scenario.next_tx(DEPLOYER);
    {
        let mut inbox_b = scenario.take_from_sender<ProtocolFeeInbox>();
        let ticket = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox_b, vector[ticket], scenario.ctx()
        );
        transfer::public_transfer(coin, DEPLOYER);
        scenario.return_to_sender(inbox_b);
    };
    scenario.end();
}

// P3: FeeMessage UID is deleted in the drain transaction.
// Asserts P3 directly via TransactionEffects.deleted() — the positive form:
// the msg_id appears in the deleted set of the drain tx. Preferred over an
// #[expected_failure] double-drain attempt, which panics at the Rust level
// (receiving_ticket_by_id calls unwrap on None for a deleted object's version)
// instead of producing a Move abort that expected_failure can catch.
#[test]
fun p3_uid_deleted_on_drain() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(1), fake_escrow_identity()),
            inbox_identity, scenario.ctx()
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let ticket    = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[ticket], scenario.ctx()
        );
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    // end() finalizes the drain tx and returns its TransactionEffects.
    // deleted() lists every UID deleted in that tx — msg_id must be there.
    let effects = scenario.end();
    let deleted = effects.deleted();
    assert!(deleted.contains(&msg_id));
}

// D8: 64 messages drained in one call — regression guard for vector::do! iteration.
// Tests that the accumulator and the loop shape are correct at N >> 4.
#[test]
fun d8_large_n_iteration_regression() {
    let mut scenario = setup();
    let mut ids: vector<ID> = vector[];
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        let mut k: u64 = 0;
        while (k < 64) {
            fee_message::post<sui::sui::SUI>(
                fee_message::new_share(balance::create_for_testing(1), fake_escrow_identity()),
                inbox_identity, scenario.ctx()
            );
            k = k + 1;
        };
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        assert_eq!(sent.length(), 64);
        let mut j: u64 = 0;
        while (j < 64) {
            ids.push_back(fee_message::sent_fee_message_id(&sent[j]));
            j = j + 1;
        };
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox   = scenario.take_from_sender<ProtocolFeeInbox>();
        let mut tickets: vector<transfer::Receiving<FeeMessage<sui::sui::SUI>>> = vector[];
        let mut k: u64 = 0;
        while (k < 64) {
            tickets.push_back(
                test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(ids[k])
            );
            k = k + 1;
        };
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 64);
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 64);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// D8b: 4 messages each carrying u64::MAX / 4 — accumulator boundary test.
// Verifies balance::join does not overflow when the total approaches u64::MAX.
// quarter = 4_611_686_018_427_387_903; sum = 4 × quarter = u64::MAX - 3.
#[test]
fun d8b_accumulator_near_u64_max() {
    let mut scenario = setup();
    let quarter: u64 = 4_611_686_018_427_387_903;
    let expected: u64 = 18_446_744_073_709_551_612; // 4 × quarter
    let mut id0: ID;
    let mut id1: ID;
    let mut id2: ID;
    let mut id3: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(quarter), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(quarter), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(quarter), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(quarter), fake_escrow_identity()), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id0 = fee_message::sent_fee_message_id(&sent[0]);
        id1 = fee_message::sent_fee_message_id(&sent[1]);
        id2 = fee_message::sent_fee_message_id(&sent[2]);
        id3 = fee_message::sent_fee_message_id(&sent[3]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id0),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id3),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), expected);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── Additional coverage ────────────────────────────────────────────────────

// Drain order independence: post [A, B], drain [B, A].
// Verifies that transfer::receive retrieves messages by object ID, not by
// insertion order. Each collected event must match its message's escrow_id
// regardless of the ticket sequence.
#[test]
fun drain_order_independence() {
    let mut scenario = setup();
    let esc_a = object::id_from_address(@0xA1);
    let esc_b = object::id_from_address(@0xB2);
    let mut id_a: ID;
    let mut id_b: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(300), escrow_identity::new(esc_a)), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(700), escrow_identity::new(esc_b)), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id_a = fee_message::sent_fee_message_id(&sent[0]);
        id_b = fee_message::sent_fee_message_id(&sent[1]);
        scenario.return_to_sender(inbox);
    };
    // Drain in reverse order: B first, then A.
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id_b),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id_a),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 1_000);
        transfer::public_transfer(coin, ADMIN);

        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 2);
        // First collected event corresponds to B (drained first)
        assert_eq!(fee_message::collected_fee_message_id(&coll[0]), id_b);
        assert_eq!(fee_message::collected_escrow_id(&coll[0]),      esc_b);
        // Second collected event corresponds to A (drained second)
        assert_eq!(fee_message::collected_fee_message_id(&coll[1]), id_a);
        assert_eq!(fee_message::collected_escrow_id(&coll[1]),      esc_a);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// u64::MAX end-to-end: post a single u64::MAX message and drain it through the
// full collect_fee_messages pipeline. S9 only checks the Sent event; this closes
// the loop by verifying the returned Coin carries u64::MAX.
#[test]
fun collect_single_max_u64_message() {
    let mut scenario = setup();
    let mut msg_id: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(
            fee_message::new_share(balance::create_for_testing(18_446_744_073_709_551_615), fake_escrow_identity()),
            inbox_identity, scenario.ctx(),
        );
        msg_id = fee_message::sent_fee_message_id(
            &event::events_by_type<FeeMessageSent<sui::sui::SUI>>()[0]
        );
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let ticket    = test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(msg_id);
        let coin      = fee_message::collect_fee_messages<sui::sui::SUI>(
            &mut inbox, vector[ticket], scenario.ctx()
        );
        assert_eq!(coin::value(&coin), 18_446_744_073_709_551_615);
        transfer::public_transfer(coin, ADMIN);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// Mixed zero and non-zero in a single batch: the accumulator must sum only the
// non-zero contributions. Zero-balance messages are valid and must not abort.
#[test]
fun collect_mixed_zero_nonzero_batch() {
    let mut scenario = setup();
    let mut id0: ID;
    let mut id1: ID;
    let mut id2: ID;
    let mut id3: ID;
    scenario.next_tx(ADMIN);
    {
        let inbox        = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_inbox_id   = object::id(&inbox);
        let inbox_identity = protocol_fee_ref::fee_inbox_identity(fee_inbox_id);
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(0),   fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(100), fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(0),   fake_escrow_identity()), inbox_identity, scenario.ctx());
        fee_message::post<sui::sui::SUI>(fee_message::new_share(balance::create_for_testing(200), fake_escrow_identity()), inbox_identity, scenario.ctx());
        let sent = event::events_by_type<FeeMessageSent<sui::sui::SUI>>();
        id0 = fee_message::sent_fee_message_id(&sent[0]);
        id1 = fee_message::sent_fee_message_id(&sent[1]);
        id2 = fee_message::sent_fee_message_id(&sent[2]);
        id3 = fee_message::sent_fee_message_id(&sent[3]);
        scenario.return_to_sender(inbox);
    };
    scenario.next_tx(ADMIN);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let tickets   = vector[
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id0),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id1),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id2),
            test_scenario::receiving_ticket_by_id<FeeMessage<sui::sui::SUI>>(id3),
        ];
        let coin = fee_message::collect_fee_messages<sui::sui::SUI>(&mut inbox, tickets, scenario.ctx());
        assert_eq!(coin::value(&coin), 300);
        transfer::public_transfer(coin, ADMIN);

        // Four collected events emitted — zero-balance ones carry amount == 0
        let coll = event::events_by_type<FeeMessageCollected<sui::sui::SUI>>();
        assert_eq!(coll.length(), 4);
        assert_eq!(fee_message::collected_amount(&coll[0]), 0);
        assert_eq!(fee_message::collected_amount(&coll[1]), 100);
        assert_eq!(fee_message::collected_amount(&coll[2]), 0);
        assert_eq!(fee_message::collected_amount(&coll[3]), 200);

        scenario.return_to_sender(inbox);
    };
    scenario.end();
}
