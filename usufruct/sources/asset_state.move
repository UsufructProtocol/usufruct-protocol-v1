// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_state;

// === Imports ===

use usufruct::asset::{Self, Asset, AssetReceipt};
use usufruct::unreachable;

// === Errors ===

// === Constants ===

// === Structs ===

/// Tracks the custody of the rentable asset throughout the escrow
/// lifecycle. `AtDutch` carries `last_acquisition_price` since the
/// price dynamics belong to the auction phase, not the lifecycle layer.
///
/// The borrow-capable variants (`HandoverOpen` / `HandoverConfirmed`)
/// carry an `Asset<U>` wrapper — its `Option<U>` slot encodes the
/// borrowed-vs-held custody. The non-borrowable variants
/// (`Idle` / `AtDutch` / `Retired`) carry the raw `U` directly,
/// preserving the type-level invariant "asset is always present here".
public enum AssetState<U: key + store> has store {
    /// Escrow holds the asset; no active rental.
    Idle    { asset: U },
    /// Escrow holds the asset; Dutch auction in progress. Carries
    /// the last acquisition price (anchor for the descent curve)
    /// and the timestamp at which the auction started (consumed by
    /// `descent_policy::has_expired` and `compute_price_descent`).
    AtDutch { asset: U, last_acquisition_price: u64, phase_start_ms: u64 },
    /// Rental active, single tenant. Asset may be borrowed
    /// (wrapper's slot is `None`) or held in escrow (`Some`).
    HandoverOpen      { asset: Asset<U> },
    /// Rental active, handover pending. Same custody semantics as
    /// `HandoverOpen`.
    HandoverConfirmed { asset: Asset<U> },
    /// Escrow holds the asset; owner has signalled retire.
    /// Asset is waiting to be claimed via `claim`.
    Retired           { asset: U },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun is_idle<U: key + store>(s: &AssetState<U>): bool {
    match (s) {
        AssetState::Idle { .. } => true,
        _                       => false,
    }
}

public(package) fun is_at_dutch<U: key + store>(s: &AssetState<U>): bool {
    match (s) {
        AssetState::AtDutch { .. } => true,
        _                          => false,
    }
}

public(package) fun is_handover_open<U: key + store>(s: &AssetState<U>): bool {
    match (s) {
        AssetState::HandoverOpen { .. } => true,
        _                               => false,
    }
}

public(package) fun is_handover_confirmed<U: key + store>(s: &AssetState<U>): bool {
    match (s) {
        AssetState::HandoverConfirmed { .. } => true,
        _                                    => false,
    }
}

public(package) fun is_retired<U: key + store>(s: &AssetState<U>): bool {
    match (s) {
        AssetState::Retired { .. } => true,
        _                          => false,
    }
}

/// Return `true` iff the asset is currently in escrow custody (not
/// borrowed by the tenant). State-agnostic — for the wrapped variants,
/// reads through `asset::is_available`.
public(package) fun has_asset<U: key + store>(s: &AssetState<U>): bool {
    match (s) {
        AssetState::Idle    { .. } => true,
        AssetState::AtDutch { .. } => true,
        AssetState::Retired { .. } => true,
        AssetState::HandoverOpen      { asset } => asset::is_available(asset),
        AssetState::HandoverConfirmed { asset } => asset::is_available(asset),
    }
}

/// Object ID of the wrapped asset. Constant for the lifetime of
/// the AssetState — for raw variants, reads `object::id`; for
/// wrapped variants, reads the stamped `AssetIdentity.asset_id`
/// (valid even when the asset is currently borrowed out).
public(package) fun asset_id<U: key + store>(s: &AssetState<U>): ID {
    match (s) {
        AssetState::Idle    { asset }     => object::id(asset),
        AssetState::AtDutch { asset, .. } => object::id(asset),
        AssetState::Retired { asset }     => object::id(asset),
        AssetState::HandoverOpen      { asset } => asset::id_asset_id(asset::identity(asset)),
        AssetState::HandoverConfirmed { asset } => asset::id_asset_id(asset::identity(asset)),
    }
}

/// Read `last_acquisition_price` from the AtDutch variant. Aborts if
/// the state is not AtDutch — consumer is `compute_price_descent` in
/// the rental-escrow layer, which already gates on the variant.
public(package) fun at_dutch_last_acq_price<U: key + store>(s: &AssetState<U>): u64 {
    match (s) {
        AssetState::AtDutch { last_acquisition_price, .. } => *last_acquisition_price,
        AssetState::Idle              { .. } => abort unreachable::unreachable(),
        AssetState::HandoverOpen      { .. } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { .. } => abort unreachable::unreachable(),
        AssetState::Retired           { .. } => abort unreachable::unreachable(),
    }
}

/// Read `phase_start_ms` from the AtDutch variant. Aborts if the
/// state is not AtDutch — feeds `descent_policy::has_expired` /
/// `expiry_at` through `lifecycle_state::phase_start_ms`.
public(package) fun at_dutch_phase_start_ms<U: key + store>(s: &AssetState<U>): u64 {
    match (s) {
        AssetState::AtDutch { phase_start_ms, .. } => *phase_start_ms,
        AssetState::Idle              { .. } => abort unreachable::unreachable(),
        AssetState::HandoverOpen      { .. } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { .. } => abort unreachable::unreachable(),
        AssetState::Retired           { .. } => abort unreachable::unreachable(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct the initial state — asset enters escrow custody as `Idle`.
public(package) fun new<U: key + store>(asset: U): AssetState<U> {
    AssetState::Idle { asset }
}

/// Transition Idle | AtDutch → HandoverOpen. Wraps the raw `U` into
/// an `Asset<U>` stamped with `escrow_id` — borrow-capable from now.
public(package) fun rent<U: key + store>(
    s:         AssetState<U>,
    escrow_id: ID,
): AssetState<U> {
    match (s) {
        AssetState::Idle    { asset } =>
            AssetState::HandoverOpen { asset: asset::new(asset, escrow_id) },
        AssetState::AtDutch { asset, last_acquisition_price: _, phase_start_ms: _ } =>
            AssetState::HandoverOpen { asset: asset::new(asset, escrow_id) },
        AssetState::HandoverOpen      { asset: _a } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { asset: _a } => abort unreachable::unreachable(),
        AssetState::Retired           { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Transition HandoverOpen → HandoverConfirmed. A competing bid
/// arrives; asset custody is unchanged (wrapper passes through).
public(package) fun bid<U: key + store>(
    s: AssetState<U>,
): AssetState<U> {
    match (s) {
        AssetState::HandoverOpen { asset } => AssetState::HandoverConfirmed { asset },
        AssetState::Idle              { asset: _a } => abort unreachable::unreachable(),
        AssetState::AtDutch           { asset: _a, last_acquisition_price: _, phase_start_ms: _ } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { asset: _a } => abort unreachable::unreachable(),
        AssetState::Retired           { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Transition HandoverConfirmed → HandoverOpen. Pending bid wins;
/// slot resets for the new current tenant. Wrapper unchanged.
public(package) fun handover<U: key + store>(
    s: AssetState<U>,
): AssetState<U> {
    match (s) {
        AssetState::HandoverConfirmed { asset } => AssetState::HandoverOpen { asset },
        AssetState::Idle              { asset: _a } => abort unreachable::unreachable(),
        AssetState::AtDutch           { asset: _a, last_acquisition_price: _, phase_start_ms: _ } => abort unreachable::unreachable(),
        AssetState::HandoverOpen      { asset: _a } => abort unreachable::unreachable(),
        AssetState::Retired           { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Transition HandoverOpen → AtDutch. Tenure expires with no active
/// handover; the wrapper is unbundled back to raw `U` for the
/// non-borrowable AtDutch variant. `asset::unbundle` aborts if the
/// slot is empty (asset still on loan) — the borrow-blocks-expire
/// invariant lives there structurally.
/// `HandoverConfirmed` cannot expire directly: the pending bid's
/// countdown must resolve first via `handover`, landing back in
/// `HandoverOpen` before tenure can expire.
public(package) fun expire<U: key + store>(
    s:                      AssetState<U>,
    last_acquisition_price: u64,
    phase_start_ms:         u64,
): AssetState<U> {
    match (s) {
        AssetState::HandoverOpen { asset } => {
            let a = asset::unbundle(asset);
            AssetState::AtDutch { asset: a, last_acquisition_price, phase_start_ms }
        },
        AssetState::Idle              { asset: _a } => abort unreachable::unreachable(),
        AssetState::AtDutch           { asset: _a, last_acquisition_price: _, phase_start_ms: _ } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { asset: _a } => abort unreachable::unreachable(),
        AssetState::Retired           { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Transition AtDutch → Idle. Auction ended with no winner; asset
/// remains in escrow.
public(package) fun no_winner<U: key + store>(
    s: AssetState<U>,
): AssetState<U> {
    match (s) {
        AssetState::AtDutch { asset, last_acquisition_price: _, phase_start_ms: _ } => AssetState::Idle { asset },
        AssetState::Idle              { asset: _a } => abort unreachable::unreachable(),
        AssetState::HandoverOpen      { asset: _a } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { asset: _a } => abort unreachable::unreachable(),
        AssetState::Retired           { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Transition Idle | AtDutch → Retired. Owner retires immediately
/// from an inactive state; asset custody unchanged.
public(package) fun retire<U: key + store>(
    s: AssetState<U>,
): AssetState<U> {
    match (s) {
        AssetState::Idle    { asset } => AssetState::Retired { asset },
        AssetState::AtDutch { asset, last_acquisition_price: _, phase_start_ms: _ } => AssetState::Retired { asset },
        AssetState::HandoverOpen      { asset: _a } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { asset: _a } => abort unreachable::unreachable(),
        AssetState::Retired           { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Terminal: consume `Retired` state and return the asset to the
/// caller (owner claims it).
public(package) fun claim<U: key + store>(
    s: AssetState<U>,
): U {
    match (s) {
        AssetState::Retired { asset } => asset,
        AssetState::Idle              { asset: _a } => abort unreachable::unreachable(),
        AssetState::AtDutch           { asset: _a, last_acquisition_price: _, phase_start_ms: _ } => abort unreachable::unreachable(),
        AssetState::HandoverOpen      { asset: _a } => abort unreachable::unreachable(),
        AssetState::HandoverConfirmed { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Give the asset to the tenant — extracts from the wrapper inside
/// HandoverOpen or HandoverConfirmed and mints an `AssetReceipt` that
/// must be presented at `give_back`. Aborts inside the wrapper if the
/// slot is already empty.
public(package) fun give<U: key + store>(
    s: AssetState<U>,
): (AssetState<U>, U, AssetReceipt) {
    match (s) {
        AssetState::HandoverOpen { mut asset } => {
            let (u, receipt) = asset::take(&mut asset);
            (AssetState::HandoverOpen { asset }, u, receipt)
        },
        AssetState::HandoverConfirmed { mut asset } => {
            let (u, receipt) = asset::take(&mut asset);
            (AssetState::HandoverConfirmed { asset }, u, receipt)
        },
        AssetState::Idle    { asset: _a } => abort unreachable::unreachable(),
        AssetState::AtDutch { asset: _a, last_acquisition_price: _, phase_start_ms: _ } => abort unreachable::unreachable(),
        AssetState::Retired { asset: _a } => abort unreachable::unreachable(),
    }
}

/// Return the asset from the tenant — places it back into the wrapper
/// inside HandoverOpen or HandoverConfirmed, consuming the receipt.
/// Cross-escrow / asset-swap / receipt-mismatch are caught by
/// `asset::put`'s three asserts.
public(package) fun give_back<U: key + store>(
    s:       AssetState<U>,
    asset:   U,
    receipt: AssetReceipt,
): AssetState<U> {
    match (s) {
        AssetState::HandoverOpen { asset: mut slot } => {
            asset::put(&mut slot, asset, receipt);
            AssetState::HandoverOpen { asset: slot }
        },
        AssetState::HandoverConfirmed { asset: mut slot } => {
            asset::put(&mut slot, asset, receipt);
            AssetState::HandoverConfirmed { asset: slot }
        },
        AssetState::Idle    { asset: _a } => abort unreachable::unreachable(),
        AssetState::AtDutch { asset: _a, last_acquisition_price: _, phase_start_ms: _ } => abort unreachable::unreachable(),
        AssetState::Retired { asset: _a } => abort unreachable::unreachable(),
    }
}

// === Private Functions ===

// === Test Functions ===
