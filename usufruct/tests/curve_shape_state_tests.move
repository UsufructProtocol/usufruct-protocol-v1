// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::curve_shape_state_tests;

use std::unit_test::assert_eq;
use usufruct::curve_shape_state;

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
    let _ = curve_shape_state::new_linear();
    let _ = curve_shape_state::new_smoothstep();
    let _ = curve_shape_state::new_logistic();
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
        let shape = curve_shape_state::new_power_law(case.in_num, case.in_den);
        let (n, d) = curve_shape_state::power_law_fields_for_testing(&shape);
        assert_eq!(n, case.out_num);
        assert_eq!(d, case.out_den);
        // Coprimality invariant: gcd(stored_num, stored_den) == 1
        assert!(gcd_u8(n, d) == 1, 0);
        i = i + 1;
    };
}

#[test]
fun new_exponential_lower_and_upper_bounds_succeed() {
    let _ = curve_shape_state::new_exponential(1, false); // lower bound, convex
    let _ = curve_shape_state::new_exponential(8, true);  // upper bound, concave
}

// ─── Constructors — abort ──────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = curve_shape_state::EAlphaNumRange, location = usufruct::curve_shape_state)]
fun new_power_law_alpha_num_zero_aborts() {
    let _ = curve_shape_state::new_power_law(0, 2);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EAlphaNumRange, location = usufruct::curve_shape_state)]
fun new_power_law_alpha_num_above_8_aborts() {
    let _ = curve_shape_state::new_power_law(9, 2);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EAlphaDenRange, location = usufruct::curve_shape_state)]
fun new_power_law_alpha_den_zero_aborts() {
    let _ = curve_shape_state::new_power_law(3, 0);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EAlphaDenRange, location = usufruct::curve_shape_state)]
fun new_power_law_alpha_den_above_4_aborts() {
    let _ = curve_shape_state::new_power_law(3, 5);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EDegenerateLinear, location = usufruct::curve_shape_state)]
fun new_power_law_degenerate_2_2_aborts() {
    let _ = curve_shape_state::new_power_law(2, 2);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EDegenerateLinear, location = usufruct::curve_shape_state)]
fun new_power_law_degenerate_4_4_aborts() {
    let _ = curve_shape_state::new_power_law(4, 4);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EAlphaAbsRange, location = usufruct::curve_shape_state)]
fun new_exponential_alpha_abs_zero_aborts() {
    let _ = curve_shape_state::new_exponential(0, false);
}

#[test]
#[expected_failure(abort_code = curve_shape_state::EAlphaAbsRange, location = usufruct::curve_shape_state)]
fun new_exponential_alpha_abs_above_8_aborts() {
    let _ = curve_shape_state::new_exponential(9, true);
}

// ─── evaluate_curve dispatcher ─────────────────────────────────────────────
//
// §11.1 edge rows × variant seeds, plus the P-D1 dispatch-equivalence
// property. The edge rows fire BEFORE any eval_* call (short-circuits on
// t == 0 and t >= t_max), so the result is identical across all variants.

#[test_only]
public struct DispatcherEdgeCase has drop {
    t: u64,
    t_max: u64,
    expected: u64,
}

#[test]
fun evaluate_curve_edge_cases_apply_to_every_variant() {
    let scale = curve_shape_state::scale_for_testing();
    let cases = vector[
        DispatcherEdgeCase { t: 0,                          t_max: 1_000_000_000, expected: 0     }, // t == 0 short-circuit
        DispatcherEdgeCase { t: 0,                          t_max: 1,             expected: 0     }, // t_max = 1 boundary
        DispatcherEdgeCase { t: 1,                          t_max: 1,             expected: scale }, // t == t_max at smallest denominator
        DispatcherEdgeCase { t: 1_000_000_000,              t_max: 1_000_000_000, expected: scale }, // t == t_max stand-in
        DispatcherEdgeCase { t: 1_000_000_001,              t_max: 1_000_000_000, expected: scale }, // t_max + 1 — clamped
        DispatcherEdgeCase { t: 18_446_744_073_709_551_615, t_max: 1_000_000_000, expected: scale }, // saturated u64::MAX
    ];
    let seeds: vector<curve_shape_state::CurveShapeState> = vector[
        curve_shape_state::new_linear(),
        curve_shape_state::new_smoothstep(),
        curve_shape_state::new_logistic(),
        curve_shape_state::new_power_law(2, 1),
        curve_shape_state::new_exponential(2, false),
    ];
    let mut s = 0;
    let slen = seeds.length();
    while (s < slen) {
        let shape = &seeds[s];
        let mut i = 0;
        let len = cases.length();
        while (i < len) {
            let case = &cases[i];
            assert_eq!(
                curve_shape_state::height_value(curve_shape_state::evaluate_curve(shape, case.t, case.t_max)),
                case.expected,
            );
            i = i + 1;
        };
        s = s + 1;
    };
}

// P-D1 dispatch equivalence: for every variant seed and every interior
// (t, t_max), evaluate_curve must route to the matching eval_* function and
// forward fields verbatim. Catches dispatcher drift (wrong arm, swapped
// fields) that no single-variant test row would surface.

#[test_only]
public struct InteriorPair has drop {
    t: u64,
    t_max: u64,
}

#[test_only]
fun pd1_interior_pairs(): vector<InteriorPair> {
    vector[
        InteriorPair { t: 1,             t_max: 4             },
        InteriorPair { t: 1,             t_max: 3             },
        InteriorPair { t: 3,             t_max: 4             },
        InteriorPair { t: 1_000_000_000, t_max: 4_000_000_000 },
    ]
}

#[test]
fun evaluate_curve_dispatch_equivalence_linear() {
    let shape = curve_shape_state::new_linear();
    let pairs = pd1_interior_pairs();
    let mut i = 0;
    let len = pairs.length();
    while (i < len) {
        let p = &pairs[i];
        assert_eq!(
            curve_shape_state::height_value(curve_shape_state::evaluate_curve(&shape, p.t, p.t_max)),
            curve_shape_state::eval_linear_for_testing(p.t, p.t_max),
        );
        i = i + 1;
    };
}

#[test]
fun evaluate_curve_dispatch_equivalence_smoothstep() {
    let shape = curve_shape_state::new_smoothstep();
    let pairs = pd1_interior_pairs();
    let mut i = 0;
    let len = pairs.length();
    while (i < len) {
        let p = &pairs[i];
        assert_eq!(
            curve_shape_state::height_value(curve_shape_state::evaluate_curve(&shape, p.t, p.t_max)),
            curve_shape_state::eval_smoothstep_for_testing(p.t, p.t_max),
        );
        i = i + 1;
    };
}

#[test]
fun evaluate_curve_dispatch_equivalence_logistic() {
    let shape = curve_shape_state::new_logistic();
    let pairs = pd1_interior_pairs();
    let mut i = 0;
    let len = pairs.length();
    while (i < len) {
        let p = &pairs[i];
        assert_eq!(
            curve_shape_state::height_value(curve_shape_state::evaluate_curve(&shape, p.t, p.t_max)),
            curve_shape_state::eval_logistic_for_testing(p.t, p.t_max),
        );
        i = i + 1;
    };
}

#[test]
fun evaluate_curve_dispatch_equivalence_power_law() {
    let shape = curve_shape_state::new_power_law(2, 1);
    let pairs = pd1_interior_pairs();
    let mut i = 0;
    let len = pairs.length();
    while (i < len) {
        let p = &pairs[i];
        assert_eq!(
            curve_shape_state::height_value(curve_shape_state::evaluate_curve(&shape, p.t, p.t_max)),
            curve_shape_state::eval_power_law_for_testing(p.t, p.t_max, 2, 1),
        );
        i = i + 1;
    };
}

#[test]
fun evaluate_curve_dispatch_equivalence_exponential() {
    let shape = curve_shape_state::new_exponential(2, false);
    let pairs = pd1_interior_pairs();
    let mut i = 0;
    let len = pairs.length();
    while (i < len) {
        let p = &pairs[i];
        assert_eq!(
            curve_shape_state::height_value(curve_shape_state::evaluate_curve(&shape, p.t, p.t_max)),
            curve_shape_state::eval_exponential_for_testing(p.t, p.t_max, 2, false),
        );
        i = i + 1;
    };
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
        assert_eq!(curve_shape_state::eval_linear_for_testing(case.t, case.t_max), case.expected);
        i = i + 1;
    };
}

#[test]
fun eval_linear_midpoint_exact() {
    // g(0.5) = 0.5 exactly when t_max is even
    let scale = curve_shape_state::scale_for_testing();
    assert_eq!(curve_shape_state::eval_linear_for_testing(2, 4), scale / 2);
    assert_eq!(
        curve_shape_state::eval_linear_for_testing(500_000_000, 1_000_000_000),
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
        let lo = curve_shape_state::eval_linear_for_testing(ts[i - 1], t_max);
        let hi = curve_shape_state::eval_linear_for_testing(ts[i],     t_max);
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
            curve_shape_state::eval_smoothstep_for_testing(case.t, case.t_max),
            case.expected,
        );
        i = i + 1;
    };
}

#[test]
fun eval_smoothstep_midpoint_exact() {
    let scale = curve_shape_state::scale_for_testing();
    assert_eq!(curve_shape_state::eval_smoothstep_for_testing(2, 4), scale / 2);
    assert_eq!(
        curve_shape_state::eval_smoothstep_for_testing(500_000_000, 1_000_000_000),
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
        let lo = curve_shape_state::eval_smoothstep_for_testing(ts[i - 1], t_max);
        let hi = curve_shape_state::eval_smoothstep_for_testing(ts[i],     t_max);
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
        curve_shape_state::eval_smoothstep_for_testing(lo_t, t_max)
            < curve_shape_state::eval_linear_for_testing(lo_t, t_max),
        0,
    );
    // second half: smoothstep > linear
    let hi_t: u64 = 3_000_000_000; // x=0.75
    assert!(
        curve_shape_state::eval_smoothstep_for_testing(hi_t, t_max)
            > curve_shape_state::eval_linear_for_testing(hi_t, t_max),
        0,
    );
}

#[test]
fun eval_smoothstep_approximate_symmetry() {
    // g(x) + g(1-x) ≈ 1 (within 1–2 ULP from floor rounding)
    let scale = curve_shape_state::scale_for_testing();
    let t_max: u64 = 4_000_000_000;
    let probes = vector[1u64, 500_000_000, 1_000_000_000, 1_700_000_000];
    let mut i = 0;
    let len = probes.length();
    while (i < len) {
        let t = probes[i];
        let a = curve_shape_state::eval_smoothstep_for_testing(t,         t_max);
        let b = curve_shape_state::eval_smoothstep_for_testing(t_max - t, t_max);
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
            curve_shape_state::eval_power_law_for_testing(case.t, case.t_max, case.n, case.d),
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
            let lo = curve_shape_state::eval_power_law_for_testing(ts[i - 1], t_max, n, d);
            let hi = curve_shape_state::eval_power_law_for_testing(ts[i],     t_max, n, d);
            assert!(lo <= hi, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

#[test]
fun eval_power_law_range() {
    let scale = curve_shape_state::scale_for_testing();
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
            let r = curve_shape_state::eval_power_law_for_testing(ts[i], t_max, n, d);
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
            let r   = curve_shape_state::eval_power_law_for_testing(ts[i], t_max, n, d);
            let lin = curve_shape_state::eval_linear_for_testing(ts[i], t_max);
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
            let r   = curve_shape_state::eval_power_law_for_testing(ts[i], t_max, n, d);
            let lin = curve_shape_state::eval_linear_for_testing(ts[i], t_max);
            assert!(r > lin, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// Algorithm-derived golden vectors for eval_power_law root-step (§11.4).
//
// Pinning procedure (one-shot at initial implementation; this test guards
// the values from then on):
//
//   1. Replace each `expected_*` literal with `0`.
//   2. Replace `assert_eq!(actual, expected)` with `std::debug::print(&actual)`.
//   3. `sui move test eval_power_law_root_golden_vectors` — captures the 5 outputs.
//   4. Paste the printed literals into spec §11.4 and back into this test.
//   5. Restore `assert_eq!`. Suite turns green.
//
// Four of the five inputs land on perfect d-th powers (1/4, 1/8, 1/16) so
// `nth_root_u128` returns an exact integer; the (3, 4, 1, 2) row exercises
// floor rounding on the irrational √0.75.
#[test]
fun eval_power_law_root_golden_vectors() {
    // α = 1/2 concave: √0.25 · SCALE = 5·10⁸ exactly (perfect square)
    assert_eq!(curve_shape_state::eval_power_law_for_testing(1, 4,  1, 2), 500_000_000);
    // α = 3/2 convex: 0.25^1.5 · SCALE = 1.25·10⁸ exactly
    assert_eq!(curve_shape_state::eval_power_law_for_testing(1, 4,  3, 2), 125_000_000);
    // α = 1/3 concave: ∛(1/8) · SCALE = 5·10⁸ exactly (perfect cube)
    assert_eq!(curve_shape_state::eval_power_law_for_testing(1, 8,  1, 3), 500_000_000);
    // α = 1/4 concave: (1/16)^(1/4) · SCALE = 5·10⁸ exactly (perfect 4th power; SCALE_CB branch)
    assert_eq!(curve_shape_state::eval_power_law_for_testing(1, 16, 1, 4), 500_000_000);
    // α = 1/2 at t = 0.75·t_max: floor(√0.75 · SCALE); √0.75 ≈ 0.866025403784...
    assert_eq!(curve_shape_state::eval_power_law_for_testing(3, 4,  1, 2), 866_025_403);
    // α = 1/2 at midpoint t = t_max/2: floor(√0.5 · SCALE); √0.5 ≈ 0.707106781...
    // Reflection-on-diagonal pair with the convex midpoint
    // (1_000_000_000, 2_000_000_000, 2, 1) → 250_000_000. See spec §11.4
    // "Reflection on the diagonal" property: PowerLaw(α) and PowerLaw(1/α)
    // are graph-reflections on y = x but NOT complementary
    // (0.25 + 0.707 ≈ 0.957 ≠ 1) — distinct from Exp's complementarity.
    assert_eq!(curve_shape_state::eval_power_law_for_testing(2_000_000_000, 4_000_000_000, 1, 2), 707_106_781);
}

// ─── exp_scaled / exp_scaled_pos ───────────────────────────────────────────
//
// Algorithm-derived golden vectors (§11.5) are pinned in a separate
// post-bootstrap commit. The tests here cover the y=0 exact case and the
// algorithm-independent properties (monotonicity, reciprocal identity, y=8
// boundary).

#[test]
fun exp_scaled_y_zero_returns_taylor_scale_regardless_of_neg() {
    let ts = curve_shape_state::taylor_scale_for_testing();
    assert_eq!(curve_shape_state::exp_scaled_for_testing(0, 1, false), ts);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(0, 1, true),  ts);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(0, 7, false), ts);
    assert_eq!(curve_shape_state::exp_scaled_pos_for_testing(0, 1),    ts);
    assert_eq!(curve_shape_state::exp_scaled_pos_for_testing(0, 7),    ts);
}

// Seed S sorted by y_num/y_den ascending: (1,2)=0.5, (1,1)=1, (2,1)=2,
// (3,1)=3, (7,2)=3.5, (4,1)=4, (6,1)=6, (15,2)=7.5, (8,1)=8. Adjacent
// pairs must be strictly increasing under exp_scaled_pos.
#[test]
fun exp_scaled_pos_strictly_monotone_over_seed_set() {
    let nums = vector[1u64, 1, 2, 3, 7, 4, 6, 15, 8];
    let dens = vector[2u64, 1, 1, 1, 2, 1, 1,  2, 1];
    let mut i = 1;
    let len = nums.length();
    while (i < len) {
        let lo = curve_shape_state::exp_scaled_pos_for_testing(nums[i - 1], dens[i - 1]);
        let hi = curve_shape_state::exp_scaled_pos_for_testing(nums[i],     dens[i]);
        assert!(lo < hi, 0);
        i = i + 1;
    };
}

// Reciprocal identity: e^y · e^(−y) = 1, integer-encoded.
//
// neg = floor(TS² / pos), so pos·neg ∈ (TS² − pos, TS²]. The slack is `pos`
// (one ULP at the neg level, multiplied by pos to project back into the
// product's TS² scale). For y ∈ S the upper bound is e^8 · TS ≈ 3·10²¹.
#[test]
fun exp_scaled_reciprocal_identity_within_one_ulp() {
    let ts_sq = curve_shape_state::taylor_scale_sq_for_testing();
    let nums = vector[1u64, 1, 2, 3, 4, 6, 8, 7, 15];
    let dens = vector[2u64, 1, 1, 1, 1, 1, 1, 2,  2];
    let mut i = 0;
    let len = nums.length();
    while (i < len) {
        let pos  = curve_shape_state::exp_scaled_for_testing(nums[i], dens[i], false);
        let neg  = curve_shape_state::exp_scaled_for_testing(nums[i], dens[i], true);
        let prod = pos * neg;
        assert!(prod <= ts_sq, 0);
        assert!(prod + pos >= ts_sq, 0);
        i = i + 1;
    };
}

// §7 overflow analysis upper bound. The value being computable at all
// (no u128 overflow abort) confirms `acc ≤ e^8 · TS` fits u128.
#[test]
fun exp_scaled_pos_y_eq_8_positive_and_within_overflow_budget() {
    let v = curve_shape_state::exp_scaled_pos_for_testing(8, 1);
    assert!(v > 0, 0);
}

// ─── eval_exponential ──────────────────────────────────────────────────────
//
// Algorithm-derived golden vectors (§11.6) are pinned in a separate
// post-bootstrap commit. The tests here cover (i) the exp_a_norm dispatcher
// wiring required by §11.6, and (ii) the algorithm-independent properties
// (range, monotonicity, below/above linear, complementarity).

// Dispatcher wiring: every (alpha_abs, alpha_neg) maps to its EXP_A_NORM_*
// constant. Already covered transitively by bootstrap_constants_match_pinned;
// pinned here as the explicit §11.6 dispatcher property.
#[test]
fun exp_a_norm_dispatcher_per_pair() {
    let pos_norms: vector<u128> = vector[
            1_718_281_828_459_045_226,
            6_389_056_098_930_650_216,
           19_085_536_923_187_667_729,
           53_598_150_033_144_239_050,
          147_413_159_102_576_587_697,
          402_428_793_492_728_453_424,
        1_095_633_158_427_339_529_377,
        2_979_957_986_946_523_322_343,
    ];
    let neg_norms: vector<u128> = vector[
        632_120_558_828_557_678,
        864_664_716_763_387_308,
        950_212_931_632_136_057,
        981_684_361_111_265_820,
        993_262_053_000_914_533,
        997_521_247_823_333_601,
        999_088_118_034_444_554,
        999_664_537_372_086_775,
    ];
    let mut a: u8 = 1;
    while (a <= 8) {
        assert_eq!(
            curve_shape_state::exp_a_norm_for_testing(a, false),
            pos_norms[(a - 1) as u64],
        );
        assert_eq!(
            curve_shape_state::exp_a_norm_for_testing(a, true),
            neg_norms[(a - 1) as u64],
        );
        a = a + 1;
    };
}

// e^a − 1 strictly increasing for a > 0 ⇒ EXP_A_NORM_a_POS strictly
// increasing in a. Catches copy-paste swaps at pinning time.
#[test]
fun exp_a_norm_pos_strictly_monotone_in_alpha() {
    let mut a: u8 = 1;
    while (a < 8) {
        let lo = curve_shape_state::exp_a_norm_for_testing(a,     false);
        let hi = curve_shape_state::exp_a_norm_for_testing(a + 1, false);
        assert!(lo < hi, 0);
        a = a + 1;
    };
}

// 1 − e^{−a} strictly increasing for a > 0.
#[test]
fun exp_a_norm_neg_strictly_monotone_in_alpha() {
    let mut a: u8 = 1;
    while (a < 8) {
        let lo = curve_shape_state::exp_a_norm_for_testing(a,     true);
        let hi = curve_shape_state::exp_a_norm_for_testing(a + 1, true);
        assert!(lo < hi, 0);
        a = a + 1;
    };
}

#[test]
fun eval_exponential_range() {
    let scale = curve_shape_state::scale_for_testing();
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1u64, 1_000_000_000, 2_000_000_000, 3_000_000_000, 3_999_999_999];
    let alphas: vector<u8> = vector[1, 2, 4, 8];
    let mut p = 0;
    let plen = alphas.length();
    while (p < plen) {
        let a = alphas[p];
        let mut i = 0;
        let tlen = ts.length();
        while (i < tlen) {
            let r_pos = curve_shape_state::eval_exponential_for_testing(ts[i], t_max, a, false);
            let r_neg = curve_shape_state::eval_exponential_for_testing(ts[i], t_max, a, true);
            assert!(r_pos <= scale, 0);
            assert!(r_neg <= scale, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

#[test]
fun eval_exponential_monotone_in_t() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1u64, 100_000_000, 1_000_000_000, 2_500_000_000, 3_999_999_999];
    let alphas: vector<u8> = vector[1, 2, 4, 8];
    let mut p = 0;
    let plen = alphas.length();
    while (p < plen) {
        let a = alphas[p];
        let mut i = 1;
        let tlen = ts.length();
        while (i < tlen) {
            let lo_pos = curve_shape_state::eval_exponential_for_testing(ts[i - 1], t_max, a, false);
            let hi_pos = curve_shape_state::eval_exponential_for_testing(ts[i],     t_max, a, false);
            assert!(lo_pos <= hi_pos, 0);
            let lo_neg = curve_shape_state::eval_exponential_for_testing(ts[i - 1], t_max, a, true);
            let hi_neg = curve_shape_state::eval_exponential_for_testing(ts[i],     t_max, a, true);
            assert!(lo_neg <= hi_neg, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// alpha_neg = false ⇒ convex ⇒ result < linear for t ∈ (0, t_max).
#[test]
fun eval_exponential_below_linear_when_convex() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let alphas: vector<u8> = vector[1, 2, 4, 8];
    let mut p = 0;
    let plen = alphas.length();
    while (p < plen) {
        let a = alphas[p];
        let mut i = 0;
        let tlen = ts.length();
        while (i < tlen) {
            let r   = curve_shape_state::eval_exponential_for_testing(ts[i], t_max, a, false);
            let lin = curve_shape_state::eval_linear_for_testing(ts[i], t_max);
            assert!(r < lin, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// alpha_neg = true ⇒ concave ⇒ result > linear for t ∈ (0, t_max).
#[test]
fun eval_exponential_above_linear_when_concave() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let alphas: vector<u8> = vector[1, 2, 4, 8];
    let mut p = 0;
    let plen = alphas.length();
    while (p < plen) {
        let a = alphas[p];
        let mut i = 0;
        let tlen = ts.length();
        while (i < tlen) {
            let r   = curve_shape_state::eval_exponential_for_testing(ts[i], t_max, a, true);
            let lin = curve_shape_state::eval_linear_for_testing(ts[i], t_max);
            assert!(r > lin, 0);
            i = i + 1;
        };
        p = p + 1;
    };
}

// f_α(x) + f_{−α}(1−x) = 1 mathematically (§8). Integer arithmetic introduces
// a small drift; spec §11.6 seed set C asserts ≤ 4 ULP either way.
// Seeds (t, t_max, alpha_abs): (1,4,2), (2,4,2), (3,4,2), (1,4,8), (3,8,4).
#[test]
fun eval_exponential_complementarity_within_4_ulp() {
    let scale = curve_shape_state::scale_for_testing();
    let ts:     vector<u64> = vector[1, 2, 3, 1, 3];
    let tmaxs:  vector<u64> = vector[4, 4, 4, 4, 8];
    let alphas: vector<u8>  = vector[2, 2, 2, 8, 4];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t     = ts[i];
        let t_max = tmaxs[i];
        let a     = alphas[i];
        let lhs = curve_shape_state::eval_exponential_for_testing(t,         t_max, a, false);
        let rhs = curve_shape_state::eval_exponential_for_testing(t_max - t, t_max, a, true);
        let sum = lhs + rhs;
        assert!(sum + 4 >= scale, 0);
        assert!(sum <= scale + 4, 0);
        i = i + 1;
    };
}

// Algorithm-derived golden vectors for eval_exponential (§11.6).
//
// Pinning procedure (one-shot at initial implementation; this test guards
// the values from then on):
//
//   1. Replace each `expected_*` literal with `0`.
//   2. Replace `assert_eq!(actual, expected)` with `std::debug::print(&actual)`.
//   3. `sui move test eval_exponential_golden_vectors` — captures the 8 outputs.
//   4. Paste the printed literals into spec §11.6 and back into this test.
//   5. Restore `assert_eq!`. Suite turns green; future §7 / §8 changes that
//      perturb outputs surface here.
#[test]
fun eval_exponential_golden_vectors() {
    // (t, t_max, alpha_abs, alpha_neg)
    assert_eq!(curve_shape_state::eval_exponential_for_testing(1, 4, 2, false), 101_536_324);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(1, 4, 2, true ), 455_054_233);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(1, 4, 4, false),  32_058_603);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(1, 4, 8, false),   2_144_008);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(1, 4, 8, true ), 864_954_876);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(1, 4, 1, true ), 349_932_008);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(2, 4, 2, false), 268_941_421);
    assert_eq!(curve_shape_state::eval_exponential_for_testing(2, 4, 2, true ), 731_058_578);
}

// ─── eval_logistic ─────────────────────────────────────────────────────────
//
// Algorithm-derived golden vectors (§11.7) are pinned in a separate
// post-bootstrap commit. The tests here cover the exact midpoint, the
// algorithm-independent properties, and the two cross-constant checks on
// LOGISTIC_DENOM / LOGISTIC_SIGMA_FLOOR.

// At x=0.5 the numerator equals half the denominator by symmetry of σ
// around y=0 — exact regardless of K, even with the +1 ULP from the floor
// in SIGMA_FLOOR's compile-time formula.
#[test]
fun eval_logistic_midpoint_exact_scale_half() {
    let scale = curve_shape_state::scale_for_testing();
    assert_eq!(curve_shape_state::eval_logistic_for_testing(2_000_000_000, 4_000_000_000), scale / 2);
    assert_eq!(curve_shape_state::eval_logistic_for_testing(500, 1_000),                   scale / 2);
    assert_eq!(curve_shape_state::eval_logistic_for_testing(2, 4),                         scale / 2);
}

#[test]
fun eval_logistic_range() {
    let scale = curve_shape_state::scale_for_testing();
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1u64, 1_000_000_000, 2_000_000_000, 3_000_000_000, 3_999_999_999];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let r = curve_shape_state::eval_logistic_for_testing(ts[i], t_max);
        assert!(r <= scale, 0);
        i = i + 1;
    };
}

#[test]
fun eval_logistic_monotone_in_t() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1u64, 100_000_000, 1_000_000_000, 2_500_000_000, 3_999_999_999];
    let mut i = 1;
    let len = ts.length();
    while (i < len) {
        let lo = curve_shape_state::eval_logistic_for_testing(ts[i - 1], t_max);
        let hi = curve_shape_state::eval_logistic_for_testing(ts[i],     t_max);
        assert!(lo <= hi, 0);
        i = i + 1;
    };
}

#[test]
fun eval_logistic_below_linear_first_half_above_second_half() {
    let t_max: u64 = 4_000_000_000;
    // first half: logistic < linear
    let lo_t: u64 = 1_000_000_000;
    assert!(
        curve_shape_state::eval_logistic_for_testing(lo_t, t_max)
            < curve_shape_state::eval_linear_for_testing(lo_t, t_max),
        0,
    );
    // second half: logistic > linear
    let hi_t: u64 = 3_000_000_000;
    assert!(
        curve_shape_state::eval_logistic_for_testing(hi_t, t_max)
            > curve_shape_state::eval_linear_for_testing(hi_t, t_max),
        0,
    );
}

// Approximate symmetry: g(x) + g(1-x) ≈ 1 within 2 ULP (§11.7 seed S_L).
#[test]
fun eval_logistic_approximate_symmetry_within_2_ulp() {
    let scale = curve_shape_state::scale_for_testing();
    let ts:    vector<u64> = vector[1, 1, 3, 1_000_000_000];
    let tmaxs: vector<u64> = vector[4, 8, 8, 4_000_000_000];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t     = ts[i];
        let t_max = tmaxs[i];
        let a = curve_shape_state::eval_logistic_for_testing(t,         t_max);
        let b = curve_shape_state::eval_logistic_for_testing(t_max - t, t_max);
        let sum = a + b;
        assert!(sum + 2 >= scale, 0);
        assert!(sum <= scale + 2, 0);
        i = i + 1;
    };
}

// Cross-constant check: SIGMA_FLOOR = floor((SCALE − DENOM) / 2) means
// 2·SIGMA_FLOOR + DENOM ∈ {SCALE − 1, SCALE} depending on the parity of
// (SCALE − DENOM). With pinned DENOM = 995_054_753, SCALE − DENOM = 4_945_247
// is odd, so the value is SCALE − 1.
//
// (Spec §11.7 states a tighter "== SCALE" identity; that holds only when the
// difference is even. The relaxed bound below is the correct invariant; spec
// follows in a separate commit.)
#[test]
fun eval_logistic_sigma_floor_denom_algebraic_identity() {
    let scale = curve_shape_state::scale_for_testing() as u128;
    let denom = curve_shape_state::logistic_denom_for_testing() as u128;
    let sf    = curve_shape_state::logistic_sigma_floor_for_testing();
    let sum   = 2 * sf + denom;
    assert!(sum + 1 >= scale, 0);
    assert!(sum <= scale, 0);
}

// Reference sanity: pinned LOGISTIC_DENOM should be within 100 ULP of the
// mathematical reference (σ(6) − σ(−6)) · SCALE ≈ 995_054_750.
#[test]
fun eval_logistic_denom_reference_within_100_ulp() {
    let denom: u64 = curve_shape_state::logistic_denom_for_testing();
    let ref_val: u64 = 995_054_750;
    let diff = if (denom >= ref_val) { denom - ref_val } else { ref_val - denom };
    assert!(diff <= 100, 0);
}

// Algorithm-derived golden vectors for eval_logistic (§11.7).
//
// Pinning procedure (one-shot at initial implementation; this test guards
// the values from then on):
//
//   1. Replace each `expected_*` literal with `0`.
//   2. Replace `assert_eq!(actual, expected)` with `std::debug::print(&actual)`.
//   3. `sui move test eval_logistic_golden_vectors` — captures the 3 outputs.
//   4. Paste the printed literals into spec §11.7 and back into this test.
//   5. Restore `assert_eq!`. Suite turns green.
#[test]
fun eval_logistic_golden_vectors() {
    // x = 0.25 — below linear
    assert_eq!(curve_shape_state::eval_logistic_for_testing(1_000_000_000, 4_000_000_000),  45_176_659);
    // x = 0.75 — above linear; complementary to row above
    assert_eq!(curve_shape_state::eval_logistic_for_testing(3_000_000_000, 4_000_000_000), 954_823_340);
    // small-integer inputs — same x = 0.25 ratio, asserts the algorithm is
    // scale-invariant in (t, t_max) at the integer-rounding granularity.
    assert_eq!(curve_shape_state::eval_logistic_for_testing(1, 4),                          45_176_659);
}

// ─── Cross-curve comparative properties ───────────────────────────────────
//
// Catch errors that pass per-curve property tests but get the relative
// ordering between curves wrong (e.g. a Logistic with the wrong k that
// satisfies its own midpoint and symmetry but does not actually cross
// Smoothstep at x = 0.5).

// (1) Logistic vs Smoothstep — both sigmoidal, both pinned to SCALE/2 at
// the midpoint. With LOGISTIC_K = 12, Logistic is steeper than Smoothstep
// at the inflection, so:
//   t < t_max/2 → Logistic < Smoothstep
//   t = t_max/2 → Logistic = Smoothstep = SCALE/2
//   t > t_max/2 → Logistic > Smoothstep
#[test]
fun logistic_vs_smoothstep_crossing_at_midpoint() {
    let scale = curve_shape_state::scale_for_testing();
    let t_max: u64 = 8_000_000_000;

    // Midpoint: both equal SCALE/2.
    assert_eq!(
        curve_shape_state::eval_logistic_for_testing(4_000_000_000, t_max),
        curve_shape_state::eval_smoothstep_for_testing(4_000_000_000, t_max),
    );
    assert_eq!(curve_shape_state::eval_logistic_for_testing(4_000_000_000, t_max), scale / 2);

    // First half (Logistic steeper ⇒ closer to 0): Logistic < Smoothstep.
    let first_half = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let mut i = 0;
    let len = first_half.length();
    while (i < len) {
        let t   = first_half[i];
        let log = curve_shape_state::eval_logistic_for_testing(t, t_max);
        let ss  = curve_shape_state::eval_smoothstep_for_testing(t, t_max);
        assert!(log < ss, 0);
        i = i + 1;
    };

    // Second half (Logistic steeper ⇒ closer to SCALE): Logistic > Smoothstep.
    let second_half = vector[5_000_000_000u64, 6_000_000_000, 7_000_000_000];
    let mut i = 0;
    let len = second_half.length();
    while (i < len) {
        let t   = second_half[i];
        let log = curve_shape_state::eval_logistic_for_testing(t, t_max);
        let ss  = curve_shape_state::eval_smoothstep_for_testing(t, t_max);
        assert!(log > ss, 0);
        i = i + 1;
    };
}

// (2) PowerLaw(2,1) ≤ Smoothstep on [0, t_max].
// Proof: Smoothstep(x) − x² = 3x² − 2x³ − x² = 2x²(1 − x) ≥ 0 for x ∈ [0, 1].
// Strict on the open interior; equal at the endpoints.
#[test]
fun power_law_2_1_below_or_equal_smoothstep_globally() {
    let t_max: u64 = 10_000_000_000;
    let ts = vector[
        1u64,
        100_000_000,
        1_000_000_000,
        2_500_000_000,
        5_000_000_000,
        7_500_000_000,
        9_000_000_000,
        9_999_999_999,
    ];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t  = ts[i];
        let pl = curve_shape_state::eval_power_law_for_testing(t, t_max, 2, 1);
        let ss = curve_shape_state::eval_smoothstep_for_testing(t, t_max);
        assert!(pl <= ss, 0);
        i = i + 1;
    };
}

// (3) PowerLaw convex chain — more convex (higher α) ⇒ lower curve.
// For x ∈ (0, 1), x^n strictly decreases in n. So
//     PowerLaw(8,1) < PowerLaw(3,1) < PowerLaw(2,1) at every interior t.
// Probe x ∈ {0.25, 0.5, 0.75, 0.95} — small enough x leads to nth-floor
// underflow for large n (e.g. x=2.5e-10 gives x^8 · SCALE = 0), which is a
// floor-rounding artifact, not a violation; this test stays in the
// representable band.
#[test]
fun power_law_convex_chain_decreasing_in_alpha() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000, 3_800_000_000];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t   = ts[i];
        let pl2 = curve_shape_state::eval_power_law_for_testing(t, t_max, 2, 1);
        let pl3 = curve_shape_state::eval_power_law_for_testing(t, t_max, 3, 1);
        let pl8 = curve_shape_state::eval_power_law_for_testing(t, t_max, 8, 1);
        assert!(pl3 < pl2, 0);
        assert!(pl8 < pl3, 0);
        i = i + 1;
    };
}

// (4) PowerLaw concave chain — deeper root (higher d) ⇒ higher curve.
// For x ∈ (0, 1), x^(1/d) strictly increases in d. So
//     PowerLaw(1,2) < PowerLaw(1,3) < PowerLaw(1,4) at every interior t.
#[test]
fun power_law_concave_chain_increasing_in_root_degree() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000, 3_800_000_000];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t     = ts[i];
        let pl_12 = curve_shape_state::eval_power_law_for_testing(t, t_max, 1, 2);
        let pl_13 = curve_shape_state::eval_power_law_for_testing(t, t_max, 1, 3);
        let pl_14 = curve_shape_state::eval_power_law_for_testing(t, t_max, 1, 4);
        assert!(pl_12 < pl_13, 0);
        assert!(pl_13 < pl_14, 0);
        i = i + 1;
    };
}

// (5a) Exponential convex chain — higher α ⇒ more convex ⇒ lower curve.
// f_α(x) = (e^(αx) − 1)/(e^α − 1) is decreasing in α for α > 0, x ∈ (0, 1).
// Verified at x=0.25: f_2 ≈ 0.1015, f_4 ≈ 0.0321, f_8 ≈ 0.00214.
#[test]
fun exponential_convex_chain_decreasing_in_alpha() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t  = ts[i];
        let e2 = curve_shape_state::eval_exponential_for_testing(t, t_max, 2, false);
        let e4 = curve_shape_state::eval_exponential_for_testing(t, t_max, 4, false);
        let e8 = curve_shape_state::eval_exponential_for_testing(t, t_max, 8, false);
        assert!(e4 < e2, 0);
        assert!(e8 < e4, 0);
        i = i + 1;
    };
}

// (5b) Exponential concave chain — higher |α| ⇒ more concave ⇒ higher curve.
// f_{−α}(x) = (e^(−αx) − 1)/(e^(−α) − 1) is increasing in α for α > 0, x ∈ (0, 1).
// Verified at x=0.25: f_{−2} ≈ 0.4551, f_{−4} ≈ 0.6438, f_{−8} ≈ 0.8650.
#[test]
fun exponential_concave_chain_increasing_in_alpha() {
    let t_max: u64 = 4_000_000_000;
    let ts = vector[1_000_000_000u64, 2_000_000_000, 3_000_000_000];
    let mut i = 0;
    let len = ts.length();
    while (i < len) {
        let t  = ts[i];
        let e2 = curve_shape_state::eval_exponential_for_testing(t, t_max, 2, true);
        let e4 = curve_shape_state::eval_exponential_for_testing(t, t_max, 4, true);
        let e8 = curve_shape_state::eval_exponential_for_testing(t, t_max, 8, true);
        assert!(e4 > e2, 0);
        assert!(e8 > e4, 0);
        i = i + 1;
    };
}

// (6) Midpoint convexity gate.
//
// At x = 0.5 (i.e. t = t_max/2 with t_max even), the universal convexity
// invariant for normalized curves with g(0)=0, g(1)=1:
//   - convex variants  →  g(0.5) <  0.5
//   - concave variants →  g(0.5) >  0.5
//   - the linear/sigmoidal (S-symmetric) family hits g(0.5) = 0.5 exactly.
// A single test that sweeps every variant and asserts the side it must land on.
#[test]
fun midpoint_convexity_gate() {
    let scale = curve_shape_state::scale_for_testing();
    let half  = scale / 2;
    let t_max: u64 = 4_000_000_000;
    let t:     u64 = 2_000_000_000;

    // S-symmetric trio — exact midpoint.
    assert_eq!(curve_shape_state::eval_linear_for_testing(t, t_max),     half);
    assert_eq!(curve_shape_state::eval_smoothstep_for_testing(t, t_max), half);
    assert_eq!(curve_shape_state::eval_logistic_for_testing(t, t_max),   half);

    // PowerLaw convex (n > d) — coprime, n ∈ [1, 8], d ∈ {1, 2, 3, 4}.
    let convex_ns = vector[2u8, 3, 8, 3, 5, 7, 4, 5, 7];
    let convex_ds = vector[1u8, 1, 1, 2, 2, 2, 3, 3, 4];
    let mut i = 0;
    let len = convex_ns.length();
    while (i < len) {
        let r = curve_shape_state::eval_power_law_for_testing(t, t_max, convex_ns[i], convex_ds[i]);
        assert!(r < half, 0);
        i = i + 1;
    };

    // PowerLaw concave (n < d).
    let concave_ns = vector[1u8, 1, 2, 1, 3];
    let concave_ds = vector[2u8, 3, 3, 4, 4];
    let mut i = 0;
    let len = concave_ns.length();
    while (i < len) {
        let r = curve_shape_state::eval_power_law_for_testing(t, t_max, concave_ns[i], concave_ds[i]);
        assert!(r > half, 0);
        i = i + 1;
    };

    // Exponential — sweep α ∈ [1, 8] for both signs.
    let mut a: u8 = 1;
    while (a <= 8) {
        let convex  = curve_shape_state::eval_exponential_for_testing(t, t_max, a, false);
        let concave = curve_shape_state::eval_exponential_for_testing(t, t_max, a, true);
        assert!(convex  < half, 0);
        assert!(concave > half, 0);
        a = a + 1;
    };
}

// ─── Algorithm-derived constants — regression check ────────────────────────
//
// Pinning procedure (run once during initial implementation, then this test
// guards the values forever):
//
//   1. Replace every `expected_*` literal below with `0`.
//   2. Replace each `assert_eq!(...)` with `std::debug::print(&actual)`.
//   3. `sui move test bootstrap_constants_match_pinned` — captures the 25
//      algorithm outputs (8 exp_scaled vectors + 16 EXP_A_NORM_* + LOGISTIC_DENOM).
//   4. Paste the printed literals into:
//        — `sources/curve_shape_state.move`: 16 EXP_A_NORM_* and LOGISTIC_DENOM
//        — `specs/primitives/curve_shape_state.spec.md`: §8, §9, §11.5
//        — this test (the `expected_*` literals).
//   5. Restore the `assert_eq!` form. Suite turns green.
//
// From this point on, any change to §7 (Taylor K, rounding) that perturbs
// outputs flags here.

#[test]
fun bootstrap_constants_match_pinned() {
    let ts    = curve_shape_state::taylor_scale_for_testing();
    let scale = curve_shape_state::scale_for_testing() as u128;

    // exp_scaled golden vectors (§11.5)
    assert_eq!(curve_shape_state::exp_scaled_for_testing(1, 1, false), 2_718_281_828_459_045_226);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(1, 1, true ),   367_879_441_171_442_322);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(1, 2, false), 1_648_721_270_700_128_139);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(1, 2, true ),   606_530_659_712_633_426);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(2, 1, false), 7_389_056_098_930_650_216);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(4, 1, false), 54_598_150_033_144_239_050);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(8, 1, false), 2_980_957_986_946_523_322_343);
    assert_eq!(curve_shape_state::exp_scaled_for_testing(8, 1, true ),   335_462_627_913_225);

    // EXP_A_NORM_{1..8}_POS (§8): exp_scaled(a, 1, false) − TS
    let pos_norms: vector<u128> = vector[
            1_718_281_828_459_045_226,
            6_389_056_098_930_650_216,
           19_085_536_923_187_667_729,
           53_598_150_033_144_239_050,
          147_413_159_102_576_587_697,
          402_428_793_492_728_453_424,
        1_095_633_158_427_339_529_377,
        2_979_957_986_946_523_322_343,
    ];
    let mut a: u64 = 1;
    while (a <= 8) {
        let pos_v    = curve_shape_state::exp_scaled_for_testing(a, 1, false);
        let computed = pos_v - ts;
        assert_eq!(computed, pos_norms[(a - 1) as u64]);
        assert_eq!(curve_shape_state::exp_a_norm_for_testing(a as u8, false), computed);
        a = a + 1;
    };

    // EXP_A_NORM_{1..8}_NEG (§8): TS − exp_scaled(a, 1, true)
    let neg_norms: vector<u128> = vector[
        632_120_558_828_557_678,
        864_664_716_763_387_308,
        950_212_931_632_136_057,
        981_684_361_111_265_820,
        993_262_053_000_914_533,
        997_521_247_823_333_601,
        999_088_118_034_444_554,
        999_664_537_372_086_775,
    ];
    let mut a: u64 = 1;
    while (a <= 8) {
        let neg_v    = curve_shape_state::exp_scaled_for_testing(a, 1, true);
        let computed = ts - neg_v;
        assert_eq!(computed, neg_norms[(a - 1) as u64]);
        assert_eq!(curve_shape_state::exp_a_norm_for_testing(a as u8, true), computed);
        a = a + 1;
    };

    // LOGISTIC_DENOM (§9): ((e⁶·TS − TS) · SCALE) / (e⁶·TS + TS)
    let ek6      = curve_shape_state::exp_scaled_pos_for_testing(6, 1);
    let computed = (((ek6 - ts) * scale) / (ek6 + ts)) as u64;
    assert_eq!(computed, 995_054_753);
    assert_eq!(curve_shape_state::logistic_denom_for_testing(), computed);
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
