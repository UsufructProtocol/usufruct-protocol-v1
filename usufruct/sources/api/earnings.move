// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::earnings;

// === Imports ===

use sui::{
    coin::Coin,
    transfer::Receiving,
};
use usufruct::{
    earnings_inbox::EarningsInbox,
    earnings_message::{Self, EarningsMessage},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun collect_earnings_messages<C>(
    inbox:   &mut EarningsInbox,
    tickets: vector<Receiving<EarningsMessage<C>>>,
    ctx:     &mut TxContext,
): Coin<C> {
    earnings_message::collect_earnings_messages(inbox, tickets, ctx)
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
