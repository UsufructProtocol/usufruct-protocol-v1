// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::route_fund;

// === Imports ===

use sui::coin;
use usufruct::{
    fee_message,
    tenant_state::{Self, Tenant},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Consume a departing `Tenant`, split the protocol fee, post it to the
/// fee inbox, and transfer the remainder to the tenant's address.
/// Returns `(cap_id, addr)` — the tenant's identity — for the caller
/// to use in event emission or further bookkeeping.
public(package) fun route<C>(
    departing:    Tenant<C>,
    fee_amount:   u64,
    escrow_id:    ID,
    fee_inbox_id: ID,
    ctx:          &mut TxContext,
): (ID, address) {
    let (departing, fee_balance) = tenant_state::split(departing, fee_amount);
    let (cap_id, addr, refund)   = tenant_state::unbundle(departing);
    fee_message::post(fee_balance, escrow_id, addr, fee_inbox_id, ctx);
    transfer::public_transfer(coin::from_balance(refund, ctx), addr);
    (cap_id, addr)
}

// === Private Functions ===

// === Test Functions ===
