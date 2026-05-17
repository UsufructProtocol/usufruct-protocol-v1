// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenures_tests;

use std::unit_test::assert_eq;
use usufruct::{
    tenures,
    monetary,
};

// ─── cycles() — abort ─────────────────────────────────────────────────────────

#[test, expected_failure(abort_code = tenures::ETenuresZero, location = usufruct::tenures)]
fun cycles_zero_aborts() {
    tenures::tenures(0);
}

// ─── proj_is_single ────────────────────────────────────────────────────────────────

#[test]
fun is_single_true_for_one() {
    assert!(tenures::proj_is_single(tenures::tenures(1)), 0);
}

#[test]
fun is_single_false_for_two() {
    assert!(!tenures::proj_is_single(tenures::tenures(2)), 0);
}

#[test]
fun is_single_false_for_large() {
    assert!(!tenures::proj_is_single(tenures::tenures(100)), 0);
}

// ─── compute_total_price ──────────────────────────────────────────────────────────────

#[test_only]
public struct TotalPriceCase has drop {
    floor_mist: u64,
    n:          u64,
    expected:   u64,
}

#[test]
fun total_price_table() {
    let cases = vector[
        // cycles(1) degenerates: total == floor
        TotalPriceCase { floor_mist: 10_000_000_000, n: 1, expected: 10_000_000_000 },
        // linear scaling
        TotalPriceCase { floor_mist: 10_000_000_000, n: 2, expected: 20_000_000_000 },
        TotalPriceCase { floor_mist: 10_000_000_000, n: 3, expected: 30_000_000_000 },
        TotalPriceCase { floor_mist: 5_000_000_000,  n: 4, expected: 20_000_000_000 },
        // minimal price
        TotalPriceCase { floor_mist: 1, n: 7, expected: 7 },
    ];
    cases.do_ref!(|c| {
        let result = monetary::price_mist(tenures::compute_total_price(monetary::price(c.floor_mist), tenures::tenures(c.n)));
        assert_eq!(result, c.expected);
    });
}

// ─── tenures_count extractor ───────────────────────────────────────────────────

#[test]
fun tenures_count_roundtrips() {
    assert_eq!(tenures::tenures_count(tenures::tenures(1)),   1);
    assert_eq!(tenures::tenures_count(tenures::tenures(5)),   5);
    assert_eq!(tenures::tenures_count(tenures::tenures(100)), 100);
}
