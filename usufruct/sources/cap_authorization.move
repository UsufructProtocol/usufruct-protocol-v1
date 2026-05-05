// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::cap_authorization;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// Role a `TenantCap` plays relative to the current lifecycle state.
/// Produced by `lifecycle_state::cap_authorization`; consumed by
/// `escrow_coordinator::borrow_asset` and `burn_tenant_cap`.
///
///   · `Current` — cap belongs to the active tenant (t1). May borrow.
///   · `Pending` — cap belongs to the pending bidder (t2) in
///                 HandoverConfirmed. May not borrow during demand.
///   · `Stale`   — cap is neither current nor pending: superseded bid,
///                 former tenant, or no active rental at all.
///
/// `copy, drop, store` so callers can pass it freely without consuming.
public enum CapAuthorization has copy, drop, store {
    Current,
    Pending,
    Stale,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff this authorization is `Current`.
public fun is_current(a: &CapAuthorization): bool {
    match (a) { CapAuthorization::Current => true, _ => false }
}

/// True iff this authorization is `Pending`.
public fun is_pending(a: &CapAuthorization): bool {
    match (a) { CapAuthorization::Pending => true, _ => false }
}

/// True iff this authorization is `Stale`.
public fun is_stale(a: &CapAuthorization): bool {
    match (a) { CapAuthorization::Stale => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct a `Current` authorization.
public(package) fun current(): CapAuthorization { CapAuthorization::Current }

/// Construct a `Pending` authorization.
public(package) fun pending(): CapAuthorization { CapAuthorization::Pending }

/// Construct a `Stale` authorization.
public(package) fun stale(): CapAuthorization { CapAuthorization::Stale }

// === Private Functions ===

// === Test Functions ===
