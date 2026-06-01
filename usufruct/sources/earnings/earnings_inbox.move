// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::earnings_inbox;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct EarningsInbox has key, store {
    id: UID,
}

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
