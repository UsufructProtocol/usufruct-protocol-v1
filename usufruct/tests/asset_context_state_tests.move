// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::asset_context_state_tests;

use std::unit_test::assert_eq;
use sui::random::{Self, Random};
use sui::{
    clock,
    sui::SUI,
    test_scenario,
};
use usufruct::{
    asset_context_state,
    commitment_policy_state,
    escrow::{Self, Escrow},
    escrow_corpus,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
};

// ─── Fixtures ────────────────────────────────────────────────────────────────

const OWNER: address = @0x07;

public struct DemoAsset has key, store { id: UID }

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
    let mut sc = test_scenario::begin(@0x0);
    { random::create_for_testing(sc.ctx()); };
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };

    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = DemoAsset { id: object::new(sc.ctx()) };
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
    let mut escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);

    // Snapshot the observable views before the round-trip.
    let asset_id_before        = escrow::asset_id(&escrow);
    let owner_cap_id_before    = escrow::owner_cap_id(&escrow);
    let is_idle_before         = escrow::is_idle(&escrow);
    let is_at_dutch_before     = escrow::is_at_dutch_auction(&escrow);
    let is_retired_before      = escrow::is_retired(&escrow);
    let is_occupied_before     = escrow::is_occupied(&escrow);
    let is_demand_before       = escrow::is_demand(&escrow);
    let next_floor_before      = escrow::next_floor_price_mist(&escrow);

    // Round-trip: take → dispatch → collect → put.
    let ctx     = escrow::take_context_for_testing(&mut escrow);
    let new_ctx = asset_context_state::roundtrip_for_testing(ctx);
    escrow::put_context_for_testing(&mut escrow, new_ctx);

    // Observable views must be byte-identical after the round-trip.
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
