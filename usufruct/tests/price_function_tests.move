// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::price_function_tests;

use std::unit_test::assert_eq;
use usufruct::{math, price_function};

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
        let pf = price_function::new_fixed_delta(case.delta);
        assert_eq!(price_function::fixed_delta_fields_for_testing(&pf), case.delta);
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
    let bpu = price_function::bps_per_unit_for_testing();
    let cases = vector[
        CompoundDeltaSuccessCase { bps: 1,                          delta: 1 }, // min bps and delta
        CompoundDeltaSuccessCase { bps: bpu,                        delta: 1 }, // 100% bps — inside bounds
        CompoundDeltaSuccessCase { bps: 18_446_744_073_709_541_615, delta: 1 }, // u64::MAX - BPS_PER_UNIT
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let pf = price_function::new_compound_delta(case.bps, case.delta);
        let (stored_bps, stored_delta) = price_function::compound_delta_fields_for_testing(&pf);
        assert_eq!(stored_bps,   case.bps);
        assert_eq!(stored_delta, case.delta);
        i = i + 1;
    };
}

// ─── §5.0.2 Constructor abort ──────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = price_function::EDeltaZero, location = usufruct::price_function)]
fun new_fixed_delta_delta_zero_aborts() {
    price_function::new_fixed_delta(0);
}

#[test]
#[expected_failure(abort_code = price_function::EDeltaZero, location = usufruct::price_function)]
fun new_compound_delta_delta_zero_aborts() {
    price_function::new_compound_delta(500, 0);
}

#[test]
#[expected_failure(abort_code = price_function::EBpsRange, location = usufruct::price_function)]
fun new_compound_delta_bps_zero_aborts() {
    price_function::new_compound_delta(0, 1);
}

#[test]
#[expected_failure(abort_code = price_function::EBpsRange, location = usufruct::price_function)]
fun new_compound_delta_bps_one_above_upper_bound_aborts() {
    // u64::MAX - BPS_PER_UNIT + 1 = 18_446_744_073_709_541_616 — smallest value that overflows
    price_function::new_compound_delta(18_446_744_073_709_541_616, 1);
}

#[test]
#[expected_failure(abort_code = price_function::EBpsRange, location = usufruct::price_function)]
fun new_compound_delta_bps_max_aborts() {
    price_function::new_compound_delta(18_446_744_073_709_551_615, 1); // u64::MAX saturated
}

// ─── §5.1 eval_fixed_delta ─────────────────────────────────────────────────

#[test_only]
public struct FixedDeltaCase has drop {
    last_rent_price: u64,
    delta:           u64,
    result:          u64,
}

// Golden vectors + strict-increase predicate (seed set F encoded as rows).
// Seed set F: {(0,1), (100,50), (u64::MAX-2,1), (10^9,10^9)} — all covered below.
#[test]
fun eval_fixed_delta_golden_vectors_and_strict_increase() {
    let cases = vector[
        FixedDeltaCase { last_rent_price: 100,                        delta: 50,            result: 150                        }, // F: (100,50)
        FixedDeltaCase { last_rent_price: 1_000_000_000,              delta: 1,             result: 1_000_000_001              },
        FixedDeltaCase { last_rent_price: 1_000_000_000,              delta: 1_000_000_000, result: 2_000_000_000              }, // F: (10^9, 10^9)
        FixedDeltaCase { last_rent_price: 0,                          delta: 1,             result: 1                          }, // F: (0, 1) — valid at eval layer
        FixedDeltaCase { last_rent_price: 18_446_744_073_709_551_614, delta: 1,             result: 18_446_744_073_709_551_615 }, // u64::MAX-1 boundary
        FixedDeltaCase { last_rent_price: 18_446_744_073_709_551_613, delta: 1,             result: 18_446_744_073_709_551_614 }, // F: (u64::MAX-2, 1)
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let r = price_function::eval_fixed_delta_for_testing(case.last_rent_price, case.delta);
        assert_eq!(r, case.result);
        assert!(r > case.last_rent_price, 0); // strict increase: delta > 0 by construction
        i = i + 1;
    };
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::price_function)]
fun eval_fixed_delta_overflow_max_plus_one_aborts() {
    price_function::eval_fixed_delta_for_testing(18_446_744_073_709_551_615, 1); // u64::MAX + 1
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::price_function)]
fun eval_fixed_delta_overflow_half_each_aborts() {
    // (u64::MAX/2 + 1) + (u64::MAX/2 + 1) = u64::MAX + 1
    price_function::eval_fixed_delta_for_testing(9_223_372_036_854_775_808, 9_223_372_036_854_775_808);
}

// ─── §5.2 eval_compound_delta ──────────────────────────────────────────────

#[test_only]
public struct CompoundDeltaCase has drop {
    last_rent_price: u64,
    bps:             u64,
    delta:           u64,
    result:          u64,
}

#[test]
fun eval_compound_delta_golden_vectors() {
    let cases = vector[
        CompoundDeltaCase { last_rent_price: 10_000,         bps: 500,    delta: 1,             result: 10_501         }, // 5% + delta
        CompoundDeltaCase { last_rent_price: 1,              bps: 500,    delta: 1,             result: 2              }, // pct floors to 0
        CompoundDeltaCase { last_rent_price: 200,            bps: 50,     delta: 1,             result: 202            }, // at threshold: pct +1, +delta
        CompoundDeltaCase { last_rent_price: 199,            bps: 50,     delta: 1,             result: 200            }, // below threshold: pct floors to 0
        CompoundDeltaCase { last_rent_price: 1_000_000_000,  bps: 10_000, delta: 1,             result: 2_000_000_001  }, // 100% + delta
        CompoundDeltaCase { last_rent_price: 0,              bps: 500,    delta: 1,             result: 1              }, // zero price: mul_div(0,…)=0, only delta
        CompoundDeltaCase { last_rent_price: 9_999,          bps: 1,      delta: 1,             result: 10_000         }, // just below bps=1 threshold
        CompoundDeltaCase { last_rent_price: 10_000,         bps: 1,      delta: 1,             result: 10_002         }, // at bps=1 threshold: pct +1, +delta
        CompoundDeltaCase { last_rent_price: 20_000,         bps: 1,      delta: 1,             result: 20_003         }, // above threshold: pct +2, +delta
        CompoundDeltaCase { last_rent_price: 1_000_000_000,  bps: 1,      delta: 1,             result: 1_000_100_001  }, // full 0.01% contribution
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let r = price_function::eval_compound_delta_for_testing(
            case.last_rent_price, case.bps, case.delta,
        );
        assert_eq!(r, case.result);
        i = i + 1;
    };
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun eval_compound_delta_overflow_mul_div_max_aborts() {
    // mul_div(u64::MAX, 10_001, 10_000) > u64::MAX — math layer aborts
    price_function::eval_compound_delta_for_testing(18_446_744_073_709_551_615, 1, 1);
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun eval_compound_delta_overflow_mul_div_double_aborts() {
    // mul_div(u64::MAX-1, 20_000, 10_000) = 2*(u64::MAX-1) — overflows u64
    price_function::eval_compound_delta_for_testing(18_446_744_073_709_551_614, 10_000, 1);
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::price_function)]
fun eval_compound_delta_overflow_add_delta_aborts() {
    // pct result (~u64::MAX/2) fits u64; delta = u64::MAX fits u64; their sum overflows
    price_function::eval_compound_delta_for_testing(9_223_372_036_854_775_807, 1, 18_446_744_073_709_551_615);
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
        let below = price_function::eval_compound_delta_for_testing(case.threshold - 1, case.bps, 1);
        assert_eq!(below, case.threshold); // (threshold-1) + delta=1 = threshold; pct = 0
        let at = price_function::eval_compound_delta_for_testing(case.threshold, case.bps, 1);
        assert!(at >= case.threshold + 1, 0); // pct contributes >= 1 at threshold
        i = i + 1;
    };
}

// Property: strict increase — seed set C'.
#[test_only]
public struct CompoundStrictIncCase has drop {
    last_rent_price: u64,
    bps:             u64,
    delta:           u64,
}

#[test]
fun eval_compound_delta_strict_increase_seed_set_c_prime() {
    let cases = vector[
        CompoundStrictIncCase { last_rent_price: 1,           bps: 1,   delta: 1             },
        CompoundStrictIncCase { last_rent_price: 200,         bps: 50,  delta: 1             },
        CompoundStrictIncCase { last_rent_price: 1_000_000_000, bps: 500, delta: 1           },
        CompoundStrictIncCase { last_rent_price: 1_000_000_000, bps: 1,  delta: 1_000_000_000 },
        CompoundStrictIncCase { last_rent_price: 0,           bps: 500, delta: 1             },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let r = price_function::eval_compound_delta_for_testing(
            case.last_rent_price, case.bps, case.delta,
        );
        assert!(r > case.last_rent_price, 0);
        i = i + 1;
    };
}

// ─── §5.3 evaluate_price_fn ────────────────────────────────────────────────

#[test]
fun evaluate_price_fn_golden_vectors() {
    assert_eq!(
        price_function::evaluate_price_fn(&price_function::new_fixed_delta(50), 100),
        150,
    );
    assert_eq!(
        price_function::evaluate_price_fn(&price_function::new_compound_delta(500, 1), 10_000),
        10_501,
    );
    assert_eq!(
        price_function::evaluate_price_fn(&price_function::new_compound_delta(50, 1), 200),
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
        let pf  = price_function::new_fixed_delta(deltas[i]);
        let lrp = prices[i];
        assert_eq!(
            price_function::evaluate_price_fn(&pf, lrp),
            price_function::eval_fixed_delta_for_testing(lrp, deltas[i]),
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
        let pf  = price_function::new_compound_delta(bpss[i], deltas[i]);
        let lrp = prices[i];
        assert_eq!(
            price_function::evaluate_price_fn(&pf, lrp),
            price_function::eval_compound_delta_for_testing(lrp, bpss[i], deltas[i]),
        );
        i = i + 1;
    };
}
