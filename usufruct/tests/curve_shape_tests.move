// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::curve_shape_tests;

use std::unit_test::assert_eq;
use usufruct::curve_shape;

// ─── Constructors — success ────────────────────────────────────────────────

#[test_only]
public struct PowerLawCase has drop {
    in_num: u8,
    in_den: u8,
    out_num: u8,
    out_den: u8,
}

#[test]
fun constructors_no_fields_succeed() {
    let _ = curve_shape::new_linear();
    let _ = curve_shape::new_smoothstep();
    let _ = curve_shape::new_logistic();
}

#[test]
fun new_power_law_reduces_via_gcd_and_stays_coprime() {
    let cases = vector[
        PowerLawCase { in_num: 2, in_den: 1, out_num: 2, out_den: 1 }, // already coprime
        PowerLawCase { in_num: 1, in_den: 2, out_num: 1, out_den: 2 }, // already coprime
        PowerLawCase { in_num: 6, in_den: 4, out_num: 3, out_den: 2 }, // gcd=2
        PowerLawCase { in_num: 6, in_den: 3, out_num: 2, out_den: 1 }, // gcd=3 → d=1
        PowerLawCase { in_num: 8, in_den: 4, out_num: 2, out_den: 1 }, // gcd=4, alpha_num=8 boundary
        PowerLawCase { in_num: 1, in_den: 3, out_num: 1, out_den: 3 }, // smallest d=3
        PowerLawCase { in_num: 1, in_den: 4, out_num: 1, out_den: 4 }, // smallest d=4, alpha_den=4 boundary
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let shape = curve_shape::new_power_law(case.in_num, case.in_den);
        let (n, d) = curve_shape::power_law_fields_for_testing(&shape);
        assert_eq!(n, case.out_num);
        assert_eq!(d, case.out_den);
        // Coprimality invariant: gcd(stored_num, stored_den) == 1
        assert!(gcd_u8(n, d) == 1, 0);
        i = i + 1;
    };
}

#[test]
fun new_exponential_lower_and_upper_bounds_succeed() {
    let _ = curve_shape::new_exponential(1, false); // lower bound, convex
    let _ = curve_shape::new_exponential(8, true);  // upper bound, concave
}

// ─── Constructors — abort ──────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = curve_shape::EAlphaNumRange, location = usufruct::curve_shape)]
fun new_power_law_alpha_num_zero_aborts() {
    let _ = curve_shape::new_power_law(0, 2);
}

#[test]
#[expected_failure(abort_code = curve_shape::EAlphaNumRange, location = usufruct::curve_shape)]
fun new_power_law_alpha_num_above_8_aborts() {
    let _ = curve_shape::new_power_law(9, 2);
}

#[test]
#[expected_failure(abort_code = curve_shape::EAlphaDenRange, location = usufruct::curve_shape)]
fun new_power_law_alpha_den_zero_aborts() {
    let _ = curve_shape::new_power_law(3, 0);
}

#[test]
#[expected_failure(abort_code = curve_shape::EAlphaDenRange, location = usufruct::curve_shape)]
fun new_power_law_alpha_den_above_4_aborts() {
    let _ = curve_shape::new_power_law(3, 5);
}

#[test]
#[expected_failure(abort_code = curve_shape::EDegenerateLinear, location = usufruct::curve_shape)]
fun new_power_law_degenerate_2_2_aborts() {
    let _ = curve_shape::new_power_law(2, 2);
}

#[test]
#[expected_failure(abort_code = curve_shape::EDegenerateLinear, location = usufruct::curve_shape)]
fun new_power_law_degenerate_4_4_aborts() {
    let _ = curve_shape::new_power_law(4, 4);
}

#[test]
#[expected_failure(abort_code = curve_shape::EAlphaAbsRange, location = usufruct::curve_shape)]
fun new_exponential_alpha_abs_zero_aborts() {
    let _ = curve_shape::new_exponential(0, false);
}

#[test]
#[expected_failure(abort_code = curve_shape::EAlphaAbsRange, location = usufruct::curve_shape)]
fun new_exponential_alpha_abs_above_8_aborts() {
    let _ = curve_shape::new_exponential(9, true);
}

// ─── eval_linear ───────────────────────────────────────────────────────────

#[test_only]
public struct LinearCase has drop {
    t: u64,
    t_max: u64,
    expected: u64,
}

#[test]
fun eval_linear_golden_vectors() {
    let cases = vector[
        LinearCase { t: 1, t_max: 4,             expected: 250_000_000 }, // floor SCALE/4
        LinearCase { t: 3, t_max: 4,             expected: 750_000_000 }, // floor 3·SCALE/4
        LinearCase { t: 1, t_max: 3,             expected: 333_333_333 }, // floor 1/3
        LinearCase { t: 2, t_max: 3,             expected: 666_666_666 }, // floor 2/3
        LinearCase { t: 1, t_max: 1_000_000_000, expected: 1           }, // minimum nonzero output
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        assert_eq!(curve_shape::eval_linear_for_testing(case.t, case.t_max), case.expected);
        i = i + 1;
    };
}

#[test]
fun eval_linear_midpoint_exact() {
    // g(0.5) = 0.5 exactly when t_max is even
    let scale = curve_shape::scale_for_testing();
    assert_eq!(curve_shape::eval_linear_for_testing(2, 4), scale / 2);
    assert_eq!(
        curve_shape::eval_linear_for_testing(500_000_000, 1_000_000_000),
        scale / 2,
    );
}

#[test]
fun eval_linear_monotone_in_t() {
    // For fixed t_max, t1 < t2 ⇒ result(t1) ≤ result(t2).
    let t_max: u64 = 1_000_000;
    let ts = vector[1u64, 2, 100, 12_345, 500_000, 999_999];
    let mut i = 1;
    let len = ts.length();
    while (i < len) {
        let lo = curve_shape::eval_linear_for_testing(ts[i - 1], t_max);
        let hi = curve_shape::eval_linear_for_testing(ts[i],     t_max);
        assert!(lo <= hi, 0);
        i = i + 1;
    };
}

// ─── eval_smoothstep ───────────────────────────────────────────────────────

#[test_only]
public struct SmoothstepCase has drop {
    t: u64,
    t_max: u64,
    expected: u64,
}

#[test]
fun eval_smoothstep_golden_vectors() {
    let cases = vector[
        SmoothstepCase { t: 1_000_000_000, t_max: 4_000_000_000, expected: 156_250_000 }, // g(0.25)=0.15625
        SmoothstepCase { t: 2_000_000_000, t_max: 4_000_000_000, expected: 500_000_000 }, // g(0.5)=0.5 exact
        SmoothstepCase { t: 3_000_000_000, t_max: 4_000_000_000, expected: 843_750_000 }, // g(0.75)=0.84375
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        assert_eq!(
            curve_shape::eval_smoothstep_for_testing(case.t, case.t_max),
            case.expected,
        );
        i = i + 1;
    };
}

#[test]
fun eval_smoothstep_midpoint_exact() {
    let scale = curve_shape::scale_for_testing();
    assert_eq!(curve_shape::eval_smoothstep_for_testing(2, 4), scale / 2);
    assert_eq!(
        curve_shape::eval_smoothstep_for_testing(500_000_000, 1_000_000_000),
        scale / 2,
    );
}

#[test]
fun eval_smoothstep_monotone_in_t() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[
        1u64,
        100_000_000,
        1_000_000_000,
        2_000_000_000,
        3_000_000_000,
        3_999_999_999,
    ];
    let mut i = 1;
    let len = ts.length();
    while (i < len) {
        let lo = curve_shape::eval_smoothstep_for_testing(ts[i - 1], t_max);
        let hi = curve_shape::eval_smoothstep_for_testing(ts[i],     t_max);
        assert!(lo <= hi, 0);
        i = i + 1;
    };
}

#[test]
fun eval_smoothstep_below_linear_first_half_above_second_half() {
    let t_max: u64 = 4_000_000_000;
    // first half: smoothstep < linear
    let lo_t: u64 = 1_000_000_000; // x=0.25
    assert!(
        curve_shape::eval_smoothstep_for_testing(lo_t, t_max)
            < curve_shape::eval_linear_for_testing(lo_t, t_max),
        0,
    );
    // second half: smoothstep > linear
    let hi_t: u64 = 3_000_000_000; // x=0.75
    assert!(
        curve_shape::eval_smoothstep_for_testing(hi_t, t_max)
            > curve_shape::eval_linear_for_testing(hi_t, t_max),
        0,
    );
}

#[test]
fun eval_smoothstep_approximate_symmetry() {
    // g(x) + g(1-x) ≈ 1 (within 1–2 ULP from floor rounding)
    let scale = curve_shape::scale_for_testing();
    let t_max: u64 = 4_000_000_000;
    let probes = vector[1u64, 500_000_000, 1_000_000_000, 1_700_000_000];
    let mut i = 0;
    let len = probes.length();
    while (i < len) {
        let t = probes[i];
        let a = curve_shape::eval_smoothstep_for_testing(t,         t_max);
        let b = curve_shape::eval_smoothstep_for_testing(t_max - t, t_max);
        let sum = a + b;
        assert!(sum + 2 >= scale && sum <= scale, 0);
        i = i + 1;
    };
}

// ─── eval_power_law ────────────────────────────────────────────────────────

#[test_only]
public struct PowerLawEvalCase has drop {
    t: u64,
    t_max: u64,
    n: u8,
    d: u8,
    expected: u64,
}

// d=1 path: integer exponent, no nth_root step. All values hand-derivable.
#[test]
fun eval_power_law_d1_golden_vectors() {
    let cases = vector[
        // 0.5^2 = 0.25
        PowerLawEvalCase { t: 1_000_000_000, t_max: 2_000_000_000, n: 2, d: 1, expected:   250_000_000 },
        // 0.5^3 = 0.125
        PowerLawEvalCase { t: 1_000_000_000, t_max: 2_000_000_000, n: 3, d: 1, expected:   125_000_000 },
        // 0.5^2 = 0.25, small-t scaling
        PowerLawEvalCase { t: 2,             t_max: 4,             n: 2, d: 1, expected:   250_000_000 },
        // 0.75^2 = 0.5625
        PowerLawEvalCase { t: 3,             t_max: 4,             n: 2, d: 1, expected:   562_500_000 },
        // 1^8 = 1
        PowerLawEvalCase { t: 4_000_000_000, t_max: 4_000_000_000, n: 8, d: 1, expected: 1_000_000_000 },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        assert_eq!(
            curve_shape::eval_power_law_for_testing(case.t, case.t_max, case.n, case.d),
            case.expected,
        );
        i = i + 1;
    };
}

// Monotonicity in t for both d=1 and d>1 paths.
#[test]
fun eval_power_law_monotone_in_t() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[
        1u64,
        100_000_000,
        1_000_000_000,
        2_500_000_000,
        3_999_999_999,
    ];
    let ns = vector[2u8, 3, 8, 1, 3, 1, 1];
    let ds = vector[1u8, 1, 1, 2, 2, 3, 4];
    let mut p = 0;
    let plen = ns.length();
    while (p < plen) {
        let n = ns[p];
        let d = ds[p];
        let mut i = 1;
        let tlen = ts.length();
        while (i < tlen) {
            let lo = curve_shape::eval_power_law_for_testing(ts[i - 1], t_max, n, d);
            let hi = curve_shape::eval_power_law_for_testing(ts[i],     t_max, n, d);
            assert!(lo <= hi, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

#[test]
fun eval_power_law_range() {
    let scale = curve_shape::scale_for_testing();
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1u64, 1_000_000_000, 2_000_000_000, 3_000_000_000, 3_999_999_999];
    let ns = vector[2u8, 3, 8, 3, 1, 1, 1, 3];
    let ds = vector[1u8, 1, 1, 2, 2, 3, 4, 4];
    let mut p = 0;
    let plen = ns.length();
    while (p < plen) {
        let n = ns[p];
        let d = ds[p];
        let mut i = 0;
        let tlen = ts.length();
        while (i < tlen) {
            let r = curve_shape::eval_power_law_for_testing(ts[i], t_max, n, d);
            assert!(r <= scale, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// alpha > 1 (n > d) ⇒ purely convex ⇒ result < linear for t ∈ (0, t_max).
#[test]
fun eval_power_law_below_linear_when_convex() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let ns = vector[2u8, 3, 3, 5];
    let ds = vector[1u8, 1, 2, 4];
    let mut p = 0;
    let plen = ns.length();
    while (p < plen) {
        let n = ns[p];
        let d = ds[p];
        let mut i = 0;
        let tlen = ts.length();
        while (i < tlen) {
            let r   = curve_shape::eval_power_law_for_testing(ts[i], t_max, n, d);
            let lin = curve_shape::eval_linear_for_testing(ts[i], t_max);
            assert!(r < lin, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// alpha < 1 (n < d) ⇒ purely concave ⇒ result > linear for t ∈ (0, t_max).
#[test]
fun eval_power_law_above_linear_when_concave() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let ns = vector[1u8, 1, 1, 3];
    let ds = vector[2u8, 3, 4, 4];
    let mut p = 0;
    let plen = ns.length();
    while (p < plen) {
        let n = ns[p];
        let d = ds[p];
        let mut i = 0;
        let tlen = ts.length();
        while (i < tlen) {
            let r   = curve_shape::eval_power_law_for_testing(ts[i], t_max, n, d);
            let lin = curve_shape::eval_linear_for_testing(ts[i], t_max);
            assert!(r > lin, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// ─── Helpers ───────────────────────────────────────────────────────────────

// Iterative Euclidean gcd (Move has no recursion).
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
