// Copyright (c) 2026 Antonio Jiménez
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

/// Drain `EarningsMessage`s addressed to the inbox, returning their summed
/// balance as a single `Coin`. Touches only owned objects — no shared escrow —
/// so collection runs at owned-object speed, exactly like fee collection. The
/// inbox is born paired with an `GovernanceCap` via `escrow::integrate`; holding it
/// (bearer) is the sole right to collect.
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
