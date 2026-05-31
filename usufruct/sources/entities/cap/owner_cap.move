// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_cap;

// === Imports ===

use sui::event;
use usufruct::escrow_identity::{Self, EscrowIdentity};

// === Errors ===

// === Constants ===

// === Structs ===

/// Pure governance token (the principal strip). Authorizes `retire`,
/// `claim_asset`, `update_ensemble` over the escrow(s) whose `OwnerSeat` records
/// its identity. Carries no escrow binding of its own — a single cap may govern
/// many escrows (one-pair-to-many via `escrow::integrate_into_portfolio`).
/// Born paired with an `EarningsInbox` via `escrow::integrate`; after birth the
/// two are independent objects.
public struct OwnerCap has key, store {
    id: UID,
}

public struct OwnerCapIdentity has copy, drop, store { id: ID }

// === Events ===

/// The cap does not store its birth escrow, but the mint event records it —
/// star-schema provenance: "this governance cap was born from escrow X".
public struct OwnerCapMinted has copy, drop {
    owner_cap_id:  ID,
    escrow_id:     ID,
    owner_address: address,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun identity(cap: &OwnerCap): OwnerCapIdentity {
    OwnerCapIdentity { id: object::id(cap) }
}

public(package) fun proj_id(o: OwnerCapIdentity): ID { o.id }

public(package) fun new(
    escrow_identity: EscrowIdentity,
    owner:           address,
    ctx:             &mut TxContext,
): OwnerCap {
    let cap          = OwnerCap { id: object::new(ctx) };
    let owner_cap_id = object::uid_to_inner(&cap.id);
    event::emit(OwnerCapMinted { owner_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), owner_address: owner });
    cap
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun minted_owner_cap_id(e: &OwnerCapMinted): ID { e.owner_cap_id }
#[test_only]
public fun minted_escrow_id(e: &OwnerCapMinted): ID { e.escrow_id }
#[test_only]
public fun minted_owner_address(e: &OwnerCapMinted): address { e.owner_address }
