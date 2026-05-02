// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::phases;

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
