// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::usufructuary_seat_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    coin,
    test_scenario,
};
use usufruct::{
    fee_message,
    monetary,
    escrow_identity,
    refund_address,
    usufructuary_seat::{Self, UsufructuarySeat},
    usufructuary_identity::{Self},
    stake_balance,
    usufruct_cap::{Self, UsufructCapIdentity},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const ADDR_T1: address = @0xA1;
const STAKE_T1: u64 = 1_000;

fun cap_t1(): UsufructCapIdentity { usufruct_cap::from_id(object::id_from_address(@0xCA1)) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun t1(): UsufructuarySeat<TEST_COIN> {
    usufructuary_seat::new(cap_t1(), refund_address::new(ADDR_T1), balance::create_for_testing<TEST_COIN>(STAKE_T1))
}

// ─── §1. Constructor and accessors ─────────────────────────────────────────────

#[test]
fun new_constructs_usufructuary_with_expected_identity_and_stake() {
    let t = t1();
    let id = usufructuary_seat::proj_identity(&t);
    assert_eq!(usufructuary_identity::proj_cap_identity(id),  cap_t1());
    assert_eq!(usufructuary_identity::proj_address(id), refund_address::new(ADDR_T1));
    assert_eq!(usufructuary_seat::proj_stake_value(&t), monetary::stake(STAKE_T1));
    usufructuary_seat::destroy_for_testing(t);
}

#[test]
fun stake_value_of_reads_inner_balance() {
    let t = t1();
    let s = usufructuary_seat::proj_stake(&t);
    assert_eq!(stake_balance::proj_value(s), monetary::stake(STAKE_T1));
    usufructuary_seat::destroy_for_testing(t);
}

// ─── §2. unbundle ──────────────────────────────────────────────────────────────

#[test]
fun unbundle_returns_identity_and_stake() {
    let t = t1();
    let (id, stake) = usufructuary_seat::unbundle(t);
    assert_eq!(usufructuary_identity::proj_cap_identity(&id),     cap_t1());
    assert_eq!(usufructuary_identity::proj_address(&id), refund_address::new(ADDR_T1));
    assert_eq!(stake_balance::proj_value(&stake), monetary::stake(STAKE_T1));
    stake_balance::destroy_for_testing(stake);
}

// ─── §3. destroy_empty_stake ──────────────────────────────────────────────────

#[test]
fun destroy_empty_stake_ok_on_zero() {
    let t = usufructuary_seat::new<TEST_COIN>(cap_t1(), refund_address::new(ADDR_T1), balance::zero<TEST_COIN>());
    let (_id, stake) = usufructuary_seat::unbundle(t);
    stake_balance::destroy_zero(stake);
}

#[test, expected_failure]
fun destroy_empty_stake_aborts_on_nonzero() {
    let t = t1();
    let (_id, stake) = usufructuary_seat::unbundle(t);
    stake_balance::destroy_zero(stake);
}

// ─── §4. take_fee_share ───────────────────────────────────────────────────────

#[test]
fun take_fee_share_partial_reduces_stake_and_returns_typed_share() {
    let mut t = t1();
    let share = usufructuary_seat::take_fee_share(&mut t, monetary::stake(75), escrow_identity::new(fake_escrow_id()));
    assert_eq!(monetary::stake_mist(fee_message::proj_share_value(&share)),     75);
    assert_eq!(fee_message::share_escrow_id(&share), fake_escrow_id());
    assert_eq!(usufructuary_seat::proj_stake_value(&t), monetary::stake(STAKE_T1 - 75));
    fee_message::destroy_share_for_testing(share);
    usufructuary_seat::destroy_for_testing(t);
}

#[test]
fun take_fee_share_zero_returns_zero_share_unchanged_stake() {
    let mut t = t1();
    let share = usufructuary_seat::take_fee_share(&mut t, monetary::stake(0), escrow_identity::new(fake_escrow_id()));
    assert_eq!(monetary::stake_mist(fee_message::proj_share_value(&share)), 0);
    assert_eq!(usufructuary_seat::proj_stake_value(&t), monetary::stake(STAKE_T1));
    fee_message::destroy_share_for_testing(share);
    usufructuary_seat::destroy_for_testing(t);
}

#[test, expected_failure]
fun take_fee_share_more_than_stake_aborts() {
    let mut t = t1();
    let share = usufructuary_seat::take_fee_share(&mut t, monetary::stake(STAKE_T1 + 1), escrow_identity::new(fake_escrow_id()));
    fee_message::destroy_share_for_testing(share);
    usufructuary_seat::destroy_for_testing(t);
}

// ─── §6. liquidate ────────────────────────────────────────────────────────────

#[test]
fun liquidate_sends_full_stake_to_address_as_coin() {
    let mut sc = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        let (_id, stake) = usufructuary_seat::unbundle(t1());
        stake_balance::liquidate(stake, ADDR_T1, sc.ctx());
    };
    sc.next_tx(ADDR_T1);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), STAKE_T1);
        transfer::public_transfer(coin, ADDR_T1);
    };
    sc.end();
}

#[test]
fun liquidate_zero_stake_sends_zero_coin() {
    let mut sc = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        let zero_t = usufructuary_seat::new<TEST_COIN>(cap_t1(), refund_address::new(ADDR_T1), balance::zero<TEST_COIN>());
        let (_id, stake) = usufructuary_seat::unbundle(zero_t);
        stake_balance::liquidate(stake, ADDR_T1, sc.ctx());
    };
    sc.next_tx(ADDR_T1);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), 0);
        transfer::public_transfer(coin, ADDR_T1);
    };
    sc.end();
}
