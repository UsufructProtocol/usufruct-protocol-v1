// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::stake_balance_tests;

use std::unit_test::assert_eq;
use sui::{balance, coin, test_scenario};
use usufruct::{
    monetary,
    stake_balance,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const ADDR: address = @0xA1;

fun mk(amount: u64): stake_balance::StakeBalance<TEST_COIN> {
    stake_balance::new(balance::create_for_testing<TEST_COIN>(amount))
}

// ─── §1. Constructor and proj_value ───────────────────────────────────────────

#[test]
fun new_proj_value_matches_input() {
    let s = mk(500);
    assert_eq!(stake_balance::proj_value(&s), monetary::stake(500));
    stake_balance::destroy_for_testing(s);
}

#[test]
fun new_zero_has_zero_value() {
    let s = mk(0);
    assert_eq!(stake_balance::proj_value(&s), monetary::stake(0));
    stake_balance::destroy_zero(s);
}

// ─── §2. split ────────────────────────────────────────────────────────────────

#[test]
fun split_partial_reduces_stake_and_returns_balance() {
    let mut s   = mk(1_000);
    let portion = stake_balance::split(&mut s, monetary::stake(300));
    assert_eq!(balance::value(&portion), 300);
    assert_eq!(stake_balance::proj_value(&s), monetary::stake(700));
    balance::destroy_for_testing(portion);
    stake_balance::destroy_for_testing(s);
}

#[test]
fun split_zero_leaves_stake_unchanged() {
    let mut s   = mk(500);
    let portion = stake_balance::split(&mut s, monetary::stake(0));
    assert_eq!(balance::value(&portion), 0);
    assert_eq!(stake_balance::proj_value(&s), monetary::stake(500));
    balance::destroy_zero(portion);
    stake_balance::destroy_for_testing(s);
}

#[test]
fun split_full_amount_drains_stake() {
    let mut s   = mk(200);
    let portion = stake_balance::split(&mut s, monetary::stake(200));
    assert_eq!(balance::value(&portion), 200);
    assert_eq!(stake_balance::proj_value(&s), monetary::stake(0));
    balance::destroy_for_testing(portion);
    stake_balance::destroy_zero(s);
}

// ─── §3. destroy_zero ─────────────────────────────────────────────────────────

#[test]
fun destroy_zero_ok_on_zero_stake() {
    stake_balance::destroy_zero(mk(0));
}

#[test, expected_failure]
fun destroy_zero_aborts_on_nonzero_stake() {
    stake_balance::destroy_zero(mk(1));
}

// ─── §4. liquidate ────────────────────────────────────────────────────────────

#[test]
fun liquidate_transfers_full_amount_as_coin() {
    let mut sc = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        stake_balance::liquidate(mk(750), ADDR, sc.ctx());
    };
    sc.next_tx(ADDR);
    {
        let c = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&c), 750);
        transfer::public_transfer(c, ADDR);
    };
    sc.end();
}

#[test]
fun liquidate_zero_stake_sends_zero_coin() {
    let mut sc = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        stake_balance::liquidate(mk(0), ADDR, sc.ctx());
    };
    sc.next_tx(ADDR);
    {
        let c = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&c), 0);
        transfer::public_transfer(c, ADDR);
    };
    sc.end();
}
