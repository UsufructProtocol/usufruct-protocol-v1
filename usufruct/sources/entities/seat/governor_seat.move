// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::governor_seat;

// === Imports ===

use usufruct::{
    earnings_inbox::EarningsInboxIdentity,
    governance_cap::GovernanceCapIdentity,
    governor_identity::{Self, GovernorIdentity},
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct GovernorSeat has store {
    identity: GovernorIdentity,
    inbox:    EarningsInboxIdentity,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity(o: &GovernorSeat): &GovernorIdentity      { &o.identity }
public(package) fun proj_inbox(o: &GovernorSeat):    EarningsInboxIdentity { o.inbox }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(cap_identity: GovernanceCapIdentity, inbox: EarningsInboxIdentity): GovernorSeat {
    GovernorSeat {
        identity: governor_identity::new(cap_identity),
        inbox,
    }
}

public(package) fun destroy(o: GovernorSeat) {
    let GovernorSeat { .. } = o;
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(o: GovernorSeat) {
    destroy(o)
}
