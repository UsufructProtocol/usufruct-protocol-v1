// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset;

// === Imports ===

use usufruct::escrow_identity::{Self, EscrowIdentity};

// === Errors ===

/// `put` was presented a receipt whose `escrow_id` does not match the
/// wrapper's. Cross-escrow attack: a receipt minted by `take` on
/// escrow X presented to `put` on escrow Y.
const E_ASSET_WRONG_ESCROW: u64 = 1;

/// `put` was presented a receipt whose `asset_id` does not match the
/// wrapper's. Defensive — within a single wrapper the ids are
/// invariant, so this guards against future reshapes (multi-asset
/// slots, foreign receipts) that could subvert the binding.
const E_ASSET_RECEIPT_MISMATCH: u64 = 2;

/// The `U` returned to `put` is a different physical object than the
/// one that left at `take`. Asset-swap: same type, different UID.
const E_ASSET_RETURNED_DIFFERENT: u64 = 3;

/// `unbundle` was called on a wrapper whose slot is empty (asset still
/// borrowed). Used by `asset_state::expire` to enforce that tenure
/// cannot expire while the asset is out — the abort is the defence.
const E_ASSET_NOT_AVAILABLE: u64 = 4;

// === Constants ===

// === Structs ===

/// Composite identity of an asset within the protocol. `asset_id` is
/// the user-asset's UID (intrinsic, global). `escrow_id` is the
/// rental-escrow's identity, stamped at wrap-time. The pair is what
/// distinguishes "this asset in this protocol context" from "this
/// asset somewhere else" — necessary because `U` is external (not
/// protocol-issued, no inherent escrow binding, unlike the caps).
public struct AssetIdentity has copy, drop, store {
    asset_id:  ID,
    escrow_id: EscrowIdentity,
}

/// Wrapper around an external `U` during active tenancy (Occupied / Demand).
/// `available` is `Some` when the asset is in escrow custody and `None`
/// while it is on loan to the tenant. The borrow protocol (take/put/receipt)
/// lives here — this wrapper exists exactly where it is needed.
public struct AssetCustodyOpen<U: key + store> has store {
    identity:  AssetIdentity,
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

/// Hot potato — no abilities. Minted by `take` and consumed by `put`
/// in the same PTB. Carries the full `AssetIdentity` so that `put` can
/// verify in one typed comparison that the receipt belongs to this escrow
/// and this asset.
public struct AssetReceipt {
    identity: AssetIdentity,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_locked_id<U: key + store>(self: &AssetCustodyLocked<U>): ID { object::id(&self.asset) }

public(package) fun proj_asset_id<U: key + store>(self: &AssetCustodyOpen<U>): ID { self.identity.asset_id }
public(package) fun proj_escrow_id<U: key + store>(self: &AssetCustodyOpen<U>): ID {
    escrow_identity::escrow_id(self.identity.escrow_id)
}
public(package) fun proj_is_available<U: key + store>(self: &AssetCustodyOpen<U>): bool {
    option::is_some(&self.available)
}

// === Admin Functions ===

// === Package Functions ===

/// Wrap a `U` for borrow-capable custody. Called when entering Renting state.
public(package) fun new<U: key + store>(u: U, escrow_id: ID): AssetCustodyOpen<U> {
    AssetCustodyOpen {
        identity:  AssetIdentity { asset_id: object::id(&u), escrow_id: escrow_identity::new(escrow_id) },
        available: option::some(u),
    }
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

/// Borrow path: extract the inner `U` and mint an `AssetReceipt`. The
/// slot is left `None`; the receipt is the proof-of-borrow, hot-potato
/// shaped so it cannot be stored or forgotten — must reach `put`
/// within the same PTB.
public(package) fun take<U: key + store>(self: &mut AssetCustodyOpen<U>): (U, AssetReceipt) {
    let u       = option::extract(&mut self.available);
    let receipt = AssetReceipt { identity: self.identity };
    (u, receipt)
}

/// Return path: consume the receipt and refill the slot. Three
/// independent assertions guard three distinct attacks:
///
///   1. cross-escrow:    self.escrow_id != receipt.escrow_id
///   2. receipt-swap:    self.asset_id  != receipt.asset_id
///   3. asset-swap:      object::id(&u) != receipt.asset_id
public(package) fun put<U: key + store>(
    self:    &mut AssetCustodyOpen<U>,
    u:       U,
    receipt: AssetReceipt,
) {
    let AssetReceipt { identity } = receipt;
    assert!(self.identity.escrow_id == identity.escrow_id, E_ASSET_WRONG_ESCROW);
    assert!(self.identity.asset_id  == identity.asset_id,  E_ASSET_RECEIPT_MISMATCH);
    assert!(object::id(&u)          == identity.asset_id,  E_ASSET_RETURNED_DIFFERENT);
    option::fill(&mut self.available, u);
}

/// Unwrap an open custody asset, returning the raw `U`. Aborts if the slot
/// is empty (asset still borrowed). Called at transitions out of Renting.
public(package) fun unbundle<U: key + store>(self: AssetCustodyOpen<U>): U {
    let AssetCustodyOpen { identity: _, available } = self;
    assert!(option::is_some(&available), E_ASSET_NOT_AVAILABLE);
    option::destroy_some(available)
}

// === Private Functions ===

// === Test Functions ===

/// Construct an `AssetReceipt` directly. Test-only — production
/// receipts only ever come from `take`. Used to drive the negative-path
/// assertions in `put` (cross-escrow, asset-id mismatch).
#[test_only]
public fun forge_receipt_for_testing(asset_id: ID, escrow_id: ID): AssetReceipt {
    AssetReceipt { identity: AssetIdentity { asset_id, escrow_id: escrow_identity::new(escrow_id) } }
}

/// Drop an `AssetReceipt` whose return-path was abandoned in the test.
#[test_only]
public fun destroy_receipt_for_testing(r: AssetReceipt) {
    let AssetReceipt { identity: _ } = r;
}

/// Inspect the asset_id stamped on a receipt. Test-only.
#[test_only]
public fun receipt_asset_id_for_testing(r: &AssetReceipt): ID { r.identity.asset_id }

/// Inspect the escrow_id stamped on a receipt. Test-only.
#[test_only]
public fun receipt_escrow_id_for_testing(r: &AssetReceipt): ID {
    escrow_identity::escrow_id(r.identity.escrow_id)
}
