// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::price_function_state_tests;

use std::unit_test::assert_eq;
use usufruct::{math, price_function_state};

// ─── §5.0.1 Constructor success ────────────────────────────────────────────

#[test_only]
public struct FixedDeltaSuccessCase has drop {
    delta: u64,
}

#[test]
fun new_fixed_delta_success() {
    let cases = vector[
        FixedDeltaSuccessCase { delta: 1                              }, // minimum valid
        FixedDeltaSuccessCase { delta: 18_446_744_073_709_551_615     }, // u64::MAX
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let pf = price_function_state::new_fixed_delta(case.delta);
        assert_eq!(price_function_state::fixed_delta_fields_for_testing(&pf), case.delta);
        i = i + 1;
    };
}

#[test_only]
public struct CompoundDeltaSuccessCase has drop {
    bps:   u64,
    delta: u64,
}

#[test]
fun new_compound_delta_success() {
    let bpu = price_function_state::bps_per_unit_for_testing();
    let cases = vector[
        CompoundDeltaSuccessCase { bps: 1,                          delta: 1 }, // min bps and delta
        CompoundDeltaSuccessCase { bps: bpu,                        delta: 1 }, // 100% bps — inside bounds
        CompoundDeltaSuccessCase { bps: 18_446_744_073_709_541_615, delta: 1 }, // u64::MAX - BPS_PER_UNIT
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let pf = price_function_state::new_compound_delta(case.bps, case.delta);
        let (stored_bps, stored_delta) = price_function_state::compound_delta_fields_for_testing(&pf);
        assert_eq!(stored_bps,   case.bps);
        assert_eq!(stored_delta, case.delta);
        i = i + 1;
    };
}

// ─── §5.0.2 Constructor abort ──────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = price_function_state::EDeltaZero, location = usufruct::price_function_state)]
fun new_fixed_delta_delta_zero_aborts() {
    price_function_state::new_fixed_delta(0);
}

#[test]
#[expected_failure(abort_code = price_function_state::EDeltaZero, location = usufruct::price_function_state)]
fun new_compound_delta_delta_zero_aborts() {
    price_function_state::new_compound_delta(500, 0);
}

#[test]
#[expected_failure(abort_code = price_function_state::EBpsRange, location = usufruct::price_function_state)]
fun new_compound_delta_bps_zero_aborts() {
    price_function_state::new_compound_delta(0, 1);
}

#[test]
#[expected_failure(abort_code = price_function_state::EBpsRange, location = usufruct::price_function_state)]
fun new_compound_delta_bps_one_above_upper_bound_aborts() {
    // u64::MAX - BPS_PER_UNIT + 1 = 18_446_744_073_709_541_616 — smallest value that overflows
    price_function_state::new_compound_delta(18_446_744_073_709_541_616, 1);
}

#[test]
#[expected_failure(abort_code = price_function_state::EBpsRange, location = usufruct::price_function_state)]
fun new_compound_delta_bps_max_aborts() {
    price_function_state::new_compound_delta(18_446_744_073_709_551_615, 1); // u64::MAX saturated
}

// ─── §5.1 eval_fixed_delta ─────────────────────────────────────────────────

#[test_only]
public struct FixedDeltaCase has drop {
    price: u64,
    delta:           u64,
    result:          u64,
}

// Golden vectors + strict-increase predicate (seed set F encoded as rows).
// Seed set F: {(0,1), (100,50), (u64::MAX-2,1), (10^9,10^9)} — all covered below.
#[test]
fun eval_fixed_delta_golden_vectors_and_strict_increase() {
    let cases = vector[
        FixedDeltaCase { price: 100,                        delta: 50,            result: 150                        }, // F: (100,50)
        FixedDeltaCase { price: 1_000_000_000,              delta: 1,             result: 1_000_000_001              },
        FixedDeltaCase { price: 1_000_000_000,              delta: 1_000_000_000, result: 2_000_000_000              }, // F: (10^9, 10^9)
        FixedDeltaCase { price: 0,                          delta: 1,             result: 1                          }, // F: (0, 1) — valid at eval layer
        FixedDeltaCase { price: 18_446_744_073_709_551_614, delta: 1,             result: 18_446_744_073_709_551_615 }, // u64::MAX-1 boundary
        FixedDeltaCase { price: 18_446_744_073_709_551_613, delta: 1,             result: 18_446_744_073_709_551_614 }, // F: (u64::MAX-2, 1)
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let r = price_function_state::eval_fixed_delta_for_testing(case.price, case.delta);
        assert_eq!(r, case.result);
        assert!(r > case.price, 0); // strict increase: delta > 0 by construction
        i = i + 1;
    };
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::price_function_state)]
fun eval_fixed_delta_overflow_max_plus_one_aborts() {
    price_function_state::eval_fixed_delta_for_testing(18_446_744_073_709_551_615, 1); // u64::MAX + 1
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::price_function_state)]
fun eval_fixed_delta_overflow_half_each_aborts() {
    // (u64::MAX/2 + 1) + (u64::MAX/2 + 1) = u64::MAX + 1
    price_function_state::eval_fixed_delta_for_testing(9_223_372_036_854_775_808, 9_223_372_036_854_775_808);
}

// ─── §5.2 eval_compound_delta ──────────────────────────────────────────────

#[test_only]
public struct CompoundDeltaCase has drop {
    price: u64,
    bps:             u64,
    delta:           u64,
    result:          u64,
}

#[test]
fun eval_compound_delta_golden_vectors() {
    let cases = vector[
        CompoundDeltaCase { price: 10_000,         bps: 500,    delta: 1,             result: 10_501         }, // 5% + delta
        CompoundDeltaCase { price: 1,              bps: 500,    delta: 1,             result: 2              }, // pct floors to 0
        CompoundDeltaCase { price: 200,            bps: 50,     delta: 1,             result: 202            }, // at threshold: pct +1, +delta
        CompoundDeltaCase { price: 199,            bps: 50,     delta: 1,             result: 200            }, // below threshold: pct floors to 0
        CompoundDeltaCase { price: 1_000_000_000,  bps: 10_000, delta: 1,             result: 2_000_000_001  }, // 100% + delta
        CompoundDeltaCase { price: 0,              bps: 500,    delta: 1,             result: 1              }, // zero price: mul_div(0,…)=0, only delta
        CompoundDeltaCase { price: 9_999,          bps: 1,      delta: 1,             result: 10_000         }, // just below bps=1 threshold
        CompoundDeltaCase { price: 10_000,         bps: 1,      delta: 1,             result: 10_002         }, // at bps=1 threshold: pct +1, +delta
        CompoundDeltaCase { price: 20_000,         bps: 1,      delta: 1,             result: 20_003         }, // above threshold: pct +2, +delta
        CompoundDeltaCase { price: 1_000_000_000,  bps: 1,      delta: 1,             result: 1_000_100_001  }, // full 0.01% contribution
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let r = price_function_state::eval_compound_delta_for_testing(
            case.price, case.bps, case.delta,
        );
        assert_eq!(r, case.result);
        i = i + 1;
    };
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun eval_compound_delta_overflow_mul_div_max_aborts() {
    // mul_div(u64::MAX, 10_001, 10_000) > u64::MAX — math layer aborts
    price_function_state::eval_compound_delta_for_testing(18_446_744_073_709_551_615, 1, 1);
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun eval_compound_delta_overflow_mul_div_double_aborts() {
    // mul_div(u64::MAX-1, 20_000, 10_000) = 2*(u64::MAX-1) — overflows u64
    price_function_state::eval_compound_delta_for_testing(18_446_744_073_709_551_614, 10_000, 1);
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::price_function_state)]
fun eval_compound_delta_overflow_add_delta_aborts() {
    // pct result (~u64::MAX/2) fits u64; delta = u64::MAX fits u64; their sum overflows
    price_function_state::eval_compound_delta_for_testing(9_223_372_036_854_775_807, 1, 18_446_744_073_709_551_615);
}

// Property: percentage-floor threshold — seed set C from §2 table.
// For each (bps, threshold):
//   (1) eval(threshold-1, bps, 1) = threshold  — pct still floors to 0
//   (2) eval(threshold,   bps, 1) >= threshold+1 — pct begins to contribute
#[test_only]
public struct ThresholdCase has drop {
    bps:       u64,
    threshold: u64,
}

#[test]
fun eval_compound_delta_pct_floor_threshold_seed_set_c() {
    let cases = vector[
        ThresholdCase { bps: 1,     threshold: 10_000 },
        ThresholdCase { bps: 10,    threshold: 1_000  },
        ThresholdCase { bps: 50,    threshold: 200    },
        ThresholdCase { bps: 100,   threshold: 100    },
        ThresholdCase { bps: 500,   threshold: 20     },
        ThresholdCase { bps: 1_000, threshold: 10     },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let below = price_function_state::eval_compound_delta_for_testing(case.threshold - 1, case.bps, 1);
        assert_eq!(below, case.threshold); // (threshold-1) + delta=1 = threshold; pct = 0
        let at = price_function_state::eval_compound_delta_for_testing(case.threshold, case.bps, 1);
        assert!(at >= case.threshold + 1, 0); // pct contributes >= 1 at threshold
        i = i + 1;
    };
}

// Property: strict increase — seed set C'.
#[test_only]
public struct CompoundStrictIncCase has drop {
    price: u64,
    bps:             u64,
    delta:           u64,
}

#[test]
fun eval_compound_delta_strict_increase_seed_set_c_prime() {
    let cases = vector[
        CompoundStrictIncCase { price: 1,           bps: 1,   delta: 1             },
        CompoundStrictIncCase { price: 200,         bps: 50,  delta: 1             },
        CompoundStrictIncCase { price: 1_000_000_000, bps: 500, delta: 1           },
        CompoundStrictIncCase { price: 1_000_000_000, bps: 1,  delta: 1_000_000_000 },
        CompoundStrictIncCase { price: 0,           bps: 500, delta: 1             },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let r = price_function_state::eval_compound_delta_for_testing(
            case.price, case.bps, case.delta,
        );
        assert!(r > case.price, 0);
        i = i + 1;
    };
}

// ─── §5.3 evaluate_price_fn ────────────────────────────────────────────────

#[test]
fun evaluate_price_fn_golden_vectors() {
    assert_eq!(
        price_function_state::evaluate_price_fn(&price_function_state::new_fixed_delta(50), 100),
        150,
    );
    assert_eq!(
        price_function_state::evaluate_price_fn(&price_function_state::new_compound_delta(500, 1), 10_000),
        10_501,
    );
    assert_eq!(
        price_function_state::evaluate_price_fn(&price_function_state::new_compound_delta(50, 1), 200),
        202,
    );
}

// P-DE — dispatch equivalence: dispatcher result matches branch-specific private
// helper for every seed-set pair. Catches wrong arm or swapped field forwarding.

#[test]
fun evaluate_price_fn_dispatch_equivalence_fixed_delta() {
    let prices: vector<u64> = vector[100, 0];
    let deltas: vector<u64> = vector[50,  1];
    let mut i = 0;
    let len = prices.length();
    while (i < len) {
        let pf  = price_function_state::new_fixed_delta(deltas[i]);
        let price = prices[i];
        assert_eq!(
            price_function_state::evaluate_price_fn(&pf, price),
            price_function_state::eval_fixed_delta_for_testing(price, deltas[i]),
        );
        i = i + 1;
    };
}

#[test]
fun evaluate_price_fn_dispatch_equivalence_compound_delta() {
    let prices: vector<u64> = vector[10_000, 200, 9_999,  10_000];
    let bpss:   vector<u64> = vector[500,    50,  1,      1     ];
    let deltas: vector<u64> = vector[1,      1,   1,      1     ];
    let mut i = 0;
    let len = prices.length();
    while (i < len) {
        let pf  = price_function_state::new_compound_delta(bpss[i], deltas[i]);
        let price = prices[i];
        assert_eq!(
            price_function_state::evaluate_price_fn(&pf, price),
            price_function_state::eval_compound_delta_for_testing(price, bpss[i], deltas[i]),
        );
        i = i + 1;
    };
}

// ─── Composition golden vectors ────────────────────────────────────────────
//
// Apply the price function n times sequentially and pin the exact integer
// result at each step. Verifies mul_div precision across accumulated rounding.
//
// Bootstrap procedure (run once; this test guards the values from then on):
//   1. Replace assert_eq!(x, expected[i]) with std::debug::print(&x).
//   2. sui move test eval_fixed_delta_composition / eval_compound_delta_composition_*
//   3. Paste the printed values back as the expected vectors.
//   4. Restore assert_eq!. Suite turns green.

#[test]
fun eval_fixed_delta_composition() {
    let mut x: u64 = 1_000;
    let delta: u64 = 500;
    let expected: vector<u64> = vector[1_500, 2_000, 2_500, 3_000, 3_500];
    let mut i = 0;
    let len = expected.length();
    while (i < len) {
        x = price_function_state::eval_fixed_delta_for_testing(x, delta);
        assert_eq!(x, expected[i]);
        i = i + 1;
    };
}

// bps=10_000 (100%), delta=1: f(x)=2x+1, no floor rounding. f^n(1)=2^(n+1)−1.
#[test]
fun eval_compound_delta_composition_100pct() {
    let mut x: u64 = 1;
    let bps:   u64 = 10_000;
    let delta: u64 = 1;
    let expected: vector<u64> = vector[3, 7, 15, 31, 63];
    let mut i = 0;
    let len = expected.length();
    while (i < len) {
        x = price_function_state::eval_compound_delta_for_testing(x, bps, delta);
        assert_eq!(x, expected[i]);
        i = i + 1;
    };
}

// bps=1_000 (10%), delta=1: pins floor-rounding accumulated across 5 steps.
#[test]
fun eval_compound_delta_composition_10pct() {
    let mut x: u64 = 10_000;
    let bps:   u64 = 1_000;
    let delta: u64 = 1;
    let expected: vector<u64> = vector[11_001, 12_102, 13_313, 14_645, 16_110];
    let mut i = 0;
    let len = expected.length();
    while (i < len) {
        x = price_function_state::eval_compound_delta_for_testing(x, bps, delta);
        assert_eq!(x, expected[i]);
        i = i + 1;
    };
}

// ─── Cross-variant and within-variant comparative properties ───────────────
//
// Catch errors that pass per-variant tests but break the relative ordering
// between FixedDelta and CompoundDelta, or monotonicity within CompoundDelta.

// (A1) Below the pct floor threshold, CompoundDelta degenerates to FixedDelta:
// both return exactly x + delta. The percentage component is swallowed by floor
// rounding, so the two variants are semantically identical in this band.
#[test]
fun compound_equals_fixed_below_pct_floor_threshold() {
    // Seed set C pairs (bps, threshold) from §2 table.
    // At price = threshold - 1 the pct still floors to 0.
    let bpss:       vector<u64> = vector[1,      10,    50,  100, 500, 1_000];
    let thresholds: vector<u64> = vector[10_000, 1_000, 200, 100, 20,  10   ];
    let delta: u64 = 5;
    let mut i = 0;
    let len = bpss.length();
    while (i < len) {
        let x = thresholds[i] - 1;
        let compound = price_function_state::eval_compound_delta_for_testing(x, bpss[i], delta);
        let fixed    = price_function_state::eval_fixed_delta_for_testing(x, delta);
        assert_eq!(compound, fixed); // pct = 0, both equal x + delta
        i = i + 1;
    };
}

// (A2) At and above the pct floor threshold, CompoundDelta strictly dominates
// FixedDelta for the same delta: the percentage component adds a positive
// premium on top of the flat increment.
#[test]
fun compound_dominates_fixed_above_pct_floor_threshold() {
    // At price = threshold the pct first contributes +1 (or more).
    let bpss:       vector<u64> = vector[1,      10,    50,  100, 500, 1_000];
    let thresholds: vector<u64> = vector[10_000, 1_000, 200, 100, 20,  10   ];
    let delta: u64 = 5;
    let mut i = 0;
    let len = bpss.length();
    while (i < len) {
        let x = thresholds[i];
        let compound = price_function_state::eval_compound_delta_for_testing(x, bpss[i], delta);
        let fixed    = price_function_state::eval_fixed_delta_for_testing(x, delta);
        assert!(compound > fixed, 0); // pct contributes >= 1, compound strictly wins
        i = i + 1;
    };
}

// (B) Higher bps ⟹ higher next price for the same price and delta.
// Uses x = 10^9 — well above every threshold in seed set C — so every bps
// value in the chain contributes, making the chain strictly increasing.
// Probe the full §2 bps range: 1 < 10 < 100 < 500 < 1_000 < 10_000.
#[test]
fun eval_compound_delta_monotone_in_bps() {
    let x:     u64 = 1_000_000_000;
    let delta: u64 = 1;
    let bps_chain: vector<u64> = vector[1, 10, 100, 500, 1_000, 10_000];
    let mut i = 1;
    let len = bps_chain.length();
    while (i < len) {
        let lo = price_function_state::eval_compound_delta_for_testing(x, bps_chain[i - 1], delta);
        let hi = price_function_state::eval_compound_delta_for_testing(x, bps_chain[i],     delta);
        assert!(lo < hi, 0);
        i = i + 1;
    };
}

// (C) For fixed bps and delta, CompoundDelta is monotone non-decreasing in
// price. Uses bps = 500, delta = 1. Probe spans below and above
// the threshold (= 20) to cover both the floor band and the contributing band.
#[test]
fun eval_compound_delta_monotone_in_price() {
    let bps:   u64 = 500;
    let delta: u64 = 1;
    let prices: vector<u64> = vector[0, 1, 19, 20, 100, 10_000, 1_000_000_000];
    let mut i = 1;
    let len = prices.length();
    while (i < len) {
        let lo = price_function_state::eval_compound_delta_for_testing(prices[i - 1], bps, delta);
        let hi = price_function_state::eval_compound_delta_for_testing(prices[i],     bps, delta);
        assert!(lo <= hi, 0);
        i = i + 1;
    };
}
