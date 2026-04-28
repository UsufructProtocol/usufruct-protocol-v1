// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_cap;

// === Imports ===

use sui::event;

// === Errors ===

// === Constants ===

// === Structs ===

public struct OwnerCap has key, store {
    id:        UID,
    escrow_id: ID,
}

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

/// Returns the ID of the `RentalEscrow` this cap authorizes.
public fun escrow_id(cap: &OwnerCap): ID {
    cap.escrow_id
}

// === Admin Functions ===

// === Package Functions ===

/// Mints an `OwnerCap` bound to `escrow_id`. Caller is responsible for
/// delivering it to `owner` — `owner` is a declarative annotation for the
/// event stream, not a runtime transfer target.
public(package) fun new(
    escrow_id: ID,
    owner:     address,
    ctx:       &mut TxContext,
): OwnerCap {
    let cap = OwnerCap {
        id: object::new(ctx),
        escrow_id,
    };
    let owner_cap_id = object::uid_to_inner(&cap.id);
    event::emit(OwnerCapMinted { owner_cap_id, escrow_id, owner });
    cap
}

/// Destroys `cap` and emits `OwnerCapBurned`. `owner` is declarative —
/// the caller binds `tx_context::sender(ctx)` at the call site.
public(package) fun burn(cap: OwnerCap, owner: address) {
    let OwnerCap { id, escrow_id } = cap;
    let owner_cap_id = object::uid_to_inner(&id);
    object::delete(id);
    event::emit(OwnerCapBurned { owner_cap_id, escrow_id, owner });
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
