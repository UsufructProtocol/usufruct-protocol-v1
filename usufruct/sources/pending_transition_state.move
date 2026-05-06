// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::pending_transition_state;

// === Imports ===

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
///   · `Handover` — handover-countdown expired in HandoverConfirmed.
///                  `boundary_ms` is the stored countdown expiry.
///   · `Tenure`   — tenure ceiling elapsed in HandoverOpen.
///                  `boundary_ms` is `phase_start_ms + tenure_ceiling`.
///   · `Auction`  — descent window elapsed in AtDutch.
///                  `boundary_ms` is `descent_policy_state::expiry_at`.
///
/// Constructed by `next_pending_from_tenancy` / `next_pending_from_state`
/// and consumed by `fire`. Not stored — derived from AssetContext on
/// demand. `drop` only; ephemeral derived value.
public struct PendingTransitionState has drop {
    boundary_ms: u64,
    kind:        PendingTransitionKind,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff this transition is the handover variant.
public fun is_handover(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Handover => true, _ => false }
}

/// True iff this transition is the tenure-expiry variant.
public fun is_tenure(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Tenure => true, _ => false }
}

/// True iff this transition is the auction-expiry variant.
public fun is_auction(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Auction => true, _ => false }
}

/// Boundary timestamp the firing handler will stamp on the resulting
/// state and on its emitted event.
public fun boundary_ms(t: &PendingTransitionState): u64 {
    t.boundary_ms
}

// === Admin Functions ===

// === Package Functions ===

/// Construct a `Handover` pending transition at `boundary_ms`.
public(package) fun handover(boundary_ms: u64): PendingTransitionState {
    PendingTransitionState { boundary_ms, kind: PendingTransitionKind::Handover }
}

/// Construct a `Tenure` pending transition at `boundary_ms`.
public(package) fun tenure(boundary_ms: u64): PendingTransitionState {
    PendingTransitionState { boundary_ms, kind: PendingTransitionKind::Tenure }
}

/// Construct an `Auction` pending transition at `boundary_ms`.
public(package) fun auction(boundary_ms: u64): PendingTransitionState {
    PendingTransitionState { boundary_ms, kind: PendingTransitionKind::Auction }
}

// === Private Functions ===

// === Test Functions ===
