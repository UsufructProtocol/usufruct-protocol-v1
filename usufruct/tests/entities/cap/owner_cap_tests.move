// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_cap_tests;

use std::unit_test::assert_eq;
use sui::{
    event,
    test_scenario,
};
use usufruct::{
    escrow_identity,
    owner_cap::{Self, OwnerCapMinted},
};

// ─── Actors ────────────────────────────────────────────────────────────────

const ALICE: address = @0xA11CE;
const BOB:   address = @0xB0B;
const ZERO:  address = @0x0;

// ─── Fixtures ──────────────────────────────────────────────────────────────

fun escrow_id_1(): ID { object::id_from_address(@0xE5C1) }
fun escrow_id_2(): ID { object::id_from_address(@0xE5C2) }

// ─── N — new ───────────────────────────────────────────────────────────────

// N1: new returns a pure governance OwnerCap (no stored escrow binding) and
//     emits one OwnerCapMinted recording provenance: the cap's id, the escrow it
//     was born from, and the declared owner.
#[test]
fun n1_new_returns_cap_and_emits_minted_event() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(events.length(), 1);
        assert_eq!(owner_cap::minted_owner_cap_id(&events[0]), object::id(&cap));
        assert_eq!(owner_cap::minted_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(owner_cap::minted_owner_address(&events[0]),         ALICE);

        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// N2: two new calls produce caps with distinct UIDs and two Minted events in
//     call order, each recording its own birth escrow.
#[test]
fun n2_two_new_calls_produce_distinct_caps_and_events() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap0 = owner_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let cap1 = owner_cap::new(escrow_identity::new(escrow_id_2()), BOB,   scenario.ctx());

        assert!(object::id(&cap0) != object::id(&cap1));

        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(events.length(), 2);
        assert_eq!(owner_cap::minted_owner_cap_id(&events[0]), object::id(&cap0));
        assert_eq!(owner_cap::minted_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(owner_cap::minted_owner_address(&events[0]),         ALICE);
        assert_eq!(owner_cap::minted_owner_cap_id(&events[1]), object::id(&cap1));
        assert_eq!(owner_cap::minted_escrow_id(&events[1]),    escrow_id_2());
        assert_eq!(owner_cap::minted_owner_address(&events[1]),         BOB);

        transfer::public_transfer(cap0, ALICE);
        transfer::public_transfer(cap1, BOB);
    };
    scenario.end();
}

// N3: owner field in the event is the declared argument, not tx_context::sender.
#[test]
fun n3_owner_is_declarative_not_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());
        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_owner_address(&events[0]), BOB);
        transfer::public_transfer(cap, BOB);
    };
    scenario.end();
}

// N4: owner == @0x0 is accepted; event records @0x0. Permissiveness at this layer
//     — policy lives in escrow::integrate.
#[test]
fun n4_owner_zero_address_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_identity::new(escrow_id_1()), ZERO, scenario.ctx());
        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_owner_address(&events[0]), ZERO);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// N5: escrow_id == @0x0 is accepted; event records @0x0.
#[test]
fun n5_zero_escrow_id_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = owner_cap::new(escrow_identity::new(zero_escrow), ALICE, scenario.ctx());
        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_escrow_id(&events[0]), zero_escrow);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// ─── I — identity ────────────────────────────────────────────────────────────

// I1: identity(cap) projects to the cap's own object id; round-trips through proj_id.
#[test]
fun i1_identity_matches_object_id() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        assert_eq!(owner_cap::proj_id(owner_cap::identity(&cap)), object::id(&cap));
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// I2: identities from distinct caps are distinct.
#[test]
fun i2_distinct_caps_distinct_identities() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let a = owner_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let b = owner_cap::new(escrow_identity::new(escrow_id_2()), ALICE, scenario.ctx());
        assert!(owner_cap::proj_id(owner_cap::identity(&a)) != owner_cap::proj_id(owner_cap::identity(&b)));
        transfer::public_transfer(a, ALICE);
        transfer::public_transfer(b, ALICE);
    };
    scenario.end();
}
