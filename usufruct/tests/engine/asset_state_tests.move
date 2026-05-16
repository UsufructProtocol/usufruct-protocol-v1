// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_state_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    clock::{Self, Clock},
    coin,
    random::{Self, Random},
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    asset_custody::{Self},
    asset_state::{Self},
    commitment_policy,
    tenures,
    escrow::{Self, Escrow},
    escrow_corpus,
    escrow_identity,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    tenant_seat::{Self, TenantSeat},
    tenant_identity::{Self},
    tenant_stake,
    tenant_cap::{Self, TenantCapIdentity},
};

// ─── Fixtures ────────────────────────────────────────────────────────────────

const OWNER:         address = @0x07;
const TENANT_ADDR_1: address = @0xA1;
const TENANT_ADDR_2: address = @0xA2;
const STAKE_T1:      u64     = 1_000_000_000;
const STAKE_T2:      u64     = 2_000_000_000;

public struct DemoAsset has key, store { id: UID }

fun setup(): Scenario {
    let mut sc = test_scenario::begin(@0x0);
    { random::create_for_testing(sc.ctx()); };
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

fun cap_id_1(): TenantCapIdentity { tenant_cap::from_id(object::id_from_address(@0xCA1)) }
fun cap_id_2(): TenantCapIdentity { tenant_cap::from_id(object::id_from_address(@0xCA2)) }

fun mk_tenant(stake: u64, addr: address, cap: TenantCapIdentity): TenantSeat<SUI> {
    tenant_seat::new(cap, addr, balance::create_for_testing<SUI>(stake))
}

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

/// Integrate an escrow with the given config and immediately take it
/// back as a shared object. Returns (escrow, owner_cap).
fun integrate_and_take_with_cfg(
    cfg: usufruct::policy_ensemble::PolicyEnsemble,
    sc:  &mut Scenario,
): (Escrow<DemoAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let rnd     = sc.take_shared<Random>();
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset,
        cfg,
        commitment_policy::new_immediate(),
        &fee_ref, &rnd, &clk, sc.ctx(),
    );
    test_scenario::return_shared(rnd);
    let escrow_id = owner_cap::proj_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    (escrow, cap)
}

/// Default integration: tag(0,0,0,0,0). Instant handover — fine for
/// tests that don't put the escrow into Demand.
fun integrate_and_take(sc: &mut Scenario): (Escrow<DemoAsset, SUI>, OwnerCap) {
    integrate_and_take_with_cfg(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0)),
        sc,
    )
}

/// Re-take the shared escrow by value (so it can be consumed by claim_asset).
fun retake_escrow_by_value(escrow: Escrow<DemoAsset, SUI>, sc: &mut Scenario): Escrow<DemoAsset, SUI> {
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    sc.take_shared<Escrow<DemoAsset, SUI>>()
}

// ─── execute_claim wrong-state aborts (C2) ───────────────────────────────────
//
// The Retired arm of `execute_claim` is the typed happy path:
// the `match` extracts the locked asset from the Retired variant and
// unwraps it. Calling the public `claim_asset` entry on an escrow in
// any other lifecycle state must abort `ENotRetired`. The four wrong-
// state arms destructure their variants inline and abort — these
// aborts are legitimate, reachable from the public API, and require
// explicit `expected_failure` coverage.
//
// The Idle case (claim immediately after integrate) is already covered
// by `escrow_tests::claim_asset_when_not_retired_aborts`. The three
// other leaves get their dedicated tests here.

#[test, expected_failure(abort_code = asset_state::ENotRetired, location = usufruct::asset_state)]
fun claim_asset_aborts_in_at_dutch_state() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(&mut sc);

    // Idle → Occupied → AtDutch.
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(&mut escrow, 0, 0, STAKE_T1, 0);

    let escrow = retake_escrow_by_value(escrow, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();
    let (asset, earnings) = escrow::claim_asset(escrow, cap, &rnd, &clk, sc.ctx());

    // Unreachable — claim_asset aborts above. Bindings only satisfy the
    // type checker; expected_failure makes the abort the success path.
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENotRetired, location = usufruct::asset_state)]
fun claim_asset_aborts_in_occupied_state() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(&mut sc);

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );

    let escrow = retake_escrow_by_value(escrow, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();
    let (asset, earnings) = escrow::claim_asset(escrow, cap, &rnd, &clk, sc.ctx());

    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENotRetired, location = usufruct::asset_state)]
fun claim_asset_aborts_in_demand_state() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(&mut sc);

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_demand_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
        10_000,
    );

    let escrow = retake_escrow_by_value(escrow, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();
    let (asset, earnings) = escrow::claim_asset(escrow, cap, &rnd, &clk, sc.ctx());

    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── execute_borrow wrong-state aborts (C3) ──────────────────────────────────
//
// `execute_borrow` does the happy path on Occupied / Demand match arms.
// The three Waiting variants (Idle, AtDutch, Retired) abort
// `EStaleTenantCap` — reachable from the public API and individually
// tested here.
//
// `execute_return` no longer has a wrong-state arm: `RentingState` in
// `AssetReceipt` limits the return match to `Occupied | Demand` by type.
//
// The Idle case for borrow is already covered by
// `escrow_tests::borrow_asset_from_idle_aborts`; the two missing
// Waiting variants (AtDutch, Retired) get their tests here.

#[test, expected_failure(abort_code = asset_state::EStaleTenantCap, location = usufruct::asset_state)]
fun borrow_asset_aborts_in_at_dutch_state() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(&mut sc);

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(&mut escrow, 0, 0, STAKE_T1, 0);

    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();
    let foreign_cap = tenant_cap::new(
        escrow_identity::new(object::id(&escrow)),
        TENANT_ADDR_1,
        sc.ctx(),
    );

    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &foreign_cap, &rnd, &clk, sc.ctx());

    transfer::public_transfer(asset, OWNER);
    asset_state::destroy_receipt_for_testing(receipt);
    transfer::public_transfer(foreign_cap, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EStaleTenantCap, location = usufruct::asset_state)]
fun borrow_asset_aborts_in_retired_state() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(&mut sc);

    escrow::drive_to_retired_for_testing(&mut escrow);

    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();
    let foreign_cap = tenant_cap::new(
        escrow_identity::new(object::id(&escrow)),
        TENANT_ADDR_1,
        sc.ctx(),
    );

    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &foreign_cap, &rnd, &clk, sc.ctx());

    transfer::public_transfer(asset, OWNER);
    asset_state::destroy_receipt_for_testing(receipt);
    transfer::public_transfer(foreign_cap, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── execute_soft_burn_tenant_cap invariants (C7) ─────────────────────────────────
//
// Two invariants travel together; neither alone is sufficient:
//
//   1. Only caps issued by THIS escrow can be burned
//      (EWrongEscrowTenantCap). Otherwise an attacker could route caps
//      issued elsewhere through any Retired escrow as a burn machine,
//      potentially destroying caps still current/pending on their
//      origin escrow.
//
//   2. Only stale caps can be burned (ETenantCapNotStale).
//      current/pending caps are still in active use.
//
// In Idle/AtDutch/Retired the second invariant is satisfied
// structurally (no current/pending exists in those contexts). The
// legacy form skipped the escrow-identity check in Retired, opening
// the bypass for invariant 1. This test fixes the latent bug.
//
// Existing coverage for the other cases (see escrow_tests):
//   · burn_tenant_cap_with_foreign_escrow_cap_aborts  — invariant 1, Idle.
//   · burn_tenant_cap_on_live_current_cap_aborts      — invariant 2, Occupied.
//   · burn_tenant_cap_burns_displaced_bidder_cap      — happy path, Demand.

#[test, expected_failure(abort_code = asset_state::EWrongEscrowTenantCap, location = usufruct::asset_state)]
fun burn_foreign_cap_in_retired_aborts() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(&mut sc);

    escrow::drive_to_retired_for_testing(&mut escrow);

    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    // Cap issued by some other escrow (here a synthetic identity); the
    // Retired state of `escrow` must not be a backdoor for burning it.
    let foreign = tenant_cap::new(
        escrow_identity::new(object::id_from_address(@0xDEAD)),
        TENANT_ADDR_1,
        sc.ctx(),
    );

    escrow::soft_burn_tenant_cap(&mut escrow, foreign, &rnd, &clk, sc.ctx());

    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapNotStale, location = usufruct::asset_state)]
fun burn_live_current_cap_in_demand_aborts() {
    let mut sc = setup();
    // Countdown handover (c=1) — without this, the Instant handover (c=0)
    // would fire on APT at the start of soft_burn_tenant_cap and Demand would
    // collapse to Occupied with cap_t2 as the new current, making cap_t1
    // legitimately stale.
    let (mut escrow, owner_cap) = integrate_and_take_with_cfg(
        escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)),
        &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    // Rent #1: Idle → Occupied. cap_t1 becomes current.
    let p1     = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &rnd, &clk, sc.ctx());
    // Rent #2: Occupied → Demand (place_bid). cap_t2 becomes pending,
    // cap_t1 stays current.
    let p2     = coin::from_balance(balance::create_for_testing<SUI>(escrow::compute_floor_price(&escrow, &clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &rnd, &clk, sc.ctx());

    // Burn the live current cap — must abort.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t1, &rnd, &clk, sc.ctx());

    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapNotStale, location = usufruct::asset_state)]
fun burn_live_pending_cap_in_demand_aborts() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take_with_cfg(
        escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)),
        &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    let p1     = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &rnd, &clk, sc.ctx());
    let p2     = coin::from_balance(balance::create_for_testing<SUI>(escrow::compute_floor_price(&escrow, &clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &rnd, &clk, sc.ctx());

    // Burn the live pending cap — must abort. This case is distinct
    // from current: pending lives only in Demand. In the legacy form
    // both checks lived in the `cap_auth_for_tenancy` match; in the
    // typed-states form `pending` is a direct field of the Demand
    // storage variant, so the assert is per-arm and per-field.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t2, &rnd, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── execute_borrow — double borrow (C3b) ────────────────────────────────────
//
// Attempting to borrow while the receipt is outstanding aborts
// `EAssetBorrowed`. After the first borrow, `escrow.state` is `None`
// (the state travels in the receipt); the guard lives in `escrow::borrow_asset`.

#[test, expected_failure(abort_code = escrow::EAssetBorrowed, location = usufruct::escrow)]
fun double_borrow_aborts() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(&mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    let p = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let t_cap = escrow::rent(&mut escrow, p, tenures::tenures(1), &rnd, &clk, sc.ctx());

    // First borrow — succeeds, slot is now empty.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &t_cap, &rnd, &clk, sc.ctx());

    // Second borrow — must abort EAssetBorrowed.
    let (asset2, receipt2) = escrow::borrow_asset(&mut escrow, &t_cap, &rnd, &clk, sc.ctx());

    // Unreachable — consumed only to satisfy the type checker.
    escrow::return_asset(&mut escrow, asset, receipt);
    escrow::return_asset(&mut escrow, asset2, receipt2);
    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── execute_return — receipt verification (C4) ───────────────────────────────
//
// Two checks live in `assert_return_valid`, called from `execute_return`.
// Both are exercised via real borrows (authentic receipts) — forge is not
// needed because `RentingState` in the receipt makes wrong-state returns
// impossible to represent.

/// Two real escrows — borrow from A, present the authentic receipt to B.
/// This is the production cross-escrow attack: the attacker holds a
/// genuine receipt but targets the wrong escrow object.
#[test, expected_failure(abort_code = asset_state::EReceiptEscrowMismatch, location = usufruct::asset_state)]
fun cross_escrow_return_with_authentic_receipt_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow_a, cap_a) = integrate_and_take(&mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take_with_cfg(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    // Rent on both escrows so they are in Occupied state.
    let p_a = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let t_cap_a = escrow::rent(&mut escrow_a, p_a, tenures::tenures(1), &rnd, &clk, sc.ctx());
    let p_b = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let t_cap_b = escrow::rent(&mut escrow_b, p_b, tenures::tenures(1), &rnd, &clk, sc.ctx());

    // Borrow from A — receipt_a carries escrow_a's identity.
    let (asset_a, receipt_a) = escrow::borrow_asset(&mut escrow_a, &t_cap_a, &rnd, &clk, sc.ctx());

    // Attempt to return asset_a to escrow_b using receipt_a — must abort.
    escrow::return_asset(&mut escrow_b, asset_a, receipt_a);

    transfer::public_transfer(t_cap_a, OWNER);
    transfer::public_transfer(t_cap_b, OWNER);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    transfer::public_transfer(cap_a, OWNER);
    transfer::public_transfer(cap_b, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Two real escrows, two real borrows — cross-return with correct escrow
/// but wrong asset. The attacker borrows asset_A from escrow_A (getting
/// receipt_A) and asset_B from escrow_B (getting receipt_B), then tries
/// to return asset_B to escrow_A using receipt_A. Escrow identity passes;
/// the asset_id check catches the swap.
#[test, expected_failure(abort_code = asset_state::EReturnedDifferentAsset, location = usufruct::asset_state)]
fun cross_borrow_asset_swap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow_a, cap_a) = integrate_and_take(&mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take_with_cfg(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    let p_a = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let t_cap_a = escrow::rent(&mut escrow_a, p_a, tenures::tenures(1), &rnd, &clk, sc.ctx());
    let p_b = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let t_cap_b = escrow::rent(&mut escrow_b, p_b, tenures::tenures(1), &rnd, &clk, sc.ctx());

    let (asset_a, receipt_a) = escrow::borrow_asset(&mut escrow_a, &t_cap_a, &rnd, &clk, sc.ctx());
    let (asset_b, receipt_b) = escrow::borrow_asset(&mut escrow_b, &t_cap_b, &rnd, &clk, sc.ctx());

    // Return asset_b to escrow_a with receipt_a:
    //   receipt_a.escrow_id = A  == A          ← passes check 1
    //   object::id(asset_b) = B_id ≠ A_id     ← fails check 2
    asset_state::destroy_receipt_for_testing(receipt_b);
    escrow::return_asset(&mut escrow_a, asset_b, receipt_a);

    transfer::public_transfer(asset_a, OWNER);
    transfer::public_transfer(t_cap_a, OWNER);
    transfer::public_transfer(t_cap_b, OWNER);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    transfer::public_transfer(cap_a, OWNER);
    transfer::public_transfer(cap_b, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Asset-swap return: authentic receipt but the physically returned object
/// is a different instance of the same type.
#[test, expected_failure(abort_code = asset_state::EReturnedDifferentAsset, location = usufruct::asset_state)]
fun return_with_swapped_asset_aborts() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(&mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    let p = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let t_cap = escrow::rent(&mut escrow, p, tenures::tenures(1), &rnd, &clk, sc.ctx());

    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &t_cap, &rnd, &clk, sc.ctx());
    // Sink the borrowed asset; present a fresh object with the authentic receipt.
    transfer::public_transfer(asset, OWNER);
    let swapped = mk_demo_asset(sc.ctx());
    escrow::return_asset(&mut escrow, swapped, receipt);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

