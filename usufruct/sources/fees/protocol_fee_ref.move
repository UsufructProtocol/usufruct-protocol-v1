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
    proj_id: FeeInboxIdentity,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public fun proj_inbox_id(fee_ref: &ProtocolFeeRef): ID {
    proj_id(fee_ref.proj_id)
}

public(package) fun proj_inbox_identity(fee_ref: &ProtocolFeeRef): FeeInboxIdentity {
    fee_ref.proj_id
}

public(package) fun fee_inbox_identity(id: ID): FeeInboxIdentity { FeeInboxIdentity { id } }

public(package) fun proj_id(i: FeeInboxIdentity): ID { i.id }

// === Admin Functions ===

// === Package Functions ===

public(package) fun create_and_freeze(proj_id: ID, ctx: &mut TxContext) {
    transfer::freeze_object(ProtocolFeeRef { id: object::new(ctx), proj_id: fee_inbox_identity(proj_id) });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun create_and_freeze_for_testing(proj_id: ID, ctx: &mut TxContext) {
    create_and_freeze(proj_id, ctx)
}

