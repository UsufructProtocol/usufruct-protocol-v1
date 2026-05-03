// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_coordinator_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    clock,
    sui::SUI,
    test_scenario,
};
use usufruct::{
    escrow_coordinator::{Self, EscrowCoordinator},
    escrow_corpus,
    owner_cap,
    protocol_fee_inbox::{Self, ProtocolFeeRef},
    tenant::{Self, Tenant},
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER: address = @0x07;

/// Test asset — minimal key+store object that satisfies the
/// `Asset` bound on `EscrowCoordinator`.
public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

/// Initialise the protocol-fee singletons. Returns a scenario whose
/// next-tx state has the `ProtocolFeeRef` frozen and the
/// `ProtocolFeeInbox` owned by `OWNER`.
fun setup(): test_scenario::Scenario {
    let mut sc = test_scenario::begin(OWNER);
    {
        protocol_fee_inbox::init_for_testing(sc.ctx());
    };
    sc
}

/// Asserts the projected state is `Idle`, using `breadcrumb` (typically
/// the corpus τ2 tag) as the abort code on mismatch.
fun assert_tag_idle<Asset: key + store, CoinType>(
    escrow:    &EscrowCoordinator<Asset, CoinType>,
    breadcrumb: u64,
) {
    let actual = escrow_coordinator::state_tag(escrow);
    assert!(escrow_coordinator::is_tag_idle(&actual), breadcrumb);
}

const TENANT_ADDR_1: address = @0xA1;
const TENANT_ADDR_2: address = @0xA2;
const STAKE_T1:      u64     = 1_000_000_000;   // 1 SUI
const STAKE_T2:      u64     = 2_000_000_000;   // 2 SUI

fun cap_id_1(): ID { object::id_from_address(@0xCA1) }
fun cap_id_2(): ID { object::id_from_address(@0xCA2) }

fun mk_tenant(stake: u64, addr: address, cap: ID): Tenant<SUI> {
    tenant::new(cap, addr, balance::create_for_testing<SUI>(stake))
}

/// Integrate, share, then take the shared escrow back. Returns the
/// escrow + cap. Common shape for view tests.
fun integrate_and_take(
    cfg: usufruct::config::IntegrationConfig,
    sc:  &mut test_scenario::Scenario,
): (EscrowCoordinator<DemoAsset, SUI>, usufruct::owner_cap::OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let cap = escrow_coordinator::integrate<DemoAsset, SUI>(
        asset, cfg, &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);
    (escrow, cap)
}

// ─── §1. integrate — happy path (single-config smoke) ─────────────────────────

#[test]
fun integrate_creates_idle_escrow_smoke() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let cfg     = escrow_corpus::by_tag(0); // c=0 instant, d=0 fixed, e=0 linear, h=0 skipped, f=0 immediate
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap = escrow_coordinator::integrate<DemoAsset, SUI>(
        asset, cfg, &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::escrow_id(&cap);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);
    assert_tag_idle(&escrow, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §2. integrate — corpus projection ───────────────────────────────────────

/// §10.1 — integrate is universally applicable. Sweeps the C axis
/// (HandoverPolicy ∈ {Instant, Countdown, FixedTime}) — three
/// behaviorally distinct handover modes — at fixed (d=0, e=0, h=0, f=0).
/// Verifies the post-condition `state_tag == Idle` for each.
///
/// The full 168-config corpus is unnecessary here: integrate does not
/// branch on policy / curve / price values; it only stores the cfg.
/// A C-axis sweep is the minimum projection that exercises the named
/// protocol modes (per the corpus operational rule: "Default to the
/// minimum projection, not all_configs()"). Cross-axis sweeps belong
/// in commits where the behavior actually depends on those axes
/// (curve sweeps in C2 views; descent sweeps in C4 boundary handlers).
#[test]
fun integrate_idle_across_handover_modes() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let mut c: u8 = 0;
    while (c <= 2) {
        let tag = escrow_corpus::tag(c, 0, 0, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);

        let fee_ref = sc.take_immutable<ProtocolFeeRef>();
        let clk     = clock::create_for_testing(sc.ctx());
        let asset   = mk_demo_asset(sc.ctx());

        let cap = escrow_coordinator::integrate<DemoAsset, SUI>(
            asset, cfg, &fee_ref, &clk, sc.ctx(),
        );
        let escrow_id = owner_cap::escrow_id(&cap);

        clock::destroy_for_testing(clk);
        test_scenario::return_immutable(fee_ref);
        owner_cap::burn(cap, OWNER);

        sc.next_tx(OWNER);
        let escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);
        assert_tag_idle(&escrow, tag);
        test_scenario::return_shared(escrow);

        c = c + 1;
    };
    sc.end();
}

// ─── §3. take/put discipline ─────────────────────────────────────────────────

/// The take_state/put_state hot-potato cycle is a no-op on the state
/// (round-trips the `Option<LifecycleState>` value). Verifies the
/// `StateReceipt` discipline mechanically: take produces a receipt;
/// put consumes it; state_tag is unchanged after the cycle.
#[test]
fun take_put_no_op_preserves_state_tag() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let cfg     = escrow_corpus::by_tag(0);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap       = escrow_coordinator::integrate<DemoAsset, SUI>(asset, cfg, &fee_ref, &clk, sc.ctx());
    let escrow_id = owner_cap::escrow_id(&cap);

    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared_by_id<EscrowCoordinator<DemoAsset, SUI>>(escrow_id);

    assert_tag_idle(&escrow, 0);
    escrow_coordinator::take_put_no_op_for_testing(&mut escrow);
    assert_tag_idle(&escrow, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §4. split_fee — pure 90/10 split ─────────────────────────────────────────

#[test]
fun split_fee_partitions_into_owner_share_plus_protocol_fee() {
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(10_000_000_000);
    // 10 SUI * 10% protocol fee = 1 SUI fee, 9 SUI owner.
    assert_eq!(fee_amt,   1_000_000_000);
    assert_eq!(owner_amt, 9_000_000_000);
}

#[test]
fun split_fee_floors_to_zero_below_threshold() {
    // Below 10 base units, mul_div(amount, 1000, 10000) = 0.
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(9);
    assert_eq!(fee_amt,   0);
    assert_eq!(owner_amt, 9);
}

#[test]
fun split_fee_zero_in_zero_out() {
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(0);
    assert_eq!(fee_amt,   0);
    assert_eq!(owner_amt, 0);
}

#[test]
fun split_fee_exact_threshold_yields_one_fee() {
    // mul_div(10, 1000, 10000) = 1.
    let (owner_amt, fee_amt) = escrow_coordinator::split_fee_for_testing(10);
    assert_eq!(fee_amt,   1);
    assert_eq!(owner_amt, 9);
}

// ─── §5. compute_floor_price ─────────────────────────────────────────────────

/// Idle returns `min_rent_price`. The corpus pins this to 10 SUI for
/// every config — the property is config-independent.
#[test]
fun floor_price_idle_returns_min_rent_price() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take(cfg, &mut sc);
    let price = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert_eq!(price, escrow_corpus::min_rent_price_const());
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// HandoverOpen returns `f_next_rent_price(current_stake)`. Sweeps
/// the D axis (PriceFunction): d=0 (FixedDelta) and d=1 (CompoundDelta)
/// — the only axis compute_next_rent_price actually consumes.
#[test]
fun floor_price_handover_open_escalates_current_stake() {
    let mut sc = setup();
    let mut d: u8 = 0;
    while (d <= 1) {
        let tag = escrow_corpus::tag(0, d, 0, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        escrow_coordinator::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );

        let price = escrow_coordinator::compute_floor_price(&escrow, 0);
        // f_next > current_stake regardless of policy — both FixedDelta
        // (delta>0) and CompoundDelta (bps>0, delta>0) are strictly
        // increasing. Spec contract; do not duplicate the formula.
        assert!(price > STAKE_T1, tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        d = d + 1;
    };
    sc.end();
}

/// HandoverConfirmed returns `f_next_rent_price(pending_stake)`.
/// Sweeps D as above, but the input stake is t2's (the bidder's).
#[test]
fun floor_price_handover_confirmed_escalates_pending_stake() {
    let mut sc = setup();
    let mut d: u8 = 0;
    while (d <= 1) {
        let tag = escrow_corpus::tag(0, d, 0, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        escrow_coordinator::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );
        escrow_coordinator::drive_to_demand_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
            10_000,
        );

        let price = escrow_coordinator::compute_floor_price(&escrow, 0);
        assert!(price > STAKE_T2, tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        d = d + 1;
    };
    sc.end();
}

/// AtDutch at t=phase_start (elapsed=0) returns `last_acquisition_price`
/// (curve evaluated at 0 → 0 consumed). Sweeps E (curve dimension) at
/// fixed h=1 (descent=Window). The boundary `g(0)=0` is universal
/// across all 7 curves.
#[test]
fun floor_price_at_dutch_at_t0_equals_last_acq_price() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 1, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        escrow_coordinator::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );
        // Drive HandoverOpen → AtDutch with last_acq_price > min_rent_price
        // so the spread is positive (otherwise the assertion would be
        // trivial: last_acq_price - 0 = last_acq_price for any curve).
        let last_acq = escrow_corpus::min_rent_price_const() * 2;
        let boundary_ms = 100_000;
        escrow_coordinator::drive_to_at_dutch_for_testing(
            &mut escrow, STAKE_T1, 0, last_acq, boundary_ms,
        );

        // At elapsed=0, descent has consumed 0 — price equals last_acq.
        let price = escrow_coordinator::compute_floor_price(&escrow, boundary_ms);
        assert!(price == last_acq, tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        e = e + 1;
    };
    sc.end();
}

/// AtDutch at t=phase_start+ceiling (full descent) collapses to
/// `min_rent_price` for every curve (g(t_max)=SCALE → consumed=spread).
#[test]
fun floor_price_at_dutch_at_full_descent_equals_min_rent_price() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 1, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        escrow_coordinator::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );
        let last_acq    = escrow_corpus::min_rent_price_const() * 2;
        let phase_start = 100_000;
        escrow_coordinator::drive_to_at_dutch_for_testing(
            &mut escrow, STAKE_T1, 0, last_acq, phase_start,
        );

        // At elapsed=ceiling, descent saturates → price = min_rent_price.
        let now = phase_start + escrow_corpus::descent_window_h1_const();
        let price = escrow_coordinator::compute_floor_price(&escrow, now);
        assert!(price == escrow_corpus::min_rent_price_const(), tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        e = e + 1;
    };
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ERetiredNoBid, location = usufruct::escrow_coordinator)]
fun floor_price_aborts_on_retired() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow);
    let _ = escrow_coordinator::compute_floor_price(&escrow, 0);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ─── §6. compute_used_credit ─────────────────────────────────────────────────

/// At elapsed=0 (timestamp == phase_start), every credit_curve
/// evaluates to 0 → used_credit = 0. Sweeps E (curve dimension) — the
/// boundary g(0)=0 is universal.
#[test]
fun used_credit_at_phase_start_is_zero_for_all_curves() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        let phase_start = 1_000_000;
        escrow_coordinator::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            phase_start,
        );

        let used = escrow_coordinator::compute_used_credit(&escrow, phase_start);
        assert!(used == 0, tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        e = e + 1;
    };
    sc.end();
}

/// At elapsed=tenure_ceiling, every credit_curve saturates to SCALE →
/// used_credit = principal (full stake consumed). Sweeps E.
#[test]
fun used_credit_at_tenure_ceiling_equals_principal_for_all_curves() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        let phase_start = 1_000_000;
        escrow_coordinator::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            phase_start,
        );

        let now = phase_start + escrow_corpus::tenure_ceiling_const();
        let used = escrow_coordinator::compute_used_credit(&escrow, now);
        assert!(used == STAKE_T1, tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        e = e + 1;
    };
    sc.end();
}

/// HandoverConfirmed clamps the effective time at
/// `handover_countdown_expiry`. With c=1 (Countdown(25_000)), a
/// callback at far-future timestamp yields the same used_credit as
/// one at exactly the expiry — the clamp is the load-bearing property.
#[test]
fun used_credit_handover_confirmed_clamps_at_expiry() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)); // c=1 Countdown
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

    let phase_start = 1_000_000;
    escrow_coordinator::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        phase_start,
    );
    let countdown_expiry = phase_start + escrow_corpus::handover_countdown_c1_const();
    escrow_coordinator::drive_to_demand_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
        countdown_expiry,
    );

    let at_expiry  = escrow_coordinator::compute_used_credit(&escrow, countdown_expiry);
    let far_future = escrow_coordinator::compute_used_credit(&escrow, countdown_expiry + 1_000_000);
    assert_eq!(at_expiry, far_future);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ENotRented, location = usufruct::escrow_coordinator)]
fun used_credit_aborts_on_idle() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take(cfg, &mut sc);
    let _ = escrow_coordinator::compute_used_credit(&escrow, 0);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ENotRented, location = usufruct::escrow_coordinator)]
fun used_credit_aborts_on_at_dutch() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);
    escrow_coordinator::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow_coordinator::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const(), 100_000,
    );
    let _ = escrow_coordinator::compute_used_credit(&escrow, 100_000);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ENotRented, location = usufruct::escrow_coordinator)]
fun used_credit_aborts_on_retired() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow);
    let _ = escrow_coordinator::compute_used_credit(&escrow, 0);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}
