// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_runtime_view_tests;

use std::unit_test::assert_eq;
use std::string;
use std::type_name;
use sui::{
    balance,
    clock,
    coin::{Self, Coin},
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    ensemble_commitment_policy,
    retire_commitment_policy,
    policy_ensemble::PolicyEnsemble,
    tenures,
    escrow::{Self, Escrow},
    escrow_corpus,
    governance_cap::GovernanceCap,
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const GOVERNOR:        address = @0x07;
const USUFRUCTUARY_ADDR:  address = @0xA1;
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
    sc.next_tx(GOVERNOR);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

fun build_escrow(ensemble: PolicyEnsemble, sc: &mut Scenario): (Escrow<DemoAsset, SUI>, GovernanceCap) {
    sc.next_tx(GOVERNOR);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let (cap, inbox) = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(),
        ensemble_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    transfer::public_transfer(inbox, GOVERNOR);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(GOVERNOR);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    (escrow, cap)
}

fun dispose_escrow(escrow: Escrow<DemoAsset, SUI>, cap: GovernanceCap) {
    test_scenario::return_shared(escrow);
    transfer::public_transfer(cap, GOVERNOR);
}

// ─── projector matrix helper ─────────────────────────────────────────────────
//
// State codes used by the cartesian-product test below. Following the
// per-axis tag convention used by escrow_view_tests.move (e.g. c == 0 for
// Instant handover), state_id encodes the expected state-machine leaf:
//
//   0 → Waiting::Idle
//   1 → Waiting::Descent
//   2 → Waiting::Retired
//   3 → Renting::Occupied
//   4 → Renting::Demand
//
// `assert_projector_pattern` runs every Option/bool view in escrow.move
// once and asserts the expected presence/absence for the given state.
// The patterns are derived from the state machine projector definitions
// in asset_state — see the per-state match arms there.

const STATE_IDLE:     u8 = 0;
const STATE_AT_DUTCH: u8 = 1;
const STATE_RETIRED:  u8 = 2;
const STATE_OCCUPIED: u8 = 3;
const STATE_DEMAND:   u8 = 4;

fun assert_projector_pattern(escrow: &Escrow<DemoAsset, SUI>, state_id: u8) {
    let in_renting = state_id == STATE_OCCUPIED || state_id == STATE_DEMAND;
    let in_demand  = state_id == STATE_DEMAND;
    let in_descent = state_id == STATE_AT_DUTCH;
    let in_waiting_with_resolved = state_id == STATE_IDLE || state_id == STATE_AT_DUTCH;

    // — Static identity — asset_id traverses both Waiting and Renting branches
    //   of proj_asset_id (asset_id_for_tenancy in Renting) —
    let _ = escrow::asset_id(escrow);

    // — Discriminators —
    assert_eq!(escrow::is_idle(escrow),             state_id == STATE_IDLE);
    assert_eq!(escrow::is_descending(escrow), state_id == STATE_AT_DUTCH);
    assert_eq!(escrow::is_retired(escrow),          state_id == STATE_RETIRED);
    assert_eq!(escrow::is_occupied(escrow),         state_id == STATE_OCCUPIED);
    assert_eq!(escrow::is_demand(escrow),           state_id == STATE_DEMAND);
    assert_eq!(escrow::is_rented(escrow),           in_renting);
    assert_eq!(escrow::is_live(escrow),           state_id != STATE_RETIRED);
    // No scenario in this matrix sets the retire flag.
    assert!(!escrow::is_retiring(escrow));

    // — Usufructuary slots: current populated under Renting; pending only under Demand —
    assert_eq!(escrow::active_usufructuary_addr(escrow).is_some(),   in_renting);
    assert_eq!(escrow::active_usufruct_cap_id(escrow).is_some(), in_renting);
    assert_eq!(escrow::active_stake_balance_mist(escrow).is_some(),         in_renting);
    assert_eq!(escrow::pending_usufructuary_addr(escrow).is_some(),   in_demand);
    assert_eq!(escrow::pending_usufruct_cap_id(escrow).is_some(), in_demand);
    assert_eq!(escrow::pending_stake_balance_mist(escrow).is_some(),         in_demand);

    // — phase_start: tenancy envelope (Renting) or state (Descent) —
    assert_eq!(escrow::phase_start_ms(escrow).is_some(), in_renting || in_descent);
    // tenure_expiry computed only under Renting (early-returns otherwise)
    assert_eq!(escrow::tenure_expiry_ms(escrow).is_some(), in_renting);

    // — tenancy-schedule totals: live in TenancyEnvelope, only Renting —
    assert_eq!(escrow::active_ceiling_total_ms(escrow).is_some(),    in_renting);
    assert_eq!(escrow::active_handover_total_ms(escrow).is_some(), in_renting);

    // — cycle_* (resolved cycle params): present in EVERY non-retired state, read
    //   from whichever state's stored snapshot (Renting or Waiting). One cross-state
    //   view replaces the old active_*/next_* split.
    let has_cycle = in_renting || in_waiting_with_resolved;
    assert_eq!(escrow::cycle_floor_price_mist(escrow).is_some(), has_cycle);
    assert_eq!(escrow::cycle_ceiling_ms(escrow).is_some(),    has_cycle);
    assert_eq!(escrow::cycle_handover_ms(escrow).is_some(), has_cycle);
    assert_eq!(escrow::cycle_descent_ms(escrow).is_some(), has_cycle);
    // — Descent-only field —
    assert_eq!(escrow::last_rent_price_mist(escrow).is_some(),              in_descent);
    assert_eq!(escrow::descent_expiry_ms(escrow).is_some(),                 in_descent);

    // — Demand-only fields (handover countdown active) —
    assert_eq!(escrow::handover_expiry_ms(escrow).is_some(), in_demand);

    // — next_boundary: the scheduling oracle — the next phase boundary is present
    //   whenever a transition is scheduled (Renting or Descent), absent in Idle/Retired.
    assert_eq!(escrow::next_boundary_ms(escrow).is_some(), in_renting || in_descent);

    // — Credit context: Accruing in Occupied, Capped in Demand —
    assert_eq!(escrow::credit_is_accruing(escrow), state_id == STATE_OCCUPIED);
    assert_eq!(escrow::credit_is_capped(escrow),   in_demand);
    assert_eq!(escrow::active_stake_balance_mist(escrow).is_some(),      in_renting);
    assert_eq!(escrow::credit_capped_at_ms(escrow).is_some(),       in_demand);
}

// ─── idle views ───────────────────────────────────────────────────────────────

#[test]
fun idle_views_post_integrate() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(ensemble, &mut sc);

    // — Identity / static —
    // asset_id and governance_cap_id stamp the Escrow at integration; never change.
    let _aid = escrow::asset_id(&escrow);
    assert_eq!(escrow::governance_cap_id(&escrow), object::id(&cap));
    let _fid = escrow::fee_inbox_id(&escrow);
    assert_eq!(escrow::asset_type_name(&escrow), string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(escrow::coin_type_name(&escrow),  string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));

    // — Always-present temporal/financial —
    assert_eq!(escrow::tenure_ceiling_ms(&escrow), escrow_corpus::tenure_ceiling_const());
    assert_eq!(escrow::rest_price_floor_mist(&escrow),    escrow_corpus::min_rent_price_const());
    let _iat = escrow::integrated_at_ms(&escrow);     // monotonic w.r.t. clock; nonzero-ness not asserted
    let _can = escrow::retire_commitment_anchor_ms(&escrow);
    let _unl = escrow::retire_commitment_unlocks_at_ms(&escrow);
    assert_eq!(escrow::retire_commitment_remaining_ms(&escrow, escrow::retire_commitment_unlocks_at_ms(&escrow)), 0);

    // — governance_cap_is_valid: round-trips its own cap —
    assert!(escrow::governance_cap_is_valid(&escrow, object::id(&cap)));

    // — Usufructuary slots — all none in idle —
    assert!(escrow::active_usufructuary_addr(&escrow).is_none());
    assert!(escrow::active_usufruct_cap_id(&escrow).is_none());
    assert!(escrow::pending_usufructuary_addr(&escrow).is_none());
    assert!(escrow::pending_usufruct_cap_id(&escrow).is_none());
    assert!(escrow::active_stake_balance_mist(&escrow).is_none());
    assert!(escrow::pending_stake_balance_mist(&escrow).is_none());

    // — Phase / active tenancy — all none in idle (no Renting yet) —
    assert!(escrow::phase_start_ms(&escrow).is_none());
    assert!(escrow::tenure_expiry_ms(&escrow).is_none());
    assert!(escrow::active_ceiling_total_ms(&escrow).is_none());
    assert!(escrow::active_handover_total_ms(&escrow).is_none());
    assert!(escrow::handover_expiry_ms(&escrow).is_none());
    assert!(escrow::handover_expiry_if_bid_at(&escrow, 1_000).is_none());
    assert!(escrow::last_rent_price_mist(&escrow).is_none());

    // — Resolved cycle params: present in Idle (resolved at integration time;
    // the four policy draws flow through the cycle cross-state, not cleared).
    assert!(escrow::cycle_floor_price_mist(&escrow).is_some());
    assert!(escrow::cycle_ceiling_ms(&escrow).is_some());
    assert!(escrow::cycle_handover_ms(&escrow).is_some());
    assert!(escrow::cycle_descent_ms(&escrow).is_some());

    // — Credit context — no tenancy → all none / false —
    assert!(!escrow::credit_is_accruing(&escrow));
    assert!(!escrow::credit_is_capped(&escrow));
    assert!(escrow::active_stake_balance_mist(&escrow).is_none());
    assert!(escrow::credit_capped_at_ms(&escrow).is_none());

    // — Pending transitions / config update — none in idle —
    let clk = clock::create_for_testing(sc.ctx());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!(escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_none());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!(!escrow::has_pending_ensemble_update(&escrow));
    clock::destroy_for_testing(clk);

    // — Cap status with an unknown ID — Stale in non-Renting state —
    let foreign = object::id_from_address(@0xDEAD);
    assert!(escrow::usufruct_cap_is_stale(&escrow, foreign));

    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── rented views ─────────────────────────────────────────────────────────────

#[test]
fun rented_views_post_rent() {
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    // Rent — pay min_rent_price as the usufructuary.
    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    // — Usufructuary slots — current populated, pending still empty —
    assert_eq!(escrow::active_usufructuary_addr(&escrow).destroy_some(),   USUFRUCTUARY_ADDR);
    assert_eq!(escrow::active_usufruct_cap_id(&escrow).destroy_some(), object::id(&t_cap));
    assert!(escrow::pending_usufructuary_addr(&escrow).is_none());
    assert!(escrow::pending_usufruct_cap_id(&escrow).is_none());
    assert_eq!(escrow::active_stake_balance_mist(&escrow).destroy_some(), STAKE);
    assert!(escrow::pending_stake_balance_mist(&escrow).is_none());

    // — Phase / runtime resolution — all populated under Renting state —
    let phase_start = escrow::phase_start_ms(&escrow).destroy_some();
    let expected_expiry = phase_start + escrow_corpus::tenure_ceiling_const();
    assert_eq!(escrow::tenure_expiry_ms(&escrow).destroy_some(), expected_expiry);
    assert_eq!(escrow::active_ceiling_total_ms(&escrow).destroy_some(), escrow_corpus::tenure_ceiling_const());
    let _ahd = escrow::active_handover_total_ms(&escrow); // Some (resolved at rent time)
    let _afp = escrow::cycle_floor_price_mist(&escrow);     // Some
    // last_acq_price is recorded only on Descent transitions, not on rent from Idle.
    assert!(escrow::last_rent_price_mist(&escrow).is_none());

    // — Credit context — accruing in Occupied-like Renting state —
    assert!(escrow::active_stake_balance_mist(&escrow).is_some());

    // — Cap status on the actual usufructuary cap —
    assert!(escrow::usufruct_cap_is_active(&escrow, object::id(&t_cap)));

    // Cleanup
    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── settlement views ────────────────────────────────────────────────────────

#[test]
fun settlement_views_in_rented_state() {
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    // tenure_settlement: aborts unless rented; here it succeeds and the
    // (governor + fee) split equals the current stake (no credit consumed yet).
    let (t_governor, t_fee) = escrow::tenure_settlement(&escrow);
    assert_eq!(t_governor + t_fee, STAKE);

    // handover_settlement at a mid-tenancy boundary: remaining + governor + fee
    // partition the current stake, with `remaining` being stake - used_credit.
    let phase_start = escrow::phase_start_ms(&escrow).destroy_some();
    let mid_boundary = phase_start + escrow_corpus::tenure_ceiling_const() / 2;
    let (h_rem, h_governor, h_fee) = escrow::handover_settlement(&escrow, mid_boundary);
    assert_eq!(h_rem + h_governor + h_fee, STAKE);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// Settlement views in Demand state: tenure_settlement and
/// handover_settlement operate on the *current* usufructuary's stake (not the
/// pending bidder's). Covers the Demand arm of `proj_active_stake_value`
/// and `proj_tenure_settlement`.
#[test]
fun settlement_views_in_demand_state() {
    let mut sc  = setup();
    // c=1 Fixed — prevents APT from immediately resolving the handover
    // inside the second rent call, keeping the escrow in Demand.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());

    // First rent: Idle → Occupied. Current usufructuary stake = STAKE.
    let payment1 = mk_payment(STAKE, sc.ctx());
    let t_cap1   = escrow::rent(&mut escrow, payment1, tenures::tenures(1), &clk, sc.ctx());

    // Second rent: Occupied → Demand (places a bid).
    let floor2   = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let payment2 = mk_payment(floor2, sc.ctx());
    let t_cap2   = escrow::rent(&mut escrow, payment2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // tenure_settlement in Demand: (governor + fee) partitions the current
    // usufructuary's stake.
    let (t_governor, t_fee) = escrow::tenure_settlement(&escrow);
    assert_eq!(t_governor + t_fee, STAKE);

    // handover_settlement in Demand: remaining + governor + fee partitions the
    // current usufructuary's stake at the requested boundary.
    let phase_start = escrow::phase_start_ms(&escrow).destroy_some();
    let boundary    = phase_start + escrow_corpus::tenure_ceiling_const() / 2;
    let (h_rem, h_governor, h_fee) = escrow::handover_settlement(&escrow, boundary);
    assert_eq!(h_rem + h_governor + h_fee, STAKE);

    transfer::public_transfer(t_cap1, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t_cap2, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── pending transitions and Descent entry ───────────────────────────────────

#[test]
fun descent_views_after_tenure_expiry() {
    let mut sc  = setup();
    // h=1 → Descent::Fixed; ensures the escrow enters Descent on tenure expiry
    // instead of collapsing back to Idle (which Descent::Skipped would do).
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    // Before tenure_expiry: no pending transition.
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));

    // next_boundary vs next_transition, the keeper distinction: BEFORE the boundary
    // nothing is *due* (next_transition_ms = none), yet the future boundary is
    // already exposed and equals tenure_expiry — what a keeper schedules on.
    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    assert!(escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_none());
    assert_eq!(escrow::next_boundary_ms(&escrow).destroy_some(), expiry);

    // Advance clock to tenure_expiry boundary.
    clock::set_for_testing(&mut clk, expiry);

    // Now a Tenure transition is pending — and next_boundary is unchanged (it is the
    // boundary, not its due-ness): both views agree once the boundary is crossed.
    assert!(escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!(escrow::is_occupied(&escrow));
    assert_eq!(escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some(), expiry);
    assert_eq!(escrow::next_boundary_ms(&escrow).destroy_some(), expiry);

    // Fire the transition → state advances to Descent (descent=Fixed).
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_descending(&escrow));
    assert!(!escrow::is_idle(&escrow));
    assert!(!escrow::is_rented(&escrow));

    // Descent records the last acquisition price and stores the resolved
    // descent window, plus the resolved values for the next bid.
    assert!(escrow::last_rent_price_mist(&escrow).is_some());
    assert!(escrow::cycle_descent_ms(&escrow).is_some());
    assert!(escrow::cycle_ceiling_ms(&escrow).is_some());
    assert!(escrow::cycle_handover_ms(&escrow).is_some());

    // Advance clock past the descent window: an Auction transition becomes pending.
    clock::set_for_testing(&mut clk, expiry + escrow_corpus::descent_window_h1_const() + 1);
    assert!(escrow::is_descending(&escrow));

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── Waiting::Retired ─────────────────────────────────────────────────────────

#[test]
fun retired_views_after_retire_from_idle() {
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(GOVERNOR);
    let clk    = clock::create_for_testing(sc.ctx());
    escrow::retire(&mut escrow, &cap, &clk, sc.ctx());

    // — State predicates —
    assert!(escrow::is_retired(&escrow));
    assert!(!escrow::is_idle(&escrow));
    assert!(!escrow::is_descending(&escrow));
    assert!(!escrow::is_rented(&escrow));
    assert!(!escrow::is_live(&escrow));            // Retired is the only inactive state
    assert!(!escrow::is_occupied(&escrow));
    assert!(!escrow::is_demand(&escrow));
    assert!(!escrow::is_retiring(&escrow));

    // — Usufructuary / phase / runtime resolution — all none in Retired —
    assert!(escrow::active_usufructuary_addr(&escrow).is_none());
    assert!(escrow::pending_usufructuary_addr(&escrow).is_none());
    assert!(escrow::active_stake_balance_mist(&escrow).is_none());
    assert!(escrow::phase_start_ms(&escrow).is_none());
    assert!(escrow::tenure_expiry_ms(&escrow).is_none());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));

    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── Renting::Demand ──────────────────────────────────────────────────────────

#[test]
fun demand_views_after_handover_bid() {
    let mut sc  = setup();
    // c=1 → handover=Fixed; second rent enters Demand (not Instant fire-through).
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());

    // First rent: Idle → Occupied at min_rent_price.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let t1_cap = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Second rent at a later time: Occupied → Demand. floor escalates by
    // state (compute_floor_price returns the right value for either state).
    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 5_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let t2_cap = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // — State predicates —
    assert!(escrow::is_demand(&escrow));
    assert!(!escrow::is_occupied(&escrow));
    assert!(escrow::is_rented(&escrow));
    assert!(escrow::is_live(&escrow));
    assert!(!escrow::is_retiring(&escrow));

    // — Both usufructuary slots populated —
    assert_eq!(escrow::active_usufructuary_addr(&escrow).destroy_some(),   USUFRUCTUARY_ADDR);
    assert_eq!(escrow::active_usufruct_cap_id(&escrow).destroy_some(), object::id(&t1_cap));
    assert_eq!(escrow::pending_usufructuary_addr(&escrow).destroy_some(),   second_usufructuary);
    assert_eq!(escrow::pending_usufruct_cap_id(&escrow).destroy_some(), object::id(&t2_cap));
    assert!(escrow::active_stake_balance_mist(&escrow).is_some());
    assert!(escrow::pending_stake_balance_mist(&escrow).is_some());

    // — Cap status: t1 current, t2 pending —
    assert!(escrow::usufruct_cap_is_active(&escrow, object::id(&t1_cap)));
    assert!(escrow::usufruct_cap_is_pending(&escrow, object::id(&t2_cap)));

    // — Handover countdown is active; expiry is recorded —
    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();

    // — Credit context flips Accruing → Capped on entering Demand; the cap is
    //   the handover countdown expiry so accrual freezes there.
    assert!(escrow::credit_is_capped(&escrow));
    assert!(!escrow::credit_is_accruing(&escrow));
    assert_eq!(escrow::credit_capped_at_ms(&escrow).destroy_some(), countdown_expiry);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── Renting::Occupied with retire flag (Retiring) ────────────────────────────

#[test]
fun retiring_flag_views_after_retire_during_renting() {
    let mut sc  = setup();
    // c=1 → Fixed handover; rules out Instant fire-through on retire.
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    // Rent.
    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    // Governor sets retire flag while in Occupied — flag is set, state remains
    // Occupied until tenure expiry handles it.
    sc.next_tx(GOVERNOR);
    escrow::retire(&mut escrow, &cap, &clk, sc.ctx());

    // — Predicates: still Occupied, but retiring flag is now true —
    assert!(escrow::is_occupied(&escrow));
    assert!(escrow::is_rented(&escrow));
    assert!(escrow::is_live(&escrow));
    assert!(escrow::is_retiring(&escrow));
    assert!(!escrow::is_demand(&escrow));
    assert!(!escrow::is_retired(&escrow));

    // — Current usufructuary unchanged by retire-flag-set —
    assert_eq!(escrow::active_usufructuary_addr(&escrow).destroy_some(), USUFRUCTUARY_ADDR);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── cartesian state × projector matrix ──────────────────────────────────────

/// Builds an escrow in each of the 5 state-machine leaves and asserts the
/// full projector vector via assert_projector_pattern. Closes the partial
/// coverage in asset_state's per-state match arms — each projector
/// is exercised on every reachable state in a single test.
#[test]
fun cartesian_state_projector_matrix() {
    let mut sc = setup();
    let ensemble           = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let cfg_countdown = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let cfg_fixed    = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));

    // — Idle —
    let (escrow, cap) = build_escrow(ensemble, &mut sc);
    assert_projector_pattern(&escrow, STATE_IDLE);
    dispose_escrow(escrow, cap);

    // — Retired (retire from Idle) —
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);
    sc.next_tx(GOVERNOR);
    let clk    = clock::create_for_testing(sc.ctx());
    escrow::retire(&mut escrow, &cap, &clk, sc.ctx());
    assert_projector_pattern(&escrow, STATE_RETIRED);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);

    // — Occupied (rent from Idle) —
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);
    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());
    assert_projector_pattern(&escrow, STATE_OCCUPIED);
    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);

    // — Demand (Fixed handover → second rent places a bid) —
    let (mut escrow, cap) = build_escrow(cfg_countdown, &mut sc);
    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let t1_cap = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 5_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let t2_cap = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert_projector_pattern(&escrow, STATE_DEMAND);
    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);

    // — Descent (Fixed descent → tenure expiry advances to Descent) —
    let (mut escrow, cap) = build_escrow(cfg_fixed, &mut sc);
    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());
    let expiry  = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert_projector_pattern(&escrow, STATE_AT_DUTCH);
    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);

    sc.end();
}

// ─── cap_is_* false-arm coverage ─────────────────────────────────────────────
//
// usufruct_cap_is_active/pending/stale call the internal cap_is_* predicates.
// The `_ => false` arms for Descent and Retired were uncovered because existing
// tests only used Idle or Renting states.

#[test]
fun usufruct_cap_views_in_descent_state() {
    let mut sc  = setup();
    // h=1 Fixed: tenure expires → Descent (does not immediately collapse).
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // In Descent: no active tenancy — any cap is stale.
    let cap_id = object::id(&t_cap);
    assert!(!escrow::usufruct_cap_is_active(&escrow, cap_id), 1);
    assert!(!escrow::usufruct_cap_is_pending(&escrow, cap_id), 2);
    assert!(escrow::usufruct_cap_is_stale(&escrow, cap_id),   3);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

#[test]
fun usufruct_cap_views_in_retired_state() {
    let mut sc  = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(GOVERNOR);
    // Drive Idle → Retired directly (no tenancy needed).
    escrow::drive_to_retired_for_testing(&mut escrow);

    // Use a synthetic cap ID — no active tenancy means any cap is stale.
    let synthetic_id = object::id_from_address(@0xCA1);
    assert!(!escrow::usufruct_cap_is_active(&escrow, synthetic_id), 0);
    assert!(!escrow::usufruct_cap_is_pending(&escrow, synthetic_id), 1);
    assert!(escrow::usufruct_cap_is_stale(&escrow, synthetic_id),   2);

    dispose_escrow(escrow, cap);
    sc.end();
}

/// cap_is_pending Occupied arm: Occupied has no pending cap, so
/// usufruct_cap_is_pending returns false (the _ => false branch for Occupied).
#[test]
fun usufruct_cap_is_pending_in_occupied_returns_false() {
    let mut sc  = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), 0);

    // In Occupied there is a current cap but no pending — is_pending is false.
    let cap_id = object::id(&t_cap);
    assert!( escrow::usufruct_cap_is_active(&escrow, cap_id), 1);
    assert!(!escrow::usufruct_cap_is_pending(&escrow, cap_id), 2);
    assert!(!escrow::usufruct_cap_is_stale(&escrow, cap_id),  3);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── §APT view-flip tests ─────────────────────────────────────────────────────
//
// Each test asserts the SAME view function immediately before and immediately
// after apply_pending_transition_states, verifying the return value changes
// across the APT boundary. A silent no-op implementation of APT would leave
// all views unchanged and fail these assertions.

#[test]
fun views_flip_across_tenure_expiry_to_idle() {
    // Occupied → Idle: tenure expires with descent=Skipped.
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);

    // ── Before APT ────────────────────────────────────────────────────────────
    assert!( escrow::is_occupied(&escrow));
    assert!(!escrow::is_idle(&escrow));
    assert!( escrow::is_rented(&escrow));
    assert!( escrow::active_usufructuary_addr(&escrow).is_some());
    assert!( escrow::active_stake_balance_mist(&escrow).is_some());
    assert!( escrow::tenure_expiry_ms(&escrow).is_some());
    assert!( escrow::cycle_floor_price_mist(&escrow).is_some());
    assert!( escrow::active_ceiling_total_ms(&escrow).is_some());
    assert!( escrow::cycle_ceiling_ms(&escrow).is_some());
    assert!( escrow::cycle_descent_ms(&escrow).is_some());
    assert!( escrow::credit_is_accruing(&escrow));
    assert!( escrow::active_stake_balance_mist(&escrow).is_some());
    assert!( escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_some());

    // ── APT ───────────────────────────────────────────────────────────────────
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // ── After APT ─────────────────────────────────────────────────────────────
    assert!(!escrow::is_occupied(&escrow));
    assert!( escrow::is_idle(&escrow));
    assert!(!escrow::is_rented(&escrow));
    assert!( escrow::active_usufructuary_addr(&escrow).is_none());
    assert!( escrow::active_stake_balance_mist(&escrow).is_none());
    assert!( escrow::tenure_expiry_ms(&escrow).is_none());
    assert!( escrow::cycle_floor_price_mist(&escrow).is_some());
    assert!( escrow::active_ceiling_total_ms(&escrow).is_none());
    assert!( escrow::cycle_ceiling_ms(&escrow).is_some());
    assert!( escrow::cycle_descent_ms(&escrow).is_some());
    assert!(!escrow::credit_is_accruing(&escrow));
    assert!( escrow::active_stake_balance_mist(&escrow).is_none());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_none());

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

#[test]
fun views_flip_across_tenure_expiry_to_descent() {
    // Occupied → Descent: tenure expires with descent=Fixed.
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);

    // ── Before APT ────────────────────────────────────────────────────────────
    assert!( escrow::is_occupied(&escrow));
    assert!(!escrow::is_descending(&escrow));
    assert!( escrow::is_rented(&escrow));
    assert!( escrow::active_usufructuary_addr(&escrow).is_some());
    assert!( escrow::active_stake_balance_mist(&escrow).is_some());
    assert!( escrow::cycle_floor_price_mist(&escrow).is_some());
    assert!( escrow::last_rent_price_mist(&escrow).is_none());
    assert!( escrow::cycle_ceiling_ms(&escrow).is_some());
    assert!( escrow::cycle_descent_ms(&escrow).is_some());
    assert!( escrow::credit_is_accruing(&escrow));
    assert!( escrow::active_stake_balance_mist(&escrow).is_some());
    assert!( escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_some());

    // ── APT ───────────────────────────────────────────────────────────────────
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // ── After APT ─────────────────────────────────────────────────────────────
    // Descent window starts now: no new pending transition until window expires.
    assert!(!escrow::is_occupied(&escrow));
    assert!( escrow::is_descending(&escrow));
    assert!(!escrow::is_rented(&escrow));
    assert!( escrow::active_usufructuary_addr(&escrow).is_none());
    assert!( escrow::active_stake_balance_mist(&escrow).is_none());
    assert!( escrow::cycle_floor_price_mist(&escrow).is_some());
    assert!( escrow::last_rent_price_mist(&escrow).is_some());
    assert!( escrow::cycle_ceiling_ms(&escrow).is_some());
    assert!( escrow::cycle_descent_ms(&escrow).is_some());
    assert!(!escrow::credit_is_accruing(&escrow));
    assert!( escrow::active_stake_balance_mist(&escrow).is_none());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_none());

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

#[test]
fun views_flip_across_auction_expiry_to_idle() {
    // Descent → Idle: descent window expires.
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Drive Occupied → Descent first.
    let tenure_expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, tenure_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow));

    // Advance clock past the descent window.
    let descent = escrow::cycle_descent_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, tenure_expiry + descent + 1);

    // ── Before APT ────────────────────────────────────────────────────────────
    assert!( escrow::is_descending(&escrow));
    assert!(!escrow::is_idle(&escrow));
    assert!( escrow::last_rent_price_mist(&escrow).is_some());
    assert!( escrow::phase_start_ms(&escrow).is_some());
    assert!( escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_some());

    // ── APT ───────────────────────────────────────────────────────────────────
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // ── After APT ─────────────────────────────────────────────────────────────
    assert!(!escrow::is_descending(&escrow));
    assert!( escrow::is_idle(&escrow));
    assert!( escrow::last_rent_price_mist(&escrow).is_none());
    assert!( escrow::phase_start_ms(&escrow).is_none());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_none());

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

#[test]
fun views_flip_across_handover_countdown_expiry() {
    // Demand → Occupied: handover countdown expires, pending usufructuary becomes current.
    // Uses c=1 (Fixed handover) so a second rent enters Demand state.
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    let t1_addr: address = @0xA1;
    let t2_addr: address = @0xA2;

    // t1 rents: Idle → Occupied.
    sc.next_tx(t1_addr);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // t2 rents at escalated floor: Occupied → Demand.
    sc.next_tx(t2_addr);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Advance to handover countdown expiry.
    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, countdown_expiry);

    // ── Before APT ────────────────────────────────────────────────────────────
    assert!( escrow::is_demand(&escrow));
    assert!(!escrow::is_occupied(&escrow));
    assert_eq!(escrow::active_usufructuary_addr(&escrow).destroy_some(), t1_addr);
    assert_eq!(escrow::pending_usufructuary_addr(&escrow).destroy_some(), t2_addr);
    assert!( escrow::pending_stake_balance_mist(&escrow).is_some());
    assert!( escrow::handover_expiry_ms(&escrow).is_some());
    assert!(!escrow::credit_is_accruing(&escrow));
    assert!( escrow::credit_is_capped(&escrow));
    assert!( escrow::credit_capped_at_ms(&escrow).is_some());
    assert!( escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_some());

    // ── APT ───────────────────────────────────────────────────────────────────
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // ── After APT ─────────────────────────────────────────────────────────────
    assert!(!escrow::is_demand(&escrow));
    assert!( escrow::is_occupied(&escrow));
    assert_eq!(escrow::active_usufructuary_addr(&escrow).destroy_some(), t2_addr);
    assert!( escrow::pending_usufructuary_addr(&escrow).is_none());
    assert!( escrow::pending_stake_balance_mist(&escrow).is_none());
    assert!( escrow::handover_expiry_ms(&escrow).is_none());
    assert!( escrow::credit_is_accruing(&escrow));
    assert!(!escrow::credit_is_capped(&escrow));
    assert!( escrow::credit_capped_at_ms(&escrow).is_none());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)));
    assert!( escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).is_none());

    transfer::public_transfer(t1_cap, t1_addr);
    transfer::public_transfer(t2_cap, t2_addr);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── active_usufructuary_time_remaining_ms ─────────────────────────────────

/// Occupied: remaining decreases as the clock advances; hits 0 at expiry.
#[test]
fun time_remaining_in_occupied_decreases_to_zero() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let payment  = mk_payment(STAKE, sc.ctx());
    let t_cap    = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    let expiry_ms = escrow::tenure_expiry_ms(&escrow).destroy_some();
    let ceiling   = escrow_corpus::tenure_ceiling_const();

    // At phase start: full ceiling remains.
    let r0 = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert!(r0 <= ceiling, 0);

    // At mid-tenure: roughly half remains.
    clock::set_for_testing(&mut clk, expiry_ms - ceiling / 2);
    let r1 = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert!(r1 <= ceiling / 2 + 1, 1);
    assert!(r1 > 0, 2);

    // At expiry: 0 remains (boundary crossed, clamped).
    clock::set_for_testing(&mut clk, expiry_ms);
    let r2 = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(r2, 0);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// Demand: remaining is measured against the handover countdown, not the tenure ceiling.
/// After a bid, the active usufructuary's horizon shrinks to the countdown expiry.
#[test]
fun time_remaining_in_demand_uses_handover_countdown() {
    let mut sc = setup();
    // c=1 Fixed handover → second rent enters Demand instead of firing through.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let p1      = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 5_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 0);

    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();
    let tenure_expiry    = escrow::tenure_expiry_ms(&escrow).destroy_some();

    // Remaining is bounded by countdown, not tenure ceiling.
    let remaining = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert!(remaining <= countdown_expiry - 5_000, 1);
    assert!(remaining < tenure_expiry - 5_000,     2);

    // At countdown expiry: 0 remains.
    clock::set_for_testing(&mut clk, countdown_expiry);
    let r2 = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(r2, 0);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// Non-renting states return None.
#[test]
fun time_remaining_is_none_outside_renting() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    assert!(escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).is_none(), 0);

    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// E2E: usufructuary has time remaining → bid arrives → remaining drops to countdown window.
#[test]
fun time_remaining_drops_when_bid_arrives() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let before_bid = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();

    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let after_bid = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();

    assert!(after_bid < before_bid, 0);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// E2E: usufructuary has time remaining → tenure expires with no next usufructuary → None.
#[test]
fun time_remaining_becomes_none_after_tenure_expiry() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).is_some(), 0);

    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).is_none(), 1);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// After APT fires a handover (Demand → Occupied), the view switches to the new
/// usufructuary's remaining time — t2's full tenure ceiling, not t1's frozen countdown.
#[test]
fun time_remaining_switches_to_new_usufructuary_after_handover() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    let second_usufructuary: address = @0xA2;

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 0);
    let t1_remaining_before_apt = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();

    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_occupied(&escrow), 1);
    assert_eq!(escrow::active_usufruct_cap_id(&escrow).destroy_some(), object::id(&t2_cap));

    let t2_remaining = escrow::active_usufructuary_time_remaining_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(t2_remaining, escrow_corpus::tenure_ceiling_const());
    assert!(t2_remaining != t1_remaining_before_apt, 2);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── active_stake_balance_remaining_mist ──────────────────────────────────────

/// Occupied: remaining stake equals full stake at start, decreases as credit accrues.
#[test]
fun stake_remaining_in_occupied_decreases_over_time() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let r0 = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(r0, STAKE);

    let expiry_ms = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry_ms / 2);
    let r1 = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert!(r1 < STAKE, 1);
    assert!(r1 > 0, 2);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// Demand: remaining stake is frozen at the handover countdown expiry (credit capped).
#[test]
fun stake_remaining_freezes_when_bid_arrives() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 0);

    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, countdown_expiry + 1);
    let frozen = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();

    clock::set_for_testing(&mut clk, countdown_expiry + 10_000);
    let still_frozen = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(frozen, still_frozen);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// Non-renting states return None.
#[test]
fun stake_remaining_is_none_outside_renting() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (escrow, cap) = build_escrow(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    assert!(escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).is_none(), 0);

    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// E2E: usufructuary has stake → bid arrives → remaining drops (bid shortened credit window).
#[test]
fun stake_remaining_drops_when_bid_arrives() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let before_bid = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(before_bid, STAKE);

    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let after_bid = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert!(after_bid < before_bid, 0);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// E2E: usufructuary has stake → tenure expires with no next usufructuary → None.
#[test]
fun stake_remaining_becomes_none_after_tenure_expiry() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).is_some(), 0);

    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).is_none(), 1);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// The bid caps credit at the countdown expiry, preserving more remaining stake than
/// Occupied would have at the same late timestamp. Two parallel escrows, same asset
/// and time: one stays Occupied, one gets bidded → bidded remaining > unbidded remaining
/// at tenure_expiry time.
#[test]
fun stake_remaining_in_demand_exceeds_occupied_at_late_time() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));

    // Escrow A: stays Occupied (no bid).
    let (mut escrow_a, cap_a) = build_escrow(ensemble, &mut sc);
    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t_cap_a = escrow::rent(&mut escrow_a, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Escrow B: same config, rent then receive a bid → Demand.
    let (mut escrow_b, cap_b) = build_escrow(ensemble, &mut sc);
    sc.next_tx(USUFRUCTUARY_ADDR);
    let t_cap_b = escrow::rent(&mut escrow_b, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let second_usufructuary: address = @0xA2;
    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::floor_price_mist(&escrow_b, clock::timestamp_ms(&clk));
    let t_cap_b2 = escrow::rent(&mut escrow_b, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow_b), 0);

    // At tenure_expiry: Occupied has consumed all credit; Demand froze at countdown.
    let tenure_expiry = escrow::tenure_expiry_ms(&escrow_a).destroy_some();
    clock::set_for_testing(&mut clk, tenure_expiry);

    let remaining_occupied = escrow::active_stake_balance_remaining_mist(&escrow_a, clock::timestamp_ms(&clk)).destroy_some();
    let remaining_demand   = escrow::active_stake_balance_remaining_mist(&escrow_b, clock::timestamp_ms(&clk)).destroy_some();

    assert!(remaining_demand > remaining_occupied, 1);

    transfer::public_transfer(t_cap_a,  USUFRUCTUARY_ADDR);
    transfer::public_transfer(t_cap_b,  USUFRUCTUARY_ADDR);
    transfer::public_transfer(t_cap_b2, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow_a, cap_a);
    dispose_escrow(escrow_b, cap_b);
    sc.end();
}

/// After APT fires a handover (Demand → Occupied), the view switches to the new
/// usufructuary's stake — t2's full stake, not t1's frozen remaining.
#[test]
fun stake_remaining_switches_to_new_usufructuary_after_handover() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    let second_usufructuary: address = @0xA2;

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk  = clock::create_for_testing(sc.ctx());
    let t1_cap   = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_stake = floor2;
    let t2_cap   = escrow::rent(&mut escrow, mk_payment(t2_stake, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 0);
    let t1_remaining_before_apt = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();

    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_occupied(&escrow), 1);
    assert_eq!(escrow::active_usufruct_cap_id(&escrow).destroy_some(), object::id(&t2_cap));

    let t2_remaining = escrow::active_stake_balance_remaining_mist(&escrow, clock::timestamp_ms(&clk)).destroy_some();
    assert_eq!(t2_remaining, t2_stake);
    assert!(t2_remaining != t1_remaining_before_apt, 2);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// At tenure start (now_ms = phase_start) the full ceiling remains;
/// at tenure end (now_ms = phase_start + ceiling) remaining is 0.
/// The u64 is passed directly — no clock required.
#[test]
fun time_remaining_boundaries_are_full_ceiling_and_zero() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    let phase_start = clock::timestamp_ms(&clk);
    let ceiling     = escrow_corpus::tenure_ceiling_const();

    let at_start = escrow::active_usufructuary_time_remaining_ms(&escrow, phase_start).destroy_some();
    assert_eq!(at_start, ceiling);

    let at_end = escrow::active_usufructuary_time_remaining_ms(&escrow, phase_start + ceiling).destroy_some();
    assert_eq!(at_end, 0);

    let past_end = escrow::active_usufructuary_time_remaining_ms(&escrow, phase_start + ceiling + 50_000).destroy_some();
    assert_eq!(past_end, 0);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// At tenure start (now_ms = phase_start) the full stake is unspent;
/// at tenure end (now_ms = phase_start + ceiling) credit equals the full
/// principal so remaining stake is 0.
/// The u64 is passed directly — no clock required.
#[test]
fun stake_remaining_boundaries_are_full_stake_and_zero() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk     = clock::create_for_testing(sc.ctx());
    let payment = mk_payment(STAKE, sc.ctx());
    let t_cap   = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    let phase_start = clock::timestamp_ms(&clk);
    let ceiling     = escrow_corpus::tenure_ceiling_const();

    let at_start = escrow::active_stake_balance_remaining_mist(&escrow, phase_start).destroy_some();
    assert_eq!(at_start, STAKE);

    let at_end = escrow::active_stake_balance_remaining_mist(&escrow, phase_start + ceiling).destroy_some();
    assert_eq!(at_end, 0);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

// ─── has_pending_transition_states / next_transition_ms — off-by-one ─────────

/// At tenure_expiry - 1 no transition is pending; at tenure_expiry exactly
/// one is. Boundary is now.ms >= boundary_ms (strict >=), so one millisecond
/// flips the predicate. u64 is passed directly — no clock object required.
#[test]
fun pending_transition_flips_at_tenure_expiry_boundary() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    sc.next_tx(USUFRUCTUARY_ADDR);
    let clk   = clock::create_for_testing(sc.ctx());
    let t_cap = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();

    assert!(!escrow::transition_is_ready(&escrow, expiry - 1));
    assert!( escrow::next_transition_ms(&escrow, expiry - 1).is_none());

    assert!( escrow::transition_is_ready(&escrow, expiry));
    assert_eq!(escrow::next_transition_ms(&escrow, expiry).destroy_some(), expiry);

    transfer::public_transfer(t_cap, USUFRUCTUARY_ADDR);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}

/// At handover_countdown_expiry - 1 no transition is pending; at
/// handover_countdown_expiry exactly one is. Same >= semantics as tenure expiry.
#[test]
fun pending_transition_flips_at_handover_countdown_boundary() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, cap) = build_escrow(ensemble, &mut sc);

    let second_usufructuary: address = @0xA2;

    sc.next_tx(USUFRUCTUARY_ADDR);
    let mut clk = clock::create_for_testing(sc.ctx());
    let t1_cap  = escrow::rent(&mut escrow, mk_payment(STAKE, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    sc.next_tx(second_usufructuary);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow));
    let countdown_expiry = escrow::handover_expiry_ms(&escrow).destroy_some();

    assert!(!escrow::transition_is_ready(&escrow, countdown_expiry - 1));
    assert!( escrow::next_transition_ms(&escrow, countdown_expiry - 1).is_none());

    assert!( escrow::transition_is_ready(&escrow, countdown_expiry));
    assert_eq!(escrow::next_transition_ms(&escrow, countdown_expiry).destroy_some(), countdown_expiry);

    transfer::public_transfer(t1_cap, USUFRUCTUARY_ADDR);
    transfer::public_transfer(t2_cap, second_usufructuary);
    clock::destroy_for_testing(clk);
    dispose_escrow(escrow, cap);
    sc.end();
}
