// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenant_state_tests;

use std::unit_test::assert_eq;
use sui::balance::{Self, Balance};
use usufruct::tenant_state::{Self, Tenant};

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

fun t1(): Tenant<TEST_COIN> { tenant_state::new_tenant(cap_t1(), ADDR_T1, stake(STAKE_T1)) }
fun t2(): Tenant<TEST_COIN> { tenant_state::new_tenant(cap_t2(), ADDR_T2, stake(STAKE_T2)) }
fun t3(): Tenant<TEST_COIN> { tenant_state::new_tenant(cap_t3(), ADDR_T3, stake(STAKE_T3)) }

fun consume_tenant(t: Tenant<TEST_COIN>) {
    let (_cap_id, _addr, b) = tenant_state::unbundle(t);
    balance::destroy_for_testing(b);
}

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
    assert_eq!(tenant_state::cap_id(&t), cap_t1());
    assert_eq!(tenant_state::addr(&t), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&t), STAKE_T1);
    consume_tenant(t);
    tenant_state::consume_absence(s);
}

#[test]
fun demand_creates_demand_with_t1_t2() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    assert!(tenant_state::is_demand(&s));

    // reoccupy returns t1 (incumbent), promotes t2 to current
    let (s, incumbent) = tenant_state::reoccupy(s);
    assert_eq!(tenant_state::cap_id(&incumbent), cap_t1());
    assert_eq!(tenant_state::stake_value(&incumbent), STAKE_T1);
    consume_tenant(incumbent);

    // vacate now returns t2 (the promoted one)
    let (s, promoted) = tenant_state::vacate(s);
    assert_eq!(tenant_state::cap_id(&promoted), cap_t2());
    assert_eq!(tenant_state::stake_value(&promoted), STAKE_T2);
    consume_tenant(promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun redemand_replaces_t2_returns_old_t2() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, displaced) = tenant_state::redemand(s, t3(), 2_000);
    assert!(tenant_state::is_demand(&s));

    // Displaced is the old t2 (T2), not the new one (T3)
    assert_eq!(tenant_state::cap_id(&displaced), cap_t2());
    assert_eq!(tenant_state::addr(&displaced), ADDR_T2);
    assert_eq!(tenant_state::stake_value(&displaced), STAKE_T2);
    consume_tenant(displaced);

    // The new t2 (T3) is what reoccupy will eventually promote
    let (s, t1_out) = tenant_state::reoccupy(s);
    consume_tenant(t1_out);
    let (s, t3_promoted) = tenant_state::vacate(s);
    assert_eq!(tenant_state::cap_id(&t3_promoted), cap_t3());
    consume_tenant(t3_promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun reoccupy_promotes_t2_returns_old_t1() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, departing) = tenant_state::reoccupy(s);
    assert!(tenant_state::is_occupied(&s));

    // Departing is the old t1 (T1)
    assert_eq!(tenant_state::cap_id(&departing), cap_t1());
    assert_eq!(tenant_state::addr(&departing), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&departing), STAKE_T1);
    consume_tenant(departing);

    // The new t1 is the promoted t2 (T2)
    let (s, promoted) = tenant_state::vacate(s);
    assert_eq!(tenant_state::cap_id(&promoted), cap_t2());
    consume_tenant(promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun vacate_returns_t1_yields_absence() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    assert!(tenant_state::is_absence(&s));
    assert_eq!(tenant_state::cap_id(&out), cap_t1());
    assert_eq!(tenant_state::addr(&out), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&out), STAKE_T1);
    consume_tenant(out);
    tenant_state::consume_absence(s);
}

// ─── §3. Transitions — abort paths ─────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun occupy_aborts_from_occupied() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::occupy(s, t2());
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun occupy_aborts_from_demand() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let s = tenant_state::occupy(s, t3());
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun demand_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let s = tenant_state::demand(s, t1(), 1_000);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun demand_aborts_from_demand() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let s = tenant_state::demand(s, t3(), 1_000);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun redemand_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let (s, t) = tenant_state::redemand(s, t1(), 2_000);
    consume_tenant(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun redemand_aborts_from_occupied() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, t) = tenant_state::redemand(s, t2(), 2_000);
    consume_tenant(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun reoccupy_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let (s, t) = tenant_state::reoccupy(s);
    consume_tenant(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun reoccupy_aborts_from_occupied() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, t) = tenant_state::reoccupy(s);
    consume_tenant(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun vacate_aborts_from_absence() {
    let s = tenant_state::absence<TEST_COIN>();
    let (s, t) = tenant_state::vacate(s);
    consume_tenant(t);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure(abort_code = tenant_state::EInvariantViolation, location = usufruct::tenant_state)]
fun vacate_aborts_from_demand() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, t) = tenant_state::vacate(s);
    consume_tenant(t);
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
    assert_eq!(tenant_state::cap_id(&t2_displaced), cap_t2());
    assert_eq!(tenant_state::addr(&t2_displaced), ADDR_T2);
    assert_eq!(tenant_state::stake_value(&t2_displaced), STAKE_T2);
    consume_tenant(t2_displaced);

    let (s, t1_departing) = tenant_state::reoccupy(s);
    // T1 departing — data preserved through occupy → demand → redemand → reoccupy
    assert_eq!(tenant_state::cap_id(&t1_departing), cap_t1());
    assert_eq!(tenant_state::addr(&t1_departing), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&t1_departing), STAKE_T1);
    consume_tenant(t1_departing);

    let (s, t3_final) = tenant_state::vacate(s);
    // T3 final — promoted from t2 to t1 and then vacated
    assert_eq!(tenant_state::cap_id(&t3_final), cap_t3());
    assert_eq!(tenant_state::addr(&t3_final), ADDR_T3);
    assert_eq!(tenant_state::stake_value(&t3_final), STAKE_T3);
    consume_tenant(t3_final);

    assert!(tenant_state::is_absence(&s));
    tenant_state::consume_absence(s);
}

// ─── §5. Identity preservation ────────────────────────────────────────────────

#[test]
fun redemand_preserves_t1_identity() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, displaced) = tenant_state::redemand(s, t3(), 2_000);
    consume_tenant(displaced);

    // After redemand, t1 inside Demand should still be T1 — only t2 swapped
    let (s, out_t1) = tenant_state::reoccupy(s);
    assert_eq!(tenant_state::cap_id(&out_t1), cap_t1());
    assert_eq!(tenant_state::addr(&out_t1), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&out_t1), STAKE_T1);
    consume_tenant(out_t1);

    let (s, t3_promoted) = tenant_state::vacate(s);
    consume_tenant(t3_promoted);
    tenant_state::consume_absence(s);
}

#[test]
fun reoccupy_t2_becomes_new_t1() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let s = tenant_state::demand(s, t2(), 1_000);
    let (s, t1_departing) = tenant_state::reoccupy(s);
    consume_tenant(t1_departing);

    // After reoccupy, the Occupied state's t1 should be the original T2
    let (s, promoted) = tenant_state::vacate(s);
    assert_eq!(tenant_state::cap_id(&promoted), cap_t2());
    assert_eq!(tenant_state::addr(&promoted), ADDR_T2);
    assert_eq!(tenant_state::stake_value(&promoted), STAKE_T2);
    consume_tenant(promoted);
    tenant_state::consume_absence(s);
}

// ─── §6. Destructor + accessors ───────────────────────────────────────────────

#[test]
fun unbundle_returns_components_matching_input() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    let (cap_id, addr, b) = tenant_state::unbundle(out);
    assert_eq!(cap_id, cap_t1());
    assert_eq!(addr, ADDR_T1);
    assert_eq!(balance::value(&b), STAKE_T1);
    balance::destroy_for_testing(b);
    tenant_state::consume_absence(s);
}

#[test]
fun accessors_read_without_consuming() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    // First read — accessors borrow, do not consume
    let _ = tenant_state::cap_id(&out);
    let _ = tenant_state::addr(&out);
    let _ = tenant_state::stake_value(&out);

    // Second read — out still usable
    assert_eq!(tenant_state::cap_id(&out), cap_t1());
    assert_eq!(tenant_state::addr(&out), ADDR_T1);
    assert_eq!(tenant_state::stake_value(&out), STAKE_T1);

    consume_tenant(out);
    tenant_state::consume_absence(s);
}

// ─── §7. split ────────────────────────────────────────────────────────────────

#[test]
fun split_partial_reduces_stake() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    let (out, separated) = tenant_state::split(out, 300);
    assert_eq!(tenant_state::stake_value(&out), STAKE_T1 - 300);
    assert_eq!(balance::value(&separated), 300);

    // Identity preserved through split: cap_id and addr untouched
    assert_eq!(tenant_state::cap_id(&out), cap_t1());
    assert_eq!(tenant_state::addr(&out), ADDR_T1);

    balance::destroy_for_testing(separated);
    consume_tenant(out);
    tenant_state::consume_absence(s);
}

#[test]
fun split_zero_leaves_stake_unchanged() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    let (out, separated) = tenant_state::split(out, 0);
    assert_eq!(tenant_state::stake_value(&out), STAKE_T1);
    assert_eq!(balance::value(&separated), 0);

    balance::destroy_for_testing(separated);
    consume_tenant(out);
    tenant_state::consume_absence(s);
}

#[test]
fun split_full_amount_leaves_zero_stake() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    let (out, separated) = tenant_state::split(out, STAKE_T1);
    assert_eq!(tenant_state::stake_value(&out), 0);
    assert_eq!(balance::value(&separated), STAKE_T1);

    balance::destroy_for_testing(separated);
    consume_tenant(out);
    tenant_state::consume_absence(s);
}

#[test]
fun split_chained_extracts_two_portions() {
    // Simulates the handover-finalize flow: peel owner_share + protocol_fee,
    // remainder ready for refund-via-unbundle.
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    let (out, owner_share)  = tenant_state::split(out, 600);
    let (out, protocol_fee) = tenant_state::split(out, 50);

    assert_eq!(balance::value(&owner_share),  600);
    assert_eq!(balance::value(&protocol_fee), 50);
    assert_eq!(tenant_state::stake_value(&out), STAKE_T1 - 650);

    balance::destroy_for_testing(owner_share);
    balance::destroy_for_testing(protocol_fee);
    consume_tenant(out);
    tenant_state::consume_absence(s);
}

#[test]
#[expected_failure]
fun split_more_than_stake_aborts() {
    let s = tenant_state::occupy(tenant_state::absence<TEST_COIN>(), t1());
    let (s, out) = tenant_state::vacate(s);

    let (out, separated) = tenant_state::split(out, STAKE_T1 + 1);

    balance::destroy_for_testing(separated);
    consume_tenant(out);
    tenant_state::consume_absence(s);
}
