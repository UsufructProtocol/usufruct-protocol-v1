// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset;

// === Imports ===

use usufruct::escrow_identity::EscrowIdentity;

// === Errors ===

// === Constants ===

// === Structs ===

/// Composite identity of an asset within the protocol. Pairs the asset's
/// own UID with the escrow that holds it. Used by `AssetReceipt` in
/// `asset_state` to verify returns against the issuing borrow.
public struct AssetIdentity has copy, drop {
    asset_id:        ID,
    escrow_identity: EscrowIdentity,
}

/// Wrapper around an external `U` during active tenancy (Occupied / Demand).
/// `available` is `Some` when the asset is in escrow custody and `None`
/// while it is on loan to the tenant. `asset_id` is stamped at wrap-time
/// so projectors can identify the asset even while the slot is empty.
public struct AssetCustodyOpen<U: key + store> has store {
    asset_id:  ID,
    available: Option<U>,
}

/// Wrapper around an external `U` while no tenancy is active (Idle, AtDutch,
/// Retired). No borrow protocol — the asset is simply held in custody.
/// Distinct from `AssetCustodyOpen` so that `WaitingContext` fields are a
/// concrete named type (`TypeInner::Apply`) rather than a raw type parameter,
/// enabling deep nested match patterns without hitting the compiler limitation
/// described in BUG_REPORT.md.
public struct AssetCustodyLocked<U: key + store> has store {
    asset: U,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_locked_id<U: key + store>(self: &AssetCustodyLocked<U>): ID { object::id(&self.asset) }

public(package) fun proj_asset_id<U: key + store>(self: &AssetCustodyOpen<U>): ID { self.asset_id }

public(package) fun new_identity(asset_id: ID, escrow_identity: EscrowIdentity): AssetIdentity {
    AssetIdentity { asset_id, escrow_identity }
}
public(package) fun identity_asset_id(id: &AssetIdentity): ID { id.asset_id }
public(package) fun identity_escrow_identity(id: &AssetIdentity): EscrowIdentity { id.escrow_identity }
public(package) fun proj_is_available<U: key + store>(self: &AssetCustodyOpen<U>): bool {
    self.available.is_some()
}

// === Admin Functions ===

// === Package Functions ===

/// Wrap a `U` for borrow-capable custody. Called when entering Renting state.
public(package) fun new<U: key + store>(u: U): AssetCustodyOpen<U> {
    AssetCustodyOpen { asset_id: object::id(&u), available: option::some(u) }
}

/// Wrap a `U` for locked custody (no borrow protocol). Called when entering
/// Waiting state (Idle, AtDutch, Retired).
public(package) fun lock<U: key + store>(u: U): AssetCustodyLocked<U> {
    AssetCustodyLocked { asset: u }
}

/// Unwrap a locked custody, returning the raw `U`. Called when transitioning
/// from Waiting to Renting (before `new` wraps it as open custody).
public(package) fun unlock<U: key + store>(self: AssetCustodyLocked<U>): U {
    let AssetCustodyLocked { asset } = self;
    asset
}

/// Borrow path: extract the inner `U`. The slot is left `None`. The caller
/// (`asset_state::execute_borrow`) is responsible for minting the `AssetReceipt`
/// hot-potato — receipt creation is a protocol concern, not a custody concern.
public(package) fun take<U: key + store>(self: &mut AssetCustodyOpen<U>): U {
    self.available.extract()
}

/// Return path: refill the slot. All receipt verification is the caller's
/// responsibility (`asset_state::execute_return`) — the custody module
/// only performs the mechanical fill.
public(package) fun put<U: key + store>(self: &mut AssetCustodyOpen<U>, u: U) {
    self.available.fill(u);
}

/// Unwrap an open custody asset, returning the raw `U`. Purely mechanical —
/// callers in `asset_state` are responsible for asserting availability
/// before calling this.
public(package) fun unbundle<U: key + store>(self: AssetCustodyOpen<U>): U {
    let AssetCustodyOpen { available, .. } = self;
    available.destroy_some()
}

/// Renting → Waiting: tenure has ended. Encapsulates `unbundle + lock` so
/// callers express the domain transition in one step. The `unbundle` assert
/// is preserved (aborts if asset is still on loan).
public(package) fun close_tenancy<U: key + store>(self: AssetCustodyOpen<U>): AssetCustodyLocked<U> {
    lock(unbundle(self))
}

/// Waiting → Renting: a new tenancy is starting. Encapsulates `unlock + new`
/// so callers express the domain transition in one step.
public(package) fun open_tenancy<U: key + store>(self: AssetCustodyLocked<U>): AssetCustodyOpen<U> {
    let AssetCustodyLocked { asset } = self;
    new(asset)
}

// === Private Functions ===

// === Test Functions ===
