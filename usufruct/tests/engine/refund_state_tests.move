// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::refund_state_tests;

use sui::balance;
use usufruct::{
    fee_message::{Self, FeeShare},
    owner_earning::{Self, OwnerEarnings},
    escrow_identity,
    refund_state,
    tenant_seat::{Self, TenantSeat},
    tenant_identity,
    tenant_cap,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TEST_COIN has drop {}

const ADDR_T1: address = @0xA1;

fun cap_t1(): ID { object::id_from_address(@0xCA1) }
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

fun mk_seat(amount: u64): TenantSeat<TEST_COIN> {
    tenant_seat::new<TEST_COIN>(tenant_cap::from_id(cap_t1()), ADDR_T1, balance::create_for_testing(amount))
}

fun fee_share(amount: u64): FeeShare<TEST_COIN> {
    fee_message::new_share(balance::create_for_testing<TEST_COIN>(amount), escrow_identity::new(fake_escrow_id()))
}

fun owner_earnings(amount: u64): OwnerEarnings<TEST_COIN> {
    owner_earning::new(balance::create_for_testing<TEST_COIN>(amount))
}

// ─── §1. Constructors → variant identity ──────────────────────────────────────

#[test]
fun nothing_constructs_nothing_variant() {
    let rs = refund_state::nothing<TEST_COIN>(fee_share(50), owner_earnings(450));
    assert!(refund_state::proj_is_nothing(&rs));
    assert!(!refund_state::proj_is_parcial(&rs));
    assert!(!refund_state::proj_is_total(&rs));
    refund_state::destroy_for_testing(rs);
}

#[test]
fun parcial_constructs_parcial_variant() {
    let rs = refund_state::parcial<TEST_COIN>(mk_seat(300), fee_share(50), owner_earnings(450));
    assert!(refund_state::proj_is_parcial(&rs));
    assert!(!refund_state::proj_is_nothing(&rs));
    assert!(!refund_state::proj_is_total(&rs));
    refund_state::destroy_for_testing(rs);
}

#[test]
fun total_constructs_total_variant() {
    let rs = refund_state::total<TEST_COIN>(mk_seat(1_000));
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
    let nothing = refund_state::nothing<TEST_COIN>(fee_share(10), owner_earnings(20));
    refund_state::destroy_for_testing(nothing);

    let parcial = refund_state::parcial<TEST_COIN>(mk_seat(100), fee_share(10), owner_earnings(20));
    refund_state::destroy_for_testing(parcial);

    let total = refund_state::total<TEST_COIN>(mk_seat(1_000));
    refund_state::destroy_for_testing(total);
}

// ─── §3. Identity preservation ────────────────────────────────────────────────

// The carried TenantIdentity (copy/drop/store) is read-only data flowed
// through the variants; using it before passing it in must not affect
// what the variant carries. This is structural — the test exists as
// a guard against future regression if TenantIdentity ever loses copy.
#[test]
fun identity_passed_into_variant_is_independent_of_caller_copy() {
    let seat = mk_seat(100);
    let id_copy = *tenant_seat::proj_identity(&seat);
    let _ = tenant_identity::proj_cap_identity(&id_copy);
    let rs = refund_state::parcial<TEST_COIN>(seat, fee_share(10), owner_earnings(20));
    refund_state::destroy_for_testing(rs);
}
