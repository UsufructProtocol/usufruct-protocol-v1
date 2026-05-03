// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_state;

// === Imports ===

// === Errors ===

/// Sentinel for caller-contract violations: transition or operation
/// invoked from an invalid state machine position.
const EInvariantViolation: u64 = 0xDEADC0DE;

// === Constants ===

// === Structs ===

/// Tracks the custody of the rentable asset throughout the escrow
/// lifecycle. Carries no temporal metadata — phase timestamps,
/// pricing, and retiring flags live in the Lifecycle layer above.
public enum AssetState<Asset: key + store> has store {
    /// Escrow holds the asset; no active rental.
    Idle              { asset: Asset },
    /// Escrow holds the asset; Dutch auction in progress.
    AtDutch           { asset: Asset },
    /// Rental active, single tenant. Asset may be borrowed
    /// (`None`) or held in escrow (`Some`).
    HandoverOpen      { asset: Option<Asset> },
    /// Rental active, handover pending. Same custody semantics as
    /// `HandoverOpen`.
    HandoverConfirmed { asset: Option<Asset> },
    /// Escrow holds the asset; owner has signalled retire.
    /// Asset is waiting to be claimed via `claim`.
    Retired           { asset: Asset },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Construct the initial state — asset enters escrow custody as `Idle`.
public(package) fun new<Asset: key + store>(asset: Asset): AssetState<Asset> {
    AssetState::Idle { asset }
}

/// Transition Idle | AtDutch → HandoverOpen. A new tenant takes over;
/// asset moves into the handover slot (initially present).
public(package) fun rent<Asset: key + store>(
    s: AssetState<Asset>,
): AssetState<Asset> {
    match (s) {
        AssetState::Idle    { asset } => AssetState::HandoverOpen { asset: option::some(asset) },
        AssetState::AtDutch { asset } => AssetState::HandoverOpen { asset: option::some(asset) },
        AssetState::HandoverOpen      { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverConfirmed { asset: _a } => abort EInvariantViolation,
        AssetState::Retired           { asset: _a } => abort EInvariantViolation,
    }
}

/// Transition HandoverOpen → HandoverConfirmed. A competing bid
/// arrives; asset custody is unchanged.
public(package) fun bid<Asset: key + store>(
    s: AssetState<Asset>,
): AssetState<Asset> {
    match (s) {
        AssetState::HandoverOpen { asset } => AssetState::HandoverConfirmed { asset },
        AssetState::Idle              { asset: _a } => abort EInvariantViolation,
        AssetState::AtDutch           { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverConfirmed { asset: _a } => abort EInvariantViolation,
        AssetState::Retired           { asset: _a } => abort EInvariantViolation,
    }
}

/// Transition HandoverConfirmed → HandoverOpen. Pending bid wins;
/// slot resets for the new current tenant. Asset custody unchanged.
public(package) fun handover<Asset: key + store>(
    s: AssetState<Asset>,
): AssetState<Asset> {
    match (s) {
        AssetState::HandoverConfirmed { asset } => AssetState::HandoverOpen { asset },
        AssetState::Idle              { asset: _a } => abort EInvariantViolation,
        AssetState::AtDutch           { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverOpen      { asset: _a } => abort EInvariantViolation,
        AssetState::Retired           { asset: _a } => abort EInvariantViolation,
    }
}

/// Transition HandoverOpen → AtDutch. Tenure expires with no active
/// handover; asset must be in escrow custody (`Some`) — aborts if
/// the tenant has it borrowed (`None`).
/// `HandoverConfirmed` cannot expire directly: the pending bid's
/// countdown must resolve first via `handover`, landing back in
/// `HandoverOpen` before tenure can expire.
public(package) fun expire<Asset: key + store>(
    s: AssetState<Asset>,
): AssetState<Asset> {
    match (s) {
        AssetState::HandoverOpen { asset } => {
            let a = option::destroy_some(asset);
            AssetState::AtDutch { asset: a }
        },
        AssetState::Idle              { asset: _a } => abort EInvariantViolation,
        AssetState::AtDutch           { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverConfirmed { asset: _a } => abort EInvariantViolation,
        AssetState::Retired           { asset: _a } => abort EInvariantViolation,
    }
}

/// Transition AtDutch → Idle. Auction ended with no winner; asset
/// remains in escrow.
public(package) fun no_winner<Asset: key + store>(
    s: AssetState<Asset>,
): AssetState<Asset> {
    match (s) {
        AssetState::AtDutch { asset } => AssetState::Idle { asset },
        AssetState::Idle              { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverOpen      { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverConfirmed { asset: _a } => abort EInvariantViolation,
        AssetState::Retired           { asset: _a } => abort EInvariantViolation,
    }
}

/// Transition Idle | AtDutch → Retired. Owner retires immediately
/// from an inactive state; asset custody unchanged.
public(package) fun retire<Asset: key + store>(
    s: AssetState<Asset>,
): AssetState<Asset> {
    match (s) {
        AssetState::Idle    { asset } => AssetState::Retired { asset },
        AssetState::AtDutch { asset } => AssetState::Retired { asset },
        AssetState::HandoverOpen      { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverConfirmed { asset: _a } => abort EInvariantViolation,
        AssetState::Retired           { asset: _a } => abort EInvariantViolation,
    }
}

/// Terminal: consume `Retired` state and return the asset to the
/// caller (owner claims it).
public(package) fun claim<Asset: key + store>(
    s: AssetState<Asset>,
): Asset {
    match (s) {
        AssetState::Retired { asset } => asset,
        AssetState::Idle              { asset: _a } => abort EInvariantViolation,
        AssetState::AtDutch           { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverOpen      { asset: _a } => abort EInvariantViolation,
        AssetState::HandoverConfirmed { asset: _a } => abort EInvariantViolation,
    }
}

/// Give the asset to the tenant — moves from `Some` to `None` inside
/// HandoverOpen or HandoverConfirmed. Aborts if already borrowed.
public(package) fun give<Asset: key + store>(
    s: AssetState<Asset>,
): (AssetState<Asset>, Asset) {
    match (s) {
        AssetState::HandoverOpen { asset } => {
            let a = option::destroy_some(asset);
            (AssetState::HandoverOpen { asset: option::none() }, a)
        },
        AssetState::HandoverConfirmed { asset } => {
            let a = option::destroy_some(asset);
            (AssetState::HandoverConfirmed { asset: option::none() }, a)
        },
        AssetState::Idle    { asset: _a } => abort EInvariantViolation,
        AssetState::AtDutch { asset: _a } => abort EInvariantViolation,
        AssetState::Retired { asset: _a } => abort EInvariantViolation,
    }
}

/// Return the asset from the tenant — moves from `None` to `Some`
/// inside HandoverOpen or HandoverConfirmed. Aborts if already held.
public(package) fun give_back<Asset: key + store>(
    s:     AssetState<Asset>,
    asset: Asset,
): AssetState<Asset> {
    match (s) {
        AssetState::HandoverOpen { asset: slot } => {
            option::destroy_none(slot);  // aborts if asset not yet returned
            AssetState::HandoverOpen { asset: option::some(asset) }
        },
        AssetState::HandoverConfirmed { asset: slot } => {
            option::destroy_none(slot);  // aborts if asset not yet returned
            AssetState::HandoverConfirmed { asset: option::some(asset) }
        },
        AssetState::Idle    { asset: _a } => abort EInvariantViolation,
        AssetState::AtDutch { asset: _a } => abort EInvariantViolation,
        AssetState::Retired { asset: _a } => abort EInvariantViolation,
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_idle<Asset: key + store>(s: &AssetState<Asset>): bool {
    match (s) {
        AssetState::Idle { .. } => true,
        _                       => false,
    }
}

#[test_only]
public fun is_at_dutch<Asset: key + store>(s: &AssetState<Asset>): bool {
    match (s) {
        AssetState::AtDutch { .. } => true,
        _                          => false,
    }
}

#[test_only]
public fun is_handover_open<Asset: key + store>(s: &AssetState<Asset>): bool {
    match (s) {
        AssetState::HandoverOpen { .. } => true,
        _                               => false,
    }
}

#[test_only]
public fun is_handover_confirmed<Asset: key + store>(s: &AssetState<Asset>): bool {
    match (s) {
        AssetState::HandoverConfirmed { .. } => true,
        _                                    => false,
    }
}

#[test_only]
public fun is_retired<Asset: key + store>(s: &AssetState<Asset>): bool {
    match (s) {
        AssetState::Retired { .. } => true,
        _                          => false,
    }
}

/// Return `true` iff the asset is currently in escrow custody (not
/// borrowed by the tenant).
#[test_only]
public fun has_asset<Asset: key + store>(s: &AssetState<Asset>): bool {
    match (s) {
        AssetState::Idle    { .. } => true,
        AssetState::AtDutch { .. } => true,
        AssetState::Retired { .. } => true,
        AssetState::HandoverOpen      { asset } => asset.is_some(),
        AssetState::HandoverConfirmed { asset } => asset.is_some(),
    }
}
