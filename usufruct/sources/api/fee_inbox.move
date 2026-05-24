// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::fee_inbox;

// === Imports ===

use sui::{
    coin::Coin,
    transfer::Receiving,
};
use usufruct::{
    fee_message::{Self, FeeMessage},
    protocol_fee_inbox::ProtocolFeeInbox,
    protocol_fee_ref::{Self, ProtocolFeeRef},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun collect_fee_messages<C>(
    inbox:   &mut ProtocolFeeInbox,
    tickets: vector<Receiving<FeeMessage<C>>>,
    ctx:     &mut TxContext,
): Coin<C> {
    fee_message::collect_fee_messages(inbox, tickets, ctx)
}

// === View Functions ===

public fun inbox_id(fee_ref: &ProtocolFeeRef): ID {
    protocol_fee_ref::proj_inbox_id(fee_ref)
}

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
