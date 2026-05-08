// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::descent_policy_state;

// === Imports ===

use usufruct::phases;

// === Errors ===

const EDescentCeilingZero:     u64 = 0;
const EDescentSkippedNoWindow: u64 = 1;

// === Structs ===

public enum DescentPolicyState has copy, drop, store {
    Skipped,
    Window { ceiling_ms: u64 },
}

// === Public Functions ===

public fun new_descent_skipped(): DescentPolicyState { DescentPolicyState::Skipped }

public fun new_descent_window(ceiling_ms: u64): DescentPolicyState {
    assert!(ceiling_ms > 0, EDescentCeilingZero);
    DescentPolicyState::Window { ceiling_ms }
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_skipped(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Skipped => true, _ => false }
}
public(package) fun proj_is_window(policy: &DescentPolicyState): bool {
    match (policy) { DescentPolicyState::Window { .. } => true, _ => false }
}
public(package) fun proj_window_ceiling(policy: &DescentPolicyState): Option<u64> {
    match (policy) {
        DescentPolicyState::Window { ceiling_ms } => option::some(*ceiling_ms),
        DescentPolicyState::Skipped               => option::none(),
    }
}

// === Package Functions ===

/// True iff the descent window has expired — the auction should
/// collapse to `Idle`.
///   - Skipped collapses to true immediately (no auction window
///     exists; `AtDutchAuction` is structurally unobservable under
///     this policy — spec M6b / Q11).
///   - Window expires when the ceiling elapses since `phase_start_ms`.
public(package) fun has_expired(
    policy:         &DescentPolicyState,
    phase_start_ms: u64,
    now_ms:         u64,
): bool {
    match (policy) {
        // Skipped collapses at `phase_start_ms`: zero window means the
        // gate opens at the moment AtDutchAuction is entered, not
        // vacuously before. Defensive monotonicity — preserves the
        // sister identity `has_expired ⇔ now >= expiry_at`
        // unconditionally (Skipped's expiry_at is phase_start_ms). In
        // production, clock-monotone makes this equivalent to `=> true`.
        DescentPolicyState::Skipped               =>
            phases::has_passed(phase_start_ms, 0, now_ms),
        DescentPolicyState::Window { ceiling_ms } =>
            phases::has_passed(phase_start_ms, *ceiling_ms, now_ms),
    }
}

/// Canonical auction-collapse boundary timestamp — the moment at
/// which `do_auction_expiry` fires. Sister view of `has_expired`:
/// the bool dispatcher gates the cascade, this names the boundary
/// itself for the `AuctionExpired.timestamp_ms` event payload.
///
/// Skipped collapses to `phase_start_ms` itself, so the boundary is
/// trivially reached at the same instant `do_tenure_expiry` produces
/// `AtDutchAuction` — the cascade collapses to `Idle` in one APT step
/// (spec M6b / Q11).
public(package) fun expiry_at(
    policy:         &DescentPolicyState,
    phase_start_ms: u64,
): u64 {
    match (policy) {
        DescentPolicyState::Skipped               => phase_start_ms,
        DescentPolicyState::Window { ceiling_ms } => phases::boundary_at(phase_start_ms, *ceiling_ms),
    }
}

/// Width of the descent window, used by the dutch-auction price
/// curve to evaluate descent progress. Aborts on `Skipped`: a caller
/// asking for the window width when no auction exists has reached an
/// unreachable state — `compute_price_descent` is only called from
/// `AtDutchAuction`, and that variant is unobservable under `Skipped`.
public(package) fun window_ceiling(policy: &DescentPolicyState): u64 {
    match (policy) {
        DescentPolicyState::Window { ceiling_ms } => *ceiling_ms,
        DescentPolicyState::Skipped               => abort EDescentSkippedNoWindow,
    }
}

