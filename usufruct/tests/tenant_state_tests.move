// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenant_state_tests;

use std::unit_test::assert_eq;
use sui::balance::{Self, Balance};
use usufruct::{
    tenant::{Self, Tenant},
    tenant_state,
    unreachable,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const ADDR_T1: address = @0xA1;
const ADDR_T2: address = @0xA2;
const ADDR_T3: address = @0xA3;

const STAKE_T1: u64 = 1_000;
const STAKE_T2: u64 = 2_000;
const STAKE_T3: u64 = 3_000;

fun cap_t1(): ID { object::id_from_address(@0xCA1) }
fun cap_t2(): ID { object::id_from_address(@0xCA2) }
fun cap_t3(): ID { object::id_from_address(@0xCA3) }

fun stake(amount: u64): Balance<TEST_COIN> {
    balance::create_for_testing<TEST_COIN>(amount)
}

fun t1(): Tenant<TEST_COIN> { tenant::new(cap_t1(), ADDR_T1, stake(STAKE_T1)) }
fun t2(): Tenant<TEST_COIN> { tenant::new(cap_t2(), ADDR_T2, stake(STAKE_T2)) }
fun t3(): Tenant<TEST_COIN> { tenant::new(cap_t3(), ADDR_T3, stake(STAKE_T3)) }

fun cap_id_of(t: &Tenant<TEST_COIN>):  ID      { tenant::id_cap_id(tenant::identity(t)) }
fun addr_of(t: &Tenant<TEST_COIN>):    address { tenant::id_address(tenant::identity(t)) }

// ─── §1. Constructor ───────────────────────────────────────────────────────────

#[test]
fun absence_returns_absent_variant() {
    let s = tenant_state::absence<TEST_COIN>();
    assert!(tenant_state::is_absence(&s));
    tenant_state::consume_absence(s);
}

// ─── §2. Transitions — happy paths ─────────────────────────────────────────────

#[test]
fun occupy_creates_occupied_with_t1() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    assert!(tenant_state::is_occupied(&s));

    let (s, t) = tenant_state::vacate(s);
    assert_eq!(cap_id_of(&t),           cap_t1());
    assert_eq!(addr_of(&t),             ADDR_T1);
    assert_eq!(tenant::stake_value(&t), STAKE_T1);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

#[test]
fun demand_creates_demand_with_t1_t2() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    assert!(tenant_state::is_demand(&s));

    // reoccupy returns t1 (incumbent), promotes t2 to current
    let (s, incumbent) = tenant_state::reoccupy(s);
    assert_eq!(cap_id_of(&incumbent),           cap_t1());
    assert_eq!(tenant::stake_value(&incumbent), STAKE_T1);
    tenant::destroy_for_testing(incumbent);

    // vacate now returns t2 (the promoted one)
    let (s, promoted) = tenant_state::vacate(s);
    assert_eq!(cap_id_of(&promoted),           cap_t2());
    assert_eq!(tenant::stake_value(&promoted), STAKE_T2);
    tenant::destroy_for_testing(promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun redemand_replaces_t2_returns_old_t2() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, displaced) = tenant_state::redemand(s, t3(), 2_000);
    assert!(tenant_state::is_demand(&s));

    // Displaced is the old t2 (T2), not the new one (T3)
    assert_eq!(cap_id_of(&displaced),           cap_t2());
    assert_eq!(addr_of(&displaced),             ADDR_T2);
    assert_eq!(tenant::stake_value(&displaced), STAKE_T2);
    tenant::destroy_for_testing(displaced);

    // The new t2 (T3) is what reoccupy will eventually promote
    let (s, t1_out) = tenant_state::reoccupy(s);
    tenant::destroy_for_testing(t1_out);
    let (s, t3_promoted) = tenant_state::vacate(s);
    assert_eq!(cap_id_of(&t3_promoted), cap_t3());
    tenant::destroy_for_testing(t3_promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun reoccupy_promotes_t2_returns_old_t1() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, departing) = tenant_state::reoccupy(s);
    assert!(tenant_state::is_occupied(&s));

    // Departing is the old t1 (T1)
    assert_eq!(cap_id_of(&departing),           cap_t1());
    assert_eq!(addr_of(&departing),             ADDR_T1);
    assert_eq!(tenant::stake_value(&departing), STAKE_T1);
    tenant::destroy_for_testing(departing);

    // The new t1 is the promoted t2 (T2)
    let (s, promoted) = tenant_state::vacate(s);
    assert_eq!(cap_id_of(&promoted), cap_t2());
    tenant::destroy_for_testing(promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun vacate_returns_t1_yields_absence() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    assert!(tenant_state::is_absence(&s));
    assert_eq!(cap_id_of(&out),           cap_t1());
    assert_eq!(addr_of(&out),             ADDR_T1);
    assert_eq!(tenant::stake_value(&out), STAKE_T1);
    tenant::destroy_for_testing(out);
    tenant_state::consume_absence(s);
}

// ─── §3. Transitions — abort paths ─────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun occupy_aborts_from_occupied() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::occupy(s, t2());
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun occupy_aborts_from_demand() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let s = tenant_state::occupy(s, t3());
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun demand_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let s = tenant_state::demand(s, t1(), 1_000);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun demand_aborts_from_demand() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let s = tenant_state::demand(s, t3(), 1_000);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun redemand_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let (s, t) = tenant_state::redemand(s, t1(), 2_000);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun redemand_aborts_from_occupied() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, t) = tenant_state::redemand(s, t2(), 2_000);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun reoccupy_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let (s, t) = tenant_state::reoccupy(s);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun reoccupy_aborts_from_occupied() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, t) = tenant_state::reoccupy(s);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun vacate_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let (s, t) = tenant_state::vacate(s);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::tenant_state)]
fun vacate_aborts_from_demand() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, t) = tenant_state::vacate(s);
    tenant::destroy_for_testing(t);
    tenant_state::consume_absence(s);
}

// ─── §4. Lifecycle composition ────────────────────────────────────────────────

#[test]
fun full_cycle_absence_to_absence_preserves_data() {
    // absence → occupy(T1) → demand(T2) → redemand(T3) → reoccupy → vacate → absence
    let s = tenant_state::absence<TEST_COIN>();
    let s = tenant_state::occupy(s, t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, t2_displaced) = tenant_state::redemand(s, t3(), 2_000);

    // T2 displaced — its data intact through the demand → redemand traversal
    assert_eq!(cap_id_of(&t2_displaced),           cap_t2());
    assert_eq!(addr_of(&t2_displaced),             ADDR_T2);
    assert_eq!(tenant::stake_value(&t2_displaced), STAKE_T2);
    tenant::destroy_for_testing(t2_displaced);

    let (s, t1_departing) = tenant_state::reoccupy(s);
    // T1 departing — data preserved through occupy → demand → redemand → reoccupy
    assert_eq!(cap_id_of(&t1_departing),           cap_t1());
    assert_eq!(addr_of(&t1_departing),             ADDR_T1);
    assert_eq!(tenant::stake_value(&t1_departing), STAKE_T1);
    tenant::destroy_for_testing(t1_departing);

    let (s, t3_final) = tenant_state::vacate(s);
    // T3 final — promoted from t2 to t1 and then vacated
    assert_eq!(cap_id_of(&t3_final),           cap_t3());
    assert_eq!(addr_of(&t3_final),             ADDR_T3);
    assert_eq!(tenant::stake_value(&t3_final), STAKE_T3);
    tenant::destroy_for_testing(t3_final);

    assert!(tenant_state::is_absence(&s));
    tenant_state::consume_absence(s);
}

// ─── §5. Identity preservation ────────────────────────────────────────────────

#[test]
fun redemand_preserves_t1_identity() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, displaced) = tenant_state::redemand(s, t3(), 2_000);
    tenant::destroy_for_testing(displaced);

    // After redemand, t1 inside Demand should still be T1 — only t2 swapped
    let (s, out_t1) = tenant_state::reoccupy(s);
    assert_eq!(cap_id_of(&out_t1),           cap_t1());
    assert_eq!(addr_of(&out_t1),             ADDR_T1);
    assert_eq!(tenant::stake_value(&out_t1), STAKE_T1);
    tenant::destroy_for_testing(out_t1);

    let (s, t3_promoted) = tenant_state::vacate(s);
    tenant::destroy_for_testing(t3_promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun reoccupy_t2_becomes_new_t1() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, t1_departing) = tenant_state::reoccupy(s);
    tenant::destroy_for_testing(t1_departing);

    // After reoccupy, the Occupied state's t1 should be the original T2
    let (s, promoted) = tenant_state::vacate(s);
    assert_eq!(cap_id_of(&promoted),           cap_t2());
    assert_eq!(addr_of(&promoted),             ADDR_T2);
    assert_eq!(tenant::stake_value(&promoted), STAKE_T2);
    tenant::destroy_for_testing(promoted);
    tenant_state::consume_absence(s);
}
