// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::asset_custody::{Self, AssetCustodyOpen};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TestAsset has key, store { id: UID }

const SINK: address = @0x0;

fun new_test_asset(ctx: &mut TxContext): TestAsset { TestAsset { id: object::new(ctx) } }

/// Compose new + unwrap-via-unbundle to dispose a wrapped Asset in
/// the success path of a test. Aborts if `available == None`.
fun dispose_wrapper(w: AssetCustodyOpen<TestAsset>) {
    let u = asset_custody::unbundle(w);
    transfer::public_transfer(u, SINK);
}

// ─── §1. Construction ─────────────────────────────────────────────────────────

#[test]
fun new_stamps_asset_id() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let uid = object::id(&u);
        let w   = asset_custody::new(u);
        assert_eq!(asset_custody::proj_asset_id(&w), uid);
        assert!(asset_custody::proj_is_available(&w));
        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §2. take ─────────────────────────────────────────────────────────────────

#[test]
fun take_extracts_u_and_marks_slot_unavailable() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let uid = object::id(&u);
        let mut w = asset_custody::new(u);

        let out = asset_custody::take(&mut w);
        assert_eq!(object::id(&out), uid);
        assert!(!asset_custody::proj_is_available(&w));

        // Restore so the wrapper can be disposed via unbundle.
        asset_custody::put(&mut w, out);
        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §3. put — happy path ─────────────────────────────────────────────────────

#[test]
fun put_restores_availability() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let mut w = asset_custody::new(u);

        let out = asset_custody::take(&mut w);
        assert!(!asset_custody::proj_is_available(&w));
        asset_custody::put(&mut w, out);
        assert!(asset_custody::proj_is_available(&w));

        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §4. unbundle ─────────────────────────────────────────────────────────────

#[test]
fun unbundle_when_available_returns_inner_u() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let uid = object::id(&u);
        let w   = asset_custody::new(u);
        let out = asset_custody::unbundle(w);
        assert_eq!(object::id(&out), uid);
        transfer::public_transfer(out, SINK);
    };
    sc.end();
}


// ─── §5. locked custody ──────────────────────────────────────────────────────

#[test]
fun proj_locked_id_returns_inner_asset_id() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u      = new_test_asset(sc.ctx());
        let uid    = object::id(&u);
        let locked = asset_custody::lock(u);
        assert_eq!(asset_custody::proj_locked_id(&locked), uid);
        transfer::public_transfer(asset_custody::unlock(locked), SINK);
    };
    sc.end();
}
