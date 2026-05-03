// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::route_fund;

// === Imports ===

use usufruct::{
    fee_message,
    tenant::{Self, Tenant},
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
    mut departing: Tenant<C>,
    fee_amount:    u64,
    escrow_id:     ID,
    fee_inbox_id:  ID,
    ctx:           &mut TxContext,
): (ID, address) {
    let fee_share         = tenant::take_fee_share(&mut departing, fee_amount, escrow_id);
    let (identity, stake) = tenant::unbundle(departing);
    let cap_id            = tenant::id_cap_id(&identity);
    let addr              = tenant::id_address(&identity);
    fee_message::post(fee_share, fee_inbox_id, ctx);
    if (tenant::stake_value_of(&stake) > 0) {
        tenant::liquidate(stake, addr, ctx);
    } else {
        tenant::destroy_empty_stake(stake);
    };
    (cap_id, addr)
}

// === Private Functions ===

// === Test Functions ===
