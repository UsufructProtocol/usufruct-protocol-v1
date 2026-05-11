// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenant_tests;

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
    tenant::{Self, Tenant},
    tenant_cap::{Self, TenantCapIdentity},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const ADDR_T1: address = @0xA1;
const STAKE_T1: u64 = 1_000;

fun cap_t1(): TenantCapIdentity { tenant_cap::from_id(object::id_from_address(@0xCA1)) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun t1(): Tenant<TEST_COIN> {
    tenant::new(cap_t1(), ADDR_T1, balance::create_for_testing<TEST_COIN>(STAKE_T1))
}

// ─── §1. Constructor and accessors ─────────────────────────────────────────────

#[test]
fun new_constructs_tenant_with_expected_identity_and_stake() {
    let t = t1();
    let id = tenant::proj_identity(&t);
    assert_eq!(tenant::proj_cap_id(id),  cap_t1());
    assert_eq!(tenant::proj_address(id), ADDR_T1);
    assert_eq!(tenant::proj_stake_value(&t), monetary::stake(STAKE_T1));
    tenant::destroy_for_testing(t);
}

#[test]
fun stake_value_of_reads_inner_balance() {
    let t = t1();
    let s = tenant::proj_stake(&t);
    assert_eq!(tenant::proj_stake_value_of(s), monetary::stake(STAKE_T1));
    tenant::destroy_for_testing(t);
}

// ─── §2. unbundle ──────────────────────────────────────────────────────────────

#[test]
fun unbundle_returns_identity_and_stake() {
    let t = t1();
    let (id, stake) = tenant::unbundle(t);
    assert_eq!(tenant::proj_cap_id(&id),     cap_t1());
    assert_eq!(tenant::proj_address(&id),    ADDR_T1);
    assert_eq!(tenant::proj_stake_value_of(&stake), monetary::stake(STAKE_T1));
    tenant::destroy_stake_for_testing(stake);
}

// ─── §3. destroy_empty_stake ──────────────────────────────────────────────────

#[test]
fun destroy_empty_stake_ok_on_zero() {
    let t = tenant::new<TEST_COIN>(cap_t1(), ADDR_T1, balance::zero<TEST_COIN>());
    let (_id, stake) = tenant::unbundle(t);
    tenant::destroy_empty_stake(stake);
}

#[test]
#[expected_failure]
fun destroy_empty_stake_aborts_on_nonzero() {
    let t = t1();
    let (_id, stake) = tenant::unbundle(t);
    tenant::destroy_empty_stake(stake);
}

// ─── §4. take_fee_share ───────────────────────────────────────────────────────

#[test]
fun take_fee_share_partial_reduces_stake_and_returns_typed_share() {
    let mut t = t1();
    let share = tenant::take_fee_share(&mut t, monetary::stake(75), escrow_identity::new(fake_escrow_id()));
    assert_eq!(monetary::stake_mist(fee_message::proj_share_value(&share)),     75);
    assert_eq!(fee_message::share_escrow_id(&share), fake_escrow_id());
    assert_eq!(tenant::proj_stake_value(&t), monetary::stake(STAKE_T1 - 75));
    fee_message::destroy_share_for_testing(share);
    tenant::destroy_for_testing(t);
}

#[test]
fun take_fee_share_zero_returns_zero_share_unchanged_stake() {
    let mut t = t1();
    let share = tenant::take_fee_share(&mut t, monetary::stake(0), escrow_identity::new(fake_escrow_id()));
    assert_eq!(monetary::stake_mist(fee_message::proj_share_value(&share)), 0);
    assert_eq!(tenant::proj_stake_value(&t), monetary::stake(STAKE_T1));
    fee_message::destroy_share_for_testing(share);
    tenant::destroy_for_testing(t);
}

#[test]
#[expected_failure]
fun take_fee_share_more_than_stake_aborts() {
    let mut t = t1();
    let share = tenant::take_fee_share(&mut t, monetary::stake(STAKE_T1 + 1), escrow_identity::new(fake_escrow_id()));
    fee_message::destroy_share_for_testing(share);
    tenant::destroy_for_testing(t);
}

// ─── §6. liquidate ────────────────────────────────────────────────────────────

#[test]
fun liquidate_sends_full_stake_to_address_as_coin() {
    let mut sc = test_scenario::begin(@0xCAFE);
    sc.next_tx(@0xCAFE);
    {
        let (_id, stake) = tenant::unbundle(t1());
        tenant::liquidate(stake, ADDR_T1, sc.ctx());
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
        let zero_t = tenant::new<TEST_COIN>(cap_t1(), ADDR_T1, balance::zero<TEST_COIN>());
        let (_id, stake) = tenant::unbundle(zero_t);
        tenant::liquidate(stake, ADDR_T1, sc.ctx());
    };
    sc.next_tx(ADDR_T1);
    {
        let coin = sc.take_from_sender<coin::Coin<TEST_COIN>>();
        assert_eq!(coin::value(&coin), 0);
        transfer::public_transfer(coin, ADDR_T1);
    };
    sc.end();
}
