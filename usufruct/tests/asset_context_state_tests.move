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
    asset_context_state,
    commitment_policy_state,
    escrow::{Self, Escrow},
    escrow_corpus,
    monetary,
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

/// Integrate an escrow and immediately take it back as a shared object.
/// Returns (escrow, owner_cap). Caller must dispose both.
fun integrate_and_take(sc: &mut Scenario): (Escrow<DemoAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let rnd     = sc.take_shared<Random>();
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset,
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0)),
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
