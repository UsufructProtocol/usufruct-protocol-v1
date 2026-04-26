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
