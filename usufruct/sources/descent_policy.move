// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::descent_policy;

// === Imports ===

use usufruct::phases;

// === Errors ===

const EDescentCeilingZero:     u64 = 0;
const EDescentSkippedNoWindow: u64 = 1;

// === Structs ===

public enum DescentPolicy has copy, drop, store {
    Skipped,
    Window { ceiling_ms: u64 },
}

// === Public Functions ===

public fun new_descent_skipped(): DescentPolicy { DescentPolicy::Skipped }

public fun new_descent_window(ceiling_ms: u64): DescentPolicy {
    assert!(ceiling_ms > 0, EDescentCeilingZero);
    DescentPolicy::Window { ceiling_ms }
}

// === Package Functions ===

/// True iff the descent window has expired — the auction should
/// collapse to `Idle`.
///   - Skipped collapses to true immediately (no auction window
///     exists; `AtDutchAuction` is structurally unobservable under
///     this policy — spec M6b / Q11).
///   - Window expires when the ceiling elapses since `phase_start_ms`.
public(package) fun has_expired(
    policy:         &DescentPolicy,
    phase_start_ms: u64,
    now_ms:         u64,
): bool {
    match (policy) {
        DescentPolicy::Skipped               => true,
        DescentPolicy::Window { ceiling_ms } =>
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
    policy:         &DescentPolicy,
    phase_start_ms: u64,
): u64 {
    match (policy) {
        DescentPolicy::Skipped               => phase_start_ms,
        DescentPolicy::Window { ceiling_ms } => phase_start_ms + *ceiling_ms,
    }
}

/// Width of the descent window, used by the dutch-auction price
/// curve to evaluate descent progress. Aborts on `Skipped`: a caller
/// asking for the window width when no auction exists has reached an
/// unreachable state — `compute_price_descent` is only called from
/// `AtDutchAuction`, and that variant is unobservable under `Skipped`.
public(package) fun window_ceiling(policy: &DescentPolicy): u64 {
    match (policy) {
        DescentPolicy::Window { ceiling_ms } => *ceiling_ms,
        DescentPolicy::Skipped               => abort EDescentSkippedNoWindow,
    }
}
