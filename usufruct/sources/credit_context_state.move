// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::credit_context_state;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state,
    monetary::{Self, Stake},
    phases::{Self, Timestamp},
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Variant-specific data for the credit sub-machine.
/// Shared fields (stake, phase_start_ms) live in CreditContext.
public enum CreditState has drop {
    Accruing,
    Capped { expiry: Timestamp },
}

/// Context-State carrier for credit consumption.
///
///   · `Accruing` — HandoverOpen: credit accumulates freely against
///                  `credit_curve` over the full tenure window.
///   · `Capped`   — HandoverConfirmed: accrual freezes at `expiry`;
///                  the remainder stays with the departing tenant.
///
/// Derived by the coordinator from `LifecycleState` accessors; never
/// stored inside `TenantState` or `LifecycleState`.
public struct CreditContext has drop {
    stake:       Stake,
    phase_start: Timestamp,
    variant:     CreditState,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_stake(ctx: &CreditContext): Stake     { ctx.stake }
public(package) fun proj_phase_start(ctx: &CreditContext): Timestamp { ctx.phase_start }

public(package) fun proj_is_accruing(ctx: &CreditContext): bool {
    match (&ctx.variant) { CreditState::Accruing => true, _ => false }
}

public(package) fun proj_is_capped(ctx: &CreditContext): bool {
    match (&ctx.variant) { CreditState::Capped { .. } => true, _ => false }
}

public(package) fun proj_expiry(ctx: &CreditContext): Option<Timestamp> {
    match (&ctx.variant) {
        CreditState::Capped { expiry } => option::some(*expiry),
        CreditState::Accruing          => option::none(),
    }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct `Accruing` — HandoverOpen, no countdown in progress.
public(package) fun accruing(stake: Stake, phase_start: Timestamp): CreditContext {
    CreditContext { stake, phase_start, variant: CreditState::Accruing }
}

/// Construct `Capped` — HandoverConfirmed, credit freezes at `expiry`.
public(package) fun capped(stake: Stake, phase_start: Timestamp, expiry: Timestamp): CreditContext {
    CreditContext { stake, phase_start, variant: CreditState::Capped { expiry } }
}

/// Credit consumed from the tenant's stake up to `now`.
///
/// Both variants evaluate `credit_curve(elapsed / tenure_ceiling)`
/// scaled by `stake`; they differ only in the effective timestamp:
/// `Accruing` uses `now` directly, `Capped` saturates at `expiry`
/// so accrual freezes when the countdown boundary passes.
///
/// Returns 0 when elapsed == 0; returns `stake` when elapsed >=
/// `tenure_ceiling` (curve short-circuit at SCALE).
public(package) fun used_credit(
    ctx: &CreditContext,
    cfg: &IntegrationConfig,
    now: Timestamp,
): Stake {
    let effective = match (&ctx.variant) {
        CreditState::Accruing          => now,
        CreditState::Capped { expiry } => phases::earliest(now, *expiry),
    };
    let elapsed = phases::elapsed_since(ctx.phase_start, effective);
    let g = curve_shape_state::evaluate_curve(
        config::proj_credit_curve(cfg),
        phases::duration_ms(elapsed),        // ← temporal → math domain
        phases::duration_ms(config::proj_tenure_ceiling(cfg)),  // ← temporal → math domain
    );
    monetary::stake(curve_shape_state::apply(monetary::stake_mist(ctx.stake), g))
}

// === Private Functions ===

// === Test Functions ===
