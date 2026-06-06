// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::protocol_fee_inbox;

// === Imports ===

use usufruct::protocol_fee_ref;

// === Errors ===

// === Constants ===

// === Structs ===

public struct ProtocolFeeInbox has key, store {
    id: UID,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun uid_mut(inbox: &mut ProtocolFeeInbox): &mut UID {
    &mut inbox.id
}

// === Private Functions ===

fun init(ctx: &mut TxContext) {
    let inbox = ProtocolFeeInbox { id: object::new(ctx) };
    protocol_fee_ref::create_and_freeze(object::id(&inbox), ctx);
    transfer::public_transfer(inbox, ctx.sender());
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

