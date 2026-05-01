// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::config;

// === Imports ===

use std::u64;
use sui::event;
use usufruct::{
    curve_shape::CurveShape,
    price_function::PriceFunction,
};

// === Errors ===

const EMinRentPriceZero:           u64 = 0;
const ETenureCeilingZero:          u64 = 1;
const EHandoverFloorExceedsTenure: u64 = 2;   // Countdown.floor_ms >= tenure_ceiling
const EHandoverFloorZero:          u64 = 3;   // Countdown::new(0) — use Instant
const EDescentCeilingZero:         u64 = 4;   // Window::new(0) — use Skipped
const ERetireFloorZero:            u64 = 5;   // Deferred::new(0) — use Immediate
const EDescentSkippedNoWindow:     u64 = 6;   // descent_window_ceiling on Skipped

// === Constants ===

// === Structs ===

public enum HandoverPolicy has copy, drop, store {
    Instant,
    Countdown { floor_ms: u64 },
    FixedTime,
}

public enum DescentPolicy has copy, drop, store {
    Skipped,
    Window { ceiling_ms: u64 },
}

public enum RetirePolicy has copy, drop, store {
    Immediate,
    Deferred { floor_ms: u64 },
}

public struct IntegrationConfig has copy, drop, store {
    min_rent_price:  u64,
    tenure_ceiling:  u64,
    handover:        HandoverPolicy,
    descent:         DescentPolicy,
    retire:          RetirePolicy,
    credit_curve:    CurveShape,
    descent_curve:   CurveShape,
    price_function:  PriceFunction,
}

// === Events ===

public struct IntegrationConfigRegistered has copy, drop {
    escrow_id: ID,
    config:    IntegrationConfig,
}

// === Method Aliases ===

// === Public Functions ===

public fun new_handover_instant():    HandoverPolicy { HandoverPolicy::Instant }
public fun new_handover_fixed_time(): HandoverPolicy { HandoverPolicy::FixedTime }

public fun new_handover_countdown(floor_ms: u64): HandoverPolicy {
    assert!(floor_ms > 0, EHandoverFloorZero);
    HandoverPolicy::Countdown { floor_ms }
}

public fun new_descent_skipped(): DescentPolicy { DescentPolicy::Skipped }

public fun new_descent_window(ceiling_ms: u64): DescentPolicy {
    assert!(ceiling_ms > 0, EDescentCeilingZero);
    DescentPolicy::Window { ceiling_ms }
}

public fun new_retire_immediate(): RetirePolicy { RetirePolicy::Immediate }

public fun new_retire_deferred(floor_ms: u64): RetirePolicy {
    assert!(floor_ms > 0, ERetireFloorZero);
    RetirePolicy::Deferred { floor_ms }
}

public fun new_config(
    min_rent_price: u64,
    tenure_ceiling: u64,
    handover:       HandoverPolicy,
    descent:        DescentPolicy,
    retire:         RetirePolicy,
    credit_curve:   CurveShape,
    descent_curve:  CurveShape,
    price_function: PriceFunction,
): IntegrationConfig {
    assert!(min_rent_price > 0, EMinRentPriceZero);
    assert!(tenure_ceiling > 0, ETenureCeilingZero);
    // Variant constructors validate intra-variant invariants. This
    // re-validation catches direct enum construction that bypasses them
    // (`HandoverPolicy::Countdown { floor_ms: 0 }`) and enforces the
    // cross-field constraint `Countdown.floor_ms < tenure_ceiling`
    // (equality is FixedTime, a separate variant).
    match (&handover) {
        HandoverPolicy::Countdown { floor_ms } => {
            assert!(*floor_ms > 0,              EHandoverFloorZero);
            assert!(*floor_ms < tenure_ceiling, EHandoverFloorExceedsTenure);
        },
        HandoverPolicy::Instant | HandoverPolicy::FixedTime => (),
    };
    match (&descent) {
        DescentPolicy::Window { ceiling_ms } =>
            assert!(*ceiling_ms > 0, EDescentCeilingZero),
        DescentPolicy::Skipped => (),
    };
    match (&retire) {
        RetirePolicy::Deferred { floor_ms } =>
            assert!(*floor_ms > 0, ERetireFloorZero),
        RetirePolicy::Immediate => (),
    };
    IntegrationConfig {
        min_rent_price,
        tenure_ceiling,
        handover,
        descent,
        retire,
        credit_curve,
        descent_curve,
        price_function,
    }
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun emit_registration(cfg: &IntegrationConfig, escrow_id: ID) {
    event::emit(IntegrationConfigRegistered { escrow_id, config: *cfg });
}

// --- IntegrationConfig getters ---

public(package) fun min_rent_price(cfg: &IntegrationConfig): u64          { cfg.min_rent_price }
public(package) fun tenure_ceiling(cfg: &IntegrationConfig): u64          { cfg.tenure_ceiling }
public(package) fun handover(cfg: &IntegrationConfig): &HandoverPolicy    { &cfg.handover }
public(package) fun descent(cfg: &IntegrationConfig): &DescentPolicy      { &cfg.descent }
public(package) fun retire(cfg: &IntegrationConfig): &RetirePolicy        { &cfg.retire }
public(package) fun credit_curve(cfg: &IntegrationConfig): &CurveShape    { &cfg.credit_curve }
public(package) fun descent_curve(cfg: &IntegrationConfig): &CurveShape   { &cfg.descent_curve }
public(package) fun price_function(cfg: &IntegrationConfig): &PriceFunction { &cfg.price_function }

// --- HandoverPolicy dispatch ---

/// Timestamp at which the handover countdown expires. Encapsulates the
/// saturation rule (spec §5.1): `Countdown` clamps to the tenure
/// boundary; `FixedTime` is the boundary itself; `Instant` collapses
/// to `now`.
public(package) fun handover_expiry(
    cfg:            &IntegrationConfig,
    now:            u64,
    phase_start_ms: u64,
): u64 {
    match (&cfg.handover) {
        HandoverPolicy::Instant                => now,
        HandoverPolicy::Countdown { floor_ms } =>
            u64::min(now + *floor_ms, phase_start_ms + cfg.tenure_ceiling),
        HandoverPolicy::FixedTime              => phase_start_ms + cfg.tenure_ceiling,
    }
}

// --- DescentPolicy dispatch ---

/// Boundary timestamp at which `do_auction_expiry` fires. `Skipped`
/// returns `phase_start_ms` itself, so `now >= boundary` is trivially
/// satisfied at the same instant `do_tenure_expiry` produces the
/// `AtDutchAuction` variant — collapsing the cascade to `Idle` in one
/// APT step (spec M6b / Q11).
public(package) fun descent_boundary(
    cfg:            &IntegrationConfig,
    phase_start_ms: u64,
): u64 {
    match (&cfg.descent) {
        DescentPolicy::Skipped               => phase_start_ms,
        DescentPolicy::Window { ceiling_ms } => phase_start_ms + *ceiling_ms,
    }
}

/// Width of the descent window. Aborts on `Skipped`: a caller asking
/// for the window duration when the policy is to skip the auction has
/// reached an unreachable state — `compute_price_descent` is only
/// called from `AtDutchAuction`, and that variant is structurally
/// unobservable under `Skipped`.
public(package) fun descent_window_ceiling(cfg: &IntegrationConfig): u64 {
    match (&cfg.descent) {
        DescentPolicy::Window { ceiling_ms } => *ceiling_ms,
        DescentPolicy::Skipped               => abort EDescentSkippedNoWindow,
    }
}

/// Whether `AtDutchAuction` is structurally observable under this config.
public(package) fun is_auction_observable(cfg: &IntegrationConfig): bool {
    match (&cfg.descent) {
        DescentPolicy::Skipped     => false,
        DescentPolicy::Window {..} => true,
    }
}

// --- RetirePolicy dispatch ---

/// Earliest clock timestamp at which `retire()` may proceed.
/// `Immediate` returns `0`, so the guard `clock >= retire_unlock(...)`
/// is trivially satisfied. `Deferred` anchors the unlock to integration
/// time.
public(package) fun retire_unlock(
    cfg:              &IntegrationConfig,
    integrated_at_ms: u64,
): u64 {
    match (&cfg.retire) {
        RetirePolicy::Immediate             => 0,
        RetirePolicy::Deferred { floor_ms } => integrated_at_ms + *floor_ms,
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun registered_escrow_id(e: &IntegrationConfigRegistered): ID { e.escrow_id }
#[test_only]
public fun registered_config(e: &IntegrationConfigRegistered): IntegrationConfig { e.config }
