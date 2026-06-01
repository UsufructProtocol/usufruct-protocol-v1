// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::governance_cap_tests;

use std::unit_test::assert_eq;
use sui::{
    event,
    test_scenario,
};
use usufruct::{
    escrow_identity,
    governance_cap::{Self, GovernanceCapMinted, GovernanceCapBurned},
};

// ─── Actors ────────────────────────────────────────────────────────────────

const ALICE: address = @0xA11CE;
const BOB:   address = @0xB0B;
const ZERO:  address = @0x0;

// ─── Fixtures ──────────────────────────────────────────────────────────────

fun escrow_id_1(): ID { object::id_from_address(@0xE5C1) }
fun escrow_id_2(): ID { object::id_from_address(@0xE5C2) }

// ─── N — new ───────────────────────────────────────────────────────────────

// N1: new returns a pure governance GovernanceCap (no stored escrow binding) and
//     emits one GovernanceCapMinted recording provenance: the cap's id, the escrow it
//     was born from, and the declared governor.
#[test]
fun n1_new_returns_cap_and_emits_minted_event() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = governance_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let events = event::events_by_type<GovernanceCapMinted>();
        assert_eq!(events.length(), 1);
        assert_eq!(governance_cap::minted_governance_cap_id(&events[0]), object::id(&cap));
        assert_eq!(governance_cap::minted_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(governance_cap::minted_governor_address(&events[0]),         ALICE);

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
        let cap0 = governance_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let cap1 = governance_cap::new(escrow_identity::new(escrow_id_2()), BOB,   scenario.ctx());

        assert!(object::id(&cap0) != object::id(&cap1));

        let events = event::events_by_type<GovernanceCapMinted>();
        assert_eq!(events.length(), 2);
        assert_eq!(governance_cap::minted_governance_cap_id(&events[0]), object::id(&cap0));
        assert_eq!(governance_cap::minted_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(governance_cap::minted_governor_address(&events[0]),         ALICE);
        assert_eq!(governance_cap::minted_governance_cap_id(&events[1]), object::id(&cap1));
        assert_eq!(governance_cap::minted_escrow_id(&events[1]),    escrow_id_2());
        assert_eq!(governance_cap::minted_governor_address(&events[1]),         BOB);

        transfer::public_transfer(cap0, ALICE);
        transfer::public_transfer(cap1, BOB);
    };
    scenario.end();
}

// N3: governor field in the event is the declared argument, not tx_context::sender.
#[test]
fun n3_governor_is_declarative_not_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = governance_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());
        let events = event::events_by_type<GovernanceCapMinted>();
        assert_eq!(governance_cap::minted_governor_address(&events[0]), BOB);
        transfer::public_transfer(cap, BOB);
    };
    scenario.end();
}

// N4: governor == @0x0 is accepted; event records @0x0. Permissiveness at this layer
//     — policy lives in escrow::integrate.
#[test]
fun n4_governor_zero_address_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = governance_cap::new(escrow_identity::new(escrow_id_1()), ZERO, scenario.ctx());
        let events = event::events_by_type<GovernanceCapMinted>();
        assert_eq!(governance_cap::minted_governor_address(&events[0]), ZERO);
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
        let cap = governance_cap::new(escrow_identity::new(zero_escrow), ALICE, scenario.ctx());
        let events = event::events_by_type<GovernanceCapMinted>();
        assert_eq!(governance_cap::minted_escrow_id(&events[0]), zero_escrow);
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
        let cap = governance_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        assert_eq!(governance_cap::proj_id(governance_cap::identity(&cap)), object::id(&cap));
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// I2: identities from distinct caps are distinct.
#[test]
fun i2_distinct_caps_distinct_identities() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let a = governance_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let b = governance_cap::new(escrow_identity::new(escrow_id_2()), ALICE, scenario.ctx());
        assert!(governance_cap::proj_id(governance_cap::identity(&a)) != governance_cap::proj_id(governance_cap::identity(&b)));
        transfer::public_transfer(a, ALICE);
        transfer::public_transfer(b, ALICE);
    };
    scenario.end();
}

// ─── B — burn ──────────────────────────────────────────────────────────────

// B1: burn consumes the cap and emits one GovernanceCapBurned recording the cap's id
//     and the tx sender. The event is pure — no escrow id (the cap governs many;
//     the sealed set is recovered via the AssetIntegrated star schema).
#[test]
fun b1_burn_emits_burned_event() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap    = governance_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let cap_id = object::id(&cap);
        governance_cap::burn(cap, scenario.ctx());

        let events = event::events_by_type<GovernanceCapBurned>();
        assert_eq!(events.length(), 1);
        assert_eq!(governance_cap::burned_governance_cap_id(&events[0]),  cap_id);
        assert_eq!(governance_cap::burned_governor_address(&events[0]), ALICE);
    };
    scenario.end();
}

// B2: the burned governor is the tx sender (ctx-derived), not a declarative arg —
//     a burn sent from BOB records BOB.
#[test]
fun b2_burn_governor_is_the_sender() {
    let mut scenario = test_scenario::begin(BOB);
    {
        let cap = governance_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        governance_cap::burn(cap, scenario.ctx());
        let events = event::events_by_type<GovernanceCapBurned>();
        assert_eq!(governance_cap::burned_governor_address(&events[0]), BOB);
    };
    scenario.end();
}
