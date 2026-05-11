// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::refund_state_tests;

use sui::balance;
use usufruct::{
    fee_message::{Self, FeeShare},
    owner::{Self, OwnerEarnings},
    escrow_identity,
    refund_state,
    tenant::{Self, TenantIdentity, TenantStake},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const ADDR_T1: address = @0xA1;

fun cap_t1(): ID         { object::id_from_address(@0xCA1) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

/// Build a fresh `(TenantIdentity, TenantStake)` pair via the tenant
/// constructor + unbundle — the only public path to producing these
/// types from tests.
fun id_and_stake(amount: u64): (TenantIdentity, TenantStake<TEST_COIN>) {
    let t = tenant::new<TEST_COIN>(cap_t1(), ADDR_T1, balance::create_for_testing(amount));
    tenant::unbundle(t)
}

fun fee_share(amount: u64): FeeShare<TEST_COIN> {
    fee_message::new_share(balance::create_for_testing<TEST_COIN>(amount), escrow_identity::new(fake_escrow_id()))
}

fun owner_earnings(amount: u64): OwnerEarnings<TEST_COIN> {
    owner::new_earnings(balance::create_for_testing<TEST_COIN>(amount))
}

// ─── §1. Constructors → variant identity ──────────────────────────────────────

#[test]
fun nothing_constructs_nothing_variant() {
    let (_, stake) = id_and_stake(0);
    tenant::destroy_empty_stake(stake);
    let rs = refund_state::nothing<TEST_COIN>(fee_share(50), owner_earnings(450));
    assert!(refund_state::proj_is_nothing(&rs));
    assert!(!refund_state::proj_is_parcial(&rs));
    assert!(!refund_state::proj_is_total(&rs));
    refund_state::destroy_for_testing(rs);
}

#[test]
fun parcial_constructs_parcial_variant() {
    let (id, stake) = id_and_stake(300);
    let rs = refund_state::parcial<TEST_COIN>(id, stake, fee_share(50), owner_earnings(450));
    assert!(refund_state::proj_is_parcial(&rs));
    assert!(!refund_state::proj_is_nothing(&rs));
    assert!(!refund_state::proj_is_total(&rs));
    refund_state::destroy_for_testing(rs);
}

#[test]
fun total_constructs_total_variant() {
    let (id, stake) = id_and_stake(1_000);
    let rs = refund_state::total<TEST_COIN>(id, stake);
    assert!(refund_state::proj_is_total(&rs));
    assert!(!refund_state::proj_is_nothing(&rs));
    assert!(!refund_state::proj_is_parcial(&rs));
    refund_state::destroy_for_testing(rs);
}

// ─── §2. Hot-potato consumption shape ──────────────────────────────────────────

// The three variants must each be consumable by an exhaustive match.
// The compiler enforces hot-potato semantics structurally — this test
// exercises the shape and ensures destroy_for_testing handles all
// three arms without leaks.
#[test]
fun destroy_for_testing_handles_all_three_variants() {
    let (_, stake_n) = id_and_stake(0);
    tenant::destroy_empty_stake(stake_n);
    let nothing = refund_state::nothing<TEST_COIN>(fee_share(10), owner_earnings(20));
    refund_state::destroy_for_testing(nothing);

    let (id_p, stake_p) = id_and_stake(100);
    let parcial = refund_state::parcial<TEST_COIN>(id_p, stake_p, fee_share(10), owner_earnings(20));
    refund_state::destroy_for_testing(parcial);

    let (id_t, stake_t) = id_and_stake(1_000);
    let total = refund_state::total<TEST_COIN>(id_t, stake_t);
    refund_state::destroy_for_testing(total);
}

// ─── §3. Identity preservation ────────────────────────────────────────────────

// The carried TenantIdentity (copy/drop/store) is read-only data flowed
// through the variants; using it before passing it in must not affect
// what the variant carries. This is structural — the test exists as
// a guard against future regression if TenantIdentity ever loses copy.
#[test]
fun identity_passed_into_variant_is_independent_of_caller_copy() {
    let (id, stake) = id_and_stake(100);
    let id_copy_before = id;
    let _ = tenant::proj_cap_id(&id_copy_before);
    let rs = refund_state::parcial<TEST_COIN>(id, stake, fee_share(10), owner_earnings(20));
    refund_state::destroy_for_testing(rs);
}
