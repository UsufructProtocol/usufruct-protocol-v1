// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_custody;

// === Imports ===

use usufruct::{
    asset_identity::{Self, AssetIdentity},
    escrowed_asset_identity::{Self, EscrowedAssetIdentity},
    escrow_identity::EscrowIdentity,
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct AssetCustodyOpen<U: key + store> has store {
    identity:  EscrowedAssetIdentity,
    available: Option<U>,
}

public struct AssetCustodyLocked<U: key + store> has store {
    asset: U,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_locked_id<U: key + store>(self: &AssetCustodyLocked<U>): ID { object::id(&self.asset) }
public(package) fun proj_asset_id<U: key + store>(self: &AssetCustodyOpen<U>): AssetIdentity { escrowed_asset_identity::asset_id(&self.identity) }
public(package) fun proj_is_available<U: key + store>(self: &AssetCustodyOpen<U>): bool { self.available.is_some() }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<U: key + store>(u: U, escrow_identity: EscrowIdentity): AssetCustodyOpen<U> {
    let identity = escrowed_asset_identity::new(asset_identity::new(object::id(&u)), escrow_identity);
    AssetCustodyOpen { identity, available: option::some(u) }
}

public(package) fun lock<U: key + store>(u: U): AssetCustodyLocked<U> {
    AssetCustodyLocked { asset: u }
}

public(package) fun unlock<U: key + store>(self: AssetCustodyLocked<U>): U {
    let AssetCustodyLocked { asset } = self;
    asset
}

public(package) fun take<U: key + store>(self: &mut AssetCustodyOpen<U>): U {
    self.available.extract()
}

public(package) fun put<U: key + store>(self: &mut AssetCustodyOpen<U>, u: U) {
    self.available.fill(u);
}

public(package) fun unbundle<U: key + store>(self: AssetCustodyOpen<U>): U {
    let AssetCustodyOpen { available, .. } = self;
    available.destroy_some()
}

public(package) fun close_tenancy<U: key + store>(self: AssetCustodyOpen<U>): AssetCustodyLocked<U> {
    lock(unbundle(self))
}

public(package) fun open_tenancy<U: key + store>(self: AssetCustodyLocked<U>, escrow_identity: EscrowIdentity): AssetCustodyOpen<U> {
    let AssetCustodyLocked { asset } = self;
    new(asset, escrow_identity)
}

// === Private Functions ===

// === Test Functions ===
