// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::protocol_fee_ref_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::protocol_fee_ref::{Self, ProtocolFeeRef};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

fun fake_inbox_id(): ID { object::id_from_address(@0xFE) }

// ─── §1. create_and_freeze ────────────────────────────────────────────────────

#[test]
fun create_and_freeze_proj_inbox_id_round_trip() {
    let inbox_id = fake_inbox_id();
    let mut sc   = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        protocol_fee_ref::create_and_freeze_for_testing(inbox_id, sc.ctx());
    };
    sc.next_tx(@0xCAFE);
    {
        let fee_ref = sc.take_immutable<ProtocolFeeRef>();
        assert_eq!(protocol_fee_ref::proj_inbox_id(&fee_ref), inbox_id);
        test_scenario::return_immutable(fee_ref);
    };
    sc.end();
}

#[test]
fun proj_inbox_identity_matches_inbox_id() {
    let inbox_id = fake_inbox_id();
    let mut sc   = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        protocol_fee_ref::create_and_freeze_for_testing(inbox_id, sc.ctx());
    };
    sc.next_tx(@0xCAFE);
    {
        let fee_ref = sc.take_immutable<ProtocolFeeRef>();
        let fi      = protocol_fee_ref::proj_inbox_identity(&fee_ref);
        assert_eq!(protocol_fee_ref::proj_id(fi), inbox_id);
        test_scenario::return_immutable(fee_ref);
    };
    sc.end();
}

// ─── §2. FeeInboxIdentity ─────────────────────────────────────────────────────

#[test]
fun fee_inbox_identity_round_trip() {
    let id = fake_inbox_id();
    let fi = protocol_fee_ref::fee_inbox_identity(id);
    assert_eq!(protocol_fee_ref::proj_id(fi), id);
}

#[test]
fun two_distinct_inbox_ids_produce_distinct_identities() {
    let id_a = object::id_from_address(@0xAA);
    let id_b = object::id_from_address(@0xBB);
    let fi_a = protocol_fee_ref::fee_inbox_identity(id_a);
    let fi_b = protocol_fee_ref::fee_inbox_identity(id_b);
    assert!(protocol_fee_ref::proj_id(fi_a) != protocol_fee_ref::proj_id(fi_b), 0);
}
