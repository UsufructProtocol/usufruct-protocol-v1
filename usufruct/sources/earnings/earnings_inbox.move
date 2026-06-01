// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::earnings_inbox;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// Receives an escrow's governor-earnings as `EarningsMessage` objects. `key +
/// store`, so it is itself integrable into a usufruct escrow — the coupon-strip
/// primitive: rent the income stream apart from the `GovernanceCap` that governs the
/// escrow. Born only via `escrow::integrate`, paired once with an `GovernanceCap`;
/// after birth the two are independent objects.
public struct EarningsInbox has key, store {
    id: UID,
}

/// Copy/drop projection of an inbox's object ID. Stored inside `GovernorSeat` as the
/// permanent earnings destination and carried by every `EarningsMessage`. Mirrors
/// `FeeInboxIdentity` — a value, never an object, so it crosses module borders
/// without touching the object store.
public struct EarningsInboxIdentity has copy, drop, store { id: ID }

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun identity(inbox: &EarningsInbox): EarningsInboxIdentity {
    EarningsInboxIdentity { id: object::id(inbox) }
}

public(package) fun inbox_identity(id: ID): EarningsInboxIdentity { EarningsInboxIdentity { id } }

public(package) fun proj_id(i: EarningsInboxIdentity): ID { i.id }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(ctx: &mut TxContext): EarningsInbox {
    EarningsInbox { id: object::new(ctx) }
}

public(package) fun uid_mut(inbox: &mut EarningsInbox): &mut UID {
    &mut inbox.id
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): EarningsInbox { new(ctx) }
