// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset;

// === Imports ===

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
/// rental-escrow's UID, stamped at wrap-time. The pair is what
/// distinguishes "this asset in this protocol context" from "this
/// asset somewhere else" — necessary because `U` is external (not
/// protocol-issued, no inherent escrow binding, unlike the caps).
public struct AssetIdentity has copy, drop, store {
    asset_id:  ID,
    escrow_id: ID,
}

/// Wrapper around an external `U` while it lives in a borrow-capable
/// state (HandoverOpen / HandoverConfirmed). `available` is `Some`
/// when the asset is in escrow custody and `None` while it is on loan
/// to the tenant. Outside those two states the asset is held raw —
/// the wrapper exists exactly where the borrow protocol needs it.
public struct Asset<U: key + store> has store {
    identity:  AssetIdentity,
    available: Option<U>,
}

/// Hot potato — no abilities. Minted by `take` and consumed by `put`
/// in the same PTB. Carries both ids so that `put` can verify (a)
/// the receipt did not originate in another escrow, and (b) the
/// returned `U` is the same physical object that left.
public struct AssetReceipt {
    asset_id:  ID,
    escrow_id: ID,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun identity<U: key + store>(self: &Asset<U>): &AssetIdentity { &self.identity }

public(package) fun is_available<U: key + store>(self: &Asset<U>): bool {
    option::is_some(&self.available)
}

public(package) fun id_asset_id(id: &AssetIdentity):  ID { id.asset_id }
public(package) fun id_escrow_id(id: &AssetIdentity): ID { id.escrow_id }

public(package) fun receipt_asset_id(r: &AssetReceipt):  ID { r.asset_id }
public(package) fun receipt_escrow_id(r: &AssetReceipt): ID { r.escrow_id }

// === Admin Functions ===

// === Package Functions ===

/// Wrap an external `U` for borrow-capable custody. `escrow_id` is
/// stamped now so the wrapper itself carries the protocol-context
/// binding from this point on. Sole construction site — called by
/// `asset_state::rent` when the lifecycle crosses into a borrowable
/// state.
public(package) fun new<U: key + store>(u: U, escrow_id: ID): Asset<U> {
    Asset {
        identity:  AssetIdentity { asset_id: object::id(&u), escrow_id },
        available: option::some(u),
    }
}

/// Borrow path: extract the inner `U` and mint an `AssetReceipt`. The
/// slot is left `None`; the receipt is the proof-of-borrow, hot-potato
/// shaped so it cannot be stored or forgotten — must reach `put`
/// within the same PTB.
public(package) fun take<U: key + store>(self: &mut Asset<U>): (U, AssetReceipt) {
    let u = option::extract(&mut self.available);
    let receipt = AssetReceipt {
        asset_id:  self.identity.asset_id,
        escrow_id: self.identity.escrow_id,
    };
    (u, receipt)
}

/// Return path: consume the receipt and refill the slot. Three
/// independent assertions guard three distinct attacks:
///
///   1. cross-escrow:    self.escrow_id != receipt.escrow_id
///   2. receipt-swap:    self.asset_id  != receipt.asset_id
///   3. asset-swap:      object::id(&u) != receipt.asset_id
public(package) fun put<U: key + store>(
    self:    &mut Asset<U>,
    u:       U,
    receipt: AssetReceipt,
) {
    let AssetReceipt { asset_id, escrow_id } = receipt;
    assert!(self.identity.escrow_id == escrow_id,    E_ASSET_WRONG_ESCROW);
    assert!(self.identity.asset_id  == asset_id,     E_ASSET_RECEIPT_MISMATCH);
    assert!(object::id(&u)          == asset_id,     E_ASSET_RETURNED_DIFFERENT);
    option::fill(&mut self.available, u);
}

/// Unwrap — extract the inner `U` and discard the wrapper. Aborts
/// if the slot is empty (asset still borrowed). Used at transitions
/// out of the borrow-capable states (e.g. `asset_state::expire`
/// HandoverOpen → AtDutch).
public(package) fun unbundle<U: key + store>(self: Asset<U>): U {
    let Asset { identity: _, available } = self;
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
    AssetReceipt { asset_id, escrow_id }
}

/// Drop an `AssetReceipt` whose return-path was abandoned in the test.
/// Production receipts must reach `put`; tests sometimes hold them
/// only to make assertions on their accessors.
#[test_only]
public fun destroy_receipt_for_testing(r: AssetReceipt) {
    let AssetReceipt { asset_id: _, escrow_id: _ } = r;
}
