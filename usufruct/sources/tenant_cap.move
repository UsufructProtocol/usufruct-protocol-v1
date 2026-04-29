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
public fun escrow_id(cap: &TenantCap): ID {
    cap.escrow_id
}

// === Admin Functions ===

// === Package Functions ===

/// Pure constructor. Builds the cap, emits `TenantCapMinted`, returns `(cap, cap_id)` by value.
public(package) fun new(
    escrow_id: ID,
    tenant:    address,
    ctx:       &mut TxContext,
): (TenantCap, ID) {
    let cap = TenantCap { id: object::new(ctx), escrow_id };
    let tenant_cap_id = object::uid_to_inner(&cap.id);
    event::emit(TenantCapMinted { tenant_cap_id, escrow_id, tenant });
    (cap, tenant_cap_id)
}

/// Destroys `cap` by value and emits `TenantCapBurned`.
public(package) fun burn(cap: TenantCap, ctx: &TxContext) {
    let TenantCap { id, escrow_id } = cap;
    let tenant_cap_id = object::uid_to_inner(&id);
    let tenant = tx_context::sender(ctx);
    object::delete(id);
    event::emit(TenantCapBurned { tenant_cap_id, escrow_id, tenant });
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
