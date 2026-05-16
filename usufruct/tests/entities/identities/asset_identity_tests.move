// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_identity_tests;

use std::unit_test::assert_eq;
use usufruct::{
    asset_identity,
    escrow_identity,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

fun fake_asset_id():  ID { object::id_from_address(@0xA5) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

// ─── §1. Constructor and accessors ───────────────────────────────────────────

#[test]
fun identity_asset_id_round_trip() {
    let ei = escrow_identity::new(fake_escrow_id());
    let ai = asset_identity::new_identity(fake_asset_id(), ei);
    assert_eq!(asset_identity::identity_asset_id(&ai), fake_asset_id());
}

#[test]
fun identity_escrow_identity_round_trip() {
    let ei = escrow_identity::new(fake_escrow_id());
    let ai = asset_identity::new_identity(fake_asset_id(), ei);
    assert_eq!(
        escrow_identity::escrow_id(asset_identity::identity_escrow_identity(&ai)),
        fake_escrow_id(),
    );
}

#[test]
fun distinct_asset_ids_are_preserved() {
    let ei   = escrow_identity::new(fake_escrow_id());
    let id_a = object::id_from_address(@0xA1);
    let id_b = object::id_from_address(@0xA2);
    let ai_a = asset_identity::new_identity(id_a, ei);
    let ai_b = asset_identity::new_identity(id_b, ei);
    assert!(asset_identity::identity_asset_id(&ai_a) != asset_identity::identity_asset_id(&ai_b), 0);
}
