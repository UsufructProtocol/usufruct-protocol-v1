// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_seat;

// === Imports ===

use usufruct::{
    earnings_inbox::EarningsInboxIdentity,
    owner_cap::OwnerCapIdentity,
    owner_identity::{Self, OwnerIdentity},
};

// === Errors ===

// === Constants ===

// === Structs ===

/// The owner's record inside an escrow. Holds no balance: owner earnings are
/// settled directly to the `EarningsInbox` as `EarningsMessage` objects, never
/// accumulated here. Two immutable identities, both set once at integrate:
/// `identity` records the governing `OwnerCap`; `inbox` records the permanent
/// earnings destination. Coin-agnostic — no phantom CoinType.
public struct OwnerSeat has store {
    identity: OwnerIdentity,
    inbox:    EarningsInboxIdentity,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity(o: &OwnerSeat): &OwnerIdentity      { &o.identity }
public(package) fun proj_inbox(o: &OwnerSeat):    EarningsInboxIdentity { o.inbox }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(cap_identity: OwnerCapIdentity, inbox: EarningsInboxIdentity): OwnerSeat {
    OwnerSeat {
        identity: owner_identity::new(cap_identity),
        inbox,
    }
}

public(package) fun destroy(o: OwnerSeat) {
    let OwnerSeat { .. } = o;
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing(o: OwnerSeat) {
    destroy(o)
}
