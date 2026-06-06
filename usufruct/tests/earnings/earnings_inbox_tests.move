// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::earnings_inbox_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::earnings_inbox::{Self, EarningsInbox};

const ALICE: address = @0xA1;
const BOB:   address = @0xB2;

// ─── N — new ─────────────────────────────────────────────────────────────────

// N1: new mints an EarningsInbox the caller owns.
#[test]
fun n1_new_mints_owned_inbox() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let inbox = earnings_inbox::new_for_testing(scenario.ctx());
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        assert!(scenario.has_most_recent_for_sender<EarningsInbox>());
        let inbox = scenario.take_from_sender<EarningsInbox>();
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}

// N2: two mints yield two distinct inbox IDs — multiplicity is allowed.
#[test]
fun n2_two_inboxes_have_distinct_ids() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let a = earnings_inbox::new_for_testing(scenario.ctx());
        let b = earnings_inbox::new_for_testing(scenario.ctx());
        assert!(object::id(&a) != object::id(&b));
        transfer::public_transfer(a, ALICE);
        transfer::public_transfer(b, ALICE);
    };
    scenario.end();
}

// ─── I — identity ────────────────────────────────────────────────────────────

// I1: identity(inbox) projects to the inbox's own object ID.
#[test]
fun i1_identity_matches_object_id() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let inbox = earnings_inbox::new_for_testing(scenario.ctx());
        let id    = object::id(&inbox);
        assert_eq!(earnings_inbox::proj_id(earnings_inbox::identity(&inbox)), id);
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.end();
}

// I2: inbox_identity(id) round-trips through proj_id.
#[test]
fun i2_inbox_identity_round_trips() {
    let id = object::id_from_address(@0xCAFE);
    assert_eq!(earnings_inbox::proj_id(earnings_inbox::inbox_identity(id)), id);
}

// I3: identities from distinct inboxes are distinct.
#[test]
fun i3_distinct_inboxes_distinct_identities() {
    let mut scenario = test_scenario::begin(ALICE);
    {
        let a = earnings_inbox::new_for_testing(scenario.ctx());
        let b = earnings_inbox::new_for_testing(scenario.ctx());
        assert!(earnings_inbox::proj_id(earnings_inbox::identity(&a))
              != earnings_inbox::proj_id(earnings_inbox::identity(&b)));
        transfer::public_transfer(a, ALICE);
        transfer::public_transfer(b, ALICE);
    };
    scenario.end();
}

// ─── C — custody ─────────────────────────────────────────────────────────────

// C1: inbox is store + key — transferable across addresses, ID stable.
#[test]
fun c1_inbox_transfers_preserving_id() {
    let mut scenario = test_scenario::begin(ALICE);
    let inbox_id;
    {
        let inbox = earnings_inbox::new_for_testing(scenario.ctx());
        inbox_id  = object::id(&inbox);
        transfer::public_transfer(inbox, ALICE);
    };
    scenario.next_tx(ALICE);
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        transfer::public_transfer(inbox, BOB);
    };
    scenario.next_tx(BOB);
    {
        let inbox = scenario.take_from_sender<EarningsInbox>();
        assert_eq!(object::id(&inbox), inbox_id);
        scenario.return_to_sender(inbox);
    };
    scenario.end();
}
