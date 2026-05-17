// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_cap;

// === Imports ===

use sui::event;
use usufruct::escrow_identity::{Self, EscrowIdentity};

// === Errors ===

// === Constants ===

// === Structs ===

public struct OwnerCap has key, store {
    id:              UID,
    escrow_identity: EscrowIdentity,
}

public struct OwnerCapIdentity has copy, drop, store { id: ID }

// === Events ===

public struct OwnerCapMinted has copy, drop {
    owner_cap_id: ID,
    escrow_id:    ID,
    owner:        address,
}

public struct OwnerCapBurned has copy, drop {
    owner_cap_id: ID,
    escrow_id:    ID,
    owner:        address,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public fun proj_escrow_id(cap: &OwnerCap): ID {
    escrow_identity::escrow_id(cap.escrow_identity)
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun identity(cap: &OwnerCap): OwnerCapIdentity {
    OwnerCapIdentity { id: object::id(cap) }
}

public(package) fun proj_id(o: OwnerCapIdentity): ID { o.id }

public(package) fun proj_escrow_identity(cap: &OwnerCap): EscrowIdentity {
    cap.escrow_identity
}

public(package) fun new(
    escrow_identity: EscrowIdentity,
    owner:           address,
    ctx:             &mut TxContext,
): OwnerCap {
    let cap          = OwnerCap { id: object::new(ctx), escrow_identity };
    let owner_cap_id = object::uid_to_inner(&cap.id);
    event::emit(OwnerCapMinted { owner_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), owner });
    cap
}

public(package) fun burn(cap: OwnerCap, owner: address) {
    let OwnerCap { id, escrow_identity } = cap;
    let owner_cap_id = object::uid_to_inner(&id);
    id.delete();
    event::emit(OwnerCapBurned { owner_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), owner });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun minted_owner_cap_id(e: &OwnerCapMinted): ID { e.owner_cap_id }
#[test_only]
public fun minted_escrow_id(e: &OwnerCapMinted): ID { e.escrow_id }
#[test_only]
public fun minted_owner(e: &OwnerCapMinted): address { e.owner }

#[test_only]
public fun burned_owner_cap_id(e: &OwnerCapBurned): ID { e.owner_cap_id }
#[test_only]
public fun burned_escrow_id(e: &OwnerCapBurned): ID { e.escrow_id }
#[test_only]
public fun burned_owner(e: &OwnerCapBurned): address { e.owner }

