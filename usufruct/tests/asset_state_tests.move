// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_state_tests;

use sui::test_scenario;
use usufruct::asset_state;

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
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())));
    assert!(asset_state::is_handover_open(&s));
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s)))));
    sc.end();
}

#[test]
fun rent_from_at_dutch_opens_handover() {
    let mut sc = test_scenario::begin(@0xA);
    // Build AtDutch via Idle → HandoverOpen → expire → AtDutch
    let s = asset_state::new(new_asset(sc.ctx()));
    let s = asset_state::expire(asset_state::rent(s));
    assert!(asset_state::is_at_dutch(&s));
    // Re-rent from AtDutch
    let s = asset_state::rent(s);
    assert!(asset_state::is_handover_open(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s)))));
    sc.end();
}

#[test]
fun bid_promotes_to_confirmed() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::bid(asset_state::rent(asset_state::new(new_asset(sc.ctx()))));
    assert!(asset_state::is_handover_confirmed(&s));
    assert!(asset_state::has_asset(&s));
    // confirmed → open → expire → dutch → retire → claim
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(
            asset_state::handover(s))))));
    sc.end();
}

#[test]
fun handover_returns_to_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::handover(
        asset_state::bid(asset_state::rent(asset_state::new(new_asset(sc.ctx())))));
    assert!(asset_state::is_handover_open(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s)))));
    sc.end();
}

#[test]
fun expire_from_open_to_dutch() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::expire(asset_state::rent(asset_state::new(new_asset(sc.ctx()))));
    assert!(asset_state::is_at_dutch(&s));
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(s)));
    sc.end();
}

#[test]
fun no_winner_returns_to_idle() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::no_winner(
        asset_state::expire(asset_state::rent(asset_state::new(new_asset(sc.ctx())))));
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
        asset_state::expire(asset_state::rent(asset_state::new(new_asset(sc.ctx())))));
    assert!(asset_state::is_retired(&s));
    destroy_asset(asset_state::claim(s));
    sc.end();
}

// ─── §3. Transitions — abort paths ─────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = asset_state::EInvariantViolation, location = usufruct::asset_state)]
fun rent_aborts_from_handover_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())));
    let s = asset_state::rent(s);  // already in HandoverOpen
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_state::EInvariantViolation, location = usufruct::asset_state)]
fun expire_aborts_from_handover_confirmed() {
    // Key invariant: HandoverConfirmed must resolve via handover() before expire.
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::bid(asset_state::rent(asset_state::new(new_asset(sc.ctx()))));
    let s = asset_state::expire(s);  // must abort — confirmed cannot expire directly
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_state::EInvariantViolation, location = usufruct::asset_state)]
fun retire_aborts_from_handover_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())));
    let s = asset_state::retire(s);  // retire only valid from Idle | AtDutch
    destroy_asset(asset_state::claim(s));
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_state::EInvariantViolation, location = usufruct::asset_state)]
fun claim_aborts_from_idle() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::new(new_asset(sc.ctx()));
    destroy_asset(asset_state::claim(s));  // must abort — not Retired
    sc.end();
}

// ─── §4. give / give_back ──────────────────────────────────────────────────────

#[test]
fun give_extracts_asset_from_handover_open() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())));
    let (s, extracted) = asset_state::give(s);

    assert!(asset_state::is_handover_open(&s));
    assert!(!asset_state::has_asset(&s));  // slot is None

    // Return it and clean up
    let s = asset_state::give_back(s, extracted);
    assert!(asset_state::has_asset(&s));
    destroy_asset(asset_state::claim(asset_state::retire(
        asset_state::no_winner(asset_state::expire(s)))));
    sc.end();
}

#[test]
#[expected_failure]
fun expire_aborts_when_asset_is_borrowed() {
    let mut sc = test_scenario::begin(@0xA);
    let s = asset_state::rent(asset_state::new(new_asset(sc.ctx())));
    let (s, extracted) = asset_state::give(s);
    // Try to expire while asset is with tenant — should abort
    let s = asset_state::expire(s);
    // unreachable cleanup
    destroy_asset(asset_state::claim(asset_state::retire(s)));
    destroy_asset(extracted);
    sc.end();
}

// ─── §5. Lifecycle composition ────────────────────────────────────────────────

#[test]
fun full_rental_cycle() {
    let mut sc = test_scenario::begin(@0xA);
    let ctx = sc.ctx();

    // Idle → rent → HandoverOpen
    let s = asset_state::new(new_asset(ctx));
    let s = asset_state::rent(s);
    assert!(asset_state::is_handover_open(&s));

    // bid → HandoverConfirmed
    let s = asset_state::bid(s);
    assert!(asset_state::is_handover_confirmed(&s));

    // handover → HandoverOpen (new tenant takes over)
    let s = asset_state::handover(s);
    assert!(asset_state::is_handover_open(&s));

    // tenure expires → AtDutch
    let s = asset_state::expire(s);
    assert!(asset_state::is_at_dutch(&s));

    // no winner → Idle
    let s = asset_state::no_winner(s);
    assert!(asset_state::is_idle(&s));

    // owner retires → Retired → claim
    let s = asset_state::retire(s);
    assert!(asset_state::is_retired(&s));
    destroy_asset(asset_state::claim(s));
    sc.end();
}
