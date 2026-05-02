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
