// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_identity;

// === Imports ===

use usufruct::{
    refund_address::{Self, RefundAddress},
    tenant_cap::TenantCapIdentity,
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct TenantIdentity has copy, drop, store {
    cap_identity: TenantCapIdentity,
    address:      RefundAddress,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_cap_identity(id: &TenantIdentity): TenantCapIdentity { id.cap_identity }
public(package) fun proj_address(id: &TenantIdentity):      RefundAddress      { id.address }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(cap_identity: TenantCapIdentity, address: RefundAddress): TenantIdentity {
    TenantIdentity { cap_identity, address }
}

public(package) fun set_address(id: &mut TenantIdentity, new: RefundAddress) {
    refund_address::set(&mut id.address, new);
}

// === Private Functions ===

// === Test Functions ===
