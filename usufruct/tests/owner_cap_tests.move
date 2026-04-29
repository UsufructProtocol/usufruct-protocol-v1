// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_cap_tests;

use std::unit_test::assert_eq;
use sui::{
    event,
    test_scenario::{Self},
};
use usufruct::owner_cap::{Self, OwnerCap, OwnerCapMinted, OwnerCapBurned};

// ─── Actors ────────────────────────────────────────────────────────────────

const ALICE: address = @0xA11CE;
const BOB:   address = @0xB0B;
const ZERO:  address = @0x0;

// ─── Fixtures ──────────────────────────────────────────────────────────────

fun escrow_id_1(): ID { object::id_from_address(@0xE5C1) }
fun escrow_id_2(): ID { object::id_from_address(@0xE5C2) }

// ─── N — new ───────────────────────────────────────────────────────────────

// N1: new returns OwnerCap with the correct escrow_id; emits one OwnerCapMinted
//     with all three fields matching the call arguments.
#[test]
fun n1_new_returns_cap_and_emits_minted_event() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());

        assert_eq!(owner_cap::escrow_id(&cap), escrow_id_1());

        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(events.length(), 1);
        assert_eq!(owner_cap::minted_owner_cap_id(&events[0]), object::id(&cap));
        assert_eq!(owner_cap::minted_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(owner_cap::minted_owner(&events[0]),         ALICE);

        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// N2: two new calls in one tx with distinct escrow_ids and owners produce
//     two caps with distinct UIDs and two Minted events in call order.
#[test]
fun n2_two_new_calls_produce_distinct_caps_and_events() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap0 = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        let cap1 = owner_cap::new(escrow_id_2(), BOB,   scenario.ctx());

        assert!(object::id(&cap0) != object::id(&cap1));
        assert_eq!(owner_cap::escrow_id(&cap0), escrow_id_1());
        assert_eq!(owner_cap::escrow_id(&cap1), escrow_id_2());

        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(events.length(), 2);
        assert_eq!(owner_cap::minted_owner_cap_id(&events[0]), object::id(&cap0));
        assert_eq!(owner_cap::minted_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(owner_cap::minted_owner(&events[0]),         ALICE);
        assert_eq!(owner_cap::minted_owner_cap_id(&events[1]), object::id(&cap1));
        assert_eq!(owner_cap::minted_escrow_id(&events[1]),    escrow_id_2());
        assert_eq!(owner_cap::minted_owner(&events[1]),         BOB);

        transfer::public_transfer(cap0, ALICE);
        transfer::public_transfer(cap1, BOB);
    };
    scenario.end();
}

// N3: owner field in the event is the declared argument, not tx_context::sender.
//     Sender is ALICE; declared owner is BOB.
#[test]
fun n3_owner_is_declarative_not_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), BOB, scenario.ctx());
        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_owner(&events[0]), BOB);
        transfer::public_transfer(cap, BOB);
    };
    scenario.end();
}

// N4: owner == @0x0 is accepted; event records @0x0.
//     Documents permissiveness at this layer — policy lives in rental_escrow::integrate.
#[test]
fun n4_owner_zero_address_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ZERO, scenario.ctx());
        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_owner(&events[0]), ZERO);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// N5: escrow_id == @0x0 is accepted; event records @0x0.
//     P5 is a construction-side guarantee in rental_escrow::integrate, not here.
#[test]
fun n5_zero_escrow_id_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = owner_cap::new(zero_escrow, ALICE, scenario.ctx());
        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_escrow_id(&events[0]), zero_escrow);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// N6: three new calls sharing an escrow_id produce three distinct caps without
//     aborting. P1 is a structural guarantee at rental_escrow::integrate, not a
//     runtime check in owner_cap::new.
#[test]
fun n6_duplicate_escrow_id_not_rejected_at_new() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap0 = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        let cap1 = owner_cap::new(escrow_id_2(), ALICE, scenario.ctx());
        let cap2 = owner_cap::new(escrow_id_1(), BOB,   scenario.ctx());

        assert!(object::id(&cap0) != object::id(&cap1));
        assert!(object::id(&cap1) != object::id(&cap2));
        assert!(object::id(&cap0) != object::id(&cap2));

        let events = event::events_by_type<OwnerCapMinted>();
        assert_eq!(events.length(), 3);

        transfer::public_transfer(cap0, ALICE);
        transfer::public_transfer(cap1, ALICE);
        transfer::public_transfer(cap2, BOB);
    };
    scenario.end();
}

// ─── B — burn ──────────────────────────────────────────────────────────────

// B1: burn deletes the cap object and emits one OwnerCapBurned with the correct
//     (owner_cap_id, escrow_id, owner) triple.
#[test]
fun b1_burn_deletes_cap_and_emits_burned_event() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        cap_id = object::id(&cap);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<OwnerCap>();
        owner_cap::burn(cap, ALICE);

        let events = event::events_by_type<OwnerCapBurned>();
        assert_eq!(events.length(), 1);
        assert_eq!(owner_cap::burned_owner_cap_id(&events[0]), cap_id);
        assert_eq!(owner_cap::burned_escrow_id(&events[0]),    escrow_id_1());
        assert_eq!(owner_cap::burned_owner(&events[0]),         ALICE);
    };
    assert!(!test_scenario::has_most_recent_for_address<OwnerCap>(ALICE));
    scenario.end();
}

// B2: burn consumes cap by value — a second burn call would not compile.
//     Verified at compile time by the successful build of L1.

// B3: cap minted with owner = ALICE, transferred to BOB, burned with owner = BOB.
//     Burned event captures the burn-time declared holder, not the mint recipient.
#[test]
fun b3_burned_owner_reflects_burn_time_holder() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        cap_id = object::id(&cap);
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(BOB);
    {
        let cap = scenario.take_from_sender<OwnerCap>();
        owner_cap::burn(cap, BOB);

        let events = event::events_by_type<OwnerCapBurned>();
        assert_eq!(owner_cap::burned_owner_cap_id(&events[0]), cap_id);
        assert_eq!(owner_cap::burned_owner(&events[0]),         BOB);
    };
    scenario.end();
}

// B4: caller passes owner = BOB while sender is ALICE — field is declarative.
//     Enables custody patterns; owner is "holder as declared", not "sender as proven".
#[test]
fun b4_burned_owner_is_declarative_not_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        owner_cap::burn(cap, BOB);

        let events = event::events_by_type<OwnerCapBurned>();
        assert_eq!(owner_cap::burned_owner(&events[0]), BOB);
    };
    scenario.end();
}

// B5: burn a cap whose escrow_id is @0x0 — symmetric with N5.
#[test]
fun b5_burn_zero_escrow_id_cap() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = owner_cap::new(zero_escrow, ALICE, scenario.ctx());
        owner_cap::burn(cap, ALICE);

        let events = event::events_by_type<OwnerCapBurned>();
        assert_eq!(owner_cap::burned_escrow_id(&events[0]), zero_escrow);
    };
    scenario.end();
}

// ─── G — escrow_id getter ──────────────────────────────────────────────────

// G1: escrow_id getter returns the value passed at mint.
#[test]
fun g1_escrow_id_getter_returns_bound_id() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        assert_eq!(owner_cap::escrow_id(&cap), escrow_id_1());
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// G2: escrow_id called five times on the same cap always returns the same ID.
#[test]
fun g2_escrow_id_getter_is_pure() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        let mut k: u64 = 0;
        while (k < 5) {
            assert_eq!(owner_cap::escrow_id(&cap), escrow_id_1());
            k = k + 1;
        };
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// G3: escrow_id getter returns @0x0 when the cap was minted with zero ID.
#[test]
fun g3_escrow_id_getter_returns_zero_when_zero() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = owner_cap::new(zero_escrow, ALICE, scenario.ctx());
        assert_eq!(owner_cap::escrow_id(&cap), zero_escrow);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.end();
}

// ─── L — Lifecycle ─────────────────────────────────────────────────────────

// L1: full mint → burn lifecycle. Both events carry the same (owner_cap_id, escrow_id).
//     num_user_events == 1 verified via TransactionEffects for both the mint and burn txs.
#[test]
fun l1_full_lifecycle_mint_then_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        cap_id = object::id(&cap);
        let minted = event::events_by_type<OwnerCapMinted>();
        assert_eq!(minted.length(), 1);
        assert_eq!(owner_cap::minted_owner_cap_id(&minted[0]), cap_id);
        assert_eq!(owner_cap::minted_escrow_id(&minted[0]),    escrow_id_1());
        assert_eq!(owner_cap::minted_owner(&minted[0]),         ALICE);
        transfer::public_transfer(cap, ALICE);
    };
    let mint_effects = scenario.next_tx(ALICE);
    assert_eq!(mint_effects.num_user_events(), 1);
    {
        let cap = scenario.take_from_sender<OwnerCap>();
        owner_cap::burn(cap, ALICE);
        let burned = event::events_by_type<OwnerCapBurned>();
        assert_eq!(burned.length(), 1);
        assert_eq!(owner_cap::burned_owner_cap_id(&burned[0]), cap_id);
        assert_eq!(owner_cap::burned_escrow_id(&burned[0]),    escrow_id_1());
        assert_eq!(owner_cap::burned_owner(&burned[0]),         ALICE);
    };
    let burn_effects = scenario.end();
    assert_eq!(burn_effects.num_user_events(), 1);
}

// L2: mint → transfer to BOB → burn by BOB. Minted carries owner = ALICE,
//     Burned carries owner = BOB. Both share the same (owner_cap_id, escrow_id).
#[test]
fun l2_custody_handoff_mint_transfer_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        cap_id = object::id(&cap);
        let minted = event::events_by_type<OwnerCapMinted>();
        assert_eq!(owner_cap::minted_owner(&minted[0]), ALICE);
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(BOB);
    {
        let cap = scenario.take_from_sender<OwnerCap>();
        owner_cap::burn(cap, BOB);
        let burned = event::events_by_type<OwnerCapBurned>();
        assert_eq!(owner_cap::burned_owner_cap_id(&burned[0]), cap_id);
        assert_eq!(owner_cap::burned_escrow_id(&burned[0]),    escrow_id_1());
        assert_eq!(owner_cap::burned_owner(&burned[0]),         BOB);
    };
    scenario.end();
}

// L3: mint two caps in tx1; burn them in reversed order in tx2.
//     Each cap's Minted and Burned pair is identified by owner_cap_id,
//     proving lifecycle independence even when batched.
#[test]
fun l3_two_caps_batched_reversed_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap0_id: ID;
    let cap1_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap0 = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        let cap1 = owner_cap::new(escrow_id_2(), BOB,   scenario.ctx());
        cap0_id = object::id(&cap0);
        cap1_id = object::id(&cap1);

        let minted = event::events_by_type<OwnerCapMinted>();
        assert_eq!(minted.length(), 2);
        assert_eq!(owner_cap::minted_owner_cap_id(&minted[0]), cap0_id);
        assert_eq!(owner_cap::minted_owner_cap_id(&minted[1]), cap1_id);

        transfer::public_transfer(cap0, ALICE);
        transfer::public_transfer(cap1, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        // Take both caps; burn in reverse order (cap1 first, then cap0).
        let cap0 = scenario.take_from_sender<OwnerCap>();
        let cap1 = scenario.take_from_sender<OwnerCap>();
        let burn_first_id  = object::id(&cap1);
        let burn_second_id = object::id(&cap0);
        owner_cap::burn(cap1, BOB);
        owner_cap::burn(cap0, ALICE);

        let burned = event::events_by_type<OwnerCapBurned>();
        assert_eq!(burned.length(), 2);
        assert_eq!(owner_cap::burned_owner_cap_id(&burned[0]), burn_first_id);
        assert_eq!(owner_cap::burned_owner_cap_id(&burned[1]), burn_second_id);
        assert!(owner_cap::burned_escrow_id(&burned[0]) != owner_cap::burned_escrow_id(&burned[1]));
    };
    scenario.end();
}

// ─── P — Properties ────────────────────────────────────────────────────────

// P2: OwnerCap UID appears in TransactionEffects.deleted() after burn.
//     Authoritative chain-level proof that the object is gone — complements
//     B1's has_most_recent_for_address check with an on-chain effects assertion.
#[test]
fun p2_uid_deleted_on_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        cap_id = object::id(&cap);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<OwnerCap>();
        owner_cap::burn(cap, ALICE);
    };
    let effects = scenario.end();
    assert!(effects.deleted().contains(&cap_id));
}

// new+burn within a single transaction: the UID does NOT appear in
// effects.deleted(). Sui optimizes away objects whose entire lifetime is
// contained within one tx — this applies to both owned and shared ephemeral
// objects. The runtime never writes them to storage, so no deletion record
// exists in the effects. Contrast with p2_uid_deleted_on_burn where the object
// was committed in a prior tx and thus has a deletion record.
#[test]
fun new_burn_same_tx_uid_not_in_deleted() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    {
        let cap = owner_cap::new(escrow_id_1(), ALICE, scenario.ctx());
        cap_id = object::id(&cap);
        owner_cap::burn(cap, ALICE);
    };
    let effects = scenario.end();
    assert!(!effects.deleted().contains(&cap_id));
}
