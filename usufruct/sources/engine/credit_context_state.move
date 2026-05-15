// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::credit_context_state;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state,
    monetary::{Self, Stake},
    phases::{Self, Duration, Timestamp},
};

// === Errors ===

// === Constants ===

// === Structs ===

public enum CreditState has drop {
    Accruing,
    Capped { expiry: Timestamp },
}

public struct CreditContext has drop {
    stake:       Stake,
    phase_start: Timestamp,
    variant:     CreditState,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

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

public(package) fun accruing(stake: Stake, phase_start: Timestamp): CreditContext {
    CreditContext { stake, phase_start, variant: CreditState::Accruing }
}

public(package) fun capped(stake: Stake, phase_start: Timestamp, expiry: Timestamp): CreditContext {
    CreditContext { stake, phase_start, variant: CreditState::Capped { expiry } }
}

public(package) fun used_credit(
    ctx:              &CreditContext,
    cfg:              &IntegrationConfig,
    resolved_ceiling: Duration,
    now:              Timestamp,
): Stake {
    let effective = match (&ctx.variant) {
        CreditState::Accruing          => now,
        CreditState::Capped { expiry } => phases::earliest(now, *expiry),
    };
    let elapsed = phases::elapsed_since(ctx.phase_start, effective);
    let g = curve_shape_state::evaluate_curve(
        config::proj_credit_curve(cfg),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_ceiling),
    );
    monetary::stake(curve_shape_state::apply(monetary::stake_mist(ctx.stake), g))
}

// === Private Functions ===

// === Test Functions ===

