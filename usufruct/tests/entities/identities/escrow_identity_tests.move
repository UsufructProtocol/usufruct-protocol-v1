// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_identity_tests;

use std::unit_test::assert_eq;
use usufruct::escrow_identity;

// ─── §1. Round-trip ───────────────────────────────────────────────────────────

#[test]
fun new_escrow_id_round_trip() {
    let id = object::id_from_address(@0xEC);
    let ei = escrow_identity::new(id);
    assert_eq!(escrow_identity::escrow_id(ei), id);
}

#[test]
fun two_distinct_ids_are_distinct() {
    let id_a = object::id_from_address(@0xAA);
    let id_b = object::id_from_address(@0xBB);
    let ea   = escrow_identity::new(id_a);
    let eb   = escrow_identity::new(id_b);
    assert!(escrow_identity::escrow_id(ea) != escrow_identity::escrow_id(eb), 0);
}
