// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::protocol_fee_inbox;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct ProtocolFeeInbox has key, store {
    id: UID,
}

public struct ProtocolFeeRef has key {
    id:       UID,
    inbox_id: ID,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// Returns the ID of the `ProtocolFeeInbox` this ref points to.
public fun inbox_id(fee_ref: &ProtocolFeeRef): ID {
    fee_ref.inbox_id
}

// === Admin Functions ===

// === Package Functions ===

/// Exposes `&mut UID` of `ProtocolFeeInbox` so `fee_message` can call
/// `transfer::receive` against it.
public(package) fun uid_mut(inbox: &mut ProtocolFeeInbox): &mut UID {
    &mut inbox.id
}

// === Private Functions ===

fun init(ctx: &mut TxContext) {
    let inbox = ProtocolFeeInbox {
        id: object::new(ctx),
    };
    let fee_ref = ProtocolFeeRef {
        id:       object::new(ctx),
        inbox_id: object::id(&inbox),
    };
    transfer::public_transfer(inbox, ctx.sender());
    transfer::freeze_object(fee_ref);
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
