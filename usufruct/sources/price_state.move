// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::price_state;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state,
    descent_policy_state,
    min_rent_price_state,
    monetary::{Self, Price, Stake},
    phases::{Self, Timestamp},
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
    Ascending  { stake: Stake },
    Descending { last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_is_rest(s: &PriceState):      bool { match (s) { PriceState::Rest => true, _ => false } }
public(package) fun proj_is_ascending(s: &PriceState): bool { match (s) { PriceState::Ascending { .. } => true, _ => false } }
public(package) fun proj_is_descending(s: &PriceState): bool { match (s) { PriceState::Descending { .. } => true, _ => false } }
public(package) fun proj_ascending_stake(s: &PriceState): Option<Stake> {
    match (s) { PriceState::Ascending { stake } => option::some(*stake), _ => option::none() }
}
public(package) fun proj_descending_last_acq_price(s: &PriceState): Option<Price> {
    match (s) { PriceState::Descending { last_acq_price, .. } => option::some(*last_acq_price), _ => option::none() }
}
public(package) fun proj_descending_phase_start(s: &PriceState): Option<Timestamp> {
    match (s) { PriceState::Descending { phase_start, .. } => option::some(*phase_start), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

/// Construct `Rest` — asset idle.
public(package) fun rest(): PriceState { PriceState::Rest }

/// Construct `Ascending` — asset rented; `stake` is the amount the
/// current (or pending) tenant paid, used as the base for the next
/// price step.
public(package) fun ascending(stake: Stake): PriceState {
    PriceState::Ascending { stake }
}

/// Construct `Descending` — Dutch auction in progress.
/// `last_acq_price` seeds the descent; `phase_start` anchors the temporal decay;
/// `resolved_floor` is the cycle's resolved floor, anchoring the descent bottom.
public(package) fun descending(last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price): PriceState {
    PriceState::Descending { last_acq_price, phase_start, resolved_floor }
}

/// Floor price a bidder must meet given the current pricing regime.
///
///   · Rest       — `min_rent_price` (config scalar, time-independent)
///   · Ascending  — `price_function_state(stake)` (time-independent)
///   · Descending — price falls from `last_acq_price` to `min_rent_price`
///                  along `descent_curve` over the descent window;
///                  saturates at `min_rent_price` when window elapses.
///
/// `now` is consumed only in the `Descending` branch.
public(package) fun floor_price(
    state: &PriceState,
    cfg:   &IntegrationConfig,
    now:   Timestamp,
): Price {
    match (state) {
        PriceState::Rest => min_rent_price_state::floor_for_view(config::proj_min_rent_price(cfg)),
        PriceState::Ascending { stake } =>
            price_function_state::evaluate_price_fn(
                config::proj_price_function_state(cfg),
                monetary::as_reference_price(*stake),
            ),
        PriceState::Descending { last_acq_price, phase_start, resolved_floor } => {
            let elapsed  = phases::elapsed_since(*phase_start, now);
            let t_max    = descent_policy_state::window_ceiling(config::proj_descent(cfg));
            let h        = curve_shape_state::evaluate_curve(
                config::proj_descent_curve(cfg),
                phases::duration_ms(elapsed),   // ← temporal → math domain
                phases::duration_ms(t_max),     // ← temporal → math domain
            );
            let spread   = monetary::price_mist(monetary::price_sub(*last_acq_price, *resolved_floor));
            let consumed = curve_shape_state::apply(spread, h);    // ← monetary → math domain
            monetary::price_sub(*last_acq_price, monetary::price(consumed))
        },
    }
}

// === Private Functions ===

// === Test Functions ===
