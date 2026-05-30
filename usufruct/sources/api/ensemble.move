// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::ensemble;

// === Imports ===

use usufruct::{
    math::BasisPoints,
    monetary::{Self, Price},
    phases::{Self, Duration},
    tenures::{Self, Tenures},
    auction_window_policy::{Self, AuctionWindowPolicy},
    retire_commitment_policy::{Self, RetireCommitmentPolicy},
    ensemble_commitment_policy::{Self, EnsembleCommitmentPolicy},
    curve_shape_policy::{Self, CurveShapePolicy},
    handover_policy::{Self, HandoverPolicy},
    policy_ensemble::{Self, PolicyEnsemble},
    price_escalation_policy::{Self, PriceEscalationPolicy},
    rest_price_policy::{Self, RestPricePolicy},
    tenure_duration_policy::{Self, TenureDurationPolicy},
    tenure_extend_policy::{Self, TenureExtendPolicy},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// --- Value types ---

public fun price(mist: u64): Price { monetary::price(mist) }

public fun duration(ms: u64): Duration { phases::duration(ms) }

public fun tenures(n: u64): Tenures { tenures::tenures(n) }

// --- AuctionWindowPolicy ---

public fun new_descent_off(): AuctionWindowPolicy { auction_window_policy::new_descent_off() }

public fun new_descent_fixed(ceiling: Duration): AuctionWindowPolicy {
    auction_window_policy::new_descent_fixed(ceiling)
}

// --- RetireCommitmentPolicy ---

public fun new_retire_commitment_immediate(): RetireCommitmentPolicy { retire_commitment_policy::new_immediate() }

public fun new_retire_commitment_deferred(floor: Duration): RetireCommitmentPolicy {
    retire_commitment_policy::new_deferred(floor)
}

// --- EnsembleCommitmentPolicy ---

public fun new_ensemble_commitment_immediate(): EnsembleCommitmentPolicy { ensemble_commitment_policy::new_immediate() }

public fun new_ensemble_commitment_deferred(floor: Duration): EnsembleCommitmentPolicy {
    ensemble_commitment_policy::new_deferred(floor)
}

// --- CurveShapePolicy ---

public fun new_linear(): CurveShapePolicy { curve_shape_policy::new_linear() }

public fun new_smoothstep(): CurveShapePolicy { curve_shape_policy::new_smoothstep() }

public fun new_logistic(): CurveShapePolicy { curve_shape_policy::new_logistic() }

public fun new_power_law(alpha_num: u8, alpha_den: u8): CurveShapePolicy {
    curve_shape_policy::new_power_law(alpha_num, alpha_den)
}

public fun new_exponential(alpha_abs: u8, alpha_neg: bool): CurveShapePolicy {
    curve_shape_policy::new_exponential(alpha_abs, alpha_neg)
}

// --- HandoverPolicy ---

public fun new_handover_off(): HandoverPolicy { handover_policy::new_handover_off() }

public fun new_handover_full_tenure(): HandoverPolicy { handover_policy::new_handover_full_tenure() }

public fun new_handover_fixed(floor: Duration): HandoverPolicy {
    handover_policy::new_handover_fixed(floor)
}

// --- PriceEscalationPolicy ---

public fun new_price_fixed_delta(delta: Price): PriceEscalationPolicy {
    price_escalation_policy::new_fixed_delta(delta)
}

public fun new_price_compound_delta(bps: BasisPoints, delta: Price): PriceEscalationPolicy {
    price_escalation_policy::new_compound_delta(bps, delta)
}

// --- RestPricePolicy ---

public fun new_rest_price_fixed(price: Price): RestPricePolicy {
    rest_price_policy::new_fixed(price)
}

// --- TenureDurationPolicy ---

public fun new_tenure_duration_fixed(ceiling: Duration): TenureDurationPolicy {
    tenure_duration_policy::new_fixed(ceiling)
}

// --- TenureExtendPolicy ---

public fun new_tenure_single(): TenureExtendPolicy { tenure_extend_policy::new_single() }

public fun new_tenure_multi(): TenureExtendPolicy { tenure_extend_policy::new_multi() }

// --- PolicyEnsemble ---

public fun new_ensemble(
    rest_price:       RestPricePolicy,
    tenure_duration:  TenureDurationPolicy,
    tenure_extend:    TenureExtendPolicy,
    handover:         HandoverPolicy,
    auction_window:   AuctionWindowPolicy,
    credit_shape:     CurveShapePolicy,
    auction_shape:    CurveShapePolicy,
    price_escalation: PriceEscalationPolicy,
): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        rest_price,
        tenure_duration,
        tenure_extend,
        handover,
        auction_window,
        credit_shape,
        auction_shape,
        price_escalation,
    )
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
