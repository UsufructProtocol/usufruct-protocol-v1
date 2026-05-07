// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::runtime_projection;

// === Imports ===

use usufruct::{
    asset::{Self, Asset},
    cap_authorization_state::{Self as cap_auth, CapAuthorizationState},
    config::{Self, IntegrationConfig},
    credit_context_state::{Self as credit, CreditContext},
    curve_shape_state::CurveShapeState,
    descent_policy_state::DescentPolicyState,
    handover_policy_state::HandoverPolicyState,
    price_function_state::PriceFunctionState,
    retire_policy_state::RetirePolicyState,
};

// === credit_context_state ===

public fun credit_stake(ctx: &CreditContext): u64          { credit::proj_stake(ctx) }
public fun credit_phase_start_ms(ctx: &CreditContext): u64 { credit::proj_phase_start_ms(ctx) }
public fun credit_is_accruing(ctx: &CreditContext): bool   { credit::proj_is_accruing(ctx) }
public fun credit_is_capped(ctx: &CreditContext): bool     { credit::proj_is_capped(ctx) }
public fun credit_expiry_ms(ctx: &CreditContext): Option<u64> { credit::proj_expiry_ms(ctx) }

// === config ===

public fun config_min_rent_price(cfg: &IntegrationConfig): u64                 { config::proj_min_rent_price(cfg) }
public fun config_tenure_ceiling(cfg: &IntegrationConfig): u64                 { config::proj_tenure_ceiling(cfg) }
public fun config_handover(cfg: &IntegrationConfig):       &HandoverPolicyState { config::proj_handover(cfg) }
public fun config_descent(cfg: &IntegrationConfig):        &DescentPolicyState  { config::proj_descent(cfg) }
public fun config_retire(cfg: &IntegrationConfig):         &RetirePolicyState   { config::proj_retire(cfg) }
public fun config_credit_curve(cfg: &IntegrationConfig):   &CurveShapeState     { config::proj_credit_curve(cfg) }
public fun config_descent_curve(cfg: &IntegrationConfig):  &CurveShapeState     { config::proj_descent_curve(cfg) }
public fun config_price_fn(cfg: &IntegrationConfig):       &PriceFunctionState  { config::proj_price_function_state(cfg) }

// === cap_authorization_state ===

public fun cap_auth_is_current(a: &CapAuthorizationState): bool { cap_auth::proj_is_current(a) }
public fun cap_auth_is_pending(a: &CapAuthorizationState): bool { cap_auth::proj_is_pending(a) }
public fun cap_auth_is_stale(a: &CapAuthorizationState):   bool { cap_auth::proj_is_stale(a)   }

// === asset ===

public fun asset_asset_id<U: key + store>(self: &Asset<U>): ID {
    asset::proj_asset_id(self)
}

public fun asset_escrow_id<U: key + store>(self: &Asset<U>): ID {
    asset::proj_escrow_id(self)
}

public fun asset_is_available<U: key + store>(self: &Asset<U>): bool {
    asset::proj_is_available(self)
}


