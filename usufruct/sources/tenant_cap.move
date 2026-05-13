// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_cap;

// === Imports ===

use sui::event;
use usufruct::escrow_identity::{Self, EscrowIdentity};

// === Errors ===

// === Constants ===

// === Structs ===

public struct TenantCap has key, store {
    id:              UID,
    escrow_identity: EscrowIdentity,
}

/// Typed identity of a `TenantCap` object — wraps its on-chain `ID`.
public struct TenantCapIdentity has copy, drop, store { id: ID }

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

/// Returns the ID of the `RentalEscrow` this cap was minted for (SDK boundary).
public fun proj_escrow_id(cap: &TenantCap): ID {
    escrow_identity::escrow_id(cap.escrow_identity)
}

// === Admin Functions ===

// === Package Functions ===

/// Produce a typed `TenantCapIdentity` from a live cap reference.
public(package) fun identity(cap: &TenantCap): TenantCapIdentity {
    TenantCapIdentity { id: object::id(cap) }
}

/// Extract the raw `ID` from a `TenantCapIdentity`.
public(package) fun cap_id(t: TenantCapIdentity): ID { t.id }

/// Wrap a raw `ID` known to belong to a `TenantCap` into a typed identity.
/// Used at SDK boundary entry points that receive raw IDs from callers.
public(package) fun from_id(id: ID): TenantCapIdentity { TenantCapIdentity { id } }

/// Package-internal: return the `EscrowIdentity` this cap is bound to.
public(package) fun proj_escrow_identity(cap: &TenantCap): EscrowIdentity {
    cap.escrow_identity
}

/// Pure constructor. Builds the cap, emits `TenantCapMinted`, returns cap by value.
public(package) fun new(
    escrow_identity: EscrowIdentity,
    tenant:          address,
    ctx:             &mut TxContext,
): TenantCap {
    let cap           = TenantCap { id: object::new(ctx), escrow_identity };
    let tenant_cap_id = object::id(&cap);
    event::emit(TenantCapMinted { tenant_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), tenant });
    cap
}

/// Destroys `cap` by value and emits `TenantCapBurned`.
public(package) fun burn(cap: TenantCap, ctx: &TxContext) {
    let TenantCap { id, escrow_identity } = cap;
    let tenant_cap_id = object::uid_to_inner(&id);
    let tenant        = tx_context::sender(ctx);
    id.delete();
    event::emit(TenantCapBurned { tenant_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), tenant });
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
public fun mint_then_burn_for_testing(escrow_identity: EscrowIdentity, tenant: address, ctx: &mut TxContext) {
    burn(new(escrow_identity, tenant, ctx), ctx);
}
