// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::pending_transition_state;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// Lazy transition due at a given timestamp. The coordinator's APT
/// loop separates *detection* (which transition is due, if any) from
/// *firing* (apply the corresponding boundary handler). Each variant
/// carries the boundary timestamp the handler will stamp on the
/// resulting state and the emitted event.
///
///   · `Handover` — handover-countdown expired in HandoverConfirmed.
///                  `boundary_ms` is the stored countdown expiry.
///   · `Tenure`   — tenure ceiling elapsed in HandoverOpen.
///                  `boundary_ms` is `phase_start_ms + tenure_ceiling`.
///   · `Auction`  — descent window elapsed in AtDutch.
///                  `boundary_ms` is `descent_policy_state::expiry_at`.
///
/// Constructed by `escrow_coordinator::next_pending` and consumed by
/// `escrow_coordinator::fire`. Not stored anywhere — derived from
/// `LifecycleState` accessors on demand. `copy, drop, store` so it can
/// be queried freely (e.g. from `devInspectTransactionBlock` for
/// keeper bots probing pending boundaries without firing).
public enum PendingTransitionState has copy, drop, store {
    Handover { boundary_ms: u64 },
    Tenure   { boundary_ms: u64 },
    Auction  { boundary_ms: u64 },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff this transition is the handover variant.
public fun is_handover(t: &PendingTransitionState): bool {
    match (t) { PendingTransitionState::Handover { .. } => true, _ => false }
}

/// True iff this transition is the tenure-expiry variant.
public fun is_tenure(t: &PendingTransitionState): bool {
    match (t) { PendingTransitionState::Tenure { .. } => true, _ => false }
}

/// True iff this transition is the auction-expiry variant.
public fun is_auction(t: &PendingTransitionState): bool {
    match (t) { PendingTransitionState::Auction { .. } => true, _ => false }
}

/// Boundary timestamp the firing handler will stamp on the resulting
/// state and on its emitted event. The same field exists in every
/// variant — the accessor reads it uniformly.
public fun boundary_ms(t: &PendingTransitionState): u64 {
    match (t) {
        PendingTransitionState::Handover { boundary_ms } => *boundary_ms,
        PendingTransitionState::Tenure   { boundary_ms } => *boundary_ms,
        PendingTransitionState::Auction  { boundary_ms } => *boundary_ms,
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct a `Handover` pending transition at `boundary_ms`. Sole
/// construction site is `escrow_coordinator::next_pending`; the
/// `public(package)` modifier reflects that the regime is detected
/// from coordinator-internal state, not synthesised externally.
public(package) fun handover(boundary_ms: u64): PendingTransitionState {
    PendingTransitionState::Handover { boundary_ms }
}

/// Construct a `Tenure` pending transition at `boundary_ms`.
public(package) fun tenure(boundary_ms: u64): PendingTransitionState {
    PendingTransitionState::Tenure { boundary_ms }
}

/// Construct an `Auction` pending transition at `boundary_ms`.
public(package) fun auction(boundary_ms: u64): PendingTransitionState {
    PendingTransitionState::Auction { boundary_ms }
}

// === Private Functions ===

// === Test Functions ===
