// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::lifecycle_state_tests;

use std::unit_test::assert_eq;
use sui::balance::{Self, Balance};
use sui::test_scenario;
use usufruct::{
    lifecycle_state::{Self, LifecycleState},
    tenant_state::{Self, Tenant},
    asset_state,
    owner_state,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TestAsset has key, store { id: UID }
public struct TEST_COIN has drop {}

const ADDR_T1: address = @0xA1;
const ADDR_T2: address = @0xA2;
const ADDR_T3: address = @0xA3;

const STAKE_T1: u64 = 1_000;
const STAKE_T2: u64 = 2_000;
const STAKE_T3: u64 = 3_000;

const OWNER_CUT:      u64 = 100;
const PHASE_MS:       u64 = 1_000_000;
const EXPIRY_MS:      u64 = 2_000_000;
const LAST_ACQ_PRICE: u64 = 500;

fun cap_t1(): ID { object::id_from_address(@0xCA1) }
fun cap_t2(): ID { object::id_from_address(@0xCA2) }
fun cap_t3(): ID { object::id_from_address(@0xCA3) }

fun new_asset(ctx: &mut TxContext): TestAsset { TestAsset { id: object::new(ctx) } }
fun destroy_asset(a: TestAsset) { let TestAsset { id } = a; object::delete(id) }

fun stake(amount: u64): Balance<TEST_COIN> { balance::create_for_testing<TEST_COIN>(amount) }

fun t1(): Tenant<TEST_COIN> { tenant_state::new_tenant(cap_t1(), ADDR_T1, stake(STAKE_T1)) }
fun t2(): Tenant<TEST_COIN> { tenant_state::new_tenant(cap_t2(), ADDR_T2, stake(STAKE_T2)) }
fun t3(): Tenant<TEST_COIN> { tenant_state::new_tenant(cap_t3(), ADDR_T3, stake(STAKE_T3)) }

fun consume_tenant(t: Tenant<TEST_COIN>) {
    let (_id, _addr, b) = tenant_state::unbundle(t);
    balance::destroy_for_testing(b);
}

/// Consume a NotRented state whose inner asset is already Retired.
fun teardown_retired(s: LifecycleState<TestAsset, TEST_COIN>) {
    let (a_state, t_state, o_state) = lifecycle_state::decompose_retired(s);
    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
    owner_state::destroy_for_testing(o_state);
}

/// Retire from Idle or AtDutch, then teardown.
fun retire_and_teardown(s: LifecycleState<TestAsset, TEST_COIN>) {
    teardown_retired(lifecycle_state::retire_now(s));
}

// ─── §1. Constructor ───────────────────────────────────────────────────────────

#[test]
fun new_returns_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    assert!(lifecycle_state::is_not_rented(&s));
    retire_and_teardown(s);
    sc.end();
}

// ─── §2. Boundary transitions — happy paths ────────────────────────────────────

#[test]
fun start_rent_transitions_to_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    assert!(lifecycle_state::is_rented(&s));
    let (s, dep) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun expire_tenure_returns_to_not_rented_with_remainder_stake() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let (s, dep) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);

    assert!(lifecycle_state::is_not_rented(&s));
    assert_eq!(tenant_state::cap_id(&dep), cap_t1());
    assert_eq!(tenant_state::addr(&dep), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&dep), STAKE_T1 - OWNER_CUT);

    consume_tenant(dep);
    retire_and_teardown(s);
    sc.end();
}

// ─── §3. Within-NotRented transitions ─────────────────────────────────────────

#[test]
fun expire_auction_stays_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let (s, dep) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep);

    let s = lifecycle_state::expire_auction(s);
    assert!(lifecycle_state::is_not_rented(&s));
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun retire_now_stays_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::retire_now(s);
    assert!(lifecycle_state::is_not_rented(&s));
    teardown_retired(s);
    sc.end();
}

#[test]
fun retire_now_from_at_dutch_stays_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let (s, dep) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep);

    let s = lifecycle_state::retire_now(s);
    assert!(lifecycle_state::is_not_rented(&s));
    teardown_retired(s);
    sc.end();
}

// ─── §4. Within-Rented transitions ────────────────────────────────────────────

#[test]
fun place_bid_stays_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    assert!(lifecycle_state::is_rented(&s));
    let (s, dep_t1) = lifecycle_state::accept_bid(s, 0, PHASE_MS);
    consume_tenant(dep_t1);
    let (s, dep_t2) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep_t2);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun supersede_bid_displaces_pending_returns_full_t2_stake() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    let (s, displaced) = lifecycle_state::supersede_bid(s, t3(), EXPIRY_MS);

    assert!(lifecycle_state::is_rented(&s));
    // Displaced is T2 — returned intact, no owner split on supersede
    assert_eq!(tenant_state::cap_id(&displaced), cap_t2());
    assert_eq!(tenant_state::addr(&displaced), ADDR_T2);
    assert_eq!(tenant_state::stake_value(&displaced), STAKE_T2);
    consume_tenant(displaced);

    let (s, dep_t1) = lifecycle_state::accept_bid(s, 0, PHASE_MS);
    consume_tenant(dep_t1);
    let (s, dep_t3) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep_t3);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun accept_bid_promotes_t2_returns_t1_with_remainder_stake() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    let (s, dep) = lifecycle_state::accept_bid(s, OWNER_CUT, PHASE_MS);

    assert!(lifecycle_state::is_rented(&s));
    assert_eq!(tenant_state::cap_id(&dep), cap_t1());
    assert_eq!(tenant_state::addr(&dep), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&dep), STAKE_T1 - OWNER_CUT);
    consume_tenant(dep);

    let (s, dep_t2) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep_t2);
    retire_and_teardown(s);
    sc.end();
}

// ─── §5. Abort paths ──────────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun start_rent_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::start_rent(s, t2(), PHASE_MS);
    let (s, dep) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun expire_tenure_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, dep) = lifecycle_state::expire_tenure(s, 0, LAST_ACQ_PRICE);
    consume_tenant(dep);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun expire_auction_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::expire_auction(s);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun retire_now_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::retire_now(s);
    teardown_retired(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun place_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::place_bid(s, t1(), EXPIRY_MS);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun supersede_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, dep) = lifecycle_state::supersede_bid(s, t1(), EXPIRY_MS);
    consume_tenant(dep);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun accept_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, dep) = lifecycle_state::accept_bid(s, 0, PHASE_MS);
    consume_tenant(dep);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun decompose_retired_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let (a_state, t_state, o_state) = lifecycle_state::decompose_retired(s);
    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
    owner_state::destroy_for_testing(o_state);
    sc.end();
}

// ─── §6. Terminal: decompose_retired ──────────────────────────────────────────

#[test]
fun decompose_retired_yields_correct_sub_states() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::retire_now(s);
    let (a_state, t_state, o_state) = lifecycle_state::decompose_retired(s);

    assert!(asset_state::is_retired(&a_state));
    assert!(tenant_state::is_absence(&t_state));
    assert!(owner_state::is_stop_flow(&o_state));
    assert_eq!(owner_state::value(&o_state), 0);

    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
    owner_state::destroy_for_testing(o_state);
    sc.end();
}

#[test]
fun decompose_retired_owner_balance_reflects_accumulated_earnings() {
    // Two tenure expirations each deposit OWNER_CUT into o_state.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    // First rental
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let (s, dep1) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    consume_tenant(dep1);

    // Re-rent (from AtDutch)
    let s = lifecycle_state::start_rent(s, t2(), PHASE_MS);
    let (s, dep2) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    consume_tenant(dep2);

    // Retire and decompose — earnings = 2 × OWNER_CUT
    let s = lifecycle_state::retire_now(s);
    let (a_state, t_state, o_state) = lifecycle_state::decompose_retired(s);
    assert_eq!(owner_state::value(&o_state), 2 * OWNER_CUT);

    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
    owner_state::destroy_for_testing(o_state);
    sc.end();
}

// ─── §7. Lifecycle composition ─────────────────────────────────────────────────

#[test]
fun full_cycle_no_bid() {
    // new → start_rent → expire_tenure → expire_auction → retire_now → decompose
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    assert!(lifecycle_state::is_not_rented(&s));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    assert!(lifecycle_state::is_rented(&s));

    let (s, dep) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    assert!(lifecycle_state::is_not_rented(&s));
    assert_eq!(tenant_state::stake_value(&dep), STAKE_T1 - OWNER_CUT);
    consume_tenant(dep);

    let s = lifecycle_state::expire_auction(s);
    assert!(lifecycle_state::is_not_rented(&s));

    retire_and_teardown(s);
    sc.end();
}

#[test]
fun full_cycle_with_bid_handover() {
    // new → start_rent(T1) → place_bid(T2) → accept_bid → expire_tenure(T2) → retire
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);

    let (s, dep_t1) = lifecycle_state::accept_bid(s, OWNER_CUT, PHASE_MS);
    assert_eq!(tenant_state::cap_id(&dep_t1), cap_t1());
    assert_eq!(tenant_state::stake_value(&dep_t1), STAKE_T1 - OWNER_CUT);
    consume_tenant(dep_t1);

    let (s, dep_t2) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    assert_eq!(tenant_state::cap_id(&dep_t2), cap_t2());
    assert_eq!(tenant_state::stake_value(&dep_t2), STAKE_T2 - OWNER_CUT);
    consume_tenant(dep_t2);

    retire_and_teardown(s);
    sc.end();
}

#[test]
fun full_cycle_with_supersede() {
    // start_rent(T1) → place_bid(T2) → supersede_bid(T3) → accept_bid → expire_tenure → retire
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);

    let (s, t2_displaced) = lifecycle_state::supersede_bid(s, t3(), EXPIRY_MS);
    assert_eq!(tenant_state::cap_id(&t2_displaced), cap_t2());
    assert_eq!(tenant_state::stake_value(&t2_displaced), STAKE_T2); // full stake — no split
    consume_tenant(t2_displaced);

    let (s, dep_t1) = lifecycle_state::accept_bid(s, OWNER_CUT, PHASE_MS);
    assert_eq!(tenant_state::cap_id(&dep_t1), cap_t1());
    assert_eq!(tenant_state::stake_value(&dep_t1), STAKE_T1 - OWNER_CUT);
    consume_tenant(dep_t1);

    let (s, dep_t3) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    assert_eq!(tenant_state::cap_id(&dep_t3), cap_t3());
    assert_eq!(tenant_state::stake_value(&dep_t3), STAKE_T3 - OWNER_CUT);
    consume_tenant(dep_t3);

    retire_and_teardown(s);
    sc.end();
}

#[test]
fun multi_rental_cycle_two_tenants_sequentially() {
    // T1 rents, expires, T2 rents, retires — verifies re-rent from AtDutch.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    // First tenant
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS);
    let (s, dep1) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    consume_tenant(dep1);
    assert!(lifecycle_state::is_not_rented(&s)); // back to NotRented(AtDutch)

    // Second tenant takes over from AtDutch
    let s = lifecycle_state::start_rent(s, t2(), PHASE_MS);
    assert!(lifecycle_state::is_rented(&s));
    let (s, dep2) = lifecycle_state::expire_tenure(s, OWNER_CUT, LAST_ACQ_PRICE);
    consume_tenant(dep2);

    retire_and_teardown(s);
    sc.end();
}
