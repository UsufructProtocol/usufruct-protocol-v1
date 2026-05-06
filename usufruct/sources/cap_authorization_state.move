// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::cap_authorization_state;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// Role a `TenantCap` plays relative to the current lifecycle state.
/// Produced by `lifecycle_state::cap_authorization_state`; consumed by
/// `escrow_coordinator::borrow_asset` and `burn_tenant_cap`.
///
///   · `Current` — cap belongs to the active tenant (t1). May borrow.
///   · `Pending` — cap belongs to the pending bidder (t2) in
///                 HandoverConfirmed. May not borrow during demand.
///   · `Stale`   — cap is neither current nor pending: superseded bid,
///                 former tenant, or no active rental at all.
///
/// `copy, drop, store` so callers can pass it freely without consuming.
public enum CapAuthorizationState has drop {
    Current,
    Pending,
    Stale,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff this authorization is `Current`.
public fun is_current(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Current => true, _ => false }
}

/// True iff this authorization is `Pending`.
public fun is_pending(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Pending => true, _ => false }
}

/// True iff this authorization is `Stale`.
public fun is_stale(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Stale => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct a `Current` authorization.
public(package) fun current(): CapAuthorizationState { CapAuthorizationState::Current }

/// Construct a `Pending` authorization.
public(package) fun pending(): CapAuthorizationState { CapAuthorizationState::Pending }

/// Construct a `Stale` authorization.
public(package) fun stale(): CapAuthorizationState { CapAuthorizationState::Stale }

// === Private Functions ===

// === Test Functions ===
