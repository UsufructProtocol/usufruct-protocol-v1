// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::monetary_tests;

use std::unit_test::assert_eq;
use usufruct::monetary;

// ─── §1. Constructors and round-trips ─────────────────────────────────────────

#[test]
fun price_round_trip() {
    assert_eq!(monetary::price_mist(monetary::price(42)), 42);
}

#[test]
fun stake_round_trip() {
    assert_eq!(monetary::stake_mist(monetary::stake(99)), 99);
}

#[test]
fun price_zero_round_trip() {
    assert_eq!(monetary::price_mist(monetary::price(0)), 0);
}

#[test]
fun stake_zero_round_trip() {
    assert_eq!(monetary::stake_mist(monetary::stake(0)), 0);
}

// ─── §2. as_reference_price ───────────────────────────────────────────────────

#[test]
fun as_reference_price_copies_mist() {
    let s = monetary::stake(500);
    let p = monetary::as_reference_price(s);
    assert_eq!(monetary::price_mist(p), 500);
}

#[test]
fun as_reference_price_zero() {
    let p = monetary::as_reference_price(monetary::stake(0));
    assert_eq!(monetary::price_mist(p), 0);
}

// ─── §3. compute_price_add ────────────────────────────────────────────────────────────

#[test]
fun price_add_sums_correctly() {
    let a = monetary::price(100);
    let b = monetary::price(250);
    assert_eq!(monetary::price_mist(monetary::compute_price_add(a, b)), 350);
}

#[test]
fun price_add_zero_identity() {
    let a = monetary::price(777);
    assert_eq!(monetary::price_mist(monetary::compute_price_add(a, monetary::price(0))), 777);
}

#[test]
fun price_add_at_u64_max_succeeds() {
    let max = 18_446_744_073_709_551_615u64;
    let a   = monetary::price(max / 2);
    let b   = monetary::price(max / 2);
    let sum = monetary::price_mist(monetary::compute_price_add(a, b));
    assert!(sum <= max, 0);
}

#[test, expected_failure(abort_code = monetary::EPriceAddOverflow, location = usufruct::monetary)]
fun price_add_overflow_aborts() {
    let max = 18_446_744_073_709_551_615u64;
    monetary::compute_price_add(monetary::price(max), monetary::price(1));
}

// ─── §4. compute_price_sub ────────────────────────────────────────────────────────────

#[test]
fun price_sub_correct() {
    let a = monetary::price(1_000);
    let b = monetary::price(300);
    assert_eq!(monetary::price_mist(monetary::compute_price_sub(a, b)), 700);
}

#[test]
fun price_sub_to_zero() {
    let v = monetary::price(50);
    assert_eq!(monetary::price_mist(monetary::compute_price_sub(v, v)), 0);
}

// ─── §5. compute_stake_sub ────────────────────────────────────────────────────────────

#[test]
fun stake_sub_correct() {
    let a = monetary::stake(2_000);
    let b = monetary::stake(500);
    assert_eq!(monetary::stake_mist(monetary::compute_stake_sub(a, b)), 1_500);
}

#[test]
fun stake_sub_to_zero() {
    let v = monetary::stake(100);
    assert_eq!(monetary::stake_mist(monetary::compute_stake_sub(v, v)), 0);
}
