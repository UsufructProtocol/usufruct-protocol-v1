// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_earning_tests;

use std::unit_test::assert_eq;
use sui::balance;
use usufruct::{
    monetary,
    owner_earning::{Self, OwnerEarnings},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

fun mk(amount: u64): OwnerEarnings<TEST_COIN> {
    owner_earning::new(balance::create_for_testing<TEST_COIN>(amount))
}

// ─── §1. Constructors ─────────────────────────────────────────────────────────

#[test]
fun new_proj_value_matches_input() {
    let e = mk(123);
    assert_eq!(owner_earning::proj_value(&e), monetary::stake(123));
    owner_earning::destroy_for_testing(e);
}

#[test]
fun zero_has_zero_value() {
    let e: OwnerEarnings<TEST_COIN> = owner_earning::zero();
    assert_eq!(owner_earning::proj_value(&e), monetary::stake(0));
    owner_earning::destroy_zero(e);
}

// ─── §2. join ─────────────────────────────────────────────────────────────────

#[test]
fun join_accumulates_both_amounts() {
    let mut a = mk(300);
    let b     = mk(200);
    owner_earning::join(&mut a, b);
    assert_eq!(owner_earning::proj_value(&a), monetary::stake(500));
    owner_earning::destroy_for_testing(a);
}

#[test]
fun join_zero_leaves_value_unchanged() {
    let mut a = mk(100);
    let z: OwnerEarnings<TEST_COIN> = owner_earning::zero();
    owner_earning::join(&mut a, z);
    assert_eq!(owner_earning::proj_value(&a), monetary::stake(100));
    owner_earning::destroy_for_testing(a);
}

#[test]
fun join_into_zero_target_equals_source() {
    let mut target: OwnerEarnings<TEST_COIN> = owner_earning::zero();
    let source = mk(75);
    owner_earning::join(&mut target, source);
    assert_eq!(owner_earning::proj_value(&target), monetary::stake(75));
    owner_earning::destroy_for_testing(target);
}

// ─── §3. drain_all ────────────────────────────────────────────────────────────

#[test]
fun drain_all_returns_full_balance_and_leaves_zero() {
    let mut e     = mk(400);
    let drained   = owner_earning::drain_all(&mut e);
    assert_eq!(balance::value(&drained), 400);
    assert_eq!(owner_earning::proj_value(&e), monetary::stake(0));
    balance::destroy_for_testing(drained);
    owner_earning::destroy_zero(e);
}

#[test]
fun drain_all_on_zero_returns_zero_balance() {
    let mut e: OwnerEarnings<TEST_COIN> = owner_earning::zero();
    let drained = owner_earning::drain_all(&mut e);
    assert_eq!(balance::value(&drained), 0);
    balance::destroy_zero(drained);
    owner_earning::destroy_zero(e);
}

// ─── §4. destroy_zero ─────────────────────────────────────────────────────────

#[test]
fun destroy_zero_ok_on_zero_value() {
    let e: OwnerEarnings<TEST_COIN> = owner_earning::zero();
    owner_earning::destroy_zero(e);
}

#[test]
fun destroy_zero_ok_after_full_drain() {
    let mut e   = mk(50);
    let drained = owner_earning::drain_all(&mut e);
    balance::destroy_for_testing(drained);
    owner_earning::destroy_zero(e);
}

#[test, expected_failure]
fun destroy_zero_aborts_on_nonzero() {
    owner_earning::destroy_zero(mk(1));
}
