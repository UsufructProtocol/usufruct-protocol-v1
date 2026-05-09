// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::protocol_fee_ref;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// Immutable pointer to the `ProtocolFeeInbox`. Frozen at deploy time;
/// no fields are ever mutated after creation. Any caller can read it
/// as `&ProtocolFeeRef` to obtain the fee inbox address.
public struct ProtocolFeeRef has key {
    id:       UID,
    inbox_id: ID,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// Returns the ID of the `ProtocolFeeInbox` this ref points to.
public fun proj_inbox_id(fee_ref: &ProtocolFeeRef): ID {
    fee_ref.inbox_id
}

// === Admin Functions ===

// === Package Functions ===

/// Constructs and freezes the ref stamped with `inbox_id`. Called once
/// from `protocol_fee_inbox::init`, which supplies `object::id(&inbox)`.
/// `ProtocolFeeRef` is `key`-only so freeze must happen within this module.
public(package) fun create_and_freeze(inbox_id: ID, ctx: &mut TxContext) {
    transfer::freeze_object(ProtocolFeeRef { id: object::new(ctx), inbox_id });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun create_and_freeze_for_testing(inbox_id: ID, ctx: &mut TxContext) {
    create_and_freeze(inbox_id, ctx)
}
