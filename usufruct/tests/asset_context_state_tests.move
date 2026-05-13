// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_context_state_tests;

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
    asset::{Self, AssetReceipt},
    asset_context_state,
    commitment_policy_state,
    cycles,
    escrow::{Self, Escrow},
    escrow_corpus,
    escrow_identity,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    tenant::{Self, Tenant},
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

fun mk_tenant(stake: u64, addr: address, cap: TenantCapIdentity): Tenant<SUI> {
    tenant::new(cap, addr, balance::create_for_testing<SUI>(stake))
}

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

/// Integrate an escrow with the given config and immediately take it
/// back as a shared object. Returns (escrow, owner_cap).
fun integrate_and_take_with_cfg(
    cfg: usufruct::config::IntegrationConfig,
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
        commitment_policy_state::new_immediate(),
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

// ─── Round-trip ──────────────────────────────────────────────────────────────
//
// `dispatch` followed by `collect` must reconstruct an observationally
// identical AssetContext. The fields are split across the temporary
// `EscrowCoreHandoff` (owner + envelope) and the per-state context
// (asset + state-specific data); `collect` merges them back.
//
// State coverage: this smoke-tests the Idle path (the state every Escrow
// occupies immediately after integrate). The remaining four leaves
// (AtDutch, Retired, Occupied, Demand) are exercised structurally by
// every execute_* migrated in C2-C9 once those routes go through the
// bridge.

#[test]
fun roundtrip_idle_state_preserves_observable_views() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(&mut sc);

    // Snapshot the observable views before the round-trip.
    let asset_id_before        = escrow::asset_id(&escrow);
    let owner_cap_id_before    = escrow::owner_cap_id(&escrow);
    let is_idle_before         = escrow::is_idle(&escrow);
    let is_at_dutch_before     = escrow::is_at_dutch_auction(&escrow);
    let is_retired_before      = escrow::is_retired(&escrow);
    let is_occupied_before     = escrow::is_occupied(&escrow);
    let is_demand_before       = escrow::is_demand(&escrow);
    let next_floor_before      = escrow::next_floor_price_mist(&escrow);

    let ctx     = escrow::take_context_for_testing(&mut escrow);
    let new_ctx = asset_context_state::roundtrip_for_testing(ctx);
    escrow::put_context_for_testing(&mut escrow, new_ctx);

    assert_eq!(escrow::asset_id(&escrow),               asset_id_before);
    assert_eq!(escrow::owner_cap_id(&escrow),           owner_cap_id_before);
    assert_eq!(escrow::is_idle(&escrow),                is_idle_before);
    assert_eq!(escrow::is_at_dutch_auction(&escrow),    is_at_dutch_before);
    assert_eq!(escrow::is_retired(&escrow),             is_retired_before);
    assert_eq!(escrow::is_occupied(&escrow),            is_occupied_before);
    assert_eq!(escrow::is_demand(&escrow),              is_demand_before);
    assert_eq!(escrow::next_floor_price_mist(&escrow),  next_floor_before);
    assert!(is_idle_before, 0);  // sanity: we were in Idle to begin with.

    test_scenario::return_shared(escrow);
    transfer::public_transfer(cap, OWNER);
    sc.end();
}

// ─── execute_claim wrong-state aborts (C2) ───────────────────────────────────
//
// `execute_claim` accepts only `RetiredContext`. Calling the public
// `claim_asset` entry on an escrow in any other lifecycle state must
// abort `ENotRetired`. The four arms of the dispatcher destructure
// their non-Retired contexts inline and abort — these aborts are
// legitimate, reachable from the public API, and require explicit
// `expected_failure` coverage.
//
// The Idle case (claim immediately after integrate) is already covered
// by `escrow_tests::claim_asset_when_not_retired_aborts`. The three
// other leaves get their dedicated tests here.

#[test, expected_failure(abort_code = asset_context_state::ENotRetired, location = usufruct::asset_context_state)]
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

#[test, expected_failure(abort_code = asset_context_state::ENotRetired, location = usufruct::asset_context_state)]
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

#[test, expected_failure(abort_code = asset_context_state::ENotRetired, location = usufruct::asset_context_state)]
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

// ─── execute_borrow / execute_return wrong-state aborts (C3) ─────────────────
//
// `execute_borrow` accepts only Occupied/Demand via the narrow contract
// `execute_borrow_renting`. The three Waiting variants (Idle, AtDutch,
// Retired) abort `EStaleTenantCap` in the wrapper's dispatch arms —
// reachable from the public API and individually tested here.
//
// `execute_return` is symmetric: Waiting variants abort
// `EReceiptEscrowMismatch`. The receipt is forged via
// `asset::forge_receipt_for_testing`; in production no caller could
// obtain a receipt while the escrow is in a Waiting state, but a hostile
// or buggy caller could forge one — the abort path is the protocol's
// final guard.
//
// The Idle case for borrow is already covered by
// `escrow_tests::borrow_asset_from_idle_aborts`; the two missing
// Waiting variants (AtDutch, Retired) get their tests here.

#[test, expected_failure(abort_code = asset_context_state::EStaleTenantCap, location = usufruct::asset_context_state)]
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
    asset::destroy_receipt_for_testing(receipt);
    transfer::public_transfer(foreign_cap, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_context_state::EStaleTenantCap, location = usufruct::asset_context_state)]
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
    asset::destroy_receipt_for_testing(receipt);
    transfer::public_transfer(foreign_cap, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Build a junk asset + receipt pair targeting `escrow_id` for the
/// wrong-state-return tests. The receipt would not be valid in production
/// (the escrow is not in Renting and the asset is a fresh object), but
/// the dispatch arm aborts EReceiptEscrowMismatch before it is validated.
fun mk_junk_asset_and_receipt(escrow_id: ID, sc: &mut Scenario): (DemoAsset, AssetReceipt) {
    let asset    = mk_demo_asset(sc.ctx());
    let asset_id = object::id(&asset);
    let receipt  = asset::forge_receipt_for_testing(asset_id, escrow_id);
    (asset, receipt)
}

#[test, expected_failure(abort_code = asset_context_state::EReceiptEscrowMismatch, location = usufruct::asset_context_state)]
fun return_asset_aborts_in_idle_state() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(&mut sc);

    let escrow_id = object::id(&escrow);
    let (junk_asset, junk_receipt) = mk_junk_asset_and_receipt(escrow_id, &mut sc);

    escrow::return_asset(&mut escrow, junk_asset, junk_receipt);

    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    sc.end();
}

#[test, expected_failure(abort_code = asset_context_state::EReceiptEscrowMismatch, location = usufruct::asset_context_state)]
fun return_asset_aborts_in_at_dutch_state() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(&mut sc);

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(&mut escrow, 0, 0, STAKE_T1, 0);

    let escrow_id = object::id(&escrow);
    let (junk_asset, junk_receipt) = mk_junk_asset_and_receipt(escrow_id, &mut sc);

    escrow::return_asset(&mut escrow, junk_asset, junk_receipt);

    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    sc.end();
}

#[test, expected_failure(abort_code = asset_context_state::EReceiptEscrowMismatch, location = usufruct::asset_context_state)]
fun return_asset_aborts_in_retired_state() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(&mut sc);

    escrow::drive_to_retired_for_testing(&mut escrow);

    let escrow_id = object::id(&escrow);
    let (junk_asset, junk_receipt) = mk_junk_asset_and_receipt(escrow_id, &mut sc);

    escrow::return_asset(&mut escrow, junk_asset, junk_receipt);

    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    sc.end();
}

// ─── execute_burn_tenant_cap invariants (C7) ─────────────────────────────────
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

#[test, expected_failure(abort_code = asset_context_state::EWrongEscrowTenantCap, location = usufruct::asset_context_state)]
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

    escrow::burn_tenant_cap(&mut escrow, foreign, &rnd, &clk, sc.ctx());

    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_context_state::ETenantCapNotStale, location = usufruct::asset_context_state)]
fun burn_live_current_cap_in_demand_aborts() {
    let mut sc = setup();
    // Countdown handover (c=1) — without this, the Instant handover (c=0)
    // would fire on APT at the start of burn_tenant_cap and Demand would
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
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &rnd, &clk, sc.ctx());
    // Rent #2: Occupied → Demand (place_bid). cap_t2 becomes pending,
    // cap_t1 stays current.
    let p2     = coin::from_balance(balance::create_for_testing<SUI>(escrow::compute_floor_price(&escrow, &clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &rnd, &clk, sc.ctx());

    // Burn the live current cap — must abort.
    escrow::burn_tenant_cap(&mut escrow, cap_t1, &rnd, &clk, sc.ctx());

    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_context_state::ETenantCapNotStale, location = usufruct::asset_context_state)]
fun burn_live_pending_cap_in_demand_aborts() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take_with_cfg(
        escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)),
        &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx());
    let rnd = sc.take_shared<Random>();

    let p1     = coin::from_balance(balance::create_for_testing<SUI>(escrow_corpus::min_rent_price_const()), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &rnd, &clk, sc.ctx());
    let p2     = coin::from_balance(balance::create_for_testing<SUI>(escrow::compute_floor_price(&escrow, &clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &rnd, &clk, sc.ctx());

    // Burn the live pending cap — must abort. This case is distinct
    // from current: pending lives only in Demand. In the legacy form
    // both checks lived in the `cap_auth_for_tenancy` match; in the
    // typed-states form `pending` is a direct field of DemandContext,
    // so the assert is per-arm and per-field.
    escrow::burn_tenant_cap(&mut escrow, cap_t2, &rnd, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    test_scenario::return_shared(rnd);
    clock::destroy_for_testing(clk);
    sc.end();
}
