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

public fun inbox_id(_fee_ref: &ProtocolFeeRef): ID {
    abort 0
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun uid_mut(_inbox: &mut ProtocolFeeInbox): &mut UID {
    abort 0
}

// === Private Functions ===

fun init(_ctx: &mut TxContext) {
    abort 0
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
