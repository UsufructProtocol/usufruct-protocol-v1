// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::governor_seat_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::{
    earnings_inbox,
    escrow_identity,
    governor_seat,
    governor_identity,
    governance_cap::{Self, GovernanceCap, GovernanceCapIdentity},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const GOVERNOR_ADDR: address = @0xA1;

fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun mk_cap(ctx: &mut TxContext): (GovernanceCap, GovernanceCapIdentity) {
    let cap    = governance_cap::new(escrow_identity::new(fake_escrow_id()), GOVERNOR_ADDR, ctx);
    let cap_id = governance_cap::identity(&cap);
    (cap, cap_id)
}

// ─── §1. Constructor and accessors ────────────────────────────────────────────

// The seat records two immutable identities — the governing cap and the
// permanent earnings inbox — and holds no balance.
#[test]
fun new_carries_cap_identity_and_inbox() {
    let mut sc = test_scenario::begin(GOVERNOR_ADDR);
    sc.next_tx(GOVERNOR_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let inbox_id      = earnings_inbox::inbox_identity(object::id_from_address(@0x1B0));
        let o = governor_seat::new(cap_id, inbox_id);
        assert_eq!(governor_identity::proj_cap_identity(governor_seat::proj_identity(&o)), cap_id);
        assert_eq!(earnings_inbox::proj_id(governor_seat::proj_inbox(&o)),
                   earnings_inbox::proj_id(inbox_id));
        governor_seat::destroy_for_testing(o);
        transfer::public_transfer(cap, GOVERNOR_ADDR);
    };
    sc.end();
}

// proj_inbox round-trips the exact inbox identity it was built with.
#[test]
fun proj_inbox_round_trips() {
    let mut sc = test_scenario::begin(GOVERNOR_ADDR);
    sc.next_tx(GOVERNOR_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let raw_inbox_id  = object::id_from_address(@0xB0B0);
        let inbox_id      = earnings_inbox::inbox_identity(raw_inbox_id);
        let o = governor_seat::new(cap_id, inbox_id);
        assert_eq!(earnings_inbox::proj_id(governor_seat::proj_inbox(&o)), raw_inbox_id);
        governor_seat::destroy_for_testing(o);
        transfer::public_transfer(cap, GOVERNOR_ADDR);
    };
    sc.end();
}

// ─── §2. destroy ────────────────────────────────────────────────────────────────

#[test]
fun destroy_consumes_seat() {
    let mut sc = test_scenario::begin(GOVERNOR_ADDR);
    sc.next_tx(GOVERNOR_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let inbox_id      = earnings_inbox::inbox_identity(object::id_from_address(@0x1B0));
        let o = governor_seat::new(cap_id, inbox_id);
        governor_seat::destroy(o);
        transfer::public_transfer(cap, GOVERNOR_ADDR);
    };
    sc.end();
}
