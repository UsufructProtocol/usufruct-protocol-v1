// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_identity;

// === Imports ===

use usufruct::escrow_identity::EscrowIdentity;

// === Errors ===

// === Constants ===

// === Structs ===

public struct AssetIdentity has copy, drop {
    asset_id:        ID,
    escrow_identity: EscrowIdentity,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun identity_asset_id(id: &AssetIdentity):        ID             { id.asset_id }
public(package) fun identity_escrow_identity(id: &AssetIdentity): EscrowIdentity { id.escrow_identity }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new_identity(asset_id: ID, escrow_identity: EscrowIdentity): AssetIdentity {
    AssetIdentity { asset_id, escrow_identity }
}

// === Private Functions ===

// === Test Functions ===
