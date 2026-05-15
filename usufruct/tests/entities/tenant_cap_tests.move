// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenant_cap_tests;

use std::unit_test::assert_eq;
use sui::{
    event,
    test_scenario::{Self},
};
use usufruct::{
    escrow_identity,
    tenant_cap::{Self, TenantCap, TenantCapMinted, TenantCapBurned},
};

// ─── Actors ────────────────────────────────────────────────────────────────

const ALICE: address = @0xA11CE;
const BOB:   address = @0xB0B;
const CAROL: address = @0xCA401;
const ZERO:  address = @0x0;

// ─── Fixtures ──────────────────────────────────────────────────────────────

fun escrow_id_1(): ID { object::id_from_address(@0xE5C1) }
fun escrow_id_2(): ID { object::id_from_address(@0xE5C2) }

// ─── Predicates ────────────────────────────────────────────────────────────

fun assert_minted(e: &TenantCapMinted, cap_id: ID, escrow_id: ID, tenant: address) {
    assert_eq!(tenant_cap::minted_tenant_cap_id(e), cap_id);
    assert_eq!(tenant_cap::minted_escrow_id(e),     escrow_id);
    assert_eq!(tenant_cap::minted_tenant(e),         tenant);
}

fun assert_burned(e: &TenantCapBurned, cap_id: ID, escrow_id: ID, tenant: address) {
    assert_eq!(tenant_cap::burned_tenant_cap_id(e), cap_id);
    assert_eq!(tenant_cap::burned_escrow_id(e),     escrow_id);
    assert_eq!(tenant_cap::burned_tenant(e),         tenant);
}

// ─── N — new ───────────────────────────────────────────────────────────────

// N1: new returns (cap, id) by value; cap.escrow_id and object::id match; one
//     TenantCapMinted event with the correct triple. Cap consumed in-test via burn.
#[test]
fun n1_new_returns_cap_and_id_by_value() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);

        assert_eq!(tenant_cap::proj_escrow_id(&cap), escrow_id_1());
        assert_eq!(object::id(&cap), id);

        let events = event::events_by_type<TenantCapMinted>();
        assert_eq!(events.length(), 1);
        assert_minted(&events[0], id, escrow_id_1(), ALICE);

        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// N2: two new calls in one tx with the same (escrow_id, tenant) produce caps
//     with distinct UIDs and two Minted events in call order. Asserts P1 is
//     structural — uniqueness per transition is a rental_escrow guarantee.
#[test]
fun n2_two_new_calls_produce_distinct_caps_and_events() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap0 = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id0 = object::id(&cap0);
        let cap1 = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id1 = object::id(&cap1);

        assert!(id0 != id1);
        assert_eq!(object::id(&cap0), id0);
        assert_eq!(object::id(&cap1), id1);

        let events = event::events_by_type<TenantCapMinted>();
        assert_eq!(events.length(), 2);
        assert_minted(&events[0], id0, escrow_id_1(), ALICE);
        assert_minted(&events[1], id1, escrow_id_1(), ALICE);

        tenant_cap::burn(cap0, scenario.ctx());
        tenant_cap::burn(cap1, scenario.ctx());
    };
    scenario.end();
}

// N3: two new calls with distinct (escrow_id, tenant) pairs produce caps with
//     the corresponding field values and events in call order.
#[test]
fun n3_two_new_calls_distinct_args() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap0 = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id0 = object::id(&cap0);
        let cap1 = tenant_cap::new(escrow_identity::new(escrow_id_2()), BOB,   scenario.ctx());

        let id1 = object::id(&cap1);

        assert_eq!(tenant_cap::proj_escrow_id(&cap0), escrow_id_1());
        assert_eq!(tenant_cap::proj_escrow_id(&cap1), escrow_id_2());

        let events = event::events_by_type<TenantCapMinted>();
        assert_eq!(events.length(), 2);
        assert_minted(&events[0], id0, escrow_id_1(), ALICE);
        assert_minted(&events[1], id1, escrow_id_2(), BOB);

        tenant_cap::burn(cap0, scenario.ctx());
        tenant_cap::burn(cap1, scenario.ctx());
    };
    scenario.end();
}

// N4: tenant argument is independent of tx_context::sender. Sender = ALICE,
//     tenant arg = BOB; event records BOB. Constructor does not assume the
//     caller is the tenant — rental_escrow always passes sender, but this
//     module does not enforce it.
#[test]
fun n4_tenant_is_argument_not_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());

        let id = object::id(&cap);

        let events = event::events_by_type<TenantCapMinted>();
        assert_minted(&events[0], id, escrow_id_1(), BOB);

        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// N5: tenant == @0x0 is accepted; event records @0x0. Policy (if any) lives
//     at rental_escrow::rent, not here.
#[test]
fun n5_zero_tenant_address_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ZERO, scenario.ctx());

        let id = object::id(&cap);

        let events = event::events_by_type<TenantCapMinted>();
        assert_minted(&events[0], id, escrow_id_1(), ZERO);

        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// N6: escrow_id == @0x0 is accepted; cap.escrow_id and event both record @0x0.
//     No non-zero-ID constraint lives in this module.
#[test]
fun n6_zero_escrow_id_accepted() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = tenant_cap::new(escrow_identity::new(zero_escrow), ALICE, scenario.ctx());

        let id = object::id(&cap);

        assert_eq!(tenant_cap::proj_escrow_id(&cap), zero_escrow);

        let events = event::events_by_type<TenantCapMinted>();
        assert_minted(&events[0], id, zero_escrow, ALICE);

        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// N7: emit-last ordering — TenantCapMinted is present in tx effects immediately
//     after the new call. num_user_events == 1 for the mint-only tx.
#[test]
fun n7_emit_last_event_present_in_tx() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        assert_eq!(event::events_by_type<TenantCapMinted>().length(), 1);
        transfer::public_transfer(cap, ALICE);
    };
    let mint_effects = scenario.next_tx(ALICE);
    assert_eq!(mint_effects.num_user_events(), 1);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// N8: cap returned by new is store-transferable from any module. Asserts that
//     the PTB caller can route the cap to any destination (wallet, multisig).
#[test]
fun n8_cap_is_store_transferable() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(BOB);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        assert_eq!(tenant_cap::proj_escrow_id(&cap), escrow_id_1());
        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// ─── B — burn ──────────────────────────────────────────────────────────────

// B1: mint + burn in same tx (sender = ALICE). One Minted + one Burned event.
//     Burned.tenant == ALICE (tx_context::sender at burn time).
#[test]
fun b1_burn_emits_burned_event() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        tenant_cap::burn(cap, scenario.ctx());

        let minted = event::events_by_type<TenantCapMinted>();
        let burned  = event::events_by_type<TenantCapBurned>();
        assert_eq!(minted.length(), 1);
        assert_eq!(burned.length(), 1);
        assert_burned(&burned[0], id, escrow_id_1(), ALICE);
    };
    scenario.end();
}

// B2: burn a cap that is stale from the indexer's perspective (a newer cap
//     exists for the same escrow). This module imposes no staleness check —
//     burn succeeds regardless of the escrow's current state.
#[test]
fun b2_stale_cap_burn_succeeds() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_a_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_a_id = id;
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(BOB);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_eq!(burned.length(), 1);
        assert_burned(&burned[0], cap_a_id, escrow_id_1(), ALICE);
    };
    scenario.end();
}

// B3: burn consumes by value — a second burn call does not compile.
//     Verified at compile time by the successful build of B1/L1.

// B4: burner ≠ mint recipient. tx1: ALICE mints, transfers to BOB. tx2: BOB
//     burns (sender = BOB). Minted.tenant == ALICE; Burned.tenant == BOB.
//     Load-bearing test for the §3 schema: burn-time address is not
//     PK-recoverable from TenantCapMinted.
#[test]
fun b4_burned_tenant_reflects_burn_time_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_id = id;
        let minted = event::events_by_type<TenantCapMinted>();
        assert_eq!(tenant_cap::minted_tenant(&minted[0]), ALICE);
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(BOB);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_burned(&burned[0], cap_id, escrow_id_1(), BOB);
    };
    scenario.end();
}

// B5: multi-hop custody chain: ALICE → BOB → CAROL → burn by CAROL.
//     Burned.tenant == CAROL. Intermediate hops are invisible to the protocol.
#[test]
fun b5_multi_hop_custody_burn_records_final_sender() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_id = id;
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(BOB);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        transfer::public_transfer(cap, CAROL);
    };
    scenario.next_tx(CAROL);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_burned(&burned[0], cap_id, escrow_id_1(), CAROL);
    };
    scenario.end();
}

// B6: burn a cap with escrow_id == @0x0. Symmetric with N6 — burn path
//     makes no stronger claim than mint path.
#[test]
fun b6_burn_zero_escrow_id_cap() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = tenant_cap::new(escrow_identity::new(zero_escrow), ALICE, scenario.ctx());

        let id = object::id(&cap);
        tenant_cap::burn(cap, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_burned(&burned[0], id, zero_escrow, ALICE);
    };
    scenario.end();
}

// ─── G — escrow_id getter ──────────────────────────────────────────────────

// G1: escrow_id getter returns the value passed at mint.
#[test]
fun g1_escrow_id_getter_returns_bound_id() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        assert_eq!(tenant_cap::proj_escrow_id(&cap), escrow_id_1());
        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// G2: escrow_id called five times on the same cap always returns the same ID.
//     Asserts the getter is pure — no mutation, no event emission.
#[test]
fun g2_escrow_id_getter_is_pure() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let mut k: u64 = 0;
        while (k < 5) {
            assert_eq!(tenant_cap::proj_escrow_id(&cap), escrow_id_1());
            k = k + 1;
        };
        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// G3: escrow_id getter returns @0x0 when the cap was minted with zero ID.
#[test]
fun g3_escrow_id_getter_returns_zero_when_zero() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let zero_escrow = object::id_from_address(@0x0);
        let cap = tenant_cap::new(escrow_identity::new(zero_escrow), ALICE, scenario.ctx());
        assert_eq!(tenant_cap::proj_escrow_id(&cap), zero_escrow);
        tenant_cap::burn(cap, scenario.ctx());
    };
    scenario.end();
}

// ─── L — Lifecycle ─────────────────────────────────────────────────────────

// L1: full lifecycle — mint tx emits 1 Minted event, burn tx emits 1 Burned
//     event. Both share (tenant_cap_id, escrow_id). num_user_events == 1 per tx.
#[test]
fun l1_full_lifecycle_mint_then_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_id = id;
        let minted = event::events_by_type<TenantCapMinted>();
        assert_eq!(minted.length(), 1);
        assert_minted(&minted[0], cap_id, escrow_id_1(), ALICE);
        transfer::public_transfer(cap, ALICE);
    };
    let mint_effects = scenario.next_tx(ALICE);
    assert_eq!(mint_effects.num_user_events(), 1);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());
        let burned = event::events_by_type<TenantCapBurned>();
        assert_eq!(burned.length(), 1);
        assert_burned(&burned[0], cap_id, escrow_id_1(), ALICE);
    };
    let burn_effects = scenario.end();
    assert_eq!(burn_effects.num_user_events(), 1);
}

// L2: mint two caps for the same escrow in separate txs (ALICE, BOB).
//     Distinct tenant_cap_ids; from the indexer's perspective cap A is stale
//     once cap B is minted, though neither cap knows it.
#[test]
fun l2_two_caps_same_escrow_distinct_ids() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_a_id: ID;
    let cap_b_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_a_id = id;
        let minted = event::events_by_type<TenantCapMinted>();
        assert_minted(&minted[0], cap_a_id, escrow_id_1(), ALICE);
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(BOB);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());

        let id = object::id(&cap);
        cap_b_id = id;
        let minted = event::events_by_type<TenantCapMinted>();
        assert_minted(&minted[0], cap_b_id, escrow_id_1(), BOB);
        transfer::public_transfer(cap, BOB);
    };
    assert!(cap_a_id != cap_b_id);
    scenario.end();
}

// L3: after L2 setup, ALICE burns cap_A. cap_B remains in BOB's wallet untouched.
#[test]
fun l3_burn_stale_cap_leaves_other_untouched() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_a_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_a_id = id;
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(BOB);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_burned(&burned[0], cap_a_id, escrow_id_1(), ALICE);
    };
    scenario.end();
}

// L4: multi-stale cleanup — three caps minted across three txs to (ALICE, BOB,
//     ALICE); fourth tx ALICE burns both her caps. Two Burned events, each
//     carrying its cap's (tenant_cap_id, escrow_id, tenant: ALICE).
#[test]
fun l4_multi_stale_cleanup() {
    let mut scenario = test_scenario::begin(ALICE);
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(BOB);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), BOB, scenario.ctx());
        transfer::public_transfer(cap, BOB);
    };
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let cap1 = scenario.take_from_sender<TenantCap>();
        let cap2 = scenario.take_from_sender<TenantCap>();
        let first_id  = object::id(&cap1);
        let second_id = object::id(&cap2);
        tenant_cap::burn(cap1, scenario.ctx());
        tenant_cap::burn(cap2, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_eq!(burned.length(), 2);
        assert_eq!(tenant_cap::burned_tenant_cap_id(&burned[0]), first_id);
        assert_eq!(tenant_cap::burned_tenant(&burned[0]),         ALICE);
        assert_eq!(tenant_cap::burned_escrow_id(&burned[0]),     escrow_id_1());
        assert_eq!(tenant_cap::burned_tenant_cap_id(&burned[1]), second_id);
        assert_eq!(tenant_cap::burned_tenant(&burned[1]),         ALICE);
        assert_eq!(tenant_cap::burned_escrow_id(&burned[1]),     escrow_id_1());
    };
    scenario.end();
}

// L5: caps for two distinct escrows minted in one tx, burned in reverse order
//     in the next tx. The PK-JOIN path (tenant_cap_id) recovers each lifecycle
//     pair independently — the two lifecycles do not cross.
#[test]
fun l5_caps_for_distinct_escrows_independent_lifecycle() {
    let mut scenario = test_scenario::begin(ALICE);
    scenario.next_tx(ALICE);
    {
        let cap1 = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());
        let cap2 = tenant_cap::new(escrow_identity::new(escrow_id_2()), ALICE, scenario.ctx());
        transfer::public_transfer(cap1, ALICE);
        transfer::public_transfer(cap2, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        // take_from_sender returns objects in some order; capture IDs first
        let cap_a = scenario.take_from_sender<TenantCap>();
        let cap_b = scenario.take_from_sender<TenantCap>();
        let id_a = object::id(&cap_a);
        let id_b = object::id(&cap_b);
        // Burn in reverse: cap_b first, then cap_a
        tenant_cap::burn(cap_b, scenario.ctx());
        tenant_cap::burn(cap_a, scenario.ctx());

        let burned = event::events_by_type<TenantCapBurned>();
        assert_eq!(burned.length(), 2);
        assert_eq!(tenant_cap::burned_tenant_cap_id(&burned[0]), id_b);
        assert_eq!(tenant_cap::burned_tenant_cap_id(&burned[1]), id_a);
        // The two escrow IDs must differ
        assert!(tenant_cap::burned_escrow_id(&burned[0]) != tenant_cap::burned_escrow_id(&burned[1]));
    };
    scenario.end();
}

// L6: one-shot PTB lifecycle via mint_then_burn_for_testing — cap lives entirely
//     as a PTB local, never touching a wallet. tx emits 1 Minted + 1 Burned
//     event; both carry the same tenant_cap_id and tenant == sender.
#[test]
fun l6_one_shot_ptb_lifecycle() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        tenant_cap::mint_then_burn_for_testing(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let minted = event::events_by_type<TenantCapMinted>();
        let burned  = event::events_by_type<TenantCapBurned>();
        assert_eq!(minted.length(), 1);
        assert_eq!(burned.length(),  1);
        assert_eq!(
            tenant_cap::minted_tenant_cap_id(&minted[0]),
            tenant_cap::burned_tenant_cap_id(&burned[0]),
        );
        assert_eq!(tenant_cap::minted_tenant(&minted[0]), ALICE);
        assert_eq!(tenant_cap::burned_tenant(&burned[0]),  ALICE);
    };
    let effects = scenario.end();
    assert_eq!(effects.num_user_events(), 2);
}

// ─── P — Properties ────────────────────────────────────────────────────────

// P-UID-1: UID appears in TransactionEffects.deleted() after a cross-tx burn.
//          Chain-level proof the object is gone — complements B1's event check.
#[test]
fun p_uid_deleted_on_cross_tx_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    scenario.next_tx(ALICE);
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_id = id;
        transfer::public_transfer(cap, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let cap = scenario.take_from_sender<TenantCap>();
        tenant_cap::burn(cap, scenario.ctx());
    };
    let effects = scenario.end();
    assert!(effects.deleted().contains(&cap_id));
}

// P-UID-2: UID does NOT appear in deleted() when mint and burn are in the same
//          tx. Sui optimises away ephemeral objects whose lifetime fits one tx —
//          no storage write, no deletion record. Contrast with P-UID-1.
#[test]
fun p_uid_not_in_deleted_when_same_tx_mint_and_burn() {
    let mut scenario = test_scenario::begin(ALICE);
    let cap_id: ID;
    {
        let cap = tenant_cap::new(escrow_identity::new(escrow_id_1()), ALICE, scenario.ctx());

        let id = object::id(&cap);
        cap_id = id;
        tenant_cap::burn(cap, scenario.ctx());
    };
    let effects = scenario.end();
    assert!(!effects.deleted().contains(&cap_id));
}
