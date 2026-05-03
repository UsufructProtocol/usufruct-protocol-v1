// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenant_tests;

use std::unit_test::assert_eq;
use sui::balance::{Self, Balance};
use usufruct::tenant::{Self, Tenant};

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

fun consume_tenant(t: Tenant<TEST_COIN>) {
    let (_cap_id, _addr, b) = tenant::unbundle(t);
    balance::destroy_for_testing(b);
}

// ─── §1. Constructor ───────────────────────────────────────────────────────────

#[test]
fun absence_returns_absent_variant() {
    let s = tenant::absence<TEST_COIN>();
    assert!(tenant::is_absence(&s));
    tenant::consume_absence(s);
}

// ─── §2. Transitions — happy paths ─────────────────────────────────────────────

#[test]
fun occupy_creates_occupied_with_t1() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    assert!(tenant::is_occupied(&s));

    let (s, t1) = tenant::vacate(s);
    assert_eq!(tenant::cap_id(&t1), cap_t1());
    assert_eq!(tenant::addr(&t1), ADDR_T1);
    assert_eq!(tenant::stake_value(&t1), STAKE_T1);
    consume_tenant(t1);
    tenant::consume_absence(s);
}

#[test]
fun demand_creates_demand_with_t1_t2() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    assert!(tenant::is_demand(&s));

    // reoccupy returns t1 (incumbent), promotes t2 to current
    let (s, t1) = tenant::reoccupy(s);
    assert_eq!(tenant::cap_id(&t1), cap_t1());
    assert_eq!(tenant::stake_value(&t1), STAKE_T1);
    consume_tenant(t1);

    // vacate now returns t2 (the promoted one)
    let (s, t2) = tenant::vacate(s);
    assert_eq!(tenant::cap_id(&t2), cap_t2());
    assert_eq!(tenant::stake_value(&t2), STAKE_T2);
    consume_tenant(t2);
    tenant::consume_absence(s);
}

#[test]
fun redemand_replaces_t2_returns_old_t2() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let (s, displaced) = tenant::redemand(s, cap_t3(), ADDR_T3, stake(STAKE_T3));
    assert!(tenant::is_demand(&s));

    // Displaced is the old t2 (T2), not the new one (T3)
    assert_eq!(tenant::cap_id(&displaced), cap_t2());
    assert_eq!(tenant::addr(&displaced), ADDR_T2);
    assert_eq!(tenant::stake_value(&displaced), STAKE_T2);
    consume_tenant(displaced);

    // The new t2 (T3) is what reoccupy will eventually promote
    let (s, t1) = tenant::reoccupy(s);
    consume_tenant(t1);
    let (s, t3_promoted) = tenant::vacate(s);
    assert_eq!(tenant::cap_id(&t3_promoted), cap_t3());
    consume_tenant(t3_promoted);
    tenant::consume_absence(s);
}

#[test]
fun reoccupy_promotes_t2_returns_old_t1() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let (s, departing) = tenant::reoccupy(s);
    assert!(tenant::is_occupied(&s));

    // Departing is the old t1 (T1)
    assert_eq!(tenant::cap_id(&departing), cap_t1());
    assert_eq!(tenant::addr(&departing), ADDR_T1);
    assert_eq!(tenant::stake_value(&departing), STAKE_T1);
    consume_tenant(departing);

    // The new t1 is the promoted t2 (T2)
    let (s, promoted) = tenant::vacate(s);
    assert_eq!(tenant::cap_id(&promoted), cap_t2());
    consume_tenant(promoted);
    tenant::consume_absence(s);
}

#[test]
fun vacate_returns_t1_yields_absence() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let (s, t1) = tenant::vacate(s);

    assert!(tenant::is_absence(&s));
    assert_eq!(tenant::cap_id(&t1), cap_t1());
    assert_eq!(tenant::addr(&t1), ADDR_T1);
    assert_eq!(tenant::stake_value(&t1), STAKE_T1);
    consume_tenant(t1);
    tenant::consume_absence(s);
}

// ─── §3. Transitions — abort paths ─────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = tenant::ENotAbsent, location = usufruct::tenant)]
fun occupy_aborts_from_occupied() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::occupy(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotAbsent, location = usufruct::tenant)]
fun occupy_aborts_from_demand() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let s = tenant::occupy(s, cap_t3(), ADDR_T3, stake(STAKE_T3));
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotOccupied, location = usufruct::tenant)]
fun demand_aborts_from_absence() {
    let s = tenant::absence<TEST_COIN>();
    let s = tenant::demand(s, cap_t1(), ADDR_T1, stake(STAKE_T1));
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotOccupied, location = usufruct::tenant)]
fun demand_aborts_from_demand() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let s = tenant::demand(s, cap_t3(), ADDR_T3, stake(STAKE_T3));
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotDemand, location = usufruct::tenant)]
fun redemand_aborts_from_absence() {
    let s = tenant::absence<TEST_COIN>();
    let (s, t) = tenant::redemand(s, cap_t1(), ADDR_T1, stake(STAKE_T1));
    consume_tenant(t);
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotDemand, location = usufruct::tenant)]
fun redemand_aborts_from_occupied() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let (s, t) = tenant::redemand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    consume_tenant(t);
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotDemand, location = usufruct::tenant)]
fun reoccupy_aborts_from_absence() {
    let s = tenant::absence<TEST_COIN>();
    let (s, t) = tenant::reoccupy(s);
    consume_tenant(t);
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotDemand, location = usufruct::tenant)]
fun reoccupy_aborts_from_occupied() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let (s, t) = tenant::reoccupy(s);
    consume_tenant(t);
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotOccupied, location = usufruct::tenant)]
fun vacate_aborts_from_absence() {
    let s = tenant::absence<TEST_COIN>();
    let (s, t) = tenant::vacate(s);
    consume_tenant(t);
    tenant::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant::ENotOccupied, location = usufruct::tenant)]
fun vacate_aborts_from_demand() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let (s, t) = tenant::vacate(s);
    consume_tenant(t);
    tenant::consume_absence(s);
}

// ─── §4. Lifecycle composition ────────────────────────────────────────────────

#[test]
fun full_cycle_absence_to_absence_preserves_data() {
    // absence → occupy(T1) → demand(T2) → redemand(T3) → reoccupy → vacate → absence
    let s = tenant::absence<TEST_COIN>();
    let s = tenant::occupy(s, cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let (s, t2_displaced) = tenant::redemand(s, cap_t3(), ADDR_T3, stake(STAKE_T3));

    // T2 displaced — its data intact through the demand → redemand traversal
    assert_eq!(tenant::cap_id(&t2_displaced), cap_t2());
    assert_eq!(tenant::addr(&t2_displaced), ADDR_T2);
    assert_eq!(tenant::stake_value(&t2_displaced), STAKE_T2);
    consume_tenant(t2_displaced);

    let (s, t1_departing) = tenant::reoccupy(s);
    // T1 departing — data preserved through occupy → demand → redemand → reoccupy
    assert_eq!(tenant::cap_id(&t1_departing), cap_t1());
    assert_eq!(tenant::addr(&t1_departing), ADDR_T1);
    assert_eq!(tenant::stake_value(&t1_departing), STAKE_T1);
    consume_tenant(t1_departing);

    let (s, t3_final) = tenant::vacate(s);
    // T3 final — promoted from t2 to t1 and then vacated
    assert_eq!(tenant::cap_id(&t3_final), cap_t3());
    assert_eq!(tenant::addr(&t3_final), ADDR_T3);
    assert_eq!(tenant::stake_value(&t3_final), STAKE_T3);
    consume_tenant(t3_final);

    assert!(tenant::is_absence(&s));
    tenant::consume_absence(s);
}

// ─── §5. Identity preservation ────────────────────────────────────────────────

#[test]
fun redemand_preserves_t1_identity() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let (s, _displaced) = tenant::redemand(s, cap_t3(), ADDR_T3, stake(STAKE_T3));
    consume_tenant(_displaced);

    // After redemand, t1 inside Demand should still be T1 — only t2 swapped
    let (s, t1) = tenant::reoccupy(s);
    assert_eq!(tenant::cap_id(&t1), cap_t1());
    assert_eq!(tenant::addr(&t1), ADDR_T1);
    assert_eq!(tenant::stake_value(&t1), STAKE_T1);
    consume_tenant(t1);

    let (s, t3_promoted) = tenant::vacate(s);
    consume_tenant(t3_promoted);
    tenant::consume_absence(s);
}

#[test]
fun reoccupy_t2_becomes_new_t1() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let s = tenant::demand(s, cap_t2(), ADDR_T2, stake(STAKE_T2));
    let (s, t1_departing) = tenant::reoccupy(s);
    consume_tenant(t1_departing);

    // After reoccupy, the Occupied state's t1 should be the original T2
    let (s, promoted) = tenant::vacate(s);
    assert_eq!(tenant::cap_id(&promoted), cap_t2());
    assert_eq!(tenant::addr(&promoted), ADDR_T2);
    assert_eq!(tenant::stake_value(&promoted), STAKE_T2);
    consume_tenant(promoted);
    tenant::consume_absence(s);
}

// ─── §6. Destructor + accessors ───────────────────────────────────────────────

#[test]
fun unbundle_returns_components_matching_input() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let (s, t1) = tenant::vacate(s);

    let (cap_id, addr, b) = tenant::unbundle(t1);
    assert_eq!(cap_id, cap_t1());
    assert_eq!(addr, ADDR_T1);
    assert_eq!(balance::value(&b), STAKE_T1);
    balance::destroy_for_testing(b);
    tenant::consume_absence(s);
}

#[test]
fun accessors_read_without_consuming() {
    let s = tenant::occupy(tenant::absence<TEST_COIN>(), cap_t1(), ADDR_T1, stake(STAKE_T1));
    let (s, t1) = tenant::vacate(s);

    // First read — accessors borrow, do not consume
    let _ = tenant::cap_id(&t1);
    let _ = tenant::addr(&t1);
    let _ = tenant::stake_value(&t1);

    // Second read — t1 still usable
    assert_eq!(tenant::cap_id(&t1), cap_t1());
    assert_eq!(tenant::addr(&t1), ADDR_T1);
    assert_eq!(tenant::stake_value(&t1), STAKE_T1);

    consume_tenant(t1);
    tenant::consume_absence(s);
}
