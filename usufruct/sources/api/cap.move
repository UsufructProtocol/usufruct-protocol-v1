// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::cap;

// === Imports ===

use usufruct::{
    owner_cap::{Self, OwnerCap},
    tenant_cap::{Self, TenantCap},
};

// === Public Functions ===

public fun owner_cap_escrow_id(cap: &OwnerCap): ID {
    owner_cap::proj_escrow_id(cap)
}

public fun tenant_cap_escrow_id(cap: &TenantCap): ID {
    tenant_cap::proj_escrow_id(cap)
}
