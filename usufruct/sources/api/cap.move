// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::cap;

// === Imports ===

use usufruct::{
    owner_cap::{Self, OwnerCap},
    tenant_cap::{Self, TenantCap},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

/// Permanently and irreversibly renounce ALL governance over every escrow this
/// cap governs: `retire`, `update_ensemble`, and `claim_asset`. The underlying
/// asset can NEVER be reclaimed — it stays in perpetual usufruct at frozen terms.
/// Income is unaffected: the `EarningsInbox` keeps receiving and remains
/// collectable. This is the supremum of the commitment ladder. There is no undo.
public fun renounce_governance(cap: OwnerCap, ctx: &TxContext) {
    owner_cap::burn(cap, ctx)
}

public fun tenant_cap_escrow_id(cap: &TenantCap): ID {
    tenant_cap::proj_escrow_id(cap)
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
