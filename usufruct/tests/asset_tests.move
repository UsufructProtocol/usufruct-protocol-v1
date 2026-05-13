// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use usufruct::asset::{Self, AssetCustodyOpen};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

public struct TestAsset has key, store { id: UID }

const ESCROW_X: address = @0xE1;
const ESCROW_Y: address = @0xE2;
const SINK:     address = @0x0;

fun escrow_x(): ID { object::id_from_address(ESCROW_X) }
fun escrow_y(): ID { object::id_from_address(ESCROW_Y) }

fun new_test_asset(ctx: &mut TxContext): TestAsset { TestAsset { id: object::new(ctx) } }

/// Compose new + unwrap-via-unbundle to dispose a wrapped Asset in
/// the success path of a test. Aborts if `available == None`.
fun dispose_wrapper(w: AssetCustodyOpen<TestAsset>) {
    let u = asset::unbundle(w);
    transfer::public_transfer(u, SINK);
}

// ─── §1. Construction ─────────────────────────────────────────────────────────

#[test]
fun new_stamps_identity_with_asset_and_escrow_ids() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let uid = object::id(&u);
        let w   = asset::new(u, escrow_x());
        assert_eq!(asset::proj_asset_id(&w),  uid);
        assert_eq!(asset::proj_escrow_id(&w), escrow_x());
        assert!(asset::proj_is_available(&w));
        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §2. take ─────────────────────────────────────────────────────────────────

#[test]
fun take_returns_u_and_receipt_carrying_both_ids() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let uid = object::id(&u);
        let mut w = asset::new(u, escrow_x());

        let (out, receipt) = asset::take(&mut w);
        assert_eq!(asset::receipt_asset_id_for_testing(&receipt),  uid);
        assert_eq!(asset::receipt_escrow_id_for_testing(&receipt), escrow_x());
        assert!(!asset::proj_is_available(&w));

        // Restore so the wrapper can be disposed via unbundle.
        asset::put(&mut w, out, receipt);
        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §3. put — happy path ─────────────────────────────────────────────────────

#[test]
fun put_with_authentic_receipt_restores_availability() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let mut w = asset::new(u, escrow_x());

        let (out, receipt) = asset::take(&mut w);
        assert!(!asset::proj_is_available(&w));
        asset::put(&mut w, out, receipt);
        assert!(asset::proj_is_available(&w));

        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §4. put — abort paths ───────────────────────────────────────────────────

// Cross-escrow: forge a receipt that claims to come from escrow Y;
// presented to a wrapper bound to escrow X. Aborts on E_ASSET_WRONG_ESCROW.
#[test, expected_failure(abort_code = asset::E_ASSET_WRONG_ESCROW, location = usufruct::asset)]
fun put_with_receipt_from_wrong_escrow_aborts() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u    = new_test_asset(sc.ctx());
        let uid  = object::id(&u);
        let mut w = asset::new(u, escrow_x());

        let (out, authentic) = asset::take(&mut w);
        // Drop the authentic receipt (test-only path) and forge one with Y.
        asset::destroy_receipt_for_testing(authentic);
        let forged = asset::forge_receipt_for_testing(uid, escrow_y());

        asset::put(&mut w, out, forged);
        dispose_wrapper(w);
    };
    sc.end();
}

// Receipt-asset-id mismatch: the receipt claims a different asset_id
// than the wrapper's. Within a single wrapper this can only happen
// via a forged or swapped receipt. Aborts on E_ASSET_RECEIPT_MISMATCH.
#[test, expected_failure(abort_code = asset::E_ASSET_RECEIPT_MISMATCH, location = usufruct::asset)]
fun put_with_receipt_carrying_wrong_asset_id_aborts() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u    = new_test_asset(sc.ctx());
        let mut w = asset::new(u, escrow_x());

        let (out, authentic) = asset::take(&mut w);
        asset::destroy_receipt_for_testing(authentic);
        // Forge with a fabricated asset_id but correct escrow_id.
        let forged = asset::forge_receipt_for_testing(
            object::id_from_address(@0xDEAD), escrow_x(),
        );

        asset::put(&mut w, out, forged);
        dispose_wrapper(w);
    };
    sc.end();
}

// Asset-swap: the wrapper and receipt agree on ids, but the returned
// `U` is a different physical object. Aborts on E_ASSET_RETURNED_DIFFERENT.
#[test, expected_failure(abort_code = asset::E_ASSET_RETURNED_DIFFERENT, location = usufruct::asset)]
fun put_with_swapped_asset_aborts() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u1 = new_test_asset(sc.ctx());
        let mut w = asset::new(u1, escrow_x());

        let (out, receipt) = asset::take(&mut w);
        // Sink the original out, fabricate a fresh U2 to attempt the swap.
        transfer::public_transfer(out, SINK);
        let u2 = new_test_asset(sc.ctx());

        asset::put(&mut w, u2, receipt);
        dispose_wrapper(w);
    };
    sc.end();
}

// ─── §5. unbundle ─────────────────────────────────────────────────────────────

#[test]
fun unbundle_when_available_returns_inner_u() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u   = new_test_asset(sc.ctx());
        let uid = object::id(&u);
        let w   = asset::new(u, escrow_x());
        let out = asset::unbundle(w);
        assert_eq!(object::id(&out), uid);
        transfer::public_transfer(out, SINK);
    };
    sc.end();
}

#[test, expected_failure(abort_code = asset::E_ASSET_NOT_AVAILABLE, location = usufruct::asset)]
fun unbundle_when_unavailable_aborts() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u    = new_test_asset(sc.ctx());
        let mut w = asset::new(u, escrow_x());

        let (out, receipt) = asset::take(&mut w);
        transfer::public_transfer(out, SINK);
        asset::destroy_receipt_for_testing(receipt);

        // Wrapper is now empty — unbundle must abort.
        let unreachable = asset::unbundle(w);
        transfer::public_transfer(unreachable, SINK);
    };
    sc.end();
}

// ─── §6. locked custody ──────────────────────────────────────────────────────

#[test]
fun proj_locked_id_returns_inner_asset_id() {
    let mut sc = test_scenario::begin(@0xA);
    sc.next_tx(@0xA);
    {
        let u      = new_test_asset(sc.ctx());
        let uid    = object::id(&u);
        let locked = asset::lock(u);
        assert_eq!(asset::proj_locked_id(&locked), uid);
        transfer::public_transfer(asset::unlock(locked), SINK);
    };
    sc.end();
}
