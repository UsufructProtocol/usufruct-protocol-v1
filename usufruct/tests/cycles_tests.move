// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::cycles_tests;

use std::unit_test::assert_eq;
use usufruct::{
    cycles::{Self, Cycles},
    monetary,
};

// ─── cycles() — abort ─────────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = cycles::ECyclesZero, location = usufruct::cycles)]
fun cycles_zero_aborts() {
    cycles::cycles(0);
}

// ─── is_single ────────────────────────────────────────────────────────────────

#[test]
fun is_single_true_for_one() {
    assert!(cycles::is_single(cycles::cycles(1)), 0);
}

#[test]
fun is_single_false_for_two() {
    assert!(!cycles::is_single(cycles::cycles(2)), 0);
}

#[test]
fun is_single_false_for_large() {
    assert!(!cycles::is_single(cycles::cycles(100)), 0);
}

// ─── total_price ──────────────────────────────────────────────────────────────

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
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        let result = monetary::price_mist(cycles::total_price(monetary::price(c.floor_mist), cycles::cycles(c.n)));
        assert_eq!(result, c.expected);
        i = i + 1;
    };
}

// ─── cycles_count extractor ───────────────────────────────────────────────────

#[test]
fun cycles_count_roundtrips() {
    assert_eq!(cycles::cycles_count(cycles::cycles(1)),   1);
    assert_eq!(cycles::cycles_count(cycles::cycles(5)),   5);
    assert_eq!(cycles::cycles_count(cycles::cycles(100)), 100);
}
