// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

// Eager projection of what each module knows about the runtime. Wraps every
// proj_* function as public for SDK/PTB access. Some types lack key+store and
// won't be observable in practice — the type system handles that curation.
module usufruct::runtime_projection;

// === Imports ===

use usufruct::{
    asset::{Self, AssetCustodyOpen, AssetCustodyLocked},
    phases,
    asset_context_state::{Self as acs, AssetContext},
    owner::{Self as owner_mod, Owner, OwnerIdentity, OwnerEarnings},
    price_state::{Self as ps, PriceState},
    refund_state::{Self as refund, RefundState},
    tenant::{Self as tenant_mod, Tenant, TenantIdentity, TenantStake},
    cap_authorization_state::{Self as cap_auth, CapAuthorizationState},
    config::{Self, IntegrationConfig},
    credit_context_state::{Self as credit, CreditContext},
    curve_shape_state::{Self as curve, CurveShapeState},
    descent_policy_state::{Self as descent, DescentPolicyState},
    fee_message::{Self as fee_msg, FeeMessage, FeeShare},
    handover_policy_state::{Self as handover, HandoverPolicyState},
    price_function_state::{Self as price_fn, PriceFunctionState},
    retire_policy_state::{Self as retire, RetirePolicyState},
};

// === asset_context_state ===

public fun asset_is_inactive<A: key + store, C>(e: &AssetContext<A, C>): bool  { acs::proj_is_inactive(e) }
public fun asset_is_idle<A: key + store, C>(e: &AssetContext<A, C>):     bool  { acs::proj_is_idle(e) }
public fun asset_is_at_dutch<A: key + store, C>(e: &AssetContext<A, C>): bool  { acs::proj_is_at_dutch(e) }
public fun asset_is_rented<A: key + store, C>(e: &AssetContext<A, C>):   bool  { acs::proj_is_rented(e) }
public fun asset_is_handover_open<A: key + store, C>(e: &AssetContext<A, C>):      bool { acs::proj_is_handover_open(e) }
public fun asset_is_handover_confirmed<A: key + store, C>(e: &AssetContext<A, C>): bool { acs::proj_is_handover_confirmed(e) }
public fun asset_is_retiring<A: key + store, C>(e: &AssetContext<A, C>):  bool  { acs::proj_is_retiring(e) }
public fun asset_owner_balance<A: key + store, C>(e: &AssetContext<A, C>):   u64 { acs::proj_owner_balance(e) }
public fun asset_owner_cap_id<A: key + store, C>(e: &AssetContext<A, C>):    ID  { acs::proj_owner_cap_id(e) }
public fun asset_fee_inbox_id<A: key + store, C>(e: &AssetContext<A, C>):    ID  { acs::proj_fee_inbox_id(e) }
public fun asset_integrated_at_ms<A: key + store, C>(e: &AssetContext<A, C>): u64 { acs::proj_integrated_at_ms(e) }
public fun asset_current_addr<A: key + store, C>(e: &AssetContext<A, C>):  Option<address> { acs::proj_current_addr(e) }
public fun asset_current_cap_id<A: key + store, C>(e: &AssetContext<A, C>): Option<ID>     { acs::proj_current_cap_id(e) }
public fun asset_pending_addr<A: key + store, C>(e: &AssetContext<A, C>):  Option<address> { acs::proj_pending_addr(e) }
public fun asset_pending_cap_id<A: key + store, C>(e: &AssetContext<A, C>): Option<ID>     { acs::proj_pending_cap_id(e) }
public fun asset_current_stake<A: key + store, C>(e: &AssetContext<A, C>):  Option<u64>    { acs::proj_current_stake(e) }
public fun asset_pending_stake<A: key + store, C>(e: &AssetContext<A, C>):  Option<u64>    { acs::proj_pending_stake(e) }
public fun asset_phase_start_ms<A: key + store, C>(e: &AssetContext<A, C>): Option<u64>   { acs::proj_phase_start_ms(e) }
public fun asset_handover_expiry<A: key + store, C>(e: &AssetContext<A, C>): Option<u64>  { acs::proj_handover_expiry(e) }
public fun asset_last_acq_price<A: key + store, C>(e: &AssetContext<A, C>):  Option<u64>  { acs::proj_last_acq_price(e) }

// === fee_message ===

public fun fee_share_value<C>(s: &FeeShare<C>):           u64 { fee_msg::proj_share_value(s) }
public fun fee_message_escrow_id<C>(msg: &FeeMessage<C>): ID  { fee_msg::proj_escrow_id(msg) }
public fun fee_message_amount<C>(msg: &FeeMessage<C>):    u64 { fee_msg::proj_amount(msg) }

// === tenant ===

public fun tenant_identity<C>(t: &Tenant<C>):          &TenantIdentity  { tenant_mod::proj_identity(t) }
public fun tenant_stake<C>(t: &Tenant<C>):             &TenantStake<C>  { tenant_mod::proj_stake(t) }
public fun tenant_stake_value<C>(t: &Tenant<C>):       u64              { tenant_mod::proj_stake_value(t) }
public fun tenant_cap_id(id: &TenantIdentity):          ID               { tenant_mod::proj_cap_id(id) }
public fun tenant_address(id: &TenantIdentity):         address          { tenant_mod::proj_address(id) }
public fun tenant_stake_value_of<C>(s: &TenantStake<C>): u64            { tenant_mod::proj_stake_value_of(s) }

// === retire_policy_state ===

public fun retire_is_immediate(p: &RetirePolicyState): bool       { retire::proj_is_immediate(p) }
public fun retire_is_deferred(p: &RetirePolicyState):  bool       { retire::proj_is_deferred(p) }
public fun retire_floor_ms(p: &RetirePolicyState): Option<u64> {
    let opt = retire::proj_floor_ms(p);
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

// === refund_state ===

public fun refund_is_nothing<C>(rs: &RefundState<C>): bool { refund::proj_is_nothing(rs) }
public fun refund_is_parcial<C>(rs: &RefundState<C>): bool { refund::proj_is_parcial(rs) }
public fun refund_is_total<C>(rs: &RefundState<C>):   bool { refund::proj_is_total(rs) }

// === price_state ===

public fun price_state_is_rest(s: &PriceState):      bool       { ps::proj_is_rest(s) }
public fun price_state_is_ascending(s: &PriceState): bool       { ps::proj_is_ascending(s) }
public fun price_state_is_descending(s: &PriceState): bool      { ps::proj_is_descending(s) }
public fun price_state_ascending_stake(s: &PriceState): Option<u64>           { ps::proj_ascending_stake(s) }
public fun price_state_descending_last_acq_price(s: &PriceState): Option<u64> { ps::proj_descending_last_acq_price(s) }
public fun price_state_descending_phase_start_ms(s: &PriceState): Option<u64> { ps::proj_descending_phase_start_ms(s) }

// === price_function_state ===

public fun price_fn_is_fixed_delta(p: &PriceFunctionState):     bool       { price_fn::proj_is_fixed_delta(p) }
public fun price_fn_is_compound_delta(p: &PriceFunctionState):  bool       { price_fn::proj_is_compound_delta(p) }
public fun price_fn_fixed_delta(p: &PriceFunctionState):        Option<u64> { price_fn::proj_fixed_delta(p) }
public fun price_fn_compound_delta_bps(p: &PriceFunctionState): Option<u64> { price_fn::proj_compound_delta_bps(p) }
public fun price_fn_compound_delta_delta(p: &PriceFunctionState): Option<u64> { price_fn::proj_compound_delta_delta(p) }

// === owner ===

public fun owner_value<C>(o: &Owner<C>):                  u64             { owner_mod::proj_value(o) }
public fun owner_cap_id(id: &OwnerIdentity):               ID              { owner_mod::proj_cap_id(id) }
public fun owner_identity<C>(o: &Owner<C>):               &OwnerIdentity  { owner_mod::proj_identity(o) }
public fun owner_earnings<C>(o: &Owner<C>):               &OwnerEarnings<C> { owner_mod::proj_earnings(o) }
public fun owner_earnings_value<C>(e: &OwnerEarnings<C>): u64             { owner_mod::proj_earnings_value(e) }

// === handover_policy_state ===

public fun handover_is_instant(p: &HandoverPolicyState):    bool       { handover::proj_is_instant(p) }
public fun handover_is_fixed_time(p: &HandoverPolicyState): bool       { handover::proj_is_fixed_time(p) }
public fun handover_is_countdown(p: &HandoverPolicyState):  bool       { handover::proj_is_countdown(p) }
public fun handover_countdown_floor_ms(p: &HandoverPolicyState): Option<u64> {
    let opt = handover::proj_countdown_floor_ms(p);
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

// === descent_policy_state ===

public fun descent_is_skipped(p: &DescentPolicyState): bool       { descent::proj_is_skipped(p) }
public fun descent_is_window(p: &DescentPolicyState):  bool       { descent::proj_is_window(p) }
public fun descent_window_ceiling(p: &DescentPolicyState): Option<u64> {
    let opt = descent::proj_window_ceiling(p);
    if (option::is_some(&opt)) option::some(phases::duration_ms(option::destroy_some(opt)))
    else option::none()
}

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
public fun config_tenure_ceiling(cfg: &IntegrationConfig): u64                 { phases::duration_ms(config::proj_tenure_ceiling(cfg)) }
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

public fun asset_locked_id<U: key + store>(self: &AssetCustodyLocked<U>): ID {
    asset::proj_locked_id(self)
}

public fun asset_asset_id<U: key + store>(self: &AssetCustodyOpen<U>): ID {
    asset::proj_asset_id(self)
}

public fun asset_escrow_id<U: key + store>(self: &AssetCustodyOpen<U>): ID {
    asset::proj_escrow_id(self)
}

public fun asset_is_available<U: key + store>(self: &AssetCustodyOpen<U>): bool {
    asset::proj_is_available(self)
}


