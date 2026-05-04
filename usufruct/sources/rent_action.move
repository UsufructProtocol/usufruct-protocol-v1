// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::rent_action;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// Which rental entry operation applies given the current lifecycle state.
/// Produced by `lifecycle_state::rent_action`; consumed by
/// `escrow_coordinator::rent`.
///
///   · `Install`      — no active tenant (Idle or AtDutchAuction).
///                      Start a new rental directly.
///   · `PlaceBid`     — HandoverOpen: there is an active tenant with no
///                      pending bidder yet. Place the first competing bid.
///   · `SupersedeBid` — HandoverConfirmed: a pending bidder already exists.
///                      Supersede the existing bid.
///   · `Retired`      — state is Retired. Unreachable in practice —
///                      `compute_floor_price` aborts with ERetiredNoBid
///                      before the dispatch is reached.
///
/// `copy, drop, store` so callers can pass it freely without consuming.
public enum RentAction has copy, drop, store {
    Install,
    PlaceBid,
    SupersedeBid,
    Retired,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff this action is `Install`.
public fun is_install(a: &RentAction): bool {
    match (a) { RentAction::Install => true, _ => false }
}

/// True iff this action is `PlaceBid`.
public fun is_place_bid(a: &RentAction): bool {
    match (a) { RentAction::PlaceBid => true, _ => false }
}

/// True iff this action is `SupersedeBid`.
public fun is_supersede_bid(a: &RentAction): bool {
    match (a) { RentAction::SupersedeBid => true, _ => false }
}

/// True iff this action is `Retired`.
public fun is_retired(a: &RentAction): bool {
    match (a) { RentAction::Retired => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct an `Install` action.
public(package) fun install(): RentAction { RentAction::Install }

/// Construct a `PlaceBid` action.
public(package) fun place_bid(): RentAction { RentAction::PlaceBid }

/// Construct a `SupersedeBid` action.
public(package) fun supersede_bid(): RentAction { RentAction::SupersedeBid }

/// Construct a `Retired` action.
public(package) fun retired(): RentAction { RentAction::Retired }

// === Private Functions ===

// === Test Functions ===
