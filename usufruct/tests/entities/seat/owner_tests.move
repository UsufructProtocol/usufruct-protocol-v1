// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::{
    earnings_inbox,
    escrow_identity,
    owner_seat,
    owner_identity,
    owner_cap::{Self, OwnerCap, OwnerCapIdentity},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER_ADDR: address = @0xA1;

fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun mk_cap(ctx: &mut TxContext): (OwnerCap, OwnerCapIdentity) {
    let cap    = owner_cap::new(escrow_identity::new(fake_escrow_id()), OWNER_ADDR, ctx);
    let cap_id = owner_cap::identity(&cap);
    (cap, cap_id)
}

// ─── §1. Constructor and accessors ────────────────────────────────────────────

// The seat records two immutable identities — the governing cap and the
// permanent earnings inbox — and holds no balance.
#[test]
fun new_carries_cap_identity_and_inbox() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let inbox_id      = earnings_inbox::inbox_identity(object::id_from_address(@0x1B0));
        let o = owner_seat::new(cap_id, inbox_id);
        assert_eq!(owner_identity::proj_cap_identity(owner_seat::proj_identity(&o)), cap_id);
        assert_eq!(earnings_inbox::proj_id(owner_seat::proj_inbox(&o)),
                   earnings_inbox::proj_id(inbox_id));
        owner_seat::destroy_for_testing(o);
        transfer::public_transfer(cap, OWNER_ADDR);
    };
    sc.end();
}

// proj_inbox round-trips the exact inbox identity it was built with.
#[test]
fun proj_inbox_round_trips() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let raw_inbox_id  = object::id_from_address(@0xB0B0);
        let inbox_id      = earnings_inbox::inbox_identity(raw_inbox_id);
        let o = owner_seat::new(cap_id, inbox_id);
        assert_eq!(earnings_inbox::proj_id(owner_seat::proj_inbox(&o)), raw_inbox_id);
        owner_seat::destroy_for_testing(o);
        transfer::public_transfer(cap, OWNER_ADDR);
    };
    sc.end();
}

// ─── §2. destroy ────────────────────────────────────────────────────────────────

#[test]
fun destroy_consumes_seat() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let inbox_id      = earnings_inbox::inbox_identity(object::id_from_address(@0x1B0));
        let o = owner_seat::new(cap_id, inbox_id);
        owner_seat::destroy(o);
        transfer::public_transfer(cap, OWNER_ADDR);
    };
    sc.end();
}
