// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::escrowed_asset_identity;

// === Imports ===

use usufruct::{
    asset_identity::AssetIdentity,
    escrow_identity::EscrowIdentity,
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct EscrowedAssetIdentity has copy, drop, store {
    asset_id:        AssetIdentity,
    escrow_identity: EscrowIdentity,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun asset_id(id: &EscrowedAssetIdentity):        AssetIdentity  { id.asset_id }
public(package) fun escrow_identity(id: &EscrowedAssetIdentity): EscrowIdentity { id.escrow_identity }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(asset_id: AssetIdentity, escrow_identity: EscrowIdentity): EscrowedAssetIdentity {
    EscrowedAssetIdentity { asset_id, escrow_identity }
}

// === Private Functions ===

// === Test Functions ===
