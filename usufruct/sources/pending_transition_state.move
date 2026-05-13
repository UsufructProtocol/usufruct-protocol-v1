// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::pending_transition_state;

// === Imports ===

use usufruct::phases::Timestamp;

// === Errors ===

// === Constants ===

// === Structs ===

/// Which kind of lazy transition is pending.
/// Unit enum — carries no per-variant data; boundary_ms lives in the
/// Context-State wrapper PendingTransitionState.
public enum PendingTransitionKind has copy, drop {
    Handover,
    Tenure,
    Auction,
}

/// Lazy transition due at a given timestamp. The coordinator's APT
/// loop separates *detection* (which transition is due, if any) from
/// *firing* (apply the corresponding boundary handler).
///
///   · `Handover` — handover-countdown expired in Demand.
///                  `boundary_ms` is the stored countdown expiry.
///   · `Tenure`   — tenure ceiling elapsed in Occupied.
///                  `boundary_ms` is `phase_start_ms + tenure_ceiling`.
///   · `Auction`  — descent window elapsed in AtDutch.
///                  `boundary_ms` is `descent_policy_state::expiry_at`.
///
/// Constructed by `next_pending_from_tenancy` / `next_pending_from_state`
/// and consumed by `fire`. Not stored — derived from AssetContext on
/// demand. `drop` only; ephemeral derived value.
public struct PendingTransitionState has drop {
    boundary: Timestamp,
    kind:     PendingTransitionKind,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

/// True iff this transition is the handover variant.
public(package) fun proj_is_handover(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Handover => true, _ => false }
}

/// True iff this transition is the tenure-expiry variant.
public(package) fun proj_is_tenure(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Tenure => true, _ => false }
}

/// True iff this transition is the auction-expiry variant.
public(package) fun proj_is_auction(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Auction => true, _ => false }
}

/// Boundary timestamp the firing handler will stamp on the resulting state and event.
public(package) fun proj_boundary(t: &PendingTransitionState): Timestamp {
    t.boundary
}

// === Admin Functions ===

// === Package Functions ===

/// Construct a `Handover` pending transition at `boundary`.
public(package) fun handover(boundary: Timestamp): PendingTransitionState {
    PendingTransitionState { boundary, kind: PendingTransitionKind::Handover }
}

/// Construct a `Tenure` pending transition at `boundary`.
public(package) fun tenure(boundary: Timestamp): PendingTransitionState {
    PendingTransitionState { boundary, kind: PendingTransitionKind::Tenure }
}

/// Construct an `Auction` pending transition at `boundary`.
public(package) fun auction(boundary: Timestamp): PendingTransitionState {
    PendingTransitionState { boundary, kind: PendingTransitionKind::Auction }
}

// === Private Functions ===

// === Test Functions ===
