// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::usufruct_cap;

// === Imports ===

use sui::event;
use usufruct::escrow_identity::{Self, EscrowIdentity};

// === Errors ===

// === Constants ===

// === Structs ===

public struct UsufructCap has key, store {
    id:              UID,
    escrow_identity: EscrowIdentity,
}

public struct UsufructCapIdentity has copy, drop, store { id: ID }

// === Events ===

public struct UsufructCapMinted has copy, drop {
    escrow_id:            ID,
    usufruct_cap_id:      ID,
    usufructuary_address: address,
}

public struct UsufructCapBurned has copy, drop {
    escrow_id:            ID,
    usufruct_cap_id:      ID,
    usufructuary_address: address,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_escrow_id(cap: &UsufructCap): ID {
    escrow_identity::escrow_id(cap.escrow_identity)
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun identity(cap: &UsufructCap): UsufructCapIdentity {
    UsufructCapIdentity { id: object::id(cap) }
}

public(package) fun proj_id(t: UsufructCapIdentity): ID { t.id }

public(package) fun from_id(id: ID): UsufructCapIdentity { UsufructCapIdentity { id } }

public(package) fun proj_escrow_identity(cap: &UsufructCap): EscrowIdentity {
    cap.escrow_identity
}

public(package) fun new(
    escrow_identity: EscrowIdentity,
    usufructuary:          address,
    ctx:             &mut TxContext,
): UsufructCap {
    let cap           = UsufructCap { id: object::new(ctx), escrow_identity };
    let usufruct_cap_id = object::id(&cap);
    event::emit(UsufructCapMinted { usufruct_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), usufructuary_address: usufructuary });
    cap
}

public(package) fun burn(cap: UsufructCap, ctx: &TxContext) {
    let UsufructCap { id, escrow_identity } = cap;
    let usufruct_cap_id = object::uid_to_inner(&id);
    let usufructuary        = ctx.sender();
    id.delete();
    event::emit(UsufructCapBurned { usufruct_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), usufructuary_address: usufructuary });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun minted_usufruct_cap_id(e: &UsufructCapMinted): ID { e.usufruct_cap_id }
#[test_only]
public fun minted_escrow_id(e: &UsufructCapMinted): ID { e.escrow_id }
#[test_only]
public fun minted_usufructuary_address(e: &UsufructCapMinted): address { e.usufructuary_address }

#[test_only]
public fun burned_usufruct_cap_id(e: &UsufructCapBurned): ID { e.usufruct_cap_id }
#[test_only]
public fun burned_escrow_id(e: &UsufructCapBurned): ID { e.escrow_id }
#[test_only]
public fun burned_usufructuary_address(e: &UsufructCapBurned): address { e.usufructuary_address }

#[test_only]
public fun mint_then_burn_for_testing(escrow_identity: EscrowIdentity, usufructuary: address, ctx: &mut TxContext) {
    burn(new(escrow_identity, usufructuary, ctx), ctx);
}

