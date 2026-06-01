// Copyright (c) 2026 Antonio Jiménez
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

/// The governor's record inside an escrow. Holds no balance: governor earnings are
/// settled directly to the `EarningsInbox` as `EarningsMessage` objects, never
/// accumulated here. Two immutable identities, both set once at integrate:
/// `identity` records the governing `GovernanceCap`; `inbox` records the permanent
/// earnings destination. Coin-agnostic — no phantom CoinType.
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
