// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_identity_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::{
    escrow_identity,
    owner_cap,
    owner_identity,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER: address = @0xA1;

fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

// ─── §1. Constructor and proj_cap_identity ────────────────────────────────────

#[test]
fun new_proj_cap_identity_round_trip() {
    let mut sc = test_scenario::begin(OWNER);
    sc.next_tx(OWNER);
    {
        let cap     = owner_cap::new(escrow_identity::new(fake_escrow_id()), OWNER, sc.ctx());
        let cap_id  = owner_cap::identity(&cap);
        let oi      = owner_identity::new(cap_id);
        assert_eq!(owner_identity::proj_cap_identity(&oi), cap_id);
        transfer::public_transfer(cap, OWNER);
    };
    sc.end();
}

#[test]
fun two_caps_produce_distinct_identities() {
    let mut sc = test_scenario::begin(OWNER);
    sc.next_tx(OWNER);
    {
        let cap_a  = owner_cap::new(escrow_identity::new(fake_escrow_id()), OWNER, sc.ctx());
        let cap_b  = owner_cap::new(escrow_identity::new(fake_escrow_id()), OWNER, sc.ctx());
        let id_a   = owner_identity::new(owner_cap::identity(&cap_a));
        let id_b   = owner_identity::new(owner_cap::identity(&cap_b));
        assert!(
            owner_cap::proj_id(owner_identity::proj_cap_identity(&id_a)) !=
            owner_cap::proj_id(owner_identity::proj_cap_identity(&id_b)),
            0,
        );
        transfer::public_transfer(cap_a, OWNER);
        transfer::public_transfer(cap_b, OWNER);
    };
    sc.end();
}
