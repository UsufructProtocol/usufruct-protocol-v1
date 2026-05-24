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

public fun owner_cap_escrow_id(cap: &OwnerCap): ID {
    owner_cap::proj_escrow_id(cap)
}

public fun tenant_cap_escrow_id(cap: &TenantCap): ID {
    tenant_cap::proj_escrow_id(cap)
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
