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

// === Public Functions ===

public fun collect_fee_messages<C>(
    inbox:   &mut ProtocolFeeInbox,
    tickets: vector<Receiving<FeeMessage<C>>>,
    ctx:     &mut TxContext,
): Coin<C> {
    fee_message::collect_fee_messages(inbox, tickets, ctx)
}

public fun proj_inbox_id(fee_ref: &ProtocolFeeRef): ID {
    protocol_fee_ref::proj_inbox_id(fee_ref)
}
