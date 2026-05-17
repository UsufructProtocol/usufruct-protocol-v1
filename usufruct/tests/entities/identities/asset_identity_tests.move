// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_identity_tests;

use std::unit_test::assert_eq;
use usufruct::asset_identity;

// ─── §1. Round-trip ───────────────────────────────────────────────────────────

#[test]
fun new_id_round_trip() {
    let raw = object::id_from_address(@0xA5);
    let ai  = asset_identity::new(raw);
    assert_eq!(asset_identity::proj_id(ai), raw);
}

#[test]
fun two_distinct_ids_are_distinct() {
    let a = asset_identity::new(object::id_from_address(@0xA1));
    let b = asset_identity::new(object::id_from_address(@0xA2));
    assert!(asset_identity::proj_id(a) != asset_identity::proj_id(b), 0);
}
