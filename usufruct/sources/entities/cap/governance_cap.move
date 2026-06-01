// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::governance_cap;

// === Imports ===

use sui::event;
use usufruct::escrow_identity::{Self, EscrowIdentity};

// === Errors ===

// === Constants ===

// === Structs ===

public struct GovernanceCap has key, store {
    id: UID,
}

public struct GovernanceCapIdentity has copy, drop, store { id: ID }

// === Events ===

public struct GovernanceCapMinted has copy, drop {
    governance_cap_id:  ID,
    escrow_id:     ID,
    governor_address: address,
}

public struct GovernanceCapBurned has copy, drop {
    governance_cap_id:  ID,
    governor_address: address,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun identity(cap: &GovernanceCap): GovernanceCapIdentity {
    GovernanceCapIdentity { id: object::id(cap) }
}

public(package) fun proj_id(o: GovernanceCapIdentity): ID { o.id }

public(package) fun new(
    escrow_identity: EscrowIdentity,
    governor_address: address,
    ctx:             &mut TxContext,
): GovernanceCap {
    let cap          = GovernanceCap { id: object::new(ctx) };
    let governance_cap_id = object::uid_to_inner(&cap.id);
    event::emit(GovernanceCapMinted { governance_cap_id, escrow_id: escrow_identity::escrow_id(escrow_identity), governor_address });
    cap
}

public(package) fun burn(cap: GovernanceCap, ctx: &TxContext) {
    let GovernanceCap { id } = cap;
    let governance_cap_id = object::uid_to_inner(&id);
    id.delete();
    event::emit(GovernanceCapBurned { governance_cap_id, governor_address: ctx.sender() });
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun minted_governance_cap_id(e: &GovernanceCapMinted): ID { e.governance_cap_id }
#[test_only]
public fun minted_escrow_id(e: &GovernanceCapMinted): ID { e.escrow_id }
#[test_only]
public fun minted_governor_address(e: &GovernanceCapMinted): address { e.governor_address }

#[test_only]
public fun burned_governance_cap_id(e: &GovernanceCapBurned): ID { e.governance_cap_id }
#[test_only]
public fun burned_governor_address(e: &GovernanceCapBurned): address { e.governor_address }
