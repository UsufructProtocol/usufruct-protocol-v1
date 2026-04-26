// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::curve_shape;

// === Imports ===

use usufruct::math;

// === Errors ===

const EAlphaNumRange:    u64 = 0;
const EAlphaDenRange:    u64 = 1;
const EDegenerateLinear: u64 = 2;
const EAlphaAbsRange:    u64 = 3;

// === Constants ===

const TAYLOR_SCALE:    u128 = 1_000_000_000_000_000_000;
const TAYLOR_SCALE_SQ: u128 = 1_000_000_000_000_000_000_000_000_000_000_000_000;

const SCALE:      u64  = 1_000_000_000;
const SCALE_U128: u128 = 1_000_000_000;
const SCALE_SQ:   u128 = 1_000_000_000_000_000_000;
const SCALE_CB:   u128 = 1_000_000_000_000_000_000_000_000_000;

const LOGISTIC_K: u64 = 12;
// PLACEHOLDER — algorithm-derived during impl phase (see spec §9). Pinned during bootstrap.
const LOGISTIC_DENOM: u64 = 0;
const LOGISTIC_SIGMA_FLOOR: u128 = (SCALE_U128 - (LOGISTIC_DENOM as u128)) / 2;

// PLACEHOLDERS — algorithm-derived during impl phase (see spec §8). Pinned during bootstrap.
const EXP_A_NORM_1_POS: u128 = 0;
const EXP_A_NORM_2_POS: u128 = 0;
const EXP_A_NORM_3_POS: u128 = 0;
const EXP_A_NORM_4_POS: u128 = 0;
const EXP_A_NORM_5_POS: u128 = 0;
const EXP_A_NORM_6_POS: u128 = 0;
const EXP_A_NORM_7_POS: u128 = 0;
const EXP_A_NORM_8_POS: u128 = 0;
const EXP_A_NORM_1_NEG: u128 = 0;
const EXP_A_NORM_2_NEG: u128 = 0;
const EXP_A_NORM_3_NEG: u128 = 0;
const EXP_A_NORM_4_NEG: u128 = 0;
const EXP_A_NORM_5_NEG: u128 = 0;
const EXP_A_NORM_6_NEG: u128 = 0;
const EXP_A_NORM_7_NEG: u128 = 0;
const EXP_A_NORM_8_NEG: u128 = 0;

// === Structs ===

public enum CurveShape has copy, drop, store {
    Linear,
    Smoothstep,
    PowerLaw {
        alpha_num: u8,
        alpha_den: u8,
    },
    Exponential {
        alpha_abs: u8,
        alpha_neg: bool,
    },
    Logistic,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun new_linear(): CurveShape { CurveShape::Linear }

public fun new_smoothstep(): CurveShape { CurveShape::Smoothstep }

public fun new_logistic(): CurveShape { CurveShape::Logistic }

public fun new_power_law(alpha_num: u8, alpha_den: u8): CurveShape {
    assert!(alpha_num >= 1 && alpha_num <= 8, EAlphaNumRange);
    assert!(alpha_den >= 1 && alpha_den <= 4, EAlphaDenRange);
    assert!(alpha_num != alpha_den,           EDegenerateLinear);
    let g = gcd_u8(alpha_num, alpha_den);
    CurveShape::PowerLaw {
        alpha_num: alpha_num / g,
        alpha_den: alpha_den / g,
    }
}

public fun new_exponential(alpha_abs: u8, alpha_neg: bool): CurveShape {
    assert!(alpha_abs >= 1 && alpha_abs <= 8, EAlphaAbsRange);
    CurveShape::Exponential { alpha_abs, alpha_neg }
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun evaluate_curve(_shape: &CurveShape, _t: u64, _t_max: u64): u64 { abort 0 }

// === Private Functions ===

fun eval_linear(_t: u64, _t_max: u64): u64 { abort 0 }

fun eval_smoothstep(_t: u64, _t_max: u64): u64 { abort 0 }

fun eval_power_law(_t: u64, _t_max: u64, _alpha_num: u8, _alpha_den: u8): u64 { abort 0 }

fun eval_exponential(_t: u64, _t_max: u64, _alpha_abs: u8, _alpha_neg: bool): u64 { abort 0 }

fun eval_logistic(_t: u64, _t_max: u64): u64 { abort 0 }

fun exp_scaled(_y_num: u64, _y_den: u64, _neg: bool): u128 { abort 0 }

fun exp_scaled_pos(_y_num: u64, _y_den: u64): u128 { abort 0 }

fun exp_a_norm(_alpha_abs: u8, _alpha_neg: bool): u128 { abort 0 }

// Iterative Euclidean gcd. Move has no recursion.
fun gcd_u8(a: u8, b: u8): u8 {
    let mut x = a;
    let mut y = b;
    while (y != 0) {
        let t = y;
        y = x % y;
        x = t;
    };
    x
}

// === Test Functions ===

#[test_only]
public fun eval_linear_for_testing(t: u64, t_max: u64): u64 {
    eval_linear(t, t_max)
}

#[test_only]
public fun eval_smoothstep_for_testing(t: u64, t_max: u64): u64 {
    eval_smoothstep(t, t_max)
}

#[test_only]
public fun eval_power_law_for_testing(t: u64, t_max: u64, alpha_num: u8, alpha_den: u8): u64 {
    eval_power_law(t, t_max, alpha_num, alpha_den)
}

#[test_only]
public fun eval_exponential_for_testing(t: u64, t_max: u64, alpha_abs: u8, alpha_neg: bool): u64 {
    eval_exponential(t, t_max, alpha_abs, alpha_neg)
}

#[test_only]
public fun eval_logistic_for_testing(t: u64, t_max: u64): u64 {
    eval_logistic(t, t_max)
}

#[test_only]
public fun exp_scaled_for_testing(y_num: u64, y_den: u64, neg: bool): u128 {
    exp_scaled(y_num, y_den, neg)
}

#[test_only]
public fun exp_scaled_pos_for_testing(y_num: u64, y_den: u64): u128 {
    exp_scaled_pos(y_num, y_den)
}

#[test_only]
public fun exp_a_norm_for_testing(alpha_abs: u8, alpha_neg: bool): u128 {
    exp_a_norm(alpha_abs, alpha_neg)
}

#[test_only]
public fun taylor_scale_for_testing(): u128 { TAYLOR_SCALE }

#[test_only]
public fun taylor_scale_sq_for_testing(): u128 { TAYLOR_SCALE_SQ }

#[test_only]
public fun logistic_sigma_floor_for_testing(): u128 { LOGISTIC_SIGMA_FLOOR }

#[test_only]
public fun logistic_denom_for_testing(): u64 { LOGISTIC_DENOM }

#[test_only]
public fun scale_for_testing(): u64 { SCALE }

// Destructure helper for new_power_law tests — only way to verify gcd
// normalization without leaking enum field access publicly.
#[test_only]
public fun power_law_fields_for_testing(shape: &CurveShape): (u8, u8) {
    match (shape) {
        CurveShape::PowerLaw { alpha_num, alpha_den } => (*alpha_num, *alpha_den),
        _ => abort 0,
    }
}
