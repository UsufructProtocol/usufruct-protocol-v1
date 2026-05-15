// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::protocol_fee_ref;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct FeeInboxIdentity has copy, drop, store { id: ID }

public struct ProtocolFeeRef has key {
    id:       UID,
    inbox_id: ID,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public fun proj_inbox_id(fee_ref: &ProtocolFeeRef): ID {
    fee_ref.inbox_id
}

public(package) fun proj_inbox_identity(fee_ref: &ProtocolFeeRef): FeeInboxIdentity {
    FeeInboxIdentity { id: fee_ref.inbox_id }
}

public(package) fun fee_inbox_identity(id: ID): FeeInboxIdentity { FeeInboxIdentity { id } }

public(package) fun inbox_id(i: FeeInboxIdentity): ID { i.id }

// === Admin Functions ===

// === Package Functions ===

public(package) fun create_and_freeze(inbox_id: ID, ctx: &mut TxContext) {
    transfer::freeze_object(ProtocolFeeRef { id: object::new(ctx), inbox_id });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun create_and_freeze_for_testing(inbox_id: ID, ctx: &mut TxContext) {
    create_and_freeze(inbox_id, ctx)
}

