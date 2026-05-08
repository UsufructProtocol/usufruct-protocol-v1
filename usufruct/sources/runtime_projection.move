// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::runtime_projection;

// === Imports ===

use usufruct::{
    asset::{Self, AssetCustodyOpen},
    cap_authorization_state::{Self as cap_auth, CapAuthorizationState},
    config::{Self, IntegrationConfig},
    credit_context_state::{Self as credit, CreditContext},
    curve_shape_state::{Self as curve, CurveShapeState},
    descent_policy_state::{Self as descent, DescentPolicyState},
    fee_message::{Self as fee_msg, FeeMessage, FeeShare},
    handover_policy_state::{Self as handover, HandoverPolicyState},
    price_function_state::PriceFunctionState,
    retire_policy_state::RetirePolicyState,
};

// === fee_message ===

public fun fee_share_value<C>(s: &FeeShare<C>):           u64 { fee_msg::proj_share_value(s) }
public fun fee_message_escrow_id<C>(msg: &FeeMessage<C>): ID  { fee_msg::proj_escrow_id(msg) }
public fun fee_message_amount<C>(msg: &FeeMessage<C>):    u64 { fee_msg::proj_amount(msg) }

// === handover_policy_state ===

public fun handover_is_instant(p: &HandoverPolicyState):    bool       { handover::proj_is_instant(p) }
public fun handover_is_fixed_time(p: &HandoverPolicyState): bool       { handover::proj_is_fixed_time(p) }
public fun handover_is_countdown(p: &HandoverPolicyState):  bool       { handover::proj_is_countdown(p) }
public fun handover_countdown_floor_ms(p: &HandoverPolicyState): Option<u64> { handover::proj_countdown_floor_ms(p) }

// === descent_policy_state ===

public fun descent_is_skipped(p: &DescentPolicyState): bool       { descent::proj_is_skipped(p) }
public fun descent_is_window(p: &DescentPolicyState):  bool       { descent::proj_is_window(p) }
public fun descent_window_ceiling(p: &DescentPolicyState): Option<u64> { descent::proj_window_ceiling(p) }

// === curve_shape_state ===

public fun curve_is_linear(s: &CurveShapeState):      bool         { curve::proj_is_linear(s) }
public fun curve_is_smoothstep(s: &CurveShapeState):  bool         { curve::proj_is_smoothstep(s) }
public fun curve_is_logistic(s: &CurveShapeState):    bool         { curve::proj_is_logistic(s) }
public fun curve_is_power_law(s: &CurveShapeState):   bool         { curve::proj_is_power_law(s) }
public fun curve_is_exponential(s: &CurveShapeState): bool         { curve::proj_is_exponential(s) }
public fun curve_power_law_alpha_num(s: &CurveShapeState): Option<u8>   { curve::proj_power_law_alpha_num(s) }
public fun curve_power_law_alpha_den(s: &CurveShapeState): Option<u8>   { curve::proj_power_law_alpha_den(s) }
public fun curve_exponential_alpha_abs(s: &CurveShapeState): Option<u8>   { curve::proj_exponential_alpha_abs(s) }
public fun curve_exponential_alpha_neg(s: &CurveShapeState): Option<bool> { curve::proj_exponential_alpha_neg(s) }

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

public fun asset_asset_id<U: key + store>(self: &AssetCustodyOpen<U>): ID {
    asset::proj_asset_id(self)
}

public fun asset_escrow_id<U: key + store>(self: &AssetCustodyOpen<U>): ID {
    asset::proj_escrow_id(self)
}

public fun asset_is_available<U: key + store>(self: &AssetCustodyOpen<U>): bool {
    asset::proj_is_available(self)
}


