// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::curve_shape_state;

// === Imports ===

use usufruct::math;

// === Errors ===

const EAlphaNumRange:    u64 = 0;
const EAlphaDenRange:    u64 = 1;
const EDegenerateLinear: u64 = 2;
const EAlphaAbsRange:    u64 = 3;
#[test_only] const ENotPowerLaw:      u64 = 4;

// === Constants ===

const TAYLOR_SCALE:    u128 = 1_000_000_000_000_000_000;
const TAYLOR_SCALE_SQ: u128 = 1_000_000_000_000_000_000_000_000_000_000_000_000;

const SCALE:      u64  = 1_000_000_000;
const SCALE_U128: u128 = 1_000_000_000;
const SCALE_SQ:   u128 = 1_000_000_000_000_000_000;
const SCALE_CB:   u128 = 1_000_000_000_000_000_000_000_000_000;

const LOGISTIC_K: u64 = 12;
const LOGISTIC_DENOM: u64 = 995_054_753;
const LOGISTIC_SIGMA_FLOOR: u128 = (SCALE_U128 - (LOGISTIC_DENOM as u128)) / 2;

const EXP_A_NORM_1_POS: u128 =     1_718_281_828_459_045_226;
const EXP_A_NORM_2_POS: u128 =     6_389_056_098_930_650_216;
const EXP_A_NORM_3_POS: u128 =    19_085_536_923_187_667_729;
const EXP_A_NORM_4_POS: u128 =    53_598_150_033_144_239_050;
const EXP_A_NORM_5_POS: u128 =   147_413_159_102_576_587_697;
const EXP_A_NORM_6_POS: u128 =   402_428_793_492_728_453_424;
const EXP_A_NORM_7_POS: u128 = 1_095_633_158_427_339_529_377;
const EXP_A_NORM_8_POS: u128 = 2_979_957_986_946_523_322_343;
const EXP_A_NORM_1_NEG: u128 = 632_120_558_828_557_678;
const EXP_A_NORM_2_NEG: u128 = 864_664_716_763_387_308;
const EXP_A_NORM_3_NEG: u128 = 950_212_931_632_136_057;
const EXP_A_NORM_4_NEG: u128 = 981_684_361_111_265_820;
const EXP_A_NORM_5_NEG: u128 = 993_262_053_000_914_533;
const EXP_A_NORM_6_NEG: u128 = 997_521_247_823_333_601;
const EXP_A_NORM_7_NEG: u128 = 999_088_118_034_444_554;
const EXP_A_NORM_8_NEG: u128 = 999_664_537_372_086_775;

// === Structs ===

public struct CurveHeight has copy, drop { h: u64 }

public enum CurveShapeState has copy, drop, store {
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

public fun new_linear(): CurveShapeState { CurveShapeState::Linear }

public fun new_smoothstep(): CurveShapeState { CurveShapeState::Smoothstep }

public fun new_logistic(): CurveShapeState { CurveShapeState::Logistic }

public fun new_power_law(alpha_num: u8, alpha_den: u8): CurveShapeState {
    assert!(alpha_num >= 1 && alpha_num <= 8, EAlphaNumRange);
    assert!(alpha_den >= 1 && alpha_den <= 4, EAlphaDenRange);
    assert!(alpha_num != alpha_den,           EDegenerateLinear);
    let g = gcd_u8(alpha_num, alpha_den);
    CurveShapeState::PowerLaw {
        alpha_num: alpha_num / g,
        alpha_den: alpha_den / g,
    }
}

public fun new_exponential(alpha_abs: u8, alpha_neg: bool): CurveShapeState {
    assert!(alpha_abs >= 1 && alpha_abs <= 8, EAlphaAbsRange);
    CurveShapeState::Exponential { alpha_abs, alpha_neg }
}

// === View Functions ===

public(package) fun proj_is_linear(s: &CurveShapeState):     bool { match (s) { CurveShapeState::Linear      => true, _ => false } }
public(package) fun proj_is_smoothstep(s: &CurveShapeState): bool { match (s) { CurveShapeState::Smoothstep  => true, _ => false } }
public(package) fun proj_is_logistic(s: &CurveShapeState):   bool { match (s) { CurveShapeState::Logistic    => true, _ => false } }
public(package) fun proj_is_power_law(s: &CurveShapeState):  bool { match (s) { CurveShapeState::PowerLaw    { .. } => true, _ => false } }
public(package) fun proj_is_exponential(s: &CurveShapeState): bool { match (s) { CurveShapeState::Exponential { .. } => true, _ => false } }

public(package) fun proj_power_law_alpha_num(s: &CurveShapeState): Option<u8> {
    match (s) { CurveShapeState::PowerLaw { alpha_num, .. } => option::some(*alpha_num), _ => option::none() }
}
public(package) fun proj_power_law_alpha_den(s: &CurveShapeState): Option<u8> {
    match (s) { CurveShapeState::PowerLaw { alpha_den, .. } => option::some(*alpha_den), _ => option::none() }
}
public(package) fun proj_exponential_alpha_abs(s: &CurveShapeState): Option<u8> {
    match (s) { CurveShapeState::Exponential { alpha_abs, .. } => option::some(*alpha_abs), _ => option::none() }
}
public(package) fun proj_exponential_alpha_neg(s: &CurveShapeState): Option<bool> {
    match (s) { CurveShapeState::Exponential { alpha_neg, .. } => option::some(*alpha_neg), _ => option::none() }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun height_value(h: CurveHeight): u64 { h.h }

public(package) fun evaluate_curve(shape: &CurveShapeState, t: u64, t_max: u64): CurveHeight {
    let h = if (t == 0)     { 0 }
            else if (t >= t_max) { SCALE }
            else match (shape) {
                CurveShapeState::Linear                               => eval_linear(t, t_max),
                CurveShapeState::Smoothstep                           => eval_smoothstep(t, t_max),
                CurveShapeState::PowerLaw { alpha_num, alpha_den }    => eval_power_law(t, t_max, *alpha_num, *alpha_den),
                CurveShapeState::Exponential { alpha_abs, alpha_neg } => eval_exponential(t, t_max, *alpha_abs, *alpha_neg),
                CurveShapeState::Logistic                             => eval_logistic(t, t_max),
            };
    CurveHeight { h }
}

public(package) fun apply(amount: u64, height: CurveHeight): u64 {
    math::mul_div(amount, height.h, SCALE)
}

// === Private Functions ===

fun eval_linear(t: u64, t_max: u64): u64 {
    math::mul_div(t, SCALE, t_max)
}

fun eval_smoothstep(t: u64, t_max: u64): u64 {
    let x: u64     = math::mul_div(t, SCALE, t_max);
    let x128: u128 = x as u128;
    let num: u128  = x128 * x128 * (3 * SCALE_U128 - 2 * x128);
    (num / SCALE_SQ) as u64
}

fun eval_power_law(t: u64, t_max: u64, alpha_num: u8, alpha_den: u8): u64 {
    let x_scaled: u64 = math::mul_div(t, SCALE, t_max);
    let mut acc:  u64 = x_scaled;
    (alpha_num - 1).do!(|_| acc = math::mul_div(acc, x_scaled, SCALE));
    if (alpha_den == 1) {
        return acc
    };
    let scale_pow: u128 = match (alpha_den) {
        2 => SCALE_U128,
        3 => SCALE_SQ,
        _ => SCALE_CB,
    };
    let target: u128 = (acc as u128) * scale_pow;
    math::nth_root_u128(target, alpha_den as u32) as u64
}

fun eval_exponential(t: u64, t_max: u64, alpha_abs: u8, alpha_neg: bool): u64 {
    let a       = alpha_abs as u64;
    let exp_ax  = exp_scaled(a * t, t_max, alpha_neg);
    let num     = if (alpha_neg) {
        TAYLOR_SCALE - exp_ax
    } else {
        exp_ax - TAYLOR_SCALE
    };
    let den = exp_a_norm(alpha_abs, alpha_neg);
    (num * SCALE_U128 / den) as u64
}

fun eval_logistic(t: u64, t_max: u64): u64 {
    let two_t = 2 * t;
    let (y_num_abs, y_neg) = if (two_t >= t_max) {
        (LOGISTIC_K * (two_t - t_max), false)
    } else {
        (LOGISTIC_K * (t_max - two_t), true)
    };
    let y_den: u64 = 2 * t_max;

    let ey:      u128 = exp_scaled(y_num_abs, y_den, y_neg);
    let sigma_y: u128 = ey * SCALE_U128 / (ey + TAYLOR_SCALE);

    ((sigma_y - LOGISTIC_SIGMA_FLOOR) * SCALE_U128 / (LOGISTIC_DENOM as u128)) as u64
}

fun exp_scaled(y_num: u64, y_den: u64, neg: bool): u128 {
    let pos = exp_scaled_pos(y_num, y_den);
    if (neg) { TAYLOR_SCALE_SQ / pos } else { pos }
}

fun exp_scaled_pos(y_num: u64, y_den: u64): u128 {
    let y_num_128: u128 = y_num as u128;
    let y_den_128: u128 = y_den as u128;
    let mut acc:   u128 = TAYLOR_SCALE;
    let mut term:  u128 = TAYLOR_SCALE;
    let mut k:     u128 = 1;
    while (k <= 32) {
        term = term * y_num_128 / (k * y_den_128);
        if (term == 0) break;
        acc = acc + term;
        k = k + 1;
    };
    acc
}

fun exp_a_norm(alpha_abs: u8, alpha_neg: bool): u128 {
    match (alpha_neg) {
        false => match (alpha_abs) {
            1 => EXP_A_NORM_1_POS,
            2 => EXP_A_NORM_2_POS,
            3 => EXP_A_NORM_3_POS,
            4 => EXP_A_NORM_4_POS,
            5 => EXP_A_NORM_5_POS,
            6 => EXP_A_NORM_6_POS,
            7 => EXP_A_NORM_7_POS,
            _ => EXP_A_NORM_8_POS,
        },
        true => match (alpha_abs) {
            1 => EXP_A_NORM_1_NEG,
            2 => EXP_A_NORM_2_NEG,
            3 => EXP_A_NORM_3_NEG,
            4 => EXP_A_NORM_4_NEG,
            5 => EXP_A_NORM_5_NEG,
            6 => EXP_A_NORM_6_NEG,
            7 => EXP_A_NORM_7_NEG,
            _ => EXP_A_NORM_8_NEG,
        },
    }
}

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

#[test_only]
public fun power_law_fields_for_testing(shape: &CurveShapeState): (u8, u8) {
    match (shape) {
        CurveShapeState::PowerLaw { alpha_num, alpha_den } => (*alpha_num, *alpha_den),
        _ => abort ENotPowerLaw,
    }
}

