// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_coordinator_tests;

use std::unit_test::assert_eq;
use sui::{
    balance,
    clock,
    coin::{Self, Coin},
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    asset,
    escrow_coordinator::{
        Self,
        EscrowCoordinator,
        RentStarted,
        BidPlaced,
        BidSuperseded,
        HandoverCompleted,
        TenureExpired,
        AuctionExpired,
        AssetRetired,
        RetireFlagSet,
        EarningsWithdrawn,
        AssetClaimed,
        AssetBorrowed,
        AssetReturned,
    },
    escrow_corpus,
    fee_message::FeeMessageSent,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox::{Self, ProtocolFeeRef},
    tenant::{Self, Tenant},
    tenant_cap,
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
fun setup(): Scenario {
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

fun mk_payment(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::from_balance(balance::create_for_testing<SUI>(amount), ctx)
}

/// Integrate, share, then take the shared escrow back. Returns the
/// escrow + cap. Common shape for view tests.
fun integrate_and_take(
    cfg: usufruct::config::IntegrationConfig,
    sc:  &mut Scenario,
): (EscrowCoordinator<DemoAsset, SUI>, OwnerCap) {
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

// ─── §7. rent — dispatch to do_install_new_tenant ────────────────────────────

/// Idle → HandoverOpen via rent. Verifies state_tag transitions and
/// RentStarted carries from_state=Idle.
#[test]
fun rent_from_idle_installs_new_tenant() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let floor = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor, sc.ctx());
    let t_cap = escrow_coordinator::rent(&mut escrow, payment, &clk, sc.ctx());

    // Post-condition: state is HandoverOpen.
    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_handover_open(&tag), 0);

    // Event check: exactly one RentStarted with from_state=Idle and
    // tenant_cap_id matching the returned cap.
    let started = event::events_by_type<RentStarted>();
    assert_eq!(started.length(), 1);
    let from = escrow_coordinator::rent_started_from_state(&started[0]);
    assert!(escrow_coordinator::is_tag_idle(&from), 1);
    assert_eq!(escrow_coordinator::rent_started_tenant_cap_id(&started[0]), object::id(&t_cap));
    assert_eq!(escrow_coordinator::rent_started_price_paid(&started[0]), floor);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// AtDutch → HandoverOpen via rent. RentStarted.from_state = AtDutchAuction.
#[test]
fun rent_from_at_dutch_installs_new_tenant() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));  // h=1 for non-zero descent window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Drive to AtDutch via test-only helpers.
    escrow_coordinator::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    let last_acq = escrow_corpus::min_rent_price_const() * 2;
    escrow_coordinator::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, last_acq, escrow_corpus::tenure_ceiling_const(),
    );

    // Sample mid-descent — APT must NOT fire auction_expiry yet (the
    // descent window has not elapsed).
    let now   = escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now);
    let floor = escrow_coordinator::compute_floor_price(&escrow, now);

    let payment = mk_payment(floor, sc.ctx());
    let t_cap = escrow_coordinator::rent(&mut escrow, payment, &clk, sc.ctx());

    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_handover_open(&tag), 0);

    let started = event::events_by_type<RentStarted>();
    assert_eq!(started.length(), 1);
    let from = escrow_coordinator::rent_started_from_state(&started[0]);
    assert!(escrow_coordinator::is_tag_at_dutch_auction(&from), 1);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §8. rent — dispatch to do_place_bid ─────────────────────────────────────

/// HandoverOpen → HandoverConfirmed via rent. BidPlaced carries
/// the pre-computed handover_countdown_expiry. Sweeps the C axis
/// (HandoverPolicy) since handover_policy::expiry_at depends on it.
#[test]
fun rent_from_handover_open_places_bid() {
    let mut sc = setup();
    let mut c: u8 = 0;
    while (c <= 2) {
        let tag_cfg = escrow_corpus::tag(c, 0, 0, 0, 0);
        let cfg     = escrow_corpus::by_tag(tag_cfg);
        let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());

        // First rent: Idle → HandoverOpen.
        let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
        let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

        // Second rent: HandoverOpen → HandoverConfirmed.
        let now2 = 5_000;
        clock::set_for_testing(&mut clk, now2);
        let floor2 = escrow_coordinator::compute_floor_price(&escrow, now2);
        let p2 = mk_payment(floor2, sc.ctx());
        let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());

        let tag = escrow_coordinator::state_tag(&escrow);
        assert!(escrow_coordinator::is_tag_handover_confirmed(&tag), tag_cfg);

        // Verify a BidPlaced event was emitted with cap_t2.
        let placed = event::events_by_type<BidPlaced>();
        assert!(placed.length() == 1, tag_cfg);
        assert_eq!(escrow_coordinator::bid_placed_tenant_cap_id(&placed[0]), object::id(&cap_t2));
        // The expiry was stamped — its specific value depends on c
        // (Instant: now+0 = now2; Countdown: min(now2+25_000, phase_start+ceiling);
        // FixedTime: phase_start+ceiling). Property: expiry > 0.
        assert!(escrow_coordinator::bid_placed_handover_countdown_expiry(&placed[0]) > 0, tag_cfg);

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        clock::destroy_for_testing(clk);
        c = c + 1;
    };
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ERetireFlagBlocksBid, location = usufruct::escrow_coordinator)]
fun rent_from_handover_open_aborts_when_retiring_flag_set() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // First rent: Idle → HandoverOpen.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    // Lift the retiring flag (real `retire`/`do_set_retiring_flag`
    // arrive in C5; the drive helper exercises the place_bid guard
    // in isolation here).
    escrow_coordinator::drive_to_retiring_flag_for_testing(&mut escrow);

    // Second rent: HandoverOpen + retiring=true → must abort.
    let p2 = mk_payment(escrow_corpus::min_rent_price_const() * 2, sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §9. rent — dispatch to do_supersede_bid ─────────────────────────────────

/// HandoverConfirmed → HandoverConfirmed via rent. The displaced
/// bidder's full stake is refunded (RefundState::Total → liquidate).
/// State tag is unchanged; pending cap_id is replaced.
#[test]
fun rent_from_handover_confirmed_supersedes_bid() {
    let mut sc = setup();
    // c=1 (Countdown) — non-zero handover-countdown so APT does NOT
    // fire handover at the third rent before supersede can run.
    let cfg     = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    let p2_amt = escrow_corpus::min_rent_price_const() * 2;
    let p2 = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());

    // Third rent supersedes t2.
    let now3 = 1_000;
    clock::set_for_testing(&mut clk, now3);
    let floor3 = escrow_coordinator::compute_floor_price(&escrow, now3);
    let p3 = mk_payment(floor3, sc.ctx());
    let cap_t3 = escrow_coordinator::rent(&mut escrow, p3, &clk, sc.ctx());

    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_handover_confirmed(&tag), 0);

    // Verify BidSuperseded carries the displaced bid amount.
    let superseded = event::events_by_type<BidSuperseded>();
    assert_eq!(superseded.length(), 1);
    assert_eq!(escrow_coordinator::bid_superseded_displaced_cap_id(&superseded[0]), object::id(&cap_t2));
    assert_eq!(escrow_coordinator::bid_superseded_new_cap_id(&superseded[0]), object::id(&cap_t3));
    assert_eq!(escrow_coordinator::bid_superseded_refunded_amount(&superseded[0]), p2_amt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §10. rent — abort paths ─────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = escrow_coordinator::EInsufficientPayment, location = usufruct::escrow_coordinator)]
fun rent_below_floor_aborts() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let payment = mk_payment(escrow_corpus::min_rent_price_const() - 1, sc.ctx());
    let cap = escrow_coordinator::rent(&mut escrow, payment, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ERetiredNoBid, location = usufruct::escrow_coordinator)]
fun rent_from_retired_aborts() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow);

    let payment = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap = escrow_coordinator::rent(&mut escrow, payment, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §11. do_handover ────────────────────────────────────────────────────────

/// HandoverConfirmed → HandoverOpen via the boundary handler.
/// Verifies: state transition, owner balance increases by owner_share,
/// HandoverCompleted carries used_credit = owner_share + protocol_fee
/// and remain_credit = principal − used_credit.
/// Uses c=1 (Countdown) + e=0 (Linear) so used_credit fires
/// mid-tenure (Parcial branch — remainder > 0).
#[test]
fun do_handover_routes_funds_and_emits_event_parcial() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Drive to HandoverConfirmed via two rent calls.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let phase_start = 0;

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow_coordinator::compute_floor_price(&escrow, now2);
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());

    let principal_t1 = escrow_corpus::min_rent_price_const();
    let owner_before = escrow_coordinator::owner_value_for_testing(&escrow);

    // Fire do_handover at the handover-countdown expiry.
    let boundary_ms = phase_start + escrow_corpus::handover_countdown_c1_const() + now2;
    // Ensure boundary < tenure: 25_000 + 5_000 = 30_000 < 100_000.
    let used_credit_expected = escrow_coordinator::compute_used_credit(&escrow, boundary_ms);
    escrow_coordinator::fire_do_handover_for_testing(&mut escrow, boundary_ms, sc.ctx());

    // Post-condition: HandoverOpen, current is t2.
    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_handover_open(&tag), 0);

    // Owner balance increased by the owner share (90% of used_credit).
    let owner_after = escrow_coordinator::owner_value_for_testing(&escrow);
    let owner_share_expected = used_credit_expected - used_credit_expected / 10;  // 90%
    assert!(owner_after - owner_before == owner_share_expected, 1);

    // HandoverCompleted event emitted with consistent figures.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    let used_credit = escrow_coordinator::handover_completed_used_credit(&completed[0]);
    let owner_share = escrow_coordinator::handover_completed_owner_share(&completed[0]);
    let protocol_fee = escrow_coordinator::handover_completed_protocol_fee(&completed[0]);
    let remain_credit = escrow_coordinator::handover_completed_remain_credit(&completed[0]);
    // Conservation: split adds up to used_credit; remain matches.
    assert_eq!(owner_share + protocol_fee, used_credit);
    assert_eq!(used_credit + remain_credit, principal_t1);

    // FeeMessage was posted (one for the protocol_fee).
    let sent = event::events_by_type<FeeMessageSent<SUI>>();
    assert_eq!(sent.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §12. do_tenure_expiry ───────────────────────────────────────────────────

/// HandoverOpen → AtDutch via tenure boundary. Refund is always
/// Nothing (full stake consumed: owner+fee). last_acquisition_price
/// equals the principal at boundary.
#[test]
fun do_tenure_expiry_routes_full_stake_and_anchors_at_dutch() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let principal = escrow_corpus::min_rent_price_const();

    let owner_before = escrow_coordinator::owner_value_for_testing(&escrow);
    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow_coordinator::fire_do_tenure_expiry_for_testing(&mut escrow, boundary_ms, sc.ctx());

    // Post-condition: NotRented + AtDutch.
    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_at_dutch_auction(&tag), 0);

    // Owner balance += owner_share (90% of full principal).
    let owner_share_expected = principal - principal / 10;
    let owner_after = escrow_coordinator::owner_value_for_testing(&escrow);
    assert!(owner_after - owner_before == owner_share_expected, 1);

    // TenureExpired carries the canonical anchor price = principal.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(escrow_coordinator::tenure_expired_last_acq_price(&expired[0]), principal);
    assert_eq!(escrow_coordinator::tenure_expired_owner_share(&expired[0]) +
               escrow_coordinator::tenure_expired_protocol_fee(&expired[0]), principal);
    let next = escrow_coordinator::tenure_expired_next_state(&expired[0]);
    assert!(escrow_coordinator::is_tag_at_dutch_auction(&next), 2);

    // No AssetRetired (retiring flag was not set).
    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 0);

    // FeeMessage was posted.
    let sent = event::events_by_type<FeeMessageSent<SUI>>();
    assert_eq!(sent.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// HandoverOpen + retiring=true → tenure expiry transitions directly
/// to Retired (skipping AtDutch). AssetRetired co-emits with
/// TenureExpired.
#[test]
fun do_tenure_expiry_with_retiring_flag_collapses_to_retired() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    // Lift retiring flag (real retire arrives in C5).
    escrow_coordinator::drive_to_retiring_flag_for_testing(&mut escrow);

    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow_coordinator::fire_do_tenure_expiry_for_testing(&mut escrow, boundary_ms, sc.ctx());

    // Post-condition: NotRented + Retired (not AtDutch).
    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_retired(&tag), 0);

    // Both events emitted: TenureExpired (next_state=Retired) + AssetRetired.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    let next = escrow_coordinator::tenure_expired_next_state(&expired[0]);
    assert!(escrow_coordinator::is_tag_retired(&next), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);
    let from = escrow_coordinator::asset_retired_from_state(&retired[0]);
    assert!(escrow_coordinator::is_tag_handover_open(&from), 2);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §13. do_auction_expiry ──────────────────────────────────────────────────

// ─── §14. retire ─────────────────────────────────────────────────────────────

/// retire from Idle → Retired in one call. Co-emits RetireFlagSet
/// (state_at_set=Idle) and AssetRetired (from_state=Idle).
#[test]
fun retire_from_idle_collapses_to_retired() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0); // f=0 immediate
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let tag_after = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_retired(&tag_after), 0);
    assert!(escrow_coordinator::is_tag_retired(&escrow_coordinator::state_tag(&escrow)), 1);

    let flagged = event::events_by_type<RetireFlagSet>();
    assert_eq!(flagged.length(), 1);
    let prev = escrow_coordinator::retire_flag_set_state_at_set(&flagged[0]);
    assert!(escrow_coordinator::is_tag_idle(&prev), 2);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);
    let from = escrow_coordinator::asset_retired_from_state(&retired[0]);
    assert!(escrow_coordinator::is_tag_idle(&from), 3);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// retire from AtDutch → Retired (same flow as Idle, different
/// from_state). Drives via the test-only AtDutch helper.
#[test]
fun retire_from_at_dutch_collapses_to_retired() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow_coordinator::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow_coordinator::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );

    let tag_after = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_retired(&tag_after), 0);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);
    let from = escrow_coordinator::asset_retired_from_state(&retired[0]);
    assert!(escrow_coordinator::is_tag_at_dutch_auction(&from), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// retire from HandoverOpen → flag set; state stays HandoverOpen.
/// RetireFlagSet emitted with state_at_set=HandoverOpen; no AssetRetired
/// (the asset stays with the tenant until tenure expiry).
#[test]
fun retire_from_handover_open_only_lifts_flag() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    let tag_after = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_handover_open(&tag_after), 0);
    assert!(escrow_coordinator::is_tag_handover_open(&escrow_coordinator::state_tag(&escrow)), 1);

    let flagged = event::events_by_type<RetireFlagSet>();
    assert_eq!(flagged.length(), 1);
    let prev = escrow_coordinator::retire_flag_set_state_at_set(&flagged[0]);
    assert!(escrow_coordinator::is_tag_handover_open(&prev), 2);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EAlreadyRetired, location = usufruct::escrow_coordinator)]
fun retire_when_already_retired_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow);
    let _ = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EAlreadyRetired, location = usufruct::escrow_coordinator)]
fun retire_when_already_retiring_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let _ = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    // Second call must fail — flag is already set.
    let _ = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EWrongEscrowOwnerCap, location = usufruct::escrow_coordinator)]
fun retire_with_wrong_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Mint a foreign cap bound to a different escrow_id.
    let foreign_cap = owner_cap::new(object::id_from_address(@0xDEAD), OWNER, sc.ctx());
    let _ = escrow_coordinator::retire(&mut escrow, &foreign_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    owner_cap::burn(foreign_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ERetireFloorNotElapsed, location = usufruct::escrow_coordinator)]
fun retire_before_floor_aborts_under_deferred_policy() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 1)); // f=1 deferred
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    // clock at 0 is far below the deferred floor (10_000_000).
    let _ = escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §13. do_auction_expiry ──────────────────────────────────────────────────

/// AtDutch → Idle via auction boundary. No tenant funds; only emits
/// AuctionExpired.
#[test]
fun do_auction_expiry_returns_to_idle() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);

    // Drive Idle → HandoverOpen → AtDutch via test helpers.
    escrow_coordinator::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow_coordinator::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );

    let boundary_ms = 100_000 + escrow_corpus::descent_window_h1_const();
    escrow_coordinator::fire_do_auction_expiry_for_testing(&mut escrow, boundary_ms);

    let tag = escrow_coordinator::state_tag(&escrow);
    assert!(escrow_coordinator::is_tag_idle(&tag), 0);

    let expired = event::events_by_type<AuctionExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(escrow_coordinator::auction_expired_timestamp_ms(&expired[0]), boundary_ms);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

// ─── §15. apply_pending_transitions ──────────────────────────────────────────

/// APT no-ops when nothing is due. Tag unchanged after the call.
#[test]
fun apt_noop_when_nothing_due() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Idle escrow at clock=0; no transitions are due.
    let tag = escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_idle(&tag), 0);
    assert!(escrow_coordinator::is_tag_idle(&escrow_coordinator::state_tag(&escrow)), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// APT fires handover when the handover-countdown expires.
/// c=1 (Countdown); after rent → place_bid, jump clock past expiry,
/// call APT. State becomes HandoverOpen (handover fired).
#[test]
fun apt_fires_handover_when_countdown_expires() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow_coordinator::compute_floor_price(&escrow, now2);
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_handover_confirmed(&escrow_coordinator::state_tag(&escrow)), 0);

    // Jump clock past the countdown expiry.
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry + 1);
    let tag = escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // Handover fired: HandoverConfirmed → HandoverOpen (t2 now t1).
    assert!(escrow_coordinator::is_tag_handover_open(&tag), 1);

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(escrow_coordinator::handover_completed_timestamp_ms(&completed[0]), countdown_expiry);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// APT fires tenure expiry when the rental's tenure elapses.
#[test]
fun apt_fires_tenure_expiry_when_elapsed() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    // Jump clock past the tenure boundary.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    let tag = escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // Tenure expired: HandoverOpen → AtDutch (h=1 window).
    assert!(escrow_coordinator::is_tag_at_dutch_auction(&tag), 0);

    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// APT cascade: rent → tenure expires → auction also expires under
/// h=0 (Skipped descent) → state collapses to Idle in one APT call.
/// Spec scenario M6b (HandoverOpen → AtDutchAuction → Idle in one
/// pass). Verifies the cascade order and that MAX_APT_ITERATIONS
/// holds (3 iterations needed: tenure, auction; the no-op final
/// iteration to confirm steady state).
#[test]
fun apt_cascade_tenure_then_auction_skipped() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0)); // h=0 Skipped
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    let tag = escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // Cascade: HandoverOpen → AtDutch (tenure_expiry) → Idle (auction_expiry under h=0 collapses to phase_start, immediately expired).
    assert!(escrow_coordinator::is_tag_idle(&tag), 0);

    let tenure_e = event::events_by_type<TenureExpired>();
    assert_eq!(tenure_e.length(), 1);
    let auction_e = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_e.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.1 borrow_asset / return_asset ──────────────────────────────────────

/// Happy path: rent → borrow → return cycles through the asset slot.
/// The receipt's three internal asserts (cross-escrow, asset-swap,
/// receipt-mismatch) all pass on a well-formed return.
#[test]
fun borrow_asset_then_return_completes_cycle() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    let (asset_out, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    let borrowed = event::events_by_type<AssetBorrowed>();
    assert_eq!(borrowed.length(), 1);

    escrow_coordinator::return_asset(&mut escrow, asset_out, receipt);
    let returned = event::events_by_type<AssetReturned>();
    assert_eq!(returned.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EWrongEscrowTenantCap, location = usufruct::escrow_coordinator)]
fun borrow_asset_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let (foreign_cap, _) = tenant_cap::new(object::id_from_address(@0xDEAD), TENANT_ADDR_1, sc.ctx());

    let (a, r) = escrow_coordinator::borrow_asset(&mut escrow, &foreign_cap, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(foreign_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EStaleTenantCap, location = usufruct::escrow_coordinator)]
fun borrow_asset_from_idle_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Mint a cap bound to this escrow but never used (no active rental).
    let escrow_id = object::id(&escrow);
    let (cap, _) = tenant_cap::new(escrow_id, TENANT_ADDR_1, sc.ctx());

    let (a, r) = escrow_coordinator::borrow_asset(&mut escrow, &cap, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EPendingTenantCap, location = usufruct::escrow_coordinator)]
fun borrow_asset_with_pending_cap_aborts() {
    let mut sc = setup();
    // c=1 Countdown so place_bid stamps a future expiry (no APT
    // handover before borrow).
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow_coordinator::compute_floor_price(&escrow, now2), sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());

    // cap_t2 is the pending bidder — cannot borrow.
    let (a, r) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t2, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EReceiptEscrowMismatch, location = usufruct::escrow_coordinator)]
fun return_asset_with_foreign_receipt_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let (asset_out, _real_receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());

    // Forge a receipt with a foreign escrow_id but the right asset_id.
    let asset_id   = object::id(&asset_out);
    let foreign_rcpt = asset::forge_receipt_for_testing(asset_id, object::id_from_address(@0xDEAD));
    escrow_coordinator::return_asset(&mut escrow, asset_out, foreign_rcpt);

    asset::destroy_receipt_for_testing(_real_receipt);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.2 burn_tenant_cap ───────────────────────────────────────────────────

/// Stale cap (from a superseded bid) burns cleanly. Live caps abort.
#[test]
fun burn_tenant_cap_burns_displaced_bidder_cap() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow_coordinator::compute_floor_price(&escrow, now2), sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());
    // Supersede t2 with t3 — t2's cap is now stale.
    let now3 = now2 + 100;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow_coordinator::compute_floor_price(&escrow, now3), sc.ctx());
    let cap_t3 = escrow_coordinator::rent(&mut escrow, p3, &clk, sc.ctx());

    // Burn the stale cap_t2.
    escrow_coordinator::burn_tenant_cap(&mut escrow, cap_t2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ETenantCapNotStale, location = usufruct::escrow_coordinator)]
fun burn_tenant_cap_on_live_current_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());
    // cap_t1 is the live current — burn must abort.
    escrow_coordinator::burn_tenant_cap(&mut escrow, cap_t1, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EWrongEscrowTenantCap, location = usufruct::escrow_coordinator)]
fun burn_tenant_cap_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let (foreign, _) = tenant_cap::new(object::id_from_address(@0xDEAD), TENANT_ADDR_1, sc.ctx());

    escrow_coordinator::burn_tenant_cap(&mut escrow, foreign, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §16. withdraw_earnings ──────────────────────────────────────────────────

/// Happy path: drive a tenure expiry → owner accumulates 90% → withdraw
/// returns a Coin with that exact value. EarningsWithdrawn fires.
#[test]
fun withdraw_earnings_drains_owner_balance() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let principal = escrow_corpus::min_rent_price_const();
    let p1 = mk_payment(principal, sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    // Tenure expiry routes 90% to owner.
    escrow_coordinator::fire_do_tenure_expiry_for_testing(
        &mut escrow, escrow_corpus::tenure_ceiling_const(), sc.ctx(),
    );
    let owner_share_expected = principal - principal / 10;
    assert_eq!(escrow_coordinator::owner_value_for_testing(&escrow), owner_share_expected);

    let coin = escrow_coordinator::withdraw_earnings(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert_eq!(coin::value(&coin), owner_share_expected);
    assert_eq!(escrow_coordinator::owner_value_for_testing(&escrow), 0);

    let withdrawn = event::events_by_type<EarningsWithdrawn>();
    assert_eq!(withdrawn.length(), 1);
    assert_eq!(escrow_coordinator::earnings_withdrawn_amount(&withdrawn[0]), owner_share_expected);

    coin::burn_for_testing(coin);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ENoEarnings, location = usufruct::escrow_coordinator)]
fun withdraw_earnings_with_zero_balance_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let coin = escrow_coordinator::withdraw_earnings(&mut escrow, &owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EWrongEscrowOwnerCap, location = usufruct::escrow_coordinator)]
fun withdraw_earnings_with_wrong_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let foreign = owner_cap::new(object::id_from_address(@0xDEAD), OWNER, sc.ctx());
    let coin = escrow_coordinator::withdraw_earnings(&mut escrow, &foreign, &clk, sc.ctx());
    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    owner_cap::burn(foreign, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §17. claim_asset ────────────────────────────────────────────────────────

/// Happy path: drive escrow to Retired, then claim. Returns
/// (asset, earnings_coin); the escrow object is deleted.
/// AssetClaimed event fires with the swept earnings.
#[test]
fun claim_asset_returns_asset_and_earnings_and_deletes_escrow() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Force the escrow into Retired (no earnings) via the test helper.
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow_handle);

    // Take the shared escrow by value so claim_asset can consume it.
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<DemoAsset, SUI>>();

    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    assert_eq!(coin::value(&earnings), 0);

    let claimed = event::events_by_type<AssetClaimed>();
    assert_eq!(claimed.length(), 1);
    assert_eq!(escrow_coordinator::asset_claimed_swept_earnings(&claimed[0]), 0);

    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Earnings sweep: drive a tenure expiry to accumulate balance, then
/// retire and claim. Earnings coin carries the owner's share.
#[test]
fun claim_asset_sweeps_owner_earnings() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let principal = escrow_corpus::min_rent_price_const();
    let p1 = mk_payment(principal, sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow_handle, p1, &clk, sc.ctx());

    escrow_coordinator::fire_do_tenure_expiry_for_testing(
        &mut escrow_handle, escrow_corpus::tenure_ceiling_const(), sc.ctx(),
    );
    // Drive auction → idle → retired so claim can run.
    escrow_coordinator::fire_do_auction_expiry_for_testing(
        &mut escrow_handle, escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const(),
    );
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow_handle);

    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<DemoAsset, SUI>>();

    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    let owner_share_expected = principal - principal / 10;
    assert_eq!(coin::value(&earnings), owner_share_expected);

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::ENotRetired, location = usufruct::escrow_coordinator)]
fun claim_asset_when_not_retired_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    // Idle, not Retired.
    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow_coordinator::EWrongEscrowOwnerCap, location = usufruct::escrow_coordinator)]
fun claim_asset_with_wrong_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow_handle);
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<DemoAsset, SUI>>();

    let foreign = owner_cap::new(object::id_from_address(@0xDEAD), OWNER, sc.ctx());
    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, foreign, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// APT cascade: HandoverConfirmed → HandoverOpen → AtDutch → Idle in
/// one pass under (c=2 FixedTime, h=0 Skipped). M6c spec scenario.
/// FixedTime saturates handover_countdown_expiry to the tenure
/// boundary; Skipped collapses descent — three transitions fire in
/// sequence within a single APT call.
#[test]
fun apt_cascade_handover_tenure_auction_under_c2_h0() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(2, 0, 0, 0, 0)); // c=2 FixedTime, h=0 Skipped
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow, p1, &clk, sc.ctx());

    let now2 = 1_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow_coordinator::compute_floor_price(&escrow, now2);
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow, p2, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_handover_confirmed(&escrow_coordinator::state_tag(&escrow)), 0);

    // Jump clock past the second tenure boundary so all three
    // transitions are due in one APT call:
    //   handover at tenure_ceiling (FixedTime expiry); after it,
    //   the new phase_start is tenure_ceiling, so tenure expiry is
    //   due at 2 × tenure_ceiling; auction fires immediately under
    //   h=0 Skipped.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() * 3);
    let tag = escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // Cascade: HandoverConfirmed → HandoverOpen → AtDutch → Idle.
    assert!(escrow_coordinator::is_tag_idle(&tag), 1);

    // All three boundary events fired.
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §18. End-to-end scenarios ───────────────────────────────────────────────

/// Full rental cycle with bid: integrate → rent (Idle→HO) → place bid
/// (HO→HC) → APT handover (HC→HO) → APT tenure (HO→AtDutch) → APT
/// auction (AtDutch→Idle) → retire → claim. Verifies the assembly
/// holds across all transitions and the events fire in order.
#[test]
fun e2e_full_rental_cycle_with_bid_and_handover() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents (Idle → HandoverOpen).
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow_handle, p1, &clk, sc.ctx());

    // T2 places a bid (HandoverOpen → HandoverConfirmed).
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow_coordinator::compute_floor_price(&escrow_handle, now2), sc.ctx());
    let cap_t2 = escrow_coordinator::rent(&mut escrow_handle, p2, &clk, sc.ctx());

    // APT at expiry: handover fires (HandoverConfirmed → HandoverOpen
    // with t2 promoted).
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    let _ = escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_handover_open(&escrow_coordinator::state_tag(&escrow_handle)), 0);

    // APT past tenure: tenure expiry fires (HO → AtDutch).
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary);
    let _ = escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_at_dutch_auction(&escrow_coordinator::state_tag(&escrow_handle)), 1);

    // APT past auction: auction expiry fires (AtDutch → Idle).
    let auction_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, auction_boundary);
    let _ = escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_idle(&escrow_coordinator::state_tag(&escrow_handle)), 2);

    // Event count sanity — boundary events from the cycle so far.
    // events_by_type returns only events emitted in the current tx,
    // so the assertions must precede sc.next_tx() below.
    assert!(event::events_by_type<HandoverCompleted>().length() == 1, 3);
    assert!(event::events_by_type<TenureExpired>().length() == 1, 4);
    assert!(event::events_by_type<AuctionExpired>().length() == 1, 5);

    // Retire and claim — escrow is consumed.
    escrow_coordinator::drive_to_retired_for_testing(&mut escrow_handle);
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<DemoAsset, SUI>>();

    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    // Both t1 and t2 contributed used_credit at boundaries; owner has
    // > 0 earnings.
    assert!(coin::value(&earnings) > 0, 6);
    assert!(event::events_by_type<AssetClaimed>().length() == 1, 7);

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Tenure expiry without a competing bid: rent → tenure expires →
/// AtDutch → no_winner → Idle. Owner accumulates the full stake's
/// 90% via tenure expiry. Sweeps E (curve dimension) at fixed
/// (c=0, d=0, h=1, f=0) — the universal boundary properties
/// (g(t_max)=SCALE, full descent collapses to min_rent_price)
/// hold across all 7 curves.
#[test]
fun e2e_tenure_expiry_then_auction_no_winner_across_curves() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let cfg_tag = escrow_corpus::tag(0, 0, e, 1, 0);
        let cfg     = escrow_corpus::by_tag(cfg_tag);
        let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());

        let principal = escrow_corpus::min_rent_price_const();
        let p1 = mk_payment(principal, sc.ctx());
        let cap_t1 = escrow_coordinator::rent(&mut escrow_handle, p1, &clk, sc.ctx());

        // APT past tenure → AtDutch.
        clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
        let _ = escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
        assert!(escrow_coordinator::is_tag_at_dutch_auction(&escrow_coordinator::state_tag(&escrow_handle)), cfg_tag);

        // APT past descent → Idle.
        clock::set_for_testing(
            &mut clk,
            escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() + 1,
        );
        let _ = escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
        assert!(escrow_coordinator::is_tag_idle(&escrow_coordinator::state_tag(&escrow_handle)), cfg_tag);

        // Owner accumulated 90 % of the principal (g(t_max)=SCALE
        // saturates the credit curve regardless of shape).
        let owner_share_expected = principal - principal / 10;
        assert_eq!(escrow_coordinator::owner_value_for_testing(&escrow_handle), owner_share_expected);

        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow_handle);
        owner_cap::burn(owner_cap, OWNER);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

/// Retire-during-rental: rent → retire (flag set, state stays HO) →
/// APT past tenure → state collapses to Retired (not AtDutch). Owner
/// claims the asset; AssetRetired emitted.
#[test]
fun e2e_retire_during_rental_collapses_to_retired_at_tenure() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow_coordinator::rent(&mut escrow_handle, p1, &clk, sc.ctx());

    // Retire mid-rental — flag lifts, state stays HO.
    let _ = escrow_coordinator::retire(&mut escrow_handle, &owner_cap, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_handover_open(&escrow_coordinator::state_tag(&escrow_handle)), 0);

    // APT past tenure: state collapses to Retired (skipping AtDutch).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    let _ = escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow_coordinator::is_tag_retired(&escrow_coordinator::state_tag(&escrow_handle)), 1);

    // AssetRetired co-emitted with TenureExpired (do_tenure_expiry's
    // retiring branch).
    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<DemoAsset, SUI>>();
    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

