// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::phases;

// === Imports ===

use std::u64;

// === Package Functions ===

/// True iff `now_ms` has reached or passed the boundary
/// `anchor_ms + duration_ms`. Time-layer primitive used by policy
/// modules to express "this phase boundary has been crossed".
public(package) fun has_passed(anchor_ms: u64, duration_ms: u64, now_ms: u64): bool {
    now_ms >= anchor_ms + duration_ms
}

/// Saturating elapsed time since `start_ms`. Returns `0` when the
/// clock has not yet reached the start (instead of underflowing the
/// u64 subtraction). Used by curve evaluators that take "elapsed
/// since phase start" as their progress input — the caller doesn't
/// need to guard against historical timestamps.
public(package) fun elapsed_since(start_ms: u64, now_ms: u64): u64 {
    if (now_ms >= start_ms) now_ms - start_ms else 0
}

/// Boundary timestamp `anchor_ms + duration_ms`. The u64 sister of
/// `has_passed`: that one asks whether the boundary has been crossed,
/// this one names the boundary itself. All temporal `+` in the
/// codebase routes through here so that `phases` is the single module
/// that performs arithmetic on timestamps.
public(package) fun boundary_at(anchor_ms: u64, duration_ms: u64): u64 {
    anchor_ms + duration_ms
}

/// Earlier of two timestamps. Used both for clock-vs-boundary clamps
/// (`earliest(now, expiry)` — credit accrual freezes at expiry) and
/// for boundary-vs-boundary saturation (`earliest(countdown_boundary,
/// tenure_boundary)` — handover Countdown rule). Semantically: pick
/// whichever event happens first.
public(package) fun earliest(a_ms: u64, b_ms: u64): u64 {
    u64::min(a_ms, b_ms)
}
