// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_state;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state,
    descent_policy_state,
    math,
    phases,
    price_function_state,
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Pricing regime of the asset — encodes which function answers
/// "¿cuánto cuesta acceder al asset ahora mismo?".
///
///   · `Rest`       — asset idle; any renter pays `min_rent_price`.
///   · `Ascending`  — asset rented; next bidder pays
///                    `price_function_state(current_stake)` (or pending stake
///                    when a handover is already in progress).
///   · `Descending` — asset in Dutch auction; price falls from
///                    `last_acq_price` toward `min_rent_price` along
///                    `descent_curve` over the descent window.
///
/// Derived by the coordinator from `LifecycleState` accessors; never
/// stored inside `AssetState` or `LifecycleState`.
public enum PriceState has drop {
    Rest,
    Ascending  { stake: u64 },
    Descending { last_acq_price: u64, phase_start_ms: u64 },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_rest(s: &PriceState):      bool { match (s) { PriceState::Rest => true, _ => false } }
public(package) fun proj_is_ascending(s: &PriceState): bool { match (s) { PriceState::Ascending { .. } => true, _ => false } }
public(package) fun proj_is_descending(s: &PriceState): bool { match (s) { PriceState::Descending { .. } => true, _ => false } }
public(package) fun proj_ascending_stake(s: &PriceState): Option<u64> {
    match (s) { PriceState::Ascending { stake } => option::some(*stake), _ => option::none() }
}
public(package) fun proj_descending_last_acq_price(s: &PriceState): Option<u64> {
    match (s) { PriceState::Descending { last_acq_price, .. } => option::some(*last_acq_price), _ => option::none() }
}
public(package) fun proj_descending_phase_start_ms(s: &PriceState): Option<u64> {
    match (s) { PriceState::Descending { phase_start_ms, .. } => option::some(*phase_start_ms), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct `Rest` — asset idle.
public(package) fun rest(): PriceState { PriceState::Rest }

/// Construct `Ascending` — asset rented; `stake` is the amount the
/// current (or pending) tenant paid, used as the base for the next
/// price step.
public(package) fun ascending(stake: u64): PriceState {
    PriceState::Ascending { stake }
}

/// Construct `Descending` — Dutch auction in progress.
/// `last_acq_price` seeds the descent; `phase_start_ms` anchors the
/// temporal decay.
public(package) fun descending(last_acq_price: u64, phase_start_ms: u64): PriceState {
    PriceState::Descending { last_acq_price, phase_start_ms }
}

/// Floor price a bidder must meet given the current pricing regime.
///
///   · Rest       — `min_rent_price` (config scalar, time-independent)
///   · Ascending  — `price_function_state(stake)` (time-independent)
///   · Descending — price falls from `last_acq_price` to `min_rent_price`
///                  along `descent_curve` over the descent window;
///                  saturates at `min_rent_price` when window elapses.
///
/// `timestamp_ms` is consumed only in the `Descending` branch.
public(package) fun floor_price(
    state:        &PriceState,
    cfg:          &IntegrationConfig,
    timestamp_ms: u64,
): u64 {
    match (state) {
        PriceState::Rest => config::proj_min_rent_price(cfg),
        PriceState::Ascending { stake } =>
            price_function_state::evaluate_price_fn(config::proj_price_function_state(cfg), *stake),
        PriceState::Descending { last_acq_price, phase_start_ms } => {
            let elapsed  = phases::elapsed_since(*phase_start_ms, timestamp_ms);
            let t_max    = descent_policy_state::window_ceiling(config::proj_descent(cfg));
            let h        = curve_shape_state::evaluate_curve(config::proj_descent_curve(cfg), elapsed, t_max);
            let spread   = *last_acq_price - config::proj_min_rent_price(cfg);
            let consumed = math::mul_div(spread, h, curve_shape_state::scale());
            *last_acq_price - consumed
        },
    }
}

// === Private Functions ===

// === Test Functions ===
