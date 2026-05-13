// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::owner_tests;

use std::unit_test::assert_eq;
use sui::{balance, coin, test_scenario};
use usufruct::{
    escrow_identity,
    monetary,
    owner,
    owner_cap::{Self, OwnerCap, OwnerCapIdentity},
    tenant_cap,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const OWNER_ADDR: address = @0xA1;
const OTHER:      address = @0xB2;

fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun mk_cap(ctx: &mut TxContext): (OwnerCap, OwnerCapIdentity) {
    let cap    = owner_cap::new(escrow_identity::new(fake_escrow_id()), OWNER_ADDR, ctx);
    let cap_id = owner_cap::identity(&cap);
    (cap, cap_id)
}

// ─── §1. Constructor and accessors ────────────────────────────────────────────

#[test]
fun new_constructs_owner_with_zero_balance_and_bound_cap_id() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let o = owner::new<TEST_COIN>(cap_id);
        assert_eq!(owner::proj_value(&o), monetary::stake(0));
        assert_eq!(owner::proj_cap_identity(owner::proj_identity(&o)), cap_id);
        owner::destroy_for_testing(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

#[test]
fun new_earnings_reflects_input_balance() {
    let e = owner::new_earnings<TEST_COIN>(balance::create_for_testing(123));
    assert_eq!(owner::proj_earnings_value(&e), monetary::stake(123));
    owner::destroy_earnings_for_testing(e);
}

#[test]
fun new_earnings_zero_balance_has_zero_value() {
    let e = owner::new_earnings<TEST_COIN>(balance::zero<TEST_COIN>());
    assert_eq!(owner::proj_earnings_value(&e), monetary::stake(0));
    owner::destroy_earnings_for_testing(e);
}

// ─── §2. deposit ──────────────────────────────────────────────────────────────

#[test]
fun deposit_accumulates_into_owner() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(100)));
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(250)));
        assert_eq!(owner::proj_value(&o), monetary::stake(350));
        owner::destroy_for_testing(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

#[test]
fun deposit_zero_leaves_value_unchanged() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(50)));
        owner::deposit(&mut o, owner::new_earnings(balance::zero<TEST_COIN>()));
        assert_eq!(owner::proj_value(&o), monetary::stake(50));
        owner::destroy_for_testing(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

// ─── §3. withdraw — happy path ─────────────────────────────────────────────────

#[test]
fun withdraw_with_correct_cap_drains_to_coin() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(777)));
        let drained = owner::withdraw(&mut o, &cap, sc.ctx());
        assert_eq!(coin::value(&drained), 777);
        assert_eq!(owner::proj_value(&o), monetary::stake(0));
        coin::burn_for_testing(drained);
        owner::destroy_for_testing(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

#[test]
fun withdraw_on_empty_earnings_returns_zero_coin() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        let drained = owner::withdraw(&mut o, &cap, sc.ctx());
        assert_eq!(coin::value(&drained), 0);
        coin::burn_for_testing(drained);
        owner::destroy_for_testing(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

// ─── §4. withdraw — abort path ────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = owner::E_OWNER_WRONG_CAP, location = usufruct::owner)]
fun withdraw_with_wrong_cap_aborts() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap_bound, cap_id) = mk_cap(sc.ctx());
        // A second cap, distinct cap_id — represents a foreign OwnerCap.
        let cap_other = owner_cap::new(escrow_identity::new(fake_escrow_id()), OTHER, sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(10)));
        let coin_drained = owner::withdraw(&mut o, &cap_other, sc.ctx());
        coin::burn_for_testing(coin_drained);
        owner::destroy_for_testing(o);
        owner_cap::burn(cap_bound, OWNER_ADDR);
        owner_cap::burn(cap_other, OTHER);
    };
    sc.end();
}

// ─── §5. destroy_empty ────────────────────────────────────────────────────────

#[test]
fun destroy_empty_ok_on_zero() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let o = owner::new<TEST_COIN>(cap_id);
        owner::destroy_empty(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

#[test]
fun destroy_empty_ok_after_full_withdraw() {
    // Roundtrip: deposit, withdraw to zero, then destroy_empty succeeds.
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(500)));
        let drained = owner::withdraw(&mut o, &cap, sc.ctx());
        coin::burn_for_testing(drained);
        owner::destroy_empty(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

#[test]
#[expected_failure]
fun destroy_empty_aborts_on_nonzero() {
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);
        owner::deposit(&mut o, owner::new_earnings(balance::create_for_testing<TEST_COIN>(1)));
        owner::destroy_empty(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}

// ─── §6. take_owner_earnings (via tenant) ──────────────────────────────────────

#[test]
fun take_owner_earnings_then_deposit_round_trip() {
    use usufruct::tenant;
    let mut sc = test_scenario::begin(OWNER_ADDR);
    sc.next_tx(OWNER_ADDR);
    {
        let (cap, cap_id) = mk_cap(sc.ctx());
        let mut o = owner::new<TEST_COIN>(cap_id);

        let mut t = tenant::new<TEST_COIN>(
            tenant_cap::from_id(object::id_from_address(@0xCA1)),
            @0xA1,
            balance::create_for_testing<TEST_COIN>(1_000),
        );
        let earn = tenant::take_owner_earnings(&mut t, monetary::stake(250));
        assert_eq!(owner::proj_earnings_value(&earn), monetary::stake(250));
        owner::deposit(&mut o, earn);
        assert_eq!(owner::proj_value(&o), monetary::stake(250));
        assert_eq!(tenant::proj_stake_value(&t), monetary::stake(750));

        tenant::destroy_for_testing(t);
        owner::destroy_for_testing(o);
        owner_cap::burn(cap, OWNER_ADDR);
    };
    sc.end();
}
