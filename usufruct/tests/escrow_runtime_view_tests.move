// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_runtime_view_tests;

use std::unit_test::assert_eq;
use std::type_name;
use sui::random::{Self, Random};
use sui::{
    balance,
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    asset_context_state,
    commitment_policy_state,
    config::IntegrationConfig,
    cycles,
    escrow::{Self, Escrow},
    escrow_corpus,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    tenant_cap::TenantCap,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER:        address = @0x07;
const TENANT_ADDR:  address = @0xA1;
const STAKE:        u64     = 10_000_000_000;   // matches corpus MIN_RENT_PRICE

public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

fun mk_payment(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::from_balance(balance::create_for_testing<SUI>(amount), ctx)
}

fun setup(): Scenario {
    let mut sc = test_scenario::begin(@0x0);
    { random::create_for_testing(sc.ctx()); };
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

fun build_escrow(cfg: IntegrationConfig, sc: &mut Scenario): (Escrow<DemoAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let random  = sc.take_shared<Random>();
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, cfg, commitment_policy_state::new_immediate(),
        &fee_ref, &random, &clk, sc.ctx(),
    );
    test_scenario::return_shared(random);
    let escrow_id = owner_cap::proj_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    (escrow, cap)
}

fun dispose_escrow(escrow: Escrow<DemoAsset, SUI>, cap: OwnerCap) {
    test_scenario::return_shared(escrow);
    transfer::public_transfer(cap, OWNER);
}

// ─── idle views ───────────────────────────────────────────────────────────────

#[test]
fun idle_views_post_integrate() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(cfg, &mut sc);

    // — Identity / static —
    // asset_id and owner_cap_id stamp the Escrow at integration; never change.
    let _aid = escrow::asset_id(&escrow);
    assert_eq!(escrow::owner_cap_id(&escrow), object::id(&cap));
    let _fid = escrow::fee_inbox_id(&escrow);
    assert_eq!(escrow::asset_type_name(&escrow), type_name::with_defining_ids<DemoAsset>());
    assert_eq!(escrow::coin_type_name(&escrow),  type_name::with_defining_ids<SUI>());

    // — Always-present temporal/financial —
    assert_eq!(escrow::tenure_ceiling_ms(&escrow), escrow_corpus::tenure_ceiling_const());
    assert_eq!(escrow::min_rent_price(&escrow),    escrow_corpus::min_rent_price_const());
    assert_eq!(escrow::owner_balance(&escrow),     0);
    let _iat = escrow::integrated_at_ms(&escrow);     // monotonic w.r.t. clock; nonzero-ness not asserted
    let _can = escrow::commitment_anchor_ms(&escrow);
    let _unl = escrow::commitment_unlocks_at_ms(&escrow);
    assert_eq!(escrow::commitment_remaining_ms(&escrow, escrow::commitment_unlocks_at_ms(&escrow)), 0);

    // — owner_cap_is_valid: round-trips its own cap —
    assert!(escrow::owner_cap_is_valid(&escrow, &cap));

    // — Tenant slots — all none in idle —
    assert!(escrow::current_tenant_addr(&escrow).is_none());
    assert!(escrow::current_tenant_cap_id(&escrow).is_none());
    assert!(escrow::pending_tenant_addr(&escrow).is_none());
    assert!(escrow::pending_tenant_cap_id(&escrow).is_none());
    assert!(escrow::current_stake(&escrow).is_none());
    assert!(escrow::pending_stake(&escrow).is_none());

    // — Phase / active tenancy — all none in idle (no Renting yet) —
    assert!(escrow::phase_start_ms(&escrow).is_none());
    assert!(escrow::tenure_expiry_ms(&escrow).is_none());
    assert!(escrow::active_tenure_ceiling_ms(&escrow).is_none());
    assert!(escrow::active_handover_duration_ms(&escrow).is_none());
    assert!(escrow::active_floor_price_mist(&escrow).is_none());
    assert!(escrow::handover_countdown_expiry_ms(&escrow).is_none());
    assert!(escrow::compute_handover_expiry_at(&escrow, 1_000).is_none());
    assert!(escrow::last_acq_price(&escrow).is_none());

    // — Waiting-side resolved values: present in Idle (locked-in for next bid) —
    // The Idle variant stores resolved_floor/ceiling/handover at integration time;
    // resolved_descent is exclusive to AtDutch.
    assert!(escrow::next_floor_price_mist(&escrow).is_some());
    assert!(escrow::next_tenure_ceiling_ms(&escrow).is_some());
    assert!(escrow::next_handover_duration_ms(&escrow).is_some());
    assert!(escrow::auction_descent_duration_ms(&escrow).is_none());

    // — Credit context — no tenancy → all none / false —
    assert!(!escrow::credit_is_accruing(&escrow));
    assert!(!escrow::credit_is_capped(&escrow));
    assert!(escrow::credit_stake_mist(&escrow).is_none());
    assert!(escrow::credit_phase_start_ms(&escrow).is_none());
    assert!(escrow::credit_expiry_ms(&escrow).is_none());

    // — Pending transitions / config update — none in idle —
    let clk = clock::create_for_testing(sc.ctx());
    assert!(!escrow::has_pending_transition_states(&escrow, &clk));
    assert!(escrow::next_transition_ms(&escrow, &clk).is_none());
    assert!(escrow::next_pending(&escrow, &clk).is_none());
    assert!(!escrow::has_pending_config_update(&escrow));
    clock::destroy_for_testing(clk);

    // — Cap status with an unknown ID — Stale in non-Renting state —
    let foreign = object::id_from_address(@0xDEAD);
    let status  = escrow::tenant_cap_status(&escrow, foreign);
    assert!(asset_context_state::proj_is_stale(&status));

    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── rented views ─────────────────────────────────────────────────────────────

#[test]
fun rented_views_post_rent() {
    let mut sc  = setup();
    let cfg     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(cfg, &mut sc);

    // Rent — pay min_rent_price as the tenant.
    sc.next_tx(TENANT_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, cycles::cycles(1), &random, &clk, sc.ctx());
    test_scenario::return_shared(random);

    // — Tenant slots — current populated, pending still empty —
    assert_eq!(escrow::current_tenant_addr(&escrow).destroy_some(),   TENANT_ADDR);
    assert_eq!(escrow::current_tenant_cap_id(&escrow).destroy_some(), object::id(&t_cap));
    assert!(escrow::pending_tenant_addr(&escrow).is_none());
    assert!(escrow::pending_tenant_cap_id(&escrow).is_none());
    assert_eq!(escrow::current_stake(&escrow).destroy_some(), STAKE);
    assert!(escrow::pending_stake(&escrow).is_none());

    // — Phase / runtime resolution — all populated under Renting state —
    let phase_start = escrow::phase_start_ms(&escrow).destroy_some();
    let expected_expiry = phase_start + escrow_corpus::tenure_ceiling_const();
    assert_eq!(escrow::tenure_expiry_ms(&escrow).destroy_some(), expected_expiry);
    assert_eq!(escrow::active_tenure_ceiling_ms(&escrow).destroy_some(), escrow_corpus::tenure_ceiling_const());
    let _ahd = escrow::active_handover_duration_ms(&escrow); // Some (resolved at rent time)
    let _afp = escrow::active_floor_price_mist(&escrow);     // Some
    // last_acq_price is recorded only on AtDutch transitions, not on rent from Idle.
    assert!(escrow::last_acq_price(&escrow).is_none());

    // — Credit context — accruing in HandoverOpen-like Renting state —
    assert!(escrow::credit_stake_mist(&escrow).is_some());
    assert!(escrow::credit_phase_start_ms(&escrow).is_some());

    // — Cap predicates on the actual tenant cap —
    assert!(escrow::tenant_cap_is_current(&escrow, &t_cap));
    assert!(!escrow::tenant_cap_is_pending(&escrow, &t_cap));
    assert!(!escrow::tenant_cap_is_stale(&escrow, &t_cap));
    let status = escrow::tenant_cap_status(&escrow, object::id(&t_cap));
    assert!(asset_context_state::proj_is_current(&status));

    // — Owner balance: rent payment is collected and split; owner_balance ≥ 0 —
    let _bal = escrow::owner_balance(&escrow);

    // Cleanup
    transfer::public_transfer(t_cap, TENANT_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}
