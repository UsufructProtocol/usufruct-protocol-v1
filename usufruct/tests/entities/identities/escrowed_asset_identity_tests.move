// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrowed_asset_identity_tests;

use std::unit_test::assert_eq;
use usufruct::{
    asset_identity,
    escrowed_asset_identity,
    escrow_identity,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

fun fake_ai(): asset_identity::AssetIdentity {
    asset_identity::new(object::id_from_address(@0xA5))
}
fun fake_ei(): escrow_identity::EscrowIdentity {
    escrow_identity::new(object::id_from_address(@0xEC))
}

// ─── §1. Constructor and accessors ───────────────────────────────────────────

#[test]
fun asset_id_round_trip() {
    let ai = fake_ai();
    let id = escrowed_asset_identity::new(ai, fake_ei());
    assert_eq!(escrowed_asset_identity::asset_id(&id), ai);
}

#[test]
fun escrow_identity_round_trip() {
    let ei = fake_ei();
    let id = escrowed_asset_identity::new(fake_ai(), ei);
    assert_eq!(
        escrow_identity::escrow_id(escrowed_asset_identity::escrow_identity(&id)),
        escrow_identity::escrow_id(ei),
    );
}

#[test]
fun distinct_asset_ids_are_preserved() {
    let ei   = fake_ei();
    let ai_a = asset_identity::new(object::id_from_address(@0xA1));
    let ai_b = asset_identity::new(object::id_from_address(@0xA2));
    let id_a = escrowed_asset_identity::new(ai_a, ei);
    let id_b = escrowed_asset_identity::new(ai_b, ei);
    assert!(escrowed_asset_identity::asset_id(&id_a) != escrowed_asset_identity::asset_id(&id_b), 0);
}
