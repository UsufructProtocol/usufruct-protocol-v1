// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_state;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state,
    floor_price_policy_state,
    monetary::{Self, Price, Stake},
    phases::{Self, Timestamp, Duration},
    price_function_state,
};

// === Errors ===

// === Constants ===

// === Structs ===

public enum PriceState has drop {
    Rest,
    Ascending  { stake: Stake },
    Descending { last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price, resolved_descent: Duration },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_rest(s: &PriceState):      bool { match (s) { PriceState::Rest => true, _ => false } }
public(package) fun proj_is_ascending(s: &PriceState): bool { match (s) { PriceState::Ascending { .. } => true, _ => false } }
public(package) fun proj_is_descending(s: &PriceState): bool { match (s) { PriceState::Descending { .. } => true, _ => false } }

// === Admin Functions ===

// === Package Functions ===

public(package) fun rest(): PriceState { PriceState::Rest }

public(package) fun ascending(stake: Stake): PriceState {
    PriceState::Ascending { stake }
}

public(package) fun descending(last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price, resolved_descent: Duration): PriceState {
    PriceState::Descending { last_acq_price, phase_start, resolved_floor, resolved_descent }
}

public(package) fun floor_price(
    state: &PriceState,
    cfg:   &IntegrationConfig,
    now:   Timestamp,
): Price {
    match (state) {
        PriceState::Rest => floor_price_policy_state::floor_for_view(config::proj_min_rent_price(cfg)),
        PriceState::Ascending { stake } =>
            price_function_state::evaluate_price_fn(
                config::proj_price_function_state(cfg),
                monetary::as_reference_price(*stake),
            ),
        PriceState::Descending { last_acq_price, phase_start, resolved_floor, resolved_descent } => {
            let elapsed  = phases::elapsed_since(*phase_start, now);
            let h        = curve_shape_state::evaluate_curve(
                config::proj_descent_curve(cfg),
                phases::duration_ms(elapsed),
                phases::duration_ms(*resolved_descent),
            );
            let spread   = monetary::price_mist(monetary::price_sub(*last_acq_price, *resolved_floor));
            let consumed = curve_shape_state::apply(spread, h);
            monetary::price_sub(*last_acq_price, monetary::price(consumed))
        },
    }
}

// === Private Functions ===

// === Test Functions ===

