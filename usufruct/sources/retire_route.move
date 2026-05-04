// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::retire_route;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

/// How a retirement request is routed given the current lifecycle state.
/// Produced by `lifecycle_state::retire_route`; consumed by
/// `escrow_coordinator::retire`.
///
///   · `Immediate`     — no active tenant (Idle or AtDutchAuction).
///                       The asset can be retired right now.
///   · `Deferred`      — active tenant (HandoverOpen or HandoverConfirmed).
///                       Set the retiring flag; the asset retires when
///                       the current tenure expires.
///   · `AlreadyRetired` — state is already Retired. Abort.
///
/// `copy, drop, store` so callers can pass it freely without consuming.
public enum RetireRoute has copy, drop, store {
    Immediate,
    Deferred,
    AlreadyRetired,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

/// True iff this route is `Immediate`.
public fun is_immediate(r: &RetireRoute): bool {
    match (r) { RetireRoute::Immediate => true, _ => false }
}

/// True iff this route is `Deferred`.
public fun is_deferred(r: &RetireRoute): bool {
    match (r) { RetireRoute::Deferred => true, _ => false }
}

/// True iff this route is `AlreadyRetired`.
public fun is_already_retired(r: &RetireRoute): bool {
    match (r) { RetireRoute::AlreadyRetired => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct an `Immediate` route.
public(package) fun immediate(): RetireRoute { RetireRoute::Immediate }

/// Construct a `Deferred` route.
public(package) fun deferred(): RetireRoute { RetireRoute::Deferred }

/// Construct an `AlreadyRetired` route.
public(package) fun already_retired(): RetireRoute { RetireRoute::AlreadyRetired }

// === Private Functions ===

// === Test Functions ===
