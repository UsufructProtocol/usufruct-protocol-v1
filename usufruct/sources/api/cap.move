// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::cap;

// === Imports ===

use usufruct::{
    governance_cap::{Self, GovernanceCap},
    usufruct_cap::{Self, UsufructCap},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun renounce_governance(cap: GovernanceCap, ctx: &TxContext) {
    governance_cap::burn(cap, ctx)
}

public fun burn_usufruct_cap(cap: UsufructCap, ctx: &mut TxContext) {
    usufruct_cap::burn(cap, ctx)
}

public fun usufruct_cap_escrow_id(cap: &UsufructCap): ID {
    usufruct_cap::proj_escrow_id(cap)
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
