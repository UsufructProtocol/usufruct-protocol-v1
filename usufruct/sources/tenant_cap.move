// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_cap;

// === Imports ===

use sui::event;

// === Errors ===

// === Constants ===

// === Structs ===

public struct TenantCap has key, store {
    id:        UID,
    escrow_id: ID,
}

// === Events ===

public struct TenantCapMinted has copy, drop {
    tenant_cap_id: ID,
    escrow_id:     ID,
    tenant:        address,
}

public struct TenantCapBurned has copy, drop {
    tenant_cap_id: ID,
    escrow_id:     ID,
    tenant:        address,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// Returns the ID of the `RentalEscrow` this cap was minted for.
public fun escrow_id(_cap: &TenantCap): ID {
    abort 0
}

// === Admin Functions ===

// === Package Functions ===

/// Pure constructor. Builds the cap, emits `TenantCapMinted`, returns `(cap, cap_id)` by value.
public(package) fun new(
    _escrow_id: ID,
    _tenant:    address,
    _ctx:       &mut TxContext,
): (TenantCap, ID) {
    abort 0
}

/// Destroys `cap` by value and emits `TenantCapBurned`.
public(package) fun burn(_cap: TenantCap, _ctx: &TxContext) {
    abort 0
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun minted_tenant_cap_id(e: &TenantCapMinted): ID { e.tenant_cap_id }
#[test_only]
public fun minted_escrow_id(e: &TenantCapMinted): ID { e.escrow_id }
#[test_only]
public fun minted_tenant(e: &TenantCapMinted): address { e.tenant }

#[test_only]
public fun burned_tenant_cap_id(e: &TenantCapBurned): ID { e.tenant_cap_id }
#[test_only]
public fun burned_escrow_id(e: &TenantCapBurned): ID { e.escrow_id }
#[test_only]
public fun burned_tenant(e: &TenantCapBurned): address { e.tenant }

#[test_only]
public fun mint_then_burn_for_testing(escrow_id: ID, tenant: address, ctx: &mut TxContext) {
    let (cap, _) = new(escrow_id, tenant, ctx);
    burn(cap, ctx);
}
