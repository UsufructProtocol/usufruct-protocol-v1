// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

// Cross-block deferred initialization requires `mut` even for single-assignment
// variables — see fee_message_tests for the full explanation.
#[allow(unused_let_mut)]
#[test_only]
module usufruct::protocol_fee_inbox_tests;

use sui::test_scenario::{Self, Scenario};
use usufruct::protocol_fee_inbox::{Self, ProtocolFeeInbox};
use usufruct::protocol_fee_ref::{Self, ProtocolFeeRef};

// ─── Actors ────────────────────────────────────────────────────────────────

const DEPLOYER: address = @0xD1;
const ALICE:    address = @0xA1;
const BOB:      address = @0xB0;

// ─── Helpers ───────────────────────────────────────────────────────────────

fun setup(): Scenario {
    let mut scenario = test_scenario::begin(DEPLOYER);
    {
        protocol_fee_inbox::init_for_testing(scenario.ctx());
    };
    scenario
}

// ─── I — Initialization ────────────────────────────────────────────────────

#[test]
fun i1_deployer_receives_exactly_one_inbox() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test, expected_failure]
fun i2_no_second_inbox_for_deployer() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox1 = scenario.take_from_sender<ProtocolFeeInbox>();
        // Only one inbox exists — second take must fail
        let inbox2 = scenario.take_from_sender<ProtocolFeeInbox>();
        scenario.return_to_sender(inbox2);
        scenario.return_to_sender(inbox1);
    };
    scenario.end();
}

#[test]
fun i3_protocol_fee_ref_is_frozen() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();
        // return_immutable is a free function, not a method on Scenario
        test_scenario::return_immutable(fee_ref);
    };
    scenario.end();
}

#[test]
fun i4_inbox_id_matches_inbox_object_id() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox   = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();

        assert!(protocol_fee_ref::proj_inbox_id(&fee_ref) == object::id(&inbox));

        scenario.return_to_sender(inbox);
        test_scenario::return_immutable(fee_ref);
    };
    scenario.end();
}

#[test]
fun i5_inbox_id_is_pure() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();

        let id1 = protocol_fee_ref::proj_inbox_id(&fee_ref);
        let id2 = protocol_fee_ref::proj_inbox_id(&fee_ref);
        assert!(id1 == id2);

        test_scenario::return_immutable(fee_ref);
    };
    scenario.end();
}

#[test]
fun i6_inbox_and_fee_ref_have_distinct_ids() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox   = scenario.take_from_sender<ProtocolFeeInbox>();
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();

        assert!(object::id(&inbox) != object::id(&fee_ref));

        scenario.return_to_sender(inbox);
        test_scenario::return_immutable(fee_ref);
    };
    scenario.end();
}

#[test]
fun i7_no_events_emitted_during_init() {
    let mut scenario = setup();
    let effects = scenario.next_tx(DEPLOYER);
    assert!(effects.num_user_events() == 0);
    scenario.end();
}

// ─── B — ProtocolFeeRef immutability ───────────────────────────────────────

#[test]
fun b1_frozen_fee_ref_readable_by_anyone() {
    let mut scenario = setup();
    // ALICE (not deployer) can read the frozen ProtocolFeeRef
    scenario.next_tx(ALICE);
    {
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();
        test_scenario::return_immutable(fee_ref);
    };
    scenario.end();
}

#[test, expected_failure]
fun b2_fee_ref_not_owned_by_deployer() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        // ProtocolFeeRef is frozen, not sender-owned — take_from_sender must fail
        let fee_ref = scenario.take_from_sender<ProtocolFeeRef>();
        scenario.return_to_sender(fee_ref);
    };
    scenario.end();
}

#[test, expected_failure]
fun b3_fee_ref_not_shared() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        // ProtocolFeeRef is frozen, not shared — take_shared must fail
        let fee_ref = scenario.take_shared<ProtocolFeeRef>();
        test_scenario::return_shared(fee_ref);
    };
    scenario.end();
}

// ─── T — Inbox transferability ─────────────────────────────────────────────

#[test]
fun t1_deployer_can_transfer_inbox_to_alice() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test, expected_failure]
fun t2_after_transfer_deployer_cannot_take_inbox() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(DEPLOYER);
    {
        // Inbox was transferred away — deployer can no longer take it
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun t3_new_holder_can_call_uid_mut() {
    let mut scenario = setup();
    // DEPLOYER → ALICE → BOB, then BOB calls uid_mut
    scenario.next_tx(DEPLOYER);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, BOB);
    };
    scenario.next_tx(BOB);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let uid = protocol_fee_inbox::uid_mut(&mut inbox);
        // uid_mut returns &mut UID for the same object
        assert!(object::uid_to_inner(uid) == object::id(&inbox));
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── U — uid_mut contract ──────────────────────────────────────────────────

#[test]
fun u1_uid_mut_returns_inbox_uid() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let uid = protocol_fee_inbox::uid_mut(&mut inbox);
        assert!(object::uid_to_inner(uid) == object::id(&inbox));
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

#[test]
fun u2_uid_mut_can_be_called_twice() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let mut inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        let id1 = object::uid_to_inner(protocol_fee_inbox::uid_mut(&mut inbox));
        let id2 = object::uid_to_inner(protocol_fee_inbox::uid_mut(&mut inbox));
        assert!(id1 == id2);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// ─── T4, B-cross-tx — Additional coverage ──────────────────────────────────

// T4: Transferring ProtocolFeeInbox to @0x0 does not abort.
// Documents the permissiveness of public_transfer — no runtime check prevents
// sending the inbox to the zero address. The object becomes unrecoverable on a
// real network; in test_scenario @0x0 is a valid address. Documented here so
// the absence of a defensive check is explicit and intentional, not an oversight.
#[test]
fun t4_transfer_to_zero_address_does_not_abort() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let inbox = scenario.take_from_sender<ProtocolFeeInbox>();
        transfer::public_transfer(inbox, @0x0);
    };
    scenario.end();
}

// inbox_id stability across transactions and callers: frozen objects are
// immutable by construction, so this is trivially guaranteed by the freeze
// mechanism — recorded here because tests are documentation.
// Combines B1 (any caller can read the frozen ref) with I5 (getter purity)
// across a transaction boundary.
#[test]
fun inbox_id_stable_across_transactions_and_callers() {
    let mut scenario = setup();
    // Read inbox_id as DEPLOYER in tx 1
    let mut id_from_deployer: ID;
    scenario.next_tx(DEPLOYER);
    {
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();
        id_from_deployer = protocol_fee_ref::proj_inbox_id(&fee_ref);
        test_scenario::return_immutable(fee_ref);
    };
    // Read inbox_id as ALICE in tx 2 — must be identical
    scenario.next_tx(ALICE);
    {
        let fee_ref = scenario.take_immutable<ProtocolFeeRef>();
        assert!(protocol_fee_ref::proj_inbox_id(&fee_ref) == id_from_deployer);
        test_scenario::return_immutable(fee_ref);
    };
    scenario.end();
}
