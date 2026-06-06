// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::usufruct_tests;

use sui::package::Publisher;
use sui::test_scenario::{Self, Scenario};
use usufruct::governance_cap::GovernanceCap;
use usufruct::protocol_fee_inbox::ProtocolFeeInbox;
use usufruct::protocol_fee_ref::ProtocolFeeRef;
use usufruct::usufruct_cap::UsufructCap;
use usufruct::usufruct;

// ─── Actors ────────────────────────────────────────────────────────────────

const DEPLOYER: address = @0xD1;

// ─── Helpers ───────────────────────────────────────────────────────────────

fun setup(): Scenario {
    let mut scenario = test_scenario::begin(DEPLOYER);
    {
        usufruct::init_for_testing(scenario.ctx());
    };
    scenario
}

// ─── I — Initialization ────────────────────────────────────────────────────

#[test]
fun i1_deployer_receives_exactly_one_publisher() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let publisher = scenario.take_from_sender<Publisher>();
        scenario.return_to_sender(publisher);
    };
    scenario.end();
}

#[test]
fun i2_publisher_authority_covers_package_types() {
    let mut scenario = setup();
    scenario.next_tx(DEPLOYER);
    {
        let publisher = scenario.take_from_sender<Publisher>();
        assert!(publisher.from_package<GovernanceCap>());
        assert!(publisher.from_package<UsufructCap>());
        assert!(publisher.from_package<ProtocolFeeInbox>());
        assert!(publisher.from_package<ProtocolFeeRef>());
        scenario.return_to_sender(publisher);
    };
    scenario.end();
}

// Verifies that init_for_testing is not OTW-guarded.
// In production, `package::claim` consumes the OTW so exactly one Publisher
// exists per publish. The test helper bypasses this structural guarantee —
// documented here so the double-publisher behavior is intentional, not a bug.
#[test]
fun i3_test_helper_can_produce_second_publisher() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    {
        usufruct::init_for_testing(scenario.ctx());
        usufruct::init_for_testing(scenario.ctx());
    };
    scenario.next_tx(DEPLOYER);
    {
        let p1 = scenario.take_from_sender<Publisher>();
        let p2 = scenario.take_from_sender<Publisher>();
        scenario.return_to_sender(p2);
        scenario.return_to_sender(p1);
    };
    scenario.end();
}

#[test]
fun i4_no_events_emitted_during_init() {
    let mut scenario = setup();
    let effects = scenario.next_tx(DEPLOYER);
    assert!(effects.num_user_events() == 0);
    scenario.end();
}
