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
    lifecycle_state::{Self, LifecycleState},
    refund_state,
    tenant::{Self, Tenant},
    tenant_state,
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

// Conservation: owner + fee == stake for tenure-expiry / full-consumption flows.
// Picked as 90/10 to mirror protocol-rate distribution without coupling tests
// to the actual rate (which lives in policy modules).
const OWNER_T1: u64 = 900;
const FEE_T1:   u64 = 100;
const OWNER_T2: u64 = 1_800;
const FEE_T2:   u64 = 200;
const OWNER_T3: u64 = 2_700;
const FEE_T3:   u64 = 300;

// Partial-consumption parameters for accept_bid: owner + fee < stake leaves a
// non-zero remainder that triggers the Parcial branch.
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

/// Consume a NotRented state whose inner asset is already Retired.
fun teardown_retired(s: LifecycleState<TestAsset, TEST_COIN>) {
    let (a_state, t_state) = lifecycle_state::decompose_retired(s);
    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
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
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    assert!(lifecycle_state::is_rented(&s));
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun expire_tenure_returns_nothing_variant() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());

    assert!(lifecycle_state::is_not_rented(&s));
    assert!(refund_state::is_nothing(&rs));
    refund_state::destroy_for_testing(rs);

    retire_and_teardown(s);
    sc.end();
}

// ─── §3. Within-NotRented transitions ─────────────────────────────────────────

#[test]
fun expire_auction_stays_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);

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
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);

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
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    assert!(lifecycle_state::is_rented(&s));
    // Drain via accept_bid (Parcial: T1 had partial consumption) then expire_tenure (Nothing)
    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    retire_and_teardown(s);
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
    // Displaced t2 routed to RefundState::Total — full stake, no owner share, no fee
    assert!(refund_state::is_total(&rs));
    refund_state::destroy_for_testing(rs);

    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T3, FEE_T3, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun accept_bid_with_remainder_returns_parcial() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    // owner+fee < stake → remainder leftover → Parcial
    let (s, rs) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());

    assert!(lifecycle_state::is_rented(&s));
    assert!(refund_state::is_parcial(&rs));
    refund_state::destroy_for_testing(rs);

    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun accept_bid_with_zero_remainder_returns_nothing() {
    // When owner_amount + fee_amount == full stake → no remainder → Nothing variant.
    // Models the A8 spec edge case (used_credit == stake at handover).
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);
    // T1's full stake split into owner + fee — nothing left for remainder
    let (s, rs) = lifecycle_state::accept_bid(s, OWNER_T1, FEE_T1, PHASE_MS, fake_escrow_id());

    assert!(refund_state::is_nothing(&rs));
    refund_state::destroy_for_testing(rs);

    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    retire_and_teardown(s);
    sc.end();
}

// ─── §5. Abort paths ──────────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun start_rent_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::start_rent(s, t2(), PHASE_MS, fake_escrow_id());
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun expire_tenure_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, rs) = lifecycle_state::expire_tenure(s, 0, 0, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun expire_auction_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::expire_auction(s);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun retire_now_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
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
    let (s, rs) = lifecycle_state::supersede_bid(s, t1(), EXPIRY_MS);
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun accept_bid_aborts_from_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, rs) = lifecycle_state::accept_bid(s, 0, 0, PHASE_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun decompose_retired_aborts_from_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (a_state, t_state) = lifecycle_state::decompose_retired(s);
    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
    sc.end();
}

// ─── §6. Terminal: decompose_retired ──────────────────────────────────────────

#[test]
fun decompose_retired_yields_correct_sub_states() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::retire_now(s);
    let (a_state, t_state) = lifecycle_state::decompose_retired(s);

    assert!(asset_state::is_retired(&a_state));
    assert!(tenant_state::is_absence(&t_state));

    destroy_asset(asset_state::claim(a_state));
    tenant_state::consume_absence(t_state);
    sc.end();
}

// ─── §7. Lifecycle composition ─────────────────────────────────────────────────

#[test]
fun full_cycle_no_bid() {
    // new → start_rent → expire_tenure → expire_auction → retire_now → decompose
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    assert!(lifecycle_state::is_not_rented(&s));

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    assert!(lifecycle_state::is_rented(&s));

    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    assert!(lifecycle_state::is_not_rented(&s));
    assert!(refund_state::is_nothing(&rs));
    refund_state::destroy_for_testing(rs);

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

    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let s = lifecycle_state::place_bid(s, t2(), EXPIRY_MS);

    let (s, rs1) = lifecycle_state::accept_bid(s, PARTIAL_OWNER, PARTIAL_FEE, PHASE_MS, fake_escrow_id());
    assert!(refund_state::is_parcial(&rs1));
    refund_state::destroy_for_testing(rs1);

    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    assert!(refund_state::is_nothing(&rs2));
    refund_state::destroy_for_testing(rs2);

    retire_and_teardown(s);
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

    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T3, FEE_T3, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    assert!(refund_state::is_nothing(&rs2));
    refund_state::destroy_for_testing(rs2);

    retire_and_teardown(s);
    sc.end();
}

#[test]
fun multi_rental_cycle_two_tenants_sequentially() {
    // T1 rents, expires, T2 rents, retires — verifies re-rent from AtDutch.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));

    // First tenant
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (s, rs1) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs1);
    assert!(lifecycle_state::is_not_rented(&s)); // back to NotRented(AtDutch)

    // Second tenant takes over from AtDutch
    let s = lifecycle_state::start_rent(s, t2(), PHASE_MS, fake_escrow_id());
    assert!(lifecycle_state::is_rented(&s));
    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);

    retire_and_teardown(s);
    sc.end();
}

// ─── §8. View accessors ───────────────────────────────────────────────────────

#[test]
fun accessors_in_rented_occupied() {
    // Rented + Occupied: phase_start, current tenant data; flags off.
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

    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun accessors_in_rented_demand() {
    // Rented + Demand: pending tenant data and handover_countdown_expiry visible.
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
    let (s, rs2) = lifecycle_state::expire_tenure(s, OWNER_T2, FEE_T2, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs2);
    retire_and_teardown(s);
    sc.end();
}

#[test]
fun accessors_in_not_rented_at_dutch() {
    // NotRented{AtDutch}: phase_start_ms reads from the AtDutch slot
    // (stamped by expire_tenure with BOUNDARY_MS); last_acq_price visible.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);

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
    // Idle: variant predicates fire; no other accessors are valid here.
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
#[expected_failure(abort_code = asset_state::EInvariantViolation, location = usufruct::asset_state)]
fun phase_start_ms_aborts_on_idle() {
    // Idle has no phase in progress; phase_start_ms delegates to the
    // AtDutch accessor on asset_state, which aborts on Idle.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let _ = lifecycle_state::phase_start_ms(&s);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun handover_countdown_expiry_ms_aborts_in_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let _ = lifecycle_state::handover_countdown_expiry_ms(&s);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun current_stake_value_aborts_in_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let _ = lifecycle_state::current_stake_value(&s);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun pending_stake_value_aborts_in_occupied() {
    // Occupied has no pending bid — the underlying tenant_state::pending aborts.
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    let _ = lifecycle_state::pending_stake_value(&s);
    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

// ─── §9. set_retiring ─────────────────────────────────────────────────────────

#[test]
fun set_retiring_lifts_flag_in_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());
    assert!(!lifecycle_state::is_retiring(&s));

    let s = lifecycle_state::set_retiring(s);
    assert!(lifecycle_state::is_retiring(&s));
    assert!(lifecycle_state::is_rented(&s));

    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun set_retiring_aborts_in_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::set_retiring(s);
    retire_and_teardown(s);
    sc.end();
}

// ─── §10. give / give_back ────────────────────────────────────────────────────

#[test]
fun give_extracts_then_give_back_restores_in_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let s = lifecycle_state::start_rent(s, t1(), PHASE_MS, fake_escrow_id());

    let (s, asset_out, receipt) = lifecycle_state::give(s);
    assert!(lifecycle_state::is_rented(&s));

    let s = lifecycle_state::give_back(s, asset_out, receipt);
    assert!(lifecycle_state::is_rented(&s));

    let (s, rs) = lifecycle_state::expire_tenure(s, OWNER_T1, FEE_T1, LAST_ACQ_PRICE, BOUNDARY_MS, fake_escrow_id());
    refund_state::destroy_for_testing(rs);
    retire_and_teardown(s);
    sc.end();
}

#[test]
#[expected_failure(abort_code = lifecycle_state::EInvariantViolation, location = usufruct::lifecycle_state)]
fun give_aborts_in_not_rented() {
    let mut sc = test_scenario::begin(@0xA);
    let s = lifecycle_state::new<TestAsset, TEST_COIN>(new_asset(sc.ctx()));
    let (s, asset_out, receipt) = lifecycle_state::give(s);
    // Unreachable in expected_failure path; satisfy the type checker.
    destroy_asset(asset_out);
    asset::destroy_receipt_for_testing(receipt);
    retire_and_teardown(s);
    sc.end();
}
