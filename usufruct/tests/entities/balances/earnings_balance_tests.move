// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::earnings_balance_tests;

use std::unit_test::assert_eq;
use sui::balance;
use usufruct::{
    monetary,
    earnings_balance::{Self, EarningsBalance},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

fun mk(amount: u64): EarningsBalance<TEST_COIN> {
    earnings_balance::new(balance::create_for_testing<TEST_COIN>(amount))
}

// ─── §1. Constructors ─────────────────────────────────────────────────────────

#[test]
fun new_proj_value_matches_input() {
    let e = mk(123);
    assert_eq!(earnings_balance::proj_value(&e), monetary::stake(123));
    earnings_balance::destroy_for_testing(e);
}

#[test]
fun zero_has_zero_value() {
    let e: EarningsBalance<TEST_COIN> = earnings_balance::zero();
    assert_eq!(earnings_balance::proj_value(&e), monetary::stake(0));
    earnings_balance::destroy_zero(e);
}

// ─── §2. join ─────────────────────────────────────────────────────────────────

#[test]
fun join_accumulates_both_amounts() {
    let mut a = mk(300);
    let b     = mk(200);
    earnings_balance::join(&mut a, b);
    assert_eq!(earnings_balance::proj_value(&a), monetary::stake(500));
    earnings_balance::destroy_for_testing(a);
}

#[test]
fun join_zero_leaves_value_unchanged() {
    let mut a = mk(100);
    let z: EarningsBalance<TEST_COIN> = earnings_balance::zero();
    earnings_balance::join(&mut a, z);
    assert_eq!(earnings_balance::proj_value(&a), monetary::stake(100));
    earnings_balance::destroy_for_testing(a);
}

#[test]
fun join_into_zero_target_equals_source() {
    let mut target: EarningsBalance<TEST_COIN> = earnings_balance::zero();
    let source = mk(75);
    earnings_balance::join(&mut target, source);
    assert_eq!(earnings_balance::proj_value(&target), monetary::stake(75));
    earnings_balance::destroy_for_testing(target);
}

// ─── §3. drain_all ────────────────────────────────────────────────────────────

#[test]
fun drain_all_returns_full_balance_and_leaves_zero() {
    let mut e     = mk(400);
    let drained   = earnings_balance::drain_all(&mut e);
    assert_eq!(balance::value(&drained), 400);
    assert_eq!(earnings_balance::proj_value(&e), monetary::stake(0));
    balance::destroy_for_testing(drained);
    earnings_balance::destroy_zero(e);
}

#[test]
fun drain_all_on_zero_returns_zero_balance() {
    let mut e: EarningsBalance<TEST_COIN> = earnings_balance::zero();
    let drained = earnings_balance::drain_all(&mut e);
    assert_eq!(balance::value(&drained), 0);
    balance::destroy_zero(drained);
    earnings_balance::destroy_zero(e);
}

// ─── §4. into_balance ───────────────────────────────────────────────────────────

#[test]
fun into_balance_consumes_and_returns_full_balance() {
    let e   = mk(640);
    let bal = earnings_balance::into_balance(e);
    assert_eq!(balance::value(&bal), 640);
    balance::destroy_for_testing(bal);
}

#[test]
fun into_balance_on_zero_returns_zero_balance() {
    let e: EarningsBalance<TEST_COIN> = earnings_balance::zero();
    let bal = earnings_balance::into_balance(e);
    assert_eq!(balance::value(&bal), 0);
    balance::destroy_zero(bal);
}

// ─── §5. destroy_zero ─────────────────────────────────────────────────────────

#[test]
fun destroy_zero_ok_on_zero_value() {
    let e: EarningsBalance<TEST_COIN> = earnings_balance::zero();
    earnings_balance::destroy_zero(e);
}

#[test]
fun destroy_zero_ok_after_full_drain() {
    let mut e   = mk(50);
    let drained = earnings_balance::drain_all(&mut e);
    balance::destroy_for_testing(drained);
    earnings_balance::destroy_zero(e);
}

#[test, expected_failure]
fun destroy_zero_aborts_on_nonzero() {
    earnings_balance::destroy_zero(mk(1));
}
