// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::pending_transition_state;

// === Imports ===

use usufruct::phases::Timestamp;

// === Errors ===

// === Constants ===

// === Structs ===

public enum PendingTransitionKind has copy, drop {
    Demand,
    Occupied,
    Auction,
}

public struct PendingTransitionState has drop {
    boundary: Timestamp,
    kind:     PendingTransitionKind,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_demand(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Demand => true, _ => false }
}

public(package) fun proj_is_occupied(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Occupied => true, _ => false }
}

public(package) fun proj_is_auction(t: &PendingTransitionState): bool {
    match (&t.kind) { PendingTransitionKind::Auction => true, _ => false }
}

public(package) fun proj_boundary(t: &PendingTransitionState): Timestamp {
    t.boundary
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun demand(boundary: Timestamp): PendingTransitionState {
    PendingTransitionState { boundary, kind: PendingTransitionKind::Demand }
}

public(package) fun occupied(boundary: Timestamp): PendingTransitionState {
    PendingTransitionState { boundary, kind: PendingTransitionKind::Occupied }
}

public(package) fun auction(boundary: Timestamp): PendingTransitionState {
    PendingTransitionState { boundary, kind: PendingTransitionKind::Auction }
}

// === Private Functions ===

// === Test Functions ===

