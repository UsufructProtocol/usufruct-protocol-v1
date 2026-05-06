// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::credit_state;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state,
    math,
    phases,
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Credit consumption regime of the current tenant — encodes how much
/// of their stake the owner has earned up to a given timestamp.
///
/// Only meaningful while the lifecycle is `Rented`; the coordinator
/// never constructs this from a `NotRented` context.
///
///   · `Accruing` — `HandoverOpen`: credit accumulates freely against
///                  `credit_curve` over the full tenure window.
///   · `Capped`   — `HandoverConfirmed`: credit is identical to
///                  `Accruing` but the effective timestamp is saturated
///                  at `expiry_ms` (the handover countdown boundary).
///                  Accrual freezes once the countdown expires — the
///                  remainder stays with the departing tenant.
///
/// Derived by the coordinator from `LifecycleState` accessors; never
/// stored inside `TenantState` or `LifecycleState`.
public enum CreditState has drop {
    Accruing { stake: u64, phase_start_ms: u64 },
    Capped   { stake: u64, phase_start_ms: u64, expiry_ms: u64 },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Construct `Accruing` — `HandoverOpen`, no countdown in progress.
public(package) fun accruing(stake: u64, phase_start_ms: u64): CreditState {
    CreditState::Accruing { stake, phase_start_ms }
}

/// Construct `Capped` — `HandoverConfirmed`, credit freezes at
/// `expiry_ms` (the stored `handover_countdown_expiry` from
/// `TenantState::Demand`).
public(package) fun capped(stake: u64, phase_start_ms: u64, expiry_ms: u64): CreditState {
    CreditState::Capped { stake, phase_start_ms, expiry_ms }
}

/// Credit consumed from the tenant's stake up to `timestamp_ms`.
///
/// Both variants evaluate `credit_curve(elapsed / tenure_ceiling)`
/// scaled by `stake`; they differ only in the effective timestamp:
/// `Accruing` uses `timestamp_ms` directly, `Capped` saturates it at
/// `expiry_ms` so accrual freezes when the countdown boundary passes.
///
/// Returns 0 when elapsed == 0; returns `stake` when elapsed >=
/// `tenure_ceiling` (curve short-circuit at SCALE).
public(package) fun used_credit(
    state:        &CreditState,
    cfg:          &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    let (stake, phase_start_ms, effective_ms) = match (state) {
        CreditState::Accruing { stake, phase_start_ms } =>
            (*stake, *phase_start_ms, timestamp_ms),
        CreditState::Capped { stake, phase_start_ms, expiry_ms } =>
            (*stake, *phase_start_ms, phases::earliest(timestamp_ms, *expiry_ms)),
    };
    let elapsed = phases::elapsed_since(phase_start_ms, effective_ms);
    let g = curve_shape_state::evaluate_curve(
        config::credit_curve(cfg),
        elapsed,
        config::tenure_ceiling(cfg),
    );
    math::mul_div(stake, g, curve_shape_state::scale())
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_accruing(s: &CreditState): bool { match (s) { CreditState::Accruing { .. } => true, _ => false } }
#[test_only]
public fun is_capped(s: &CreditState):   bool { match (s) { CreditState::Capped   { .. } => true, _ => false } }
