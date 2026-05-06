// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::lifecycle_state_tests;

use std::unit_test::assert_eq;
use sui::balance::{Self, Balance};
use sui::test_scenario;
use usufruct::{
    asset,
    asset_state,
    lifecycle_state::{Self, LifecycleState, TenureExpiryState},
    refund_state,
    tenant::{Self, Tenant},
    tenant_state,
    unreachable,
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

const OWNER_T1: u64 = 900;
const FEE_T1:   u64 = 100;
const OWNER_T2: u64 = 1_800;
const FEE_T2:   u64 = 200;
const OWNER_T3: u64 = 2_700;
const FEE_T3:   u64 = 300;

const PARTIAL_OWNER: u64 = 100;
const PARTIAL_FEE:   u64 = 20;

const PHASE_MS:       u64 = 1_000_000;
const EXPIRY_MS:      u64 = 2_000_000;
const BOUNDARY_MS:    u64 = 3_000_000;
const LAST_ACQ_PRICE: u64 = 500;

fun cap_t1(): ID         { object::id_from_address(@0xCA1) }
fun cap_t2(): ID         { object::id_from_address(@0xCA2) }
fun cap_t3(): ID         { object::id_from_address(@0xCA3) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun new_asset(ctx: &mut TxContext): TestAsset { TestAsset { id: object::new(ctx) } }
fun destroy_asset(a: TestAsset) { let TestAsset { id } = a; object::delete(id) }

fun stake(amount: u64): Balance<TEST_COIN> { balance::create_for_testing<TEST_COIN>(amount) }

fun t1(): Tenant<TEST_COIN> { tenant::new(cap_t1(), ADDR_T1, stake(STAKE_T1)) }
fun t2(): Tenant<TEST_COIN> { tenant::new(cap_t2(), ADDR_T2, stake(STAKE_T2)) }
fun t3(): Tenant<TEST_COIN> { tenant::new(cap_t3(), ADDR_T3, stake(STAKE_T3)) }

/// Retire from Idle or AtDutch and consume the asset.
fun retire_and_teardown(s: LifecycleState<TestAsset, TEST_COIN>) {
    destroy_asset(lifecycle_state::retire_and_extract(s));
}

/// Consume a `TenureExpiryState` produced by `expire_tenure`.
fun teardown_expiry(expiry: TenureExpiryState<TestAsset, TEST_COIN>) {
    if (lifecycle_state::tenure_expiry_is_at_dutch(&expiry)) {
        retire_and_teardown(lifecycle_state::tenure_expiry_unwrap_at_dutch(expiry))
    } else {
        destroy_asset(lifecycle_state::tenure_expiry_unwrap_retired(expiry))
    }
}

/// Extract the LifecycleState from an AtDutch expiry.
fun unwrap_at_dutch(expiry: TenureExpiryState<TestAsset, TEST_COIN>): LifecycleState<TestAsset, TEST_COIN> {
    lifecycle_state::tenure_expiry_unwrap_at_dutch(expiry)
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
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    assert!(lifecycle_state::is_rented(&s));
    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun expire_tenure_returns_nothing_refund_and_at_dutch() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());

    assert!(lifecycle_state::tenure_expiry_is_at_dutch(&expiry));
    assert!(refund_state::is_nothing(&rs));
    refund_state::destroy_for_testing(rs);

    teardown_expiry(expiry);
    sc.end();
}

// ─── §3. Within-NotRented transitions ─────────────────────────────────────────

#[test]
fun expire_auction_stays_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);

    let s = lifecycle_state::expire_auction(unwrap_at_dutch(expiry));
    assert!(lifecycle_state::is_not_rented(&s));
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun retire_and_extract_returns_asset() {
    let mut sc = test_scenario::begin(@0xA);
    let asset = new_asset(sc.ctx());
    let expected_id = object::id(&asset);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(asset);
    let extracted = lifecycle_state::retire_and_extract(s);
    assert!(object::id(&extracted) == expected_id);
    destroy_asset(extracted);
    sc.end();
}

#[test]
fun retire_and_extract_from_at_dutch_works() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    destroy_asset(lifecycle_state::retire_and_extract(unwrap_at_dutch(expiry)));
    sc.end();
}

// ─── §4. Within-Rented transitions ────────────────────────────────────────────

#[test]
fun place_bid_stays_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    assert!(lifecycle_state::is_rented(&s));
    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun supersede_bid_returns_total_variant() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    let (s, rs) = lifecycle_state::supersede_bid(s, t3(), EXPIRY_MS);

    assert!(lifecycle_state::is_rented(&s));
    assert!(refund_state::is_total(&rs));
    refund_state::destroy_for_testing(rs);

    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T3, FEE_T3, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun accept_bid_with_remainder_returns_parcial() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    let (s, rs) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());

    assert!(lifecycle_state::is_rented(&s));
    assert!(refund_state::is_parcial(&rs));
    refund_state::destroy_for_testing(rs);

    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun accept_bid_with_zero_remainder_returns_nothing() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    let (s, rs) = lifecycle_state::accept_bid(s, OWNER_T1, FEE_T1, PHASE_MS, fake_escrow_id());

    assert!(refund_state::is_nothing(&rs));
    refund_state::destroy_for_testing(rs);

    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    teardown_expiry(expiry);
    sc.end();
}

// ─── §5. Abort paths ──────────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun start_rent_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::start_rent(s, t2(), PHASE_MS, fake_escrow_id());
    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun expire_tenure_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (expiry, rs) = lifecycle_state::expire_tenure(s, 0, 0, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun expire_auction_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::expire_auction(s);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun retire_and_extract_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    destroy_asset(lifecycle_state::retire_and_extract(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun place_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::place_bid(s, t1(), EXPIRY_MS);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun supersede_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, rs) = lifecycle_state::supersede_bid(s, t1(), EXPIRY_MS);
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::lifecycle_state)]
fun accept_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, rs) = lifecycle_state::accept_bid(s, 0, 0, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

// ─── §6. Terminal: retire_and_extract ────────────────────────────────────────

#[test]
fun retire_and_extract_yields_correct_asset() {
    // Verifies that the asset returned is the same object that was integrated.
    let mut sc = test_scenario::begin(@0xA);
    let asset = new_asset(sc.ctx());
    let expected_id = object::id(&asset);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(asset);
    let extracted = lifecycle_state::retire_and_extract(s);
    assert!(object::id(&extracted) == expected_id);
    destroy_asset(extracted);
    sc.end();
}

// ─── §7. Lifecycle composition ─────────────────────────────────────────────────

#[test]
fun full_cycle_no_bid() {
    // new → start_rent → expire_tenure → expire_auction → retire_and_extract
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    assert!(lifecycle_state::is_not_rented(&s));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    assert!(lifecycle_state::is_rented(&s));

    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    assert!(lifecycle_state::tenure_expiry_is_at_dutch(&expiry));
    assert!(refund_state::is_nothing(&rs));
    refund_state::destroy_for_testing(rs);

    let s = lifecycle_state::expire_auction(unwrap_at_dutch(expiry));
    assert!(lifecycle_state::is_not_rented(&s));

    retire_and_teardown(s);
    sc.end();
}

#[test]
fun full_cycle_with_bid_handover() {
    // new → start_rent(T1) → place_bid(T2) → accept_bid → expire_tenure(T2) → retire
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);

    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    assert!(refund_state::is_parcial(&rs1));
    refund_state::destroy_for_testing(rs1);

    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    assert!(refund_state::is_nothing(&rs2));
    refund_state::destroy_for_testing(rs2);

    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun full_cycle_with_supersede() {
    // start_rent(T1) → place_bid(T2) → supersede_bid(T3) → accept_bid → expire_tenure → retire
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);

    let (s, rs_displaced) = lifecycle_state::supersede_bid(s, t3(), EXPIRY_MS);
    assert!(refund_state::is_total(&rs_displaced));
    refund_state::destroy_for_testing(rs_displaced);

    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    assert!(refund_state::is_parcial(&rs1));
    refund_state::destroy_for_testing(rs1);

    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T3, FEE_T3, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    assert!(refund_state::is_nothing(&rs2));
    refund_state::destroy_for_testing(rs2);

    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun multi_rental_cycle_two_tenants_sequentially() {
    // T1 rents, expires, T2 rents, retires — verifies re-rent from AtDutch.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (expiry1, rs1) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    assert!(lifecycle_state::tenure_expiry_is_at_dutch(&expiry1));

    let s = lifecycle_state::start_rent(unwrap_at_dutch(expiry1), t2(), PHASE_MS, fake_escrow_id());
    assert!(lifecycle_state::is_rented(&s));
    let (expiry2, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);

    teardown_expiry(expiry2);
    sc.end();
}

// ─── §8. View accessors ───────────────────────────────────────────────────────

#[test]
fun accessors_in_rented_occupied() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());

    assert!(lifecycle_state::is_rented(&s));
    assert!(!lifecycle_state::is_not_rented(&s));
    assert!(!lifecycle_state::is_retiring(&s));
    assert!(lifecycle_state::is_a_state_handover_open(&s));
    assert!(!lifecycle_state::is_a_state_idle(&s));
    assert!(!lifecycle_state::is_a_state_at_dutch(&s));
    assert!(!lifecycle_state::is_a_state_handover_confirmed(&s));
    assert!(!lifecycle_state::is_a_state_retired(&s));
    assert!(!lifecycle_state::is_t_state_demand(&s));
    assert_eq!(lifecycle_state::phase_start_ms(&s), PHASE_MS);
    assert_eq!(lifecycle_state::current_stake_value(&s), STAKE_T1);
    assert_eq!(lifecycle_state::current_cap_id(&s), cap_t1());
    assert_eq!(lifecycle_state::current_addr(&s), ADDR_T1);

    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun accessors_in_rented_demand() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);

    assert!(lifecycle_state::is_t_state_demand(&s));
    assert!(lifecycle_state::is_a_state_handover_confirmed(&s));
    assert_eq!(lifecycle_state::handover_countdown_expiry_ms(&s), EXPIRY_MS);
    assert_eq!(lifecycle_state::current_stake_value(&s), STAKE_T1);
    assert_eq!(lifecycle_state::pending_stake_value(&s), STAKE_T2);
    assert_eq!(lifecycle_state::pending_cap_id(&s), cap_t2());
    assert_eq!(lifecycle_state::pending_addr(&s), ADDR_T2);

    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    let (expiry, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    teardown_expiry(expiry);
    sc.end();
}

#[test]
fun accessors_in_not_rented_at_dutch() {
    // AtDutch LifecycleState: phase_start and last_acq_price visible.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (expiry, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);

    let s = unwrap_at_dutch(expiry);
    assert!(lifecycle_state::is_not_rented(&s));
    assert!(lifecycle_state::is_a_state_at_dutch(&s));
    assert!(!lifecycle_state::is_retiring(&s));
    assert_eq!(lifecycle_state::phase_start_ms(&s), BOUNDARY_MS);
    assert_eq!(lifecycle_state::last_acq_price_of_at_dutch(&s), LAST_ACQ_PRICE);

    retire_and_teardown(s);
    sc.end();
}

#[test]
fun accessors_in_not_rented_idle() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    assert!(lifecycle_state::is_not_rented(&s));
    assert!(lifecycle_state::is_a_state_idle(&s));
    assert!(!lifecycle_state::is_retiring(&s));
    assert!(!lifecycle_state::is_t_state_demand(&s));

    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::asset_state)]
fun phase_start_ms_aborts_on_idle() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let _ = lifecycle_state::phase_start_ms(&s);
    retire_and_teardown(s);
    sc.end();
}
