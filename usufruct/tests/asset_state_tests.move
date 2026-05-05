// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_state_tests;

use sui::test_scenario;
use usufruct::{asset, asset_state, unreachable};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

/// Minimal key+store object used as the rentable asset in tests.
public struct TestAsset has key, store { id: UID }

fun new_asset(ctx: &mut TxContext): TestAsset {
    TestAsset { id: object::new(ctx) }
}

fun destroy_asset(a: TestAsset) {
    let TestAsset { id } = a;
    object::delete(id);
}

const PRICE:          u64 = 1_000;
const PHASE_START_MS: u64 = 5_000;
fun fake_escrow_id(): ID { object::id_from_address(@0xEC) }

// ─── §1. Constructor ───────────────────────────────────────────────────────────

#[test]
fun new_returns_idle_with_asset() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::new(new_asset(sc.ctx()));
    assert!(asset_state::is_idle(&s));
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(s)));
    sc.end();
}

// ─── §2. Transitions — happy paths ─────────────────────────────────────────────

#[test]
fun rent_from_idle_opens_handover() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id());
    assert!(asset_state::is_handover_open(&s));
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s, PRICE, PHASE_START_MS)))));
    sc.end();
}

#[test]
fun rent_from_at_dutch_opens_handover() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::new(new_asset(sc.ctx()));
    let s = asset_state::expire(asset_state::rent(s, fake_escrow_id()), PRICE, PHASE_START_MS);
    assert!(asset_state::is_at_dutch(&s));
    let s = asset_state::rent(s, fake_escrow_id());
    assert!(asset_state::is_handover_open(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s, PRICE, PHASE_START_MS)))));
    sc.end();
}

#[test]
fun bid_promotes_to_confirmed() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::bid(asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id()));
    assert!(asset_state::is_handover_confirmed(&s));
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(
            asset_state::handover(s), PRICE, PHASE_START_MS)))));
    sc.end();
}

#[test]
fun handover_returns_to_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::handover(
        asset_state::bid(asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id())));
    assert!(asset_state::is_handover_open(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s, PRICE, PHASE_START_MS)))));
    sc.end();
}

#[test]
fun expire_from_open_to_dutch() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::expire(
        asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id()), PRICE, PHASE_START_MS);
    assert!(asset_state::is_at_dutch(&s));
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(s)));
    sc.end();
}

#[test]
fun no_winner_returns_to_idle() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::no_winner(
        asset_state::expire(
            asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id()), PRICE, PHASE_START_MS));
    assert!(asset_state::is_idle(&s));
    destroy_asset(asset_state::claim(asset_state::retire(s)));
    sc.end();
}

#[test]
fun retire_from_idle_yields_retired() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::retire(asset_state::new(new_asset(sc.ctx())));
    assert!(asset_state::is_retired(&s));
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
fun retire_from_at_dutch_yields_retired() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::retire(
        asset_state::expire(
            asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id()), PRICE, PHASE_START_MS));
    assert!(asset_state::is_retired(&s));
    destroy_asset(asset_state::claim(s));
    sc.end();
}

// ─── §3. Transitions — abort paths ─────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::asset_state)]
fun rent_aborts_from_handover_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id());
    let s = asset_state::rent(s, fake_escrow_id());
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::asset_state)]
fun expire_aborts_from_handover_confirmed() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::bid(asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id()));
    let s = asset_state::expire(s, PRICE, PHASE_START_MS);
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::asset_state)]
fun retire_aborts_from_handover_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id());
    let s = asset_state::retire(s);
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = unreachable::EInvariantViolation, location = usufruct::asset_state)]
fun claim_aborts_from_idle() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::new(new_asset(sc.ctx()));
    destroy_asset(asset_state::claim(s));
    sc.end();
}

// ─── §4. give / give_back ──────────────────────────────────────────────────────

#[test]
fun give_extracts_asset_and_mints_receipt() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id());
    let (s, extracted, receipt) = asset_state::give(s);
    assert!(asset_state::is_handover_open(&s));
    assert!(!asset_state::has_asset(&s));
    let s = asset_state::give_back(s, extracted, receipt);
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s, PRICE, PHASE_START_MS)))));
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset::E_ASSET_NOT_AVAILABLE, location = usufruct::asset)]
fun expire_aborts_when_asset_is_borrowed() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())), fake_escrow_id());
    let (s, extracted, receipt) = asset_state::give(s);
    let s = asset_state::expire(s, PRICE, PHASE_START_MS);
    destroy_asset(asset_state::claim(asset_state::retire(s)));
    destroy_asset(extracted);
    asset::destroy_receipt_for_testing(receipt);
    sc.end();
}

// ─── §5. Lifecycle composition ────────────────────────────────────────────────

#[test]
fun full_rental_cycle() {
    let mut sc = test_scenario::begin(@0xA);
    let ctx = sc.ctx();
    let s = asset_state::new(new_asset(ctx));
    let s = asset_state::rent(s, fake_escrow_id());
    assert!(asset_state::is_handover_open(&s));
    let s = asset_state::bid(s);
    assert!(asset_state::is_handover_confirmed(&s));
    let s = asset_state::handover(s);
    assert!(asset_state::is_handover_open(&s));
    let s = asset_state::expire(s, PRICE, PHASE_START_MS);
    assert!(asset_state::is_at_dutch(&s));
    let s = asset_state::no_winner(s);
    assert!(asset_state::is_idle(&s));
    let s = asset_state::retire(s);
    assert!(asset_state::is_retired(&s));
    destroy_asset(asset_state::claim(s));
    sc.end();
}
