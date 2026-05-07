// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::credit_context_state;

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

/// Variant-specific data for the credit sub-machine.
/// Shared fields (stake, phase_start_ms) live in CreditContext.
public enum CreditState has drop {
    Accruing,
    Capped { expiry_ms: u64 },
}

/// Context-State carrier for credit consumption.
///
///   · `Accruing` — HandoverOpen: credit accumulates freely against
///                  `credit_curve` over the full tenure window.
///   · `Capped`   — HandoverConfirmed: accrual freezes at `expiry_ms`;
///                  the remainder stays with the departing tenant.
///
/// Derived by the coordinator from `LifecycleState` accessors; never
/// stored inside `TenantState` or `LifecycleState`.
public struct CreditContext has drop {
    stake:          u64,
    phase_start_ms: u64,
    variant:        CreditState,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_stake(ctx: &CreditContext): u64 { ctx.stake }
public(package) fun proj_phase_start_ms(ctx: &CreditContext): u64 { ctx.phase_start_ms }

public(package) fun proj_is_accruing(ctx: &CreditContext): bool {
    match (&ctx.variant) { CreditState::Accruing => true, _ => false }
}

public(package) fun proj_is_capped(ctx: &CreditContext): bool {
    match (&ctx.variant) { CreditState::Capped { .. } => true, _ => false }
}

public(package) fun proj_expiry_ms(ctx: &CreditContext): Option<u64> {
    match (&ctx.variant) {
        CreditState::Capped { expiry_ms } => option::some(*expiry_ms),
        CreditState::Accruing             => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct `Accruing` — HandoverOpen, no countdown in progress.
public(package) fun accruing(stake: u64, phase_start_ms: u64): CreditContext {
    CreditContext { stake, phase_start_ms, variant: CreditState::Accruing }
}

/// Construct `Capped` — HandoverConfirmed, credit freezes at `expiry_ms`.
public(package) fun capped(stake: u64, phase_start_ms: u64, expiry_ms: u64): CreditContext {
    CreditContext { stake, phase_start_ms, variant: CreditState::Capped { expiry_ms } }
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
    ctx:          &CreditContext,
    cfg:          &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    let effective_ms = match (&ctx.variant) {
        CreditState::Accruing             => timestamp_ms,
        CreditState::Capped { expiry_ms } => phases::earliest(timestamp_ms, *expiry_ms),
    };
    let elapsed = phases::elapsed_since(ctx.phase_start_ms, effective_ms);
    let g = curve_shape_state::evaluate_curve(
        config::proj_credit_curve(cfg),
        elapsed,
        config::proj_tenure_ceiling(cfg),
    );
    math::mul_div(ctx.stake, g, curve_shape_state::scale())
}

// === Private Functions ===

// === Test Functions ===
