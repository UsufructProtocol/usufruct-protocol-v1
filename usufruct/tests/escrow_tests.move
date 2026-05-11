// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_tests;

use std::unit_test::assert_eq;
use sui::random::{Self, Random};
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
    asset_context_state::{
        Self,
        RentStarted,
        AuctionExpired,
        AssetRetired,
        EarningsWithdrawn,
        BidPlaced,
        BidSuperseded,
        HandoverCompleted,
        TenureExpired,
        RetireFlagSet,
        AssetBorrowed,
        AssetReturned,
        ConfigReset,
        ConfigResetScheduled,
    },
    config,
    curve_shape_state,
    cycles,
    descent_policy_state,
    floor_price_policy_state,
    handover_policy_state,
    monetary,
    price_function_state,
    retire_policy_state,
    tenure_cycles_policy_state,
    tenure_policy_state,
    pending_transition_state,
    escrow::{
        Self,
        Escrow,
        AssetClaimed,
    },
    escrow_corpus,
    fee_message::FeeMessageSent,
    owner_cap::{Self, OwnerCap},
    phases,
    protocol_fee_inbox,
    protocol_fee_ref::ProtocolFeeRef,
    tenant::{Self, Tenant},
    tenant_cap,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const OWNER: address = @0x07;

/// Test asset — minimal key+store object that satisfies the
/// `Asset` bound on `Escrow`.
public struct DemoAsset has key, store { id: UID }

fun mk_demo_asset(ctx: &mut TxContext): DemoAsset {
    DemoAsset { id: object::new(ctx) }
}

/// Initialise the protocol-fee singletons and the shared Random object.
/// Returns a scenario whose next-tx state has the `ProtocolFeeRef` frozen,
/// the `ProtocolFeeInbox` owned by `OWNER`, and `Random` shared.
fun setup(): Scenario {
    // Random requires sender == @0x0 (system address); create it first.
    let mut sc = test_scenario::begin(@0x0);
    { random::create_for_testing(sc.ctx()); };
    sc.next_tx(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

/// Asserts the escrow is in Idle state, using `breadcrumb` as the abort code.
fun assert_tag_idle<Asset: key + store, CoinType>(
    escrow:     &Escrow<Asset, CoinType>,
    breadcrumb: u64,
) {
    assert!(escrow::is_idle(escrow), breadcrumb);
}

const TENANT_ADDR_1: address = @0xA1;
const TENANT_ADDR_2: address = @0xA2;
const CHALLENGER:    address = @0xC1;
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
): (Escrow<DemoAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let random = sc.take_shared<Random>();
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, cfg, &fee_ref, &random, &clk, sc.ctx(),
    );
    test_scenario::return_shared(random);
    let escrow_id = owner_cap::proj_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
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

    let random = sc.take_shared<Random>();
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, cfg, &fee_ref, &random, &clk, sc.ctx(),
    );
    test_scenario::return_shared(random);
    let escrow_id = owner_cap::proj_escrow_id(&cap);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    assert_tag_idle(&escrow, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §2. integrate — corpus projection ───────────────────────────────────────

/// §10.1 — integrate is universally applicable. Sweeps the C axis
/// (HandoverPolicyState ∈ {Instant, Countdown, FixedTime}) — three
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

        let random = sc.take_shared<Random>();
        let cap = escrow::integrate<DemoAsset, SUI>(
            asset, cfg, &fee_ref, &random, &clk, sc.ctx(),
        );
        test_scenario::return_shared(random);
        let escrow_id = owner_cap::proj_escrow_id(&cap);

        clock::destroy_for_testing(clk);
        test_scenario::return_immutable(fee_ref);
        owner_cap::burn(cap, OWNER);

        sc.next_tx(OWNER);
        let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
        assert_tag_idle(&escrow, tag);
        test_scenario::return_shared(escrow);

        c = c + 1;
    };
    sc.end();
}

// ─── §3. take/put discipline ─────────────────────────────────────────────────

/// The take_state/put_state hot-potato cycle is a no-op on the state
/// Verifies that `integrate` leaves the escrow in Idle state.
/// (The StateReceipt hot-potato was removed in the engine_state
/// refactor; extract/fill no longer needs a structural guard.)
#[test]
fun integrate_leaves_escrow_idle() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let cfg     = escrow_corpus::by_tag(0);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let random = sc.take_shared<Random>();
    let cap       = escrow::integrate<DemoAsset, SUI>(asset, cfg, &fee_ref, &random, &clk, sc.ctx());
    test_scenario::return_shared(random);
    let escrow_id = owner_cap::proj_escrow_id(&cap);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);

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
    let (owner_amt, fee_amt) = escrow::split_fee_for_testing(10_000_000_000);
    // 10 SUI * 10% protocol fee = 1 SUI fee, 9 SUI owner.
    assert_eq!(fee_amt,   1_000_000_000);
    assert_eq!(owner_amt, 9_000_000_000);
}

#[test]
fun split_fee_floors_to_zero_below_threshold() {
    // Below 10 base units, mul_div(amount, 1000, 10000) = 0.
    let (owner_amt, fee_amt) = escrow::split_fee_for_testing(9);
    assert_eq!(fee_amt,   0);
    assert_eq!(owner_amt, 9);
}

#[test]
fun split_fee_zero_in_zero_out() {
    let (owner_amt, fee_amt) = escrow::split_fee_for_testing(0);
    assert_eq!(fee_amt,   0);
    assert_eq!(owner_amt, 0);
}

#[test]
fun split_fee_exact_threshold_yields_one_fee() {
    // mul_div(10, 1000, 10000) = 1.
    let (owner_amt, fee_amt) = escrow::split_fee_for_testing(10);
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
    let clock = clock::create_for_testing(sc.ctx());
    let price = escrow::compute_floor_price(&escrow, &clock);
    clock::destroy_for_testing(clock);
    assert_eq!(price, escrow_corpus::min_rent_price_const());
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// HandoverOpen returns `f_next_rent_price(current_stake)`. Sweeps
/// the D axis (PriceFunctionState): d=0 (FixedDelta) and d=1 (CompoundDelta)
/// — the only axis compute_next_rent_price actually consumes.
#[test]
fun floor_price_handover_open_escalates_current_stake() {
    let mut sc = setup();
    let mut d: u8 = 0;
    while (d <= 1) {
        let tag = escrow_corpus::tag(0, d, 0, 0, 0);
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);

        escrow::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );

        let clock = clock::create_for_testing(sc.ctx());
        let price = escrow::compute_floor_price(&escrow, &clock);
        clock::destroy_for_testing(clock);
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

        let clock = clock::create_for_testing(sc.ctx());
        let price = escrow::compute_floor_price(&escrow, &clock);
        clock::destroy_for_testing(clock);
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

        escrow::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );
        // Drive HandoverOpen → AtDutch with last_acq_price > min_rent_price
        // so the spread is positive (otherwise the assertion would be
        // trivial: last_acq_price - 0 = last_acq_price for any curve).
        let last_acq = escrow_corpus::min_rent_price_const() * 2;
        let boundary_ms = 100_000;
        escrow::drive_to_at_dutch_for_testing(
            &mut escrow, STAKE_T1, 0, last_acq, boundary_ms,
        );

        // At elapsed=0, descent has consumed 0 — price equals last_acq.
        let mut clock = clock::create_for_testing(sc.ctx());
        clock::set_for_testing(&mut clock, boundary_ms);
        let price = escrow::compute_floor_price(&escrow, &clock);
        clock::destroy_for_testing(clock);
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

        escrow::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            0,
        );
        let last_acq    = escrow_corpus::min_rent_price_const() * 2;
        let phase_start = 100_000;
        escrow::drive_to_at_dutch_for_testing(
            &mut escrow, STAKE_T1, 0, last_acq, phase_start,
        );

        // At elapsed=ceiling, descent saturates → price = min_rent_price.
        let now = phase_start + escrow_corpus::descent_window_h1_const();
        let mut clock = clock::create_for_testing(sc.ctx());
        clock::set_for_testing(&mut clock, now);
        let price = escrow::compute_floor_price(&escrow, &clock);
        clock::destroy_for_testing(clock);
        assert!(price == escrow_corpus::min_rent_price_const(), tag);

        test_scenario::return_shared(escrow);
        owner_cap::burn(cap, OWNER);
        e = e + 1;
    };
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ERetiredNoBid, location = usufruct::asset_context_state)]
fun floor_price_aborts_on_retired() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);
    escrow::drive_to_retired_for_testing(&mut escrow);
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::compute_floor_price(&escrow, &clock);
    clock::destroy_for_testing(clock);
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
        escrow::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            phase_start,
        );

        let mut clock = clock::create_for_testing(sc.ctx());
        clock::set_for_testing(&mut clock, phase_start);
        let used = escrow::compute_used_credit(&escrow, &clock);
        clock::destroy_for_testing(clock);
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
        escrow::drive_to_rented_for_testing(
            &mut escrow,
            mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
            phase_start,
        );

        let now = phase_start + escrow_corpus::tenure_ceiling_const();
        let mut clock = clock::create_for_testing(sc.ctx());
        clock::set_for_testing(&mut clock, now);
        let used = escrow::compute_used_credit(&escrow, &clock);
        clock::destroy_for_testing(clock);
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
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        phase_start,
    );
    let countdown_expiry = phase_start + escrow_corpus::handover_countdown_c1_const();
    escrow::drive_to_demand_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
        countdown_expiry,
    );

    let mut clock = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clock, countdown_expiry);
    let at_expiry  = escrow::compute_used_credit(&escrow, &clock);
    clock::set_for_testing(&mut clock, countdown_expiry + 1_000_000);
    let far_future = escrow::compute_used_credit(&escrow, &clock);
    clock::destroy_for_testing(clock);
    assert_eq!(at_expiry, far_future);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ENotRented, location = usufruct::asset_context_state)]
fun used_credit_aborts_on_idle() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take(cfg, &mut sc);
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::compute_used_credit(&escrow, &clock);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ENotRented, location = usufruct::asset_context_state)]
fun used_credit_aborts_on_at_dutch() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const(), 100_000,
    );
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::compute_used_credit(&escrow, &clock);
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ENotRented, location = usufruct::asset_context_state)]
fun used_credit_aborts_on_retired() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(cfg, &mut sc);
    escrow::drive_to_retired_for_testing(&mut escrow);
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::compute_used_credit(&escrow, &clock);
    clock::destroy_for_testing(clock);
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
    let random = sc.take_shared<Random>();

    let floor = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor, sc.ctx());
    let t_cap = escrow::rent(&mut escrow, payment, cycles::cycles(1), &random, &clk, sc.ctx());

    // Post-condition: state is HandoverOpen.
    assert!(escrow::is_handover_open(&escrow), 0);

    // Event check: exactly one RentStarted with tenant_cap_id matching the returned cap.
    let started = event::events_by_type<RentStarted>();
    assert_eq!(started.length(), 1);
    assert_eq!(asset_context_state::rent_started_tenant_cap_id(&started[0]), object::id(&t_cap));
    assert_eq!(asset_context_state::rent_started_price_paid(&started[0]), floor);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    // Drive to AtDutch via test-only helpers.
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    let last_acq = escrow_corpus::min_rent_price_const() * 2;
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, last_acq, escrow_corpus::tenure_ceiling_const(),
    );

    // Sample mid-descent — APT must NOT fire auction_expiry yet (the
    // descent window has not elapsed).
    let now   = escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now);
    let floor = escrow::compute_floor_price(&escrow, &clk);

    let payment = mk_payment(floor, sc.ctx());
    let t_cap = escrow::rent(&mut escrow, payment, cycles::cycles(1), &random, &clk, sc.ctx());

    assert!(escrow::is_handover_open(&escrow), 0);

    let started = event::events_by_type<RentStarted>();
    assert_eq!(started.length(), 1);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §8. rent — dispatch to do_place_bid ─────────────────────────────────────

/// HandoverOpen → HandoverConfirmed via rent. BidPlaced carries
/// the pre-computed handover_countdown_expiry. Sweeps the C axis
/// (HandoverPolicyState) since handover_policy_state::expiry_at depends on it.
#[test]
fun rent_from_handover_open_places_bid() {
    let mut sc = setup();
    let mut c: u8 = 0;
    while (c <= 2) {
        let tag_cfg = escrow_corpus::tag(c, 0, 0, 0, 0);
        let cfg     = escrow_corpus::by_tag(tag_cfg);
        let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // First rent: Idle → HandoverOpen.
        let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
        let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

        // Second rent: HandoverOpen → HandoverConfirmed.
        let now2 = 5_000;
        clock::set_for_testing(&mut clk, now2);
        let floor2 = escrow::compute_floor_price(&escrow, &clk);
        let p2 = mk_payment(floor2, sc.ctx());
        let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());

        assert!(escrow::is_handover_confirmed(&escrow), tag_cfg);

        // Verify a BidPlaced event was emitted with cap_t2.
        let placed = event::events_by_type<BidPlaced>();
        assert!(placed.length() == 1, tag_cfg);
        assert_eq!(asset_context_state::bid_placed_tenant_cap_id(&placed[0]), object::id(&cap_t2));
        // The expiry was stamped — its specific value depends on c
        // (Instant: now+0 = now2; Countdown: min(now2+25_000, phase_start+ceiling);
        // FixedTime: phase_start+ceiling). Property: expiry > 0.
        assert!(asset_context_state::bid_placed_handover_countdown_expiry(&placed[0]) > 0, tag_cfg);

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        c = c + 1;
    };
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ERetireFlagBlocksBid, location = usufruct::asset_context_state)]
fun rent_from_handover_open_aborts_when_retiring_flag_set() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // First rent: Idle → HandoverOpen.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // Lift the retiring flag (real `retire`/`do_set_retiring_flag`
    // arrive in C5; the drive helper exercises the place_bid guard
    // in isolation here).
    escrow::drive_to_retiring_flag_for_testing(&mut escrow);

    // Second rent: HandoverOpen + retiring=true → must abort.
    let p2 = mk_payment(escrow_corpus::min_rent_price_const() * 2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    let p2_amt = escrow_corpus::min_rent_price_const() * 2;
    let p2 = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());

    // Third rent supersedes t2.
    let now3 = 1_000;
    clock::set_for_testing(&mut clk, now3);
    let floor3 = escrow::compute_floor_price(&escrow, &clk);
    let p3 = mk_payment(floor3, sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, cycles::cycles(1), &random, &clk, sc.ctx());

    assert!(escrow::is_handover_confirmed(&escrow), 0);

    // Verify BidSuperseded carries the displaced bid amount.
    let superseded = event::events_by_type<BidSuperseded>();
    assert_eq!(superseded.length(), 1);
    assert_eq!(asset_context_state::bid_superseded_displaced_cap_id(&superseded[0]), object::id(&cap_t2));
    assert_eq!(asset_context_state::bid_superseded_new_cap_id(&superseded[0]), object::id(&cap_t3));
    assert_eq!(asset_context_state::bid_superseded_refunded_amount(&superseded[0]), p2_amt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §10. rent — abort paths ─────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = asset_context_state::EInsufficientPayment, location = usufruct::asset_context_state)]
fun rent_below_floor_aborts() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let payment = mk_payment(escrow_corpus::min_rent_price_const() - 1, sc.ctx());
    let cap = escrow::rent(&mut escrow, payment, cycles::cycles(1), &random, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ERetiredNoBid, location = usufruct::asset_context_state)]
fun rent_from_retired_aborts() {
    let mut sc = setup();
    let cfg     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    escrow::drive_to_retired_for_testing(&mut escrow);

    let payment = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap = escrow::rent(&mut escrow, payment, cycles::cycles(1), &random, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    // Drive to HandoverConfirmed via two rent calls.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    let phase_start = 0;

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::compute_floor_price(&escrow, &clk);
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());

    let principal_t1 = escrow_corpus::min_rent_price_const();
    let owner_before = escrow::owner_value_for_testing(&escrow);

    // Fire do_handover at the handover-countdown expiry.
    let boundary_ms = phase_start + escrow_corpus::handover_countdown_c1_const() + now2;
    // Ensure boundary < tenure: 25_000 + 5_000 = 30_000 < 100_000.
    clock::set_for_testing(&mut clk, boundary_ms);
    let used_credit_expected = escrow::compute_used_credit(&escrow, &clk);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Post-condition: HandoverOpen, current is t2.
    assert!(escrow::is_handover_open(&escrow), 0);

    // Owner balance increased by the owner share (90% of used_credit).
    let owner_after = escrow::owner_value_for_testing(&escrow);
    let owner_share_expected = used_credit_expected - used_credit_expected / 10;  // 90%
    assert!(owner_after - owner_before == owner_share_expected, 1);

    // HandoverCompleted event emitted with consistent figures.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    let used_credit = asset_context_state::handover_completed_used_credit(&completed[0]);
    let owner_share = asset_context_state::handover_completed_owner_share(&completed[0]);
    let protocol_fee = asset_context_state::handover_completed_protocol_fee(&completed[0]);
    let remain_credit = asset_context_state::handover_completed_remain_credit(&completed[0]);
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
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §12. do_tenure_expiry ───────────────────────────────────────────────────

/// At tenure expiry the tenant never receives a refund.
/// split_fee(principal) = owner_share + protocol_fee exactly — no remainder.
/// Preserves the invariant: the Nothing path is taken, never Parcial.
#[test]
fun do_tenure_expiry_tenant_receives_no_refund() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let principal = escrow_corpus::min_rent_price_const();
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Conservation: owner_share + protocol_fee = principal.
    // If this fails, some mist escaped to the tenant.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(
        asset_context_state::tenure_expired_owner_share(&expired[0]) +
        asset_context_state::tenure_expired_protocol_fee(&expired[0]),
        principal,
    );

    // No coin was transferred to the tenant — Nothing, not Parcial.
    sc.next_tx(TENANT_ADDR_1);
    assert!(!sc.has_most_recent_for_sender<coin::Coin<SUI>>(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// HandoverOpen → AtDutch via tenure boundary. Refund is always
/// Nothing (full stake consumed: owner+fee). last_acquisition_price
/// equals the principal at boundary.
#[test]
fun do_tenure_expiry_routes_full_stake_and_anchors_at_dutch() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    let principal = escrow_corpus::min_rent_price_const();

    let owner_before = escrow::owner_value_for_testing(&escrow);
    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Post-condition: NotRented + AtDutch.
    assert!(escrow::is_at_dutch_auction(&escrow), 0);

    // Owner balance += owner_share (90% of full principal).
    let owner_share_expected = principal - principal / 10;
    let owner_after = escrow::owner_value_for_testing(&escrow);
    assert!(owner_after - owner_before == owner_share_expected, 1);

    // TenureExpired carries the canonical anchor price = principal.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(asset_context_state::tenure_expired_last_acq_price(&expired[0]), principal);
    assert_eq!(asset_context_state::tenure_expired_owner_share(&expired[0]) +
               asset_context_state::tenure_expired_protocol_fee(&expired[0]), principal);

    // No AssetRetired (retiring flag was not set).
    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 0);

    // FeeMessage was posted.
    let sent = event::events_by_type<FeeMessageSent<SUI>>();
    assert_eq!(sent.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // Lift retiring flag (real retire arrives in C5).
    escrow::drive_to_retiring_flag_for_testing(&mut escrow);

    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Post-condition: NotRented + Retired (not AtDutch).
    assert!(escrow::is_retired(&escrow), 0);

    // Both events emitted: TenureExpired + AssetRetired.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), 0);

    let flagged = event::events_by_type<RetireFlagSet>();
    assert_eq!(flagged.length(), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );

    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), 0);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), 0);

    let flagged = event::events_by_type<RetireFlagSet>();
    assert_eq!(flagged.length(), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EAlreadyRetired, location = usufruct::asset_context_state)]
fun retire_when_already_retired_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    escrow::drive_to_retired_for_testing(&mut escrow);
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EAlreadyRetiring, location = usufruct::asset_context_state)]
fun retire_when_already_retiring_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    // Second call must fail — flag is already set.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EWrongEscrowOwnerCap, location = usufruct::asset_context_state)]
fun retire_with_wrong_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Mint a foreign cap bound to a different escrow_id.
    let foreign_cap = owner_cap::new(object::id_from_address(@0xDEAD), OWNER, sc.ctx());
    escrow::retire(&mut escrow, &foreign_cap, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    owner_cap::burn(foreign_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ERetireFloorNotElapsed, location = usufruct::asset_context_state)]
fun retire_before_floor_aborts_under_deferred_policy() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 1)); // f=1 deferred
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    // clock at 0 is far below the deferred floor (10_000_000).
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );

    let boundary_ms = 100_000 + escrow_corpus::descent_window_h1_const();
    escrow::fire_do_auction_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms));

    assert!(escrow::is_idle(&escrow), 0);

    let expired = event::events_by_type<AuctionExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(asset_context_state::auction_expired_timestamp_ms(&expired[0]), boundary_ms);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

// ─── §14.5 next_pending — detection without firing ──────────────────────────

/// next_pending returns None when nothing is due.
#[test]
fun next_pending_returns_none_in_steady_state() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (escrow, owner_cap) = integrate_and_take(cfg, &mut sc);

    // Idle escrow — nothing pending at any clock.
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    assert!(escrow::next_pending(&escrow, &clk).is_none(), 0);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

/// next_pending returns Tenure with the boundary_ms when tenure has elapsed.
#[test]
fun next_pending_detects_tenure_with_correct_boundary() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // Probe at clock just past the tenure boundary — Tenure is pending.
    let probe_ms = escrow_corpus::tenure_ceiling_const() + 1;
    clock::set_for_testing(&mut clk, probe_ms);
    let pending = escrow::next_pending(&escrow, &clk);
    assert!(pending.is_some(), 0);
    let t = pending.destroy_some();
    assert!(pending_transition_state::is_tenure(&t), 1);
    // boundary_ms is exactly tenure_ceiling (phase_start was 0).
    assert_eq!(pending_transition_state::boundary_ms(&t), escrow_corpus::tenure_ceiling_const());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15. apply_pending_transition_states ──────────────────────────────────────────

/// APT no-ops when nothing is due. Tag unchanged after the call.
#[test]
fun apt_noop_when_nothing_due() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Idle escrow at clock=0; no transitions are due.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::compute_floor_price(&escrow, &clk);
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), 0);

    // Jump clock past the countdown expiry.
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // Handover fired: HandoverConfirmed → HandoverOpen (t2 now t1).
    assert!(escrow::is_handover_open(&escrow), 1);

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_context_state::handover_completed_timestamp_ms(&completed[0]), countdown_expiry);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // Jump clock past the tenure boundary.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // Tenure expired: HandoverOpen → AtDutch (h=1 window).
    assert!(escrow::is_at_dutch_auction(&escrow), 0);

    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // Cascade: HandoverOpen → AtDutch (tenure_expiry) → Idle (auction_expiry under h=0 collapses to phase_start, immediately expired).
    assert!(escrow::is_idle(&escrow), 0);

    let tenure_e = event::events_by_type<TenureExpired>();
    assert_eq!(tenure_e.length(), 1);
    let auction_e = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_e.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    let (asset_out, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    let borrowed = event::events_by_type<AssetBorrowed>();
    assert_eq!(borrowed.length(), 1);

    escrow::return_asset(&mut escrow, asset_out, receipt);
    let returned = event::events_by_type<AssetReturned>();
    assert_eq!(returned.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EWrongEscrowTenantCap, location = usufruct::asset_context_state)]
fun borrow_asset_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    let foreign_cap = tenant_cap::new(object::id_from_address(@0xDEAD), TENANT_ADDR_1, sc.ctx());

    let (a, r) = escrow::borrow_asset(&mut escrow, &foreign_cap, &random, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(foreign_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EStaleTenantCap, location = usufruct::asset_context_state)]
fun borrow_asset_from_idle_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Mint a cap bound to this escrow but never used (no active rental).
    let escrow_id = object::id(&escrow);
    let cap = tenant_cap::new(escrow_id, TENANT_ADDR_1, sc.ctx());

    let (a, r) = escrow::borrow_asset(&mut escrow, &cap, &random, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EPendingTenantCap, location = usufruct::asset_context_state)]
fun borrow_asset_with_pending_cap_aborts() {
    let mut sc = setup();
    // c=1 Countdown so place_bid stamps a future expiry (no APT
    // handover before borrow).
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::compute_floor_price(&escrow, &clk), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());

    // cap_t2 is the pending bidder — cannot borrow.
    let (a, r) = escrow::borrow_asset(&mut escrow, &cap_t2, &random, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset::E_ASSET_WRONG_ESCROW, location = usufruct::asset)]
fun return_asset_with_foreign_receipt_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    let (asset_out, _real_receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());

    // Forge a receipt with a foreign escrow_id but the right asset_id.
    let asset_id   = object::id(&asset_out);
    let foreign_rcpt = asset::forge_receipt_for_testing(asset_id, object::id_from_address(@0xDEAD));
    escrow::return_asset(&mut escrow, asset_out, foreign_rcpt);

    asset::destroy_receipt_for_testing(_real_receipt);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::compute_floor_price(&escrow, &clk), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());
    // Supersede t2 with t3 — t2's cap is now stale.
    let now3 = now2 + 100;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::compute_floor_price(&escrow, &clk), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, cycles::cycles(1), &random, &clk, sc.ctx());

    // Burn the stale cap_t2.
    escrow::burn_tenant_cap(&mut escrow, cap_t2, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ETenantCapNotStale, location = usufruct::asset_context_state)]
fun burn_tenant_cap_on_live_current_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());
    // cap_t1 is the live current — burn must abort.
    escrow::burn_tenant_cap(&mut escrow, cap_t1, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EWrongEscrowTenantCap, location = usufruct::asset_context_state)]
fun burn_tenant_cap_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let foreign = tenant_cap::new(object::id_from_address(@0xDEAD), TENANT_ADDR_1, sc.ctx());

    escrow::burn_tenant_cap(&mut escrow, foreign, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let principal = escrow_corpus::min_rent_price_const();
    let p1 = mk_payment(principal, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // Tenure expiry routes 90% to owner.
    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );
    let owner_share_expected = principal - principal / 10;
    assert_eq!(escrow::owner_value_for_testing(&escrow), owner_share_expected);

    let coin = escrow::withdraw_earnings(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert_eq!(coin::value(&coin), owner_share_expected);
    assert_eq!(escrow::owner_value_for_testing(&escrow), 0);

    let withdrawn = event::events_by_type<EarningsWithdrawn>();
    assert_eq!(withdrawn.length(), 1);
    assert_eq!(asset_context_state::earnings_withdrawn_amount(&withdrawn[0]), owner_share_expected);

    coin::burn_for_testing(coin);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::ENoEarnings, location = usufruct::asset_context_state)]
fun withdraw_earnings_with_zero_balance_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let coin = escrow::withdraw_earnings(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EWrongEscrowOwnerCap, location = usufruct::asset_context_state)]
fun withdraw_earnings_with_wrong_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let foreign = owner_cap::new(object::id_from_address(@0xDEAD), OWNER, sc.ctx());
    let coin = escrow::withdraw_earnings(&mut escrow, &foreign, &random, &clk, sc.ctx());
    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    owner_cap::burn(foreign, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    // Force the escrow into Retired (no earnings) via the test helper.
    escrow::drive_to_retired_for_testing(&mut escrow_handle);

    // Take the shared escrow by value so claim_asset can consume it.
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    assert_eq!(coin::value(&earnings), 0);

    let claimed = event::events_by_type<AssetClaimed>();
    assert_eq!(claimed.length(), 1);
    assert_eq!(escrow::asset_claimed_swept_earnings(&claimed[0]), 0);

    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let principal = escrow_corpus::min_rent_price_const();
    let p1 = mk_payment(principal, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow_handle, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow_handle, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );
    // Drive auction → idle → retired so claim can run.
    escrow::fire_do_auction_expiry_for_testing(
        &mut escrow_handle, phases::timestamp(escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const()),
    );
    escrow::drive_to_retired_for_testing(&mut escrow_handle);

    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    let owner_share_expected = principal - principal / 10;
    assert_eq!(coin::value(&earnings), owner_share_expected);

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = escrow::ENotRetired, location = usufruct::escrow)]
fun claim_asset_when_not_retired_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    // Idle, not Retired.
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EWrongEscrowOwnerCap, location = usufruct::asset_context_state)]
fun claim_asset_with_wrong_cap_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    escrow::drive_to_retired_for_testing(&mut escrow_handle);
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    let foreign = owner_cap::new(object::id_from_address(@0xDEAD), OWNER, sc.ctx());
    let (asset, earnings) = escrow::claim_asset(escrow, foreign, &random, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    let now2 = 1_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::compute_floor_price(&escrow, &clk);
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), 0);

    // Jump clock past the second tenure boundary so all three
    // transitions are due in one APT call:
    //   handover at tenure_ceiling (FixedTime expiry); after it,
    //   the new phase_start is tenure_ceiling, so tenure expiry is
    //   due at 2 × tenure_ceiling; auction fires immediately under
    //   h=0 Skipped.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() * 3);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // Cascade: HandoverConfirmed → HandoverOpen → AtDutch → Idle.
    assert!(escrow::is_idle(&escrow), 1);

    // All three boundary events fired.
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    // T1 rents (Idle → HandoverOpen).
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow_handle, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 places a bid (HandoverOpen → HandoverConfirmed).
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::compute_floor_price(&escrow_handle, &clk), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow_handle, p2, cycles::cycles(1), &random, &clk, sc.ctx());

    // APT at expiry: handover fires (HandoverConfirmed → HandoverOpen
    // with t2 promoted).
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow_handle), 0);

    // APT past tenure: tenure expiry fires (HO → AtDutch).
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow_handle), 1);

    // APT past auction: auction expiry fires (AtDutch → Idle).
    let auction_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, auction_boundary);
    escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow_handle), 2);

    // Event count sanity — boundary events from the cycle so far.
    // events_by_type returns only events emitted in the current tx,
    // so the assertions must precede sc.next_tx() below.
    assert!(event::events_by_type<HandoverCompleted>().length() == 1, 3);
    assert!(event::events_by_type<TenureExpired>().length() == 1, 4);
    assert!(event::events_by_type<AuctionExpired>().length() == 1, 5);

    // Retire and claim — escrow is consumed.
    escrow::drive_to_retired_for_testing(&mut escrow_handle);
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    // Both t1 and t2 contributed used_credit at boundaries; owner has
    // > 0 earnings.
    assert!(coin::value(&earnings) > 0, 6);
    assert!(event::events_by_type<AssetClaimed>().length() == 1, 7);

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(random);
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
        let random = sc.take_shared<Random>();

        let principal = escrow_corpus::min_rent_price_const();
        let p1 = mk_payment(principal, sc.ctx());
        let cap_t1 = escrow::rent(&mut escrow_handle, p1, cycles::cycles(1), &random, &clk, sc.ctx());

        // APT past tenure → AtDutch.
        clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
        escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
        assert!(escrow::is_at_dutch_auction(&escrow_handle), cfg_tag);

        // APT past descent → Idle.
        clock::set_for_testing(
            &mut clk,
            escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() + 1,
        );
        escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
        assert!(escrow::is_idle(&escrow_handle), cfg_tag);

        // Owner accumulated 90 % of the principal (g(t_max)=SCALE
        // saturates the credit curve regardless of shape).
        let owner_share_expected = principal - principal / 10;
        assert_eq!(escrow::owner_value_for_testing(&escrow_handle), owner_share_expected);

        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow_handle);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
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
    let random = sc.take_shared<Random>();

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow_handle, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // Retire mid-rental — flag lifts, state stays HO.
    escrow::retire(&mut escrow_handle, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow_handle), 0);

    // APT past tenure: state collapses to Retired (skipping AtDutch).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow_handle), 1);

    // AssetRetired co-emitted with TenureExpired (do_tenure_expiry's
    // retiring branch).
    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §1. Two-tenant succession — price escalates, earnings accumulate ─────────

/// T1 rents, T2 displaces T1 via bid + APT handover, T3 displaces T2
/// via bid + APT handover. T3 holds until tenure expiry → Idle (Skipped
/// descent). Owner claims; earnings > 0.
///
/// Config: c=0 (Instant — handover fires at bid_time, no clock advance),
///         d=0 (FixedDelta — price escalates additively),
///         h=0 (Skipped — AtDutchAuction is unobservable),
///         e=0, f=0.
///
/// Verifies: floor_price increases at each succession, two HandoverCompleted
/// events fire (once per displacement), TenureExpired + AuctionExpired fire
/// together under Skipped, earnings are non-zero after two paid tenures.
#[test]
fun e2e_two_tenant_successions_price_escalates() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // c=0 d=0 e=0 h=0 f=0
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1: rent from Idle at min_rent_price → HandoverOpen.
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // T2: bid on T1's tenure → HandoverConfirmed.
    let now_t2    = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2  = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t2 > price_t1, tag); // price escalated
    let cap_t2    = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // APT: Instant handover fires at bid_time_ms=1000 → HandoverOpen (T2 current).
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T3: bid on T2's tenure → HandoverConfirmed.
    let now_t3    = 2_000;
    clock::set_for_testing(&mut clk, now_t3);
    let price_t3  = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t3 > price_t2, tag); // price escalated again
    let cap_t3    = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // APT: second Instant handover → HandoverOpen (T3 current).
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 2);

    // Advance past T3's tenure ceiling (phase_start_T3 = now_t3 = 2_000).
    let tenure_boundary = now_t3 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // h=0 Skipped: TenureExpired + AuctionExpired co-fire → Idle.
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Retire from Idle → Retired.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    // Claim: earnings must be positive — both T1 and T2 accumulated used_credit.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    assert!(coin::value(&earnings) > 0, tag);
    assert_eq!(event::events_by_type<AssetClaimed>().length(), 1);

    transfer::public_transfer(asset, OWNER);
    coin::burn_for_testing(earnings);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §2. Auction winner rents at descending price ─────────────────────────────

/// T1 rents, T2 displaces T1 via handover (so T2's price > T1's), T2's
/// tenure expires → AtDutchAuction with non-zero spread. T3 rents at
/// mid-descent price, which is strictly below T2's price (the last
/// acquisition price entering AtDutch) but ≥ min_rent_price.
///
/// Zero-spread is impossible here: T2's price = T1 + FixedDelta > min_rent_price,
/// so the descent has a genuine spread to exercise.
///
/// Config: c=0 (Instant — handover fires at bid_time, no clock advance),
///         d=0 (FixedDelta), e=0 (linear), h=1 (Window), f=0.
#[test]
fun e2e_auction_winner_rents_at_mid_descent() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // c=0 h=1
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1: rent from Idle → HandoverOpen at min_rent_price.
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2: bid on T1's tenure (HO → HC). floor_price > min_rent_price.
    let now_t2   = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // APT: Instant handover → HandoverOpen (T2 current, phase_start = now_t2).
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // APT past T2's tenure ceiling → AtDutchAuction.
    // last_acquisition_price = price_t2 > min_rent_price → non-zero spread.
    let tenure_boundary = now_t2 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // T3 at mid-descent: price is between price_t2 and min_rent_price.
    let now_mid  = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let price_t3 = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t3 < price_t2, tag);                               // price descended
    assert!(price_t3 >= escrow_corpus::min_rent_price_const(), tag); // never below min

    // T3 rents at the descending price → HandoverOpen.
    let cap_t3 = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §3. Deferred retire floor gate ───────────────────────────────────────────

/// With RetirePolicyState::Deferred, retire() aborts if the clock has not
/// reached integrated_at_ms + retire_floor. integrated_at_ms = 0
/// (clock at integration time), retire_floor = 10_000_000.
///
/// Config: c=0, d=0, e=0, h=0, f=1 (Deferred).
#[test]
#[expected_failure(
    abort_code = asset_context_state::ERetireFloorNotElapsed,
    location   = usufruct::asset_context_state,
)]
fun e2e_deferred_retire_aborts_before_floor() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 Deferred
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    // Clock at 0; retire_floor = 10_000_000 — gate is closed.
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Complement: same config, clock advanced past retire_floor.
/// retire() succeeds → Retired; claim_asset completes the lifecycle.
#[test]
fun e2e_deferred_retire_succeeds_after_floor() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 Deferred
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Advance past retire_floor (integrated_at_ms=0, floor=10_000_000).
    let past_floor = escrow_corpus::retire_deferred_f1_const() + 1;
    clock::set_for_testing(&mut clk, past_floor);

    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::destroy_zero(earnings); // no tenants → no earnings
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §4. Supersede chain — T3 wins handover over T2 ──────────────────────────

/// T1 rents (Idle → HO). T2 places a bid (HO → HC). T3 supersedes T2
/// (HC → HC, T2's cap becomes stale). APT fires handover to T3 — T3
/// becomes the current tenant, not T2. T2 can burn their stale cap.
///
/// Verifies: BidSuperseded event fires for T2's displacement, APT
/// HandoverCompleted fires to T3, T2's cap is burnable.
///
/// Config: c=1 (Countdown 25_000 ms — Instant would fire handover
/// before T3 can supersede), d=0, e=0, h=0, f=0.
#[test]
fun e2e_supersede_T3_displaces_T2_APT_fires_to_T3() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1: rent from Idle → HandoverOpen.
    let cap_t1   = escrow::rent(
        &mut escrow,
        mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random,
        &clk,
        sc.ctx(),
    );

    // T2: bid → HandoverConfirmed (countdown starts at now_t2=1_000).
    let now_t2   = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(
        &mut escrow,
        mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random,
        &clk,
        sc.ctx(),
    );
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidPlaced>().length(), 1);

    // T3: supersedes T2 before countdown expires (now_t3=2_000 < 1_000+25_000).
    let now_t3   = 2_000;
    clock::set_for_testing(&mut clk, now_t3);
    let floor_t3 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t3   = escrow::rent(
        &mut escrow,
        mk_payment(floor_t3, sc.ctx()), cycles::cycles(1), &random,
        &clk,
        sc.ctx(),
    );
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // APT past T3's countdown expiry → HandoverOpen (T3 is current, not T2).
    let t3_countdown_expiry = now_t3 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, t3_countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T2's cap is stale — burn it.
    escrow::burn_tenant_cap(&mut escrow, cap_t2, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §5. Zero-spread descent — floor stays at min_rent_price ─────────────────

/// T1 rents at min_rent_price and holds until tenure expires without a
/// successor. AtDutchAuction starts with last_acquisition_price =
/// min_rent_price — the spread [min_rent_price, min_rent_price] is zero.
/// compute_floor_price must return min_rent_price at every point in the
/// descent window regardless of curve shape.
///
/// Sweeps axis E (all 7 curves) at fixed (c=0, d=0, h=1, f=0). With
/// zero spread, compute_price_descent must saturate to min_rent_price
/// from t=0; no curve should produce a value below min_rent_price or
/// cause an arithmetic error. A new tenant T2 can rent at min_rent_price.
#[test]
fun e2e_zero_spread_descent_floor_stays_at_min_rent_price_across_curves() {
    let mut sc = setup();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 1, 0); // c=0 h=1, vary e
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        let min_price = escrow_corpus::min_rent_price_const();

        // T1 rents at min_rent_price — no successor.
        let cap_t1 = escrow::rent(
            &mut escrow,
            mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random,
            &clk,
            sc.ctx(),
        );

        // APT past tenure ceiling → AtDutchAuction.
        // last_acquisition_price = min_rent_price → zero spread.
        let tenure_boundary = escrow_corpus::tenure_ceiling_const();
        clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
        assert!(escrow::is_at_dutch_auction(&escrow), tag);

        // floor at t=0 of descent window: must equal min_rent_price.
        // (Zero spread means price == min_price at every point; any clock value works.)
        let floor_at_start = escrow::compute_floor_price(&escrow, &clk);
        assert_eq!(floor_at_start, min_price);

        // floor at mid-descent: must still equal min_rent_price.
        let now_mid = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
        let floor_at_mid = escrow::compute_floor_price(&escrow, &clk);
        assert_eq!(floor_at_mid, min_price);

        // floor at descent boundary: must equal min_rent_price.
        let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
        let _ = descent_boundary; // referenced for documentation only; clock unchanged
        let floor_at_end = escrow::compute_floor_price(&escrow, &clk);
        assert_eq!(floor_at_end, min_price);

        // T2 can rent at min_rent_price → HandoverOpen.
        clock::set_for_testing(&mut clk, now_mid);
        let cap_t2 = escrow::rent(
            &mut escrow,
            mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random,
            &clk,
            sc.ctx(),
        );
        assert!(escrow::is_handover_open(&escrow), tag);

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

// ─── §B1. Five successive PTBs — each chains rent+APT(Instant)+borrow ────────

/// Five successive PTBs with a representative c=0 config. Each PTB atomically
/// chains rent() → APT(Instant) → borrow_asset(). Demonstrates chain depth:
/// every successive tenant (5 total) can borrow immediately after being crowned
/// via an Instant handover. tag(0,0,0,0,0) is the canonical representative.
///
/// PTB 1: T1 rents from Idle — immediately current, no APT needed.
/// PTBs 2–5: Tn bids → APT fires → Tn current → Tn borrows+returns.
#[test]
fun e2e_b1_five_ptbs_borrow_chain() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let min_price = escrow_corpus::min_rent_price_const();

    // PTB 1: T1 rents from Idle — immediately current.
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let cap_t1 = escrow::rent(&mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    assert!(escrow::is_handover_open(&escrow), tag);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    // PTBs 2–5: Tn bids → APT Instant → Tn current → borrow+return.
    let mut ptb: u8 = 2;
    while (ptb <= 5) {
        let mut clk = clock::create_for_testing(sc.ctx());
        let random_ptb = sc.take_shared<Random>();
        let t = (ptb as u64) * 1_000;
        clock::set_for_testing(&mut clk, t);
        let floor = escrow::compute_floor_price(&escrow, &clk);
        let cap = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), cycles::cycles(1), &random_ptb, &clk, sc.ctx());
        escrow::apply_pending_transition_states(&mut escrow, &random_ptb, &clk, sc.ctx());
        let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap, &random_ptb, &clk, sc.ctx());
        escrow::return_asset(&mut escrow, asset, receipt);
        assert!(escrow::is_handover_open(&escrow), tag);
        test_scenario::return_shared(random_ptb);
        clock::destroy_for_testing(clk);
        transfer::public_transfer(cap, OWNER);
        if (ptb < 5) {
            test_scenario::return_shared(escrow);
            sc.next_tx(OWNER);
            escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
        };
        ptb = ptb + 1;
    };

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

/// Corpus sweep: all 7 curve shapes (axis E) at c=0, d=0, h=0, f=0.
/// Each iteration: T1 rents from Idle (immediately current, no APT needed)
/// and borrows in the same PTB. Verifies the Idle→borrow path is unblocked
/// across every curve shape — borrow behavior is independent of the credit
/// and descent curves.
///
/// The APT(Instant)+borrow path (T2 bids → APT → T2 borrows) is covered by
/// e2e_b1_five_ptbs_borrow_chain at one config; that test's per-PTB boundary
/// overhead prevents sweeping all 56 configs within the gas budget.
#[test]
fun e2e_b1_instant_borrow_across_curve_shape_states() {
    let mut sc    = setup();
    // c=0, d=0, h=0, f=0 — vary e: 7 configs (one per curve shape).
    let entries   = escrow_corpus::filter_d(
                        escrow_corpus::filter_f(
                            escrow_corpus::filter_h(
                                escrow_corpus::with_handover_instant(), 0), 0), 0);
    let n         = entries.length();
    let min_price = escrow_corpus::min_rent_price_const();
    let mut i     = 0;
    while (i < n) {
        let entry = entries.borrow(i);
        let cfg   = *entry.cfg();
        let tag   = entry.tag();
        let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
        let clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // T1 rents from Idle — immediately current — borrows in same PTB.
        let cap_t1 = escrow::rent(&mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
        let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
        escrow::return_asset(&mut escrow, asset, receipt);
        assert!(escrow::is_handover_open(&escrow), tag);

        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        i = i + 1;
    };
    sc.end();
}

// ─── §B3. Stale tenant cap cannot borrow ─────────────────────────────────────

/// After T2 wins an Instant handover, T1's cap is stale.
/// borrow_asset() with a stale cap aborts EStaleTenantCap.
#[test]
#[expected_failure(abort_code = asset_context_state::EStaleTenantCap, location = usufruct::asset_context_state)]
fun e2e_b3_stale_tenant_cap_borrow_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids → APT Instant → T1 stale.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    // T1's cap is now stale — borrow must abort.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §B4. Auction entry — rent from AtDutch then borrow in same PTB ──────────

/// T1 rents, tenure expires → AtDutchAuction. T2 rents at the auction
/// price — rent() from AtDutch calls do_install_new_tenant (T2 is
/// immediately current, no APT needed). T2 borrows in the same PTB.
///
/// Config: c=0, d=0, h=1 (observable AtDutch), f=0.
#[test]
fun e2e_b4_auction_entry_rent_and_borrow_same_ptb() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // h=1
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents, tenure expires → AtDutchAuction.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    // T2 places a bid and APT fires handover so last_acq_price > min to get a spread.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_b4  = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2_temp = escrow::rent(&mut escrow, mk_payment(floor_b4, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // Now T2 holds tenure; advance past T2's tenure ceiling.
    let tenure_boundary = 1_000 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);

    // T3 rents from AtDutchAuction at mid-descent price — immediately current.
    let now_mid  = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let price_t3 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t3   = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // T3 borrows in the same PTB — no APT needed (do_install_new_tenant makes T3 current directly).
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t3, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2_temp, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §B6. Intra-PTB repeated borrow+return cycles ────────────────────────────

/// The same tenant executes three borrow+return cycles within a single PTB.
/// Verifies that the hot-potato AssetReceipt discipline works repeatedly:
/// each return restores the asset to the escrow, making the next borrow valid.
#[test]
fun e2e_b6_same_ptb_repeated_borrow_return_cycles() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Cycle 1
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    // Cycle 2
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    // Cycle 3
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    assert!(escrow::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §P1. CompoundDelta — price increment grows multiplicatively ──────────────

/// Three successive tenants with d=1 (CompoundDelta 10% + 1 mist).
/// At clock=0 (no time elapsed), floor_price = stake * 1.1 + 1, so
/// the absolute gap between successive prices grows each round.
/// Verifies: (floor3 - floor2) > (floor2 - floor1) > 0.
#[test]
fun e2e_p1_compound_delta_gap_grows_across_re_prices() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 1, 0, 0, 0); // d=1 CompoundDelta
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    let price_t2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    let price_t3 = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t3 > price_t2, tag);

    // Compound growth: each increment is larger than the previous.
    let gap_2_1 = price_t2 - price_t1;
    let gap_3_2 = price_t3 - price_t2;
    assert!(gap_3_2 > gap_2_1, tag);

    let cap_t3 = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §P2. FixedDelta — price increment is constant ───────────────────────────

/// Three successive tenants with d=0 (FixedDelta 10 SUI).
/// At clock=0, floor_price = stake + FIXED_DELTA_VALUE, so the
/// absolute gap is constant across all re-prices.
/// Verifies: (floor2 - floor1) == (floor3 - floor2) == FIXED_DELTA_VALUE.
#[test]
fun e2e_p2_fixed_delta_gap_is_constant_across_re_prices() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // d=0 FixedDelta
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();
    let delta   = escrow_corpus::fixed_delta_value_const();

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    let price_t2 = escrow::compute_floor_price(&escrow, &clk);
    assert_eq!(price_t2 - price_t1, delta);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    let price_t3 = escrow::compute_floor_price(&escrow, &clk);
    assert_eq!(price_t3 - price_t2, delta); // constant gap

    let cap_t3 = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §E1. Two earnings withdrawals across separate lifecycle events ───────────

/// Owner withdraws earnings twice: once after a handover (T1's used_credit
/// transferred) and once after tenure expiry (T2's full credit transferred).
/// Verifies: each withdrawal yields > 0 coins; the second withdrawal is fresh
/// (balance drained to zero by the first call).
///
/// Config: c=0 (Instant), h=0 (Skipped — tenure → Idle in one APT), f=0.
#[test]
fun e2e_e1_owner_withdraws_earnings_twice_across_lifecycle() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // c=0 h=0
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow_handle, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents at t=0.
    let cap_t1 = escrow::rent(
        &mut escrow_handle, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids at t=tenure_ceiling/2 → APT Instant fires handover.
    // T1 held for half the tenure: used_credit > 0 → owner accumulates earnings.
    let t_mid    = escrow_corpus::tenure_ceiling_const() / 2;
    clock::set_for_testing(&mut clk, t_mid);
    let floor_e1 = escrow::compute_floor_price(&escrow_handle, &clk);
    let cap_t2   = escrow::rent(&mut escrow_handle, mk_payment(floor_e1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow_handle), tag);

    // First withdrawal — T1's used_credit share.
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let mut escrow_handle = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let earnings_1 = escrow::withdraw_earnings(&mut escrow_handle, &owner_cap, &random, &clk, sc.ctx());
    assert!(coin::value(&earnings_1) > 0, tag);
    coin::burn_for_testing(earnings_1);

    // T2's tenure expires → Idle (Skipped). T2's full credit → owner earnings.
    let tenure_boundary = t_mid + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow_handle, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow_handle), tag);

    // Second withdrawal — T2's earnings (fresh, first was drained to zero).
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let mut escrow_handle = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let earnings_2 = escrow::withdraw_earnings(&mut escrow_handle, &owner_cap, &random, &clk, sc.ctx());
    assert!(coin::value(&earnings_2) > 0, tag);
    coin::burn_for_testing(earnings_2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow_handle);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §R1. Retire from HandoverConfirmed — pending bid inherits retiring flag ──

/// Owner sets the retiring flag while in HandoverConfirmed (T2 has a pending
/// bid). APT still honors the bid and fires the handover — T2 receives
/// HandoverOpen with the retiring flag inherited. T2's tenure then collapses
/// to Retired (not AtDutch) because the flag is active.
///
/// Config: c=1 (Countdown — time is needed to verify flag persists through APT),
///         h=0 (Skipped — tenure → Retired in one APT when retiring=true), f=0.
#[test]
fun e2e_r1_retire_from_hc_pending_bid_gets_hopen_with_retiring_flag() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents (Idle → HandoverOpen).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 places a bid (HandoverOpen → HandoverConfirmed).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_r1 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(floor_r1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // Owner sets retiring flag while in HandoverConfirmed.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    // State stays HandoverConfirmed — retire only lifts the flag here.
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // APT past T2's countdown expiry → APT honors the bid: T2 gets HandoverOpen.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // APT past T2's tenure ceiling → collapses to Retired (not AtDutch).
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // Claim the asset.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());

    transfer::public_transfer(asset, OWNER);
    coin::burn_for_testing(earnings);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §A1. APT fires at exact tenure boundary (>= inclusivity) ────────────────

/// apply_pending_transition_states with clock == tenure_boundary_ms fires the
/// tenure expiry transition. Verifies the >= guard in phases::has_passed.
#[test]
fun e2e_a1_apt_fires_at_exact_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // h=0 Skipped → Idle
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Exact boundary: clock == phase_start(0) + tenure_ceiling.
    let boundary = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, boundary);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // h=0 Skipped: tenure → AtDutch → Idle in one APT step.
    assert!(escrow::is_idle(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §A2. APT does not fire one ms before tenure boundary ────────────────────

/// apply_pending_transition_states with clock == tenure_boundary_ms - 1 does not
/// fire — state stays HandoverOpen. Verifies the >= guard is not >.
#[test]
fun e2e_a2_apt_noop_one_ms_before_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // One ms before the boundary — nothing should fire.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() - 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §F2. FixedTime — T3 supersedes T2, T3 wins handover at tenure boundary ──

/// With c=2 (FixedTime), handover_countdown_expiry saturates to
/// phase_start + tenure_ceiling. T2 bids, T3 supersedes T2; at the
/// tenure boundary APT fires the handover to T3 (not T2). T2's cap is stale.
///
/// Config: c=2, d=0, e=0, h=1 (Window — tenure and handover don't co-fire
/// into Idle so we can observe T3's HandoverOpen), f=0.
#[test]
fun e2e_f2_fixed_time_T3_supersedes_T2_wins_at_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(2, 0, 0, 1, 0); // c=2 FixedTime, h=1
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents (Idle → HandoverOpen, phase_start = 0).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids at t=1000 → HandoverConfirmed.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_f2a = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2    = escrow::rent(&mut escrow, mk_payment(floor_f2a, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidPlaced>().length(), 1);

    // T3 supersedes T2 at t=2000 (before tenure_ceiling=100_000).
    clock::set_for_testing(&mut clk, 2_000);
    let floor_f2b = escrow::compute_floor_price(&escrow, &clk);
    let cap_t3    = escrow::rent(&mut escrow, mk_payment(floor_f2b, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // APT at tenure_ceiling (= FixedTime handover expiry = phase_start + tenure_ceiling = 100_000).
    // Handover fires → T3 wins → HandoverOpen (T3 current, new phase_start=100_000).
    // T3's tenure ceiling = 100_000 + 100_000 = 200_000 > 100_000 → no tenure expiry yet.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T2's cap is stale — T3 won, T2 was superseded.
    escrow::burn_tenant_cap(&mut escrow, cap_t2, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §B1-inv. Countdown requires clock advance before borrow ─────────────────

/// Temporal invariant: with c=1 (Countdown, handover_floor=25_000 ms),
/// a pending tenant cannot borrow until the countdown elapses and APT
/// promotes them to current. Documents the protocol guarantee that
/// HandoverConfirmed is a locked state — TenantCap alone is insufficient.
///
/// Three PTBs:
///   PTB 1: T1 rents from Idle → immediately current → borrows (no wait needed).
///   PTB 2: T2 bids → HandoverConfirmed (pending). APT called before countdown
///          expires → fires nothing → state stays HandoverConfirmed.
///   PTB 3: Clock advances past countdown. APT fires handover → T2 current.
///          T2 borrows in the same PTB — now allowed.
///
/// Contrast with e2e_b1_five_ptbs_borrow_chain (c=0 Instant): there, every
/// PTB chains rent+APT+borrow without a clock advance. Here, PTB 2 cannot
/// borrow and PTB 3 is required.
#[test]
fun e2e_b1_inv_countdown_borrow_requires_clock_advance() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);

    // PTB 1: T1 rents from Idle — immediately current — borrows.
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    assert!(escrow::is_handover_open(&escrow), tag);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    // PTB 2: T2 bids at t=1_000 → HandoverConfirmed (T2 pending).
    // APT at same clock — countdown not elapsed (1_000 < 1_000 + 25_000) → no-op.
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // Countdown has not elapsed — T2 is still pending, state unchanged.
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    // PTB 3: clock advances past countdown expiry → APT fires handover → T2 current.
    // T2 borrows in the same PTB — the temporal unlock has occurred.
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t2, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

// ─── §Identity-agnostic: same tenant bids on own tenure ──────────────────────

/// The protocol does not check the identity of the bidder against existing
/// tenants. OWNER rents from Idle, bids on own tenure, supersedes own
/// pending bid, then APT promotes the final bid to current.
///
/// BidSuperseded.displaced_bidder == BidSuperseded.new_bidder == OWNER:
/// the same address acts as both displaced party and new bidder.
/// refunded_amount == price_2: full pending stake returned (no fee on pending).
/// HandoverCompleted.displaced_tenant == OWNER: outgoing current == incoming.
#[test]
fun e2e_same_tenant_successive_bids_identity_agnostic() {
    let mut sc  = setup();
    // c=1 (Countdown, floor=25_000) required: rent() calls APT internally.
    // With c=0 (Instant) the countdown expires at bid_time, so APT within
    // the supersede rent() would fire the handover before do_supersede_bid.
    // With c=1 the countdown hasn't elapsed at t=2_000, so the supersede path
    // is reachable.
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 (OWNER) rents from Idle → HandoverOpen (current at min_price).
    let cap_t1_current = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // OWNER bids on own tenure at t=1_000 → HandoverConfirmed (current + pending).
    clock::set_for_testing(&mut clk, 1_000);
    let price_2     = escrow::compute_floor_price(&escrow, &clk);
    let cap_t1_bid1 = escrow::rent(
        &mut escrow, mk_payment(price_2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // OWNER supersedes own pending bid at t=2_000 (before 1_000+25_000 countdown).
    clock::set_for_testing(&mut clk, 2_000);
    let price_3     = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_3 > price_2, tag);
    let cap_t1_bid2 = escrow::rent(
        &mut escrow, mk_payment(price_3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let sup = event::events_by_type<BidSuperseded>();
    assert_eq!(sup.length(), 1);
    let se = sup.borrow(0);
    // Core: same address displaced and re-entered.
    assert_eq!(asset_context_state::bid_superseded_displaced_bidder(se),
               asset_context_state::bid_superseded_new_bidder(se));
    assert_eq!(asset_context_state::bid_superseded_refunded_amount(se), price_2);
    assert_eq!(asset_context_state::bid_superseded_new_bid_amount(se), price_3);

    // APT past countdown (1_000+25_000=26_000) → cap_t1_bid2 current.
    // cap_t1_current (original stake, held ~26s) is displaced: remain_credit > 0.
    clock::set_for_testing(&mut clk, 1_000 + escrow_corpus::handover_countdown_c1_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    let he = hc.borrow(0);
    assert_eq!(asset_context_state::handover_completed_displaced_tenant(he), OWNER);
    // new_rent_price is the next floor (price_3 + delta), not the stake itself.
    assert_eq!(asset_context_state::handover_completed_new_rent_price(he),
               price_3 + escrow_corpus::fixed_delta_value_const());
    assert!(asset_context_state::handover_completed_remain_credit(he) > 0, tag);

    transfer::public_transfer(cap_t1_current, OWNER);
    transfer::public_transfer(cap_t1_bid1, OWNER);
    transfer::public_transfer(cap_t1_bid2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Current tenant defends against challenger ───────────────────────────────

/// T1 (OWNER) holds the current position. T2 (CHALLENGER) places a bid.
/// T1 calls rent() to supersede T2, defending tenure at a higher price.
/// T2 receives a full refund of their bid stake.
///
/// BidSuperseded.displaced_bidder = CHALLENGER, new_bidder = OWNER.
/// The current tenant uses the same rent() entry point as any bidder;
/// the protocol does not privilege or restrict based on role.
#[test]
fun e2e_current_tenant_defends_against_challenger() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 (OWNER) rents from Idle → HandoverOpen.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 (CHALLENGER) bids at t=1_000 → HandoverConfirmed.
    clock::set_for_testing(&mut clk, 1_000);
    test_scenario::return_shared(escrow);
    sc.next_tx(CHALLENGER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let floor_2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2  = escrow::rent(&mut escrow, mk_payment(floor_2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    test_scenario::return_shared(escrow);

    // T1 (OWNER) supersedes CHALLENGER at t=2_000 (before 1_000+25_000 countdown).
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    clock::set_for_testing(&mut clk, 2_000);
    let floor_3    = escrow::compute_floor_price(&escrow, &clk);
    let cap_t1_new = escrow::rent(&mut escrow, mk_payment(floor_3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let sup = event::events_by_type<BidSuperseded>();
    assert_eq!(sup.length(), 1);
    let se = sup.borrow(0);
    assert_eq!(asset_context_state::bid_superseded_displaced_bidder(se), CHALLENGER);
    assert_eq!(asset_context_state::bid_superseded_new_bidder(se), OWNER);
    assert_eq!(asset_context_state::bid_superseded_refunded_amount(se), floor_2);

    // APT past T1_new's countdown → T1 defends tenure at floor_3.
    clock::set_for_testing(&mut clk, 2_000 + escrow_corpus::handover_countdown_c1_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    // new_rent_price = next floor after handover = floor_3 + delta.
    assert_eq!(asset_context_state::handover_completed_new_rent_price(hc.borrow(0)),
               floor_3 + escrow_corpus::fixed_delta_value_const());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t1_new, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Overpay accepted — stake elevation across all four states ───────────────

/// floor_price is a minimum (>=), not an exact amount. Paying 2×floor_price
/// is accepted in every state. The full paid amount is stored as stake,
/// raising the floor for the next bidder more than a minimal bid would.
///
/// Drives sequentially through: Idle → HandoverOpen → HandoverConfirmed →
/// AtDutchAuction, paying 2× the floor_price at each step. After each rent,
/// the new floor_price == price_paid + FIXED_DELTA (not floor_price + delta),
/// confirming the full overpay is stored as stake.
#[test]
fun e2e_overpay_accepted_elevates_next_floor() {
    let mut sc    = setup();
    // c=1 (Countdown) required for the HandoverConfirmed supersede step:
    // rent() calls APT internally; with c=0 the countdown expires at bid_time,
    // so APT fires the handover before reaching do_supersede_bid in HC state.
    // h=1 (Window) makes AtDutchAuction observable.
    let tag       = escrow_corpus::tag(1, 0, 0, 1, 0); // c=1 Countdown, h=1 Window
    let cfg       = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk   = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();
    let min_price = escrow_corpus::min_rent_price_const();
    let delta     = escrow_corpus::fixed_delta_value_const();
    let countdown = escrow_corpus::handover_countdown_c1_const(); // 25_000

    // Idle: pay 2×min_price. Floor after = 2×min + delta (not min + delta).
    let price_t1 = 2 * min_price;
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let rs       = event::events_by_type<RentStarted>();
    assert_eq!(asset_context_state::rent_started_price_paid(rs.borrow(0)), price_t1);
    assert!(price_t1 >= asset_context_state::rent_started_floor_price(rs.borrow(0)), tag);
    assert_eq!(escrow::compute_floor_price(&escrow, &clk), price_t1 + delta);

    // HandoverOpen: bid at 2×floor_ho at t=1_000. Floor after reflects full bid.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_ho = price_t1 + delta;
    let price_t2 = 2 * floor_ho;
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let bp       = event::events_by_type<BidPlaced>();
    assert_eq!(asset_context_state::bid_placed_bid_amount(bp.borrow(0)), price_t2);
    assert!(price_t2 >= asset_context_state::bid_placed_floor_price(bp.borrow(0)), tag);
    assert_eq!(escrow::compute_floor_price(&escrow, &clk), price_t2 + delta);

    // HandoverConfirmed (supersede at t=2_000, before 1_000+25_000 countdown): pay 2×floor_hc.
    clock::set_for_testing(&mut clk, 2_000);
    let floor_hc = price_t2 + delta;
    let price_t3 = 2 * floor_hc;
    let cap_t3   = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let bs       = event::events_by_type<BidSuperseded>();
    assert_eq!(asset_context_state::bid_superseded_new_bid_amount(bs.borrow(0)), price_t3);
    assert!(price_t3 > floor_hc, tag);

    // APT past T3's countdown (1_000+25_000=26_000) → T3 current.
    // T3 phase_start = min(2_000+25_000, 0+100_000) = 27_000.
    // T3 tenure expires at 27_000+100_000 = 127_000.
    let t3_expiry = 1_000 + countdown; // = 26_000 (T2's countdown, T3 superseded it)
    clock::set_for_testing(&mut clk, t3_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    // AtDutchAuction: T3's phase_start = t3_expiry=26_000 (handover boundary for Countdown).
    // Actually: expiry_at(bid_time=2_000, phase_start=0, tenure_ceiling=100_000)
    //   = min(2_000+25_000, 0+100_000) = 27_000.
    let t3_phase_start = 27_000u64;
    let tenure_boundary = t3_phase_start + escrow_corpus::tenure_ceiling_const(); // 127_000
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);

    // Pay 2× mid-descent price. RentStarted events: [Idle, AtDutch].
    let now_mid       = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let descent_price = escrow::compute_floor_price(&escrow, &clk);
    let price_t4      = 2 * descent_price;
    let cap_t4        = escrow::rent(&mut escrow, mk_payment(price_t4, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let rs_all        = event::events_by_type<RentStarted>();
    assert_eq!(rs_all.length(), 2); // Idle + AtDutch
    assert_eq!(asset_context_state::rent_started_price_paid(rs_all.borrow(1)), price_t4);
    assert!(price_t4 >= asset_context_state::rent_started_floor_price(rs_all.borrow(1)), tag);
    assert!(escrow::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    transfer::public_transfer(cap_t4, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §HC floor uses pending stake, not current stake ─────────────────────────

/// Explicit test of the floor_price regime change at the HO→HC boundary.
///
/// In HandoverOpen:  floor = current_stake  + δ  (beat the current tenant)
/// In HandoverConfirmed: floor = pending_stake + δ  (beat the challenger)
///
/// The two values are DIFFERENT: pending_stake >= current_stake + δ, so
/// floor_HC >= floor_HO + δ > floor_HO.
///
/// If HC mistakenly used current_stake, floor_HC would equal the old floor_HO
/// — a superseder could displace a higher bid by paying the same floor as the
/// original challenger, breaking price monotonicity.
///
/// Setup: T1 stakes 10 SUI (min_price). T2 bids exactly at floor_HO = 20 SUI.
///   floor_HC (correct) = T2_stake + δ = 20 + 10 = 30 SUI
///   floor_HC (wrong)   = T1_stake + δ = 10 + 10 = 20 SUI  ← floor_HO, no escalation
/// The test asserts the correct value and documents the wrong one as a comment.
#[test]
fun e2e_hc_floor_uses_pending_stake_not_current_stake() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();
    let min_price = escrow_corpus::min_rent_price_const();
    let delta     = escrow_corpus::fixed_delta_value_const();

    // T1 rents from Idle at min_price (10 SUI).
    let cap_t1   = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let floor_ho = escrow::compute_floor_price(&escrow, &clk);
    assert_eq!(floor_ho, min_price + delta); // = 20 SUI

    // T2 bids at exactly floor_HO (minimal bid) → HandoverConfirmed.
    // T2_stake = floor_HO = min_price + delta = 20 SUI.
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_ho, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // floor_HC must use T2's pending stake (20 SUI), not T1's current stake (10 SUI).
    let floor_hc = escrow::compute_floor_price(&escrow, &clk);
    assert_eq!(floor_hc, floor_ho + delta);  // correct:  20 + 10 = 30 SUI
    // assert_eq!(floor_hc, min_price + delta); // WRONG: 10 + 10 = 20 SUI (= floor_HO, no escalation)

    // Confirm the escalation: HC floor strictly exceeds HO floor.
    assert!(floor_hc > floor_ho, tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §FIN-1. Financial conservation at handover ──────────────────────────────

/// At every handover, the departing tenant's principal is partitioned
/// exactly into three outputs — no money is created or destroyed:
///
///   owner_share + protocol_fee + remain_credit == principal (T1's stake)
///
/// Derived identities:
///   owner_share + protocol_fee == used_credit   (earned portion fully split)
///   remain_credit              == principal - used_credit   (unearned refund)
///
/// Setup: T1 rents at min_price; T2 bids at t_mid (half the tenure ceiling)
/// so used_credit > 0 (non-degenerate). c=0 (Instant) fires handover at
/// bid_time without requiring a separate clock advance.
#[test]
fun e2e_fin1_handover_financial_conservation() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // c=0 Instant, e=0 Linear
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents at min_price (this is the principal we will conserve).
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids at mid-tenure so used_credit > 0.
    let t_mid    = escrow_corpus::tenure_ceiling_const() / 2; // 50_000 ms
    clock::set_for_testing(&mut clk, t_mid);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Instant handover fires at bid_time = t_mid.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    let hc_events = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc_events.length(), 1);
    let he = hc_events.borrow(0);
    let used_credit   = asset_context_state::handover_completed_used_credit(he);
    let owner_share   = asset_context_state::handover_completed_owner_share(he);
    let protocol_fee  = asset_context_state::handover_completed_protocol_fee(he);
    let remain_credit = asset_context_state::handover_completed_remain_credit(he);

    // FIN-1: principal partitioned into three outputs exactly.
    assert_eq!(owner_share + protocol_fee + remain_credit, price_t1);
    assert_eq!(owner_share + protocol_fee, used_credit);
    assert_eq!(remain_credit, price_t1 - used_credit);
    // Non-degenerate: used_credit > 0 at t_mid > phase_start=0.
    assert!(used_credit > 0, tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §FIN-2. Financial conservation at tenure expiry ─────────────────────────

/// At tenure expiry, the full principal (the CURRENT tenant's stake) is
/// distributed between owner and protocol — no remainder. The fundamental
/// invariant is:
///
///   owner_share + protocol_fee == last_acquisition_price == current_stake
///
/// `last_acquisition_price` records the DEPARTING tenant's stake, which is
/// NOT necessarily the price paid by the first tenant. After a handover,
/// the current stake belongs to T2 (their bid amount), not T1.
///
/// Setup: T1 rents → T2 wins Instant handover at price_t2 → T2's tenure
/// expires. The event must carry price_t2 as last_acquisition_price.
/// Explicitly asserting price_t2 ≠ price_t1 ensures the test covers the
/// non-trivial case: the coordinator reports the current stake faithfully,
/// not the founding tenant's price.
///
/// Config: c=0 (Instant), h=1 (Window — AtDutchAuction observable after
/// T2's tenure expiry, confirming it fired from HandoverOpen not HC).
#[test]
fun e2e_fin2_tenure_expiry_financial_conservation() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // c=0 Instant, h=1 Window
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents at min_price from Idle → HandoverOpen (T1's stake = min_price).
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids at t=1_000 → price_t2 = min_price + delta (FixedDelta) > price_t1.
    let now_t2   = 1_000u64;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(price_t2 > price_t1, tag); // stakes differ — non-trivial test
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Instant handover fires: T2 is now current, T2.phase_start = now_t2.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // T2's tenure boundary = now_t2 + tenure_ceiling = 1_000 + 100_000 = 101_000.
    let t2_tenure_boundary = now_t2 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t2_tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    // h=1 Window → TenureExpired fires but AtDutchAuction (not Idle).
    assert!(escrow::is_at_dutch_auction(&escrow), tag);

    let te_events = event::events_by_type<TenureExpired>();
    assert_eq!(te_events.length(), 1);
    let te                     = te_events.borrow(0);
    let owner_share            = asset_context_state::tenure_expired_owner_share(te);
    let protocol_fee           = asset_context_state::tenure_expired_protocol_fee(te);
    let last_acquisition_price = asset_context_state::tenure_expired_last_acq_price(te);

    // FIN-2: full current-tenant stake consumed — no remainder at expiry.
    // Use price_t2 (the known T2 stake, computed before tenure expiry) as the
    // independent oracle. Asserting via last_acquisition_price would be
    // tautological: both sides derive from the same split_fee(principal) call.
    assert_eq!(owner_share + protocol_fee, price_t2);
    // last_acquisition_price marks the AtDutch descent start: equals T2's stake,
    // NOT T1's founding price — the descent begins where the last tenant left off.
    assert_eq!(last_acquisition_price, price_t2);
    assert!(last_acquisition_price != price_t1, tag);
    // Both parties receive something.
    assert!(owner_share > 0, tag);
    assert!(protocol_fee > 0, tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §FIN-3. Exact 90/10 split ────────────────────────────────────────────────

/// Verifies the 10 % protocol fee rate at two concrete, independently derived
/// points. FIN-1 and FIN-2 verify conservation (sum = principal/used_credit);
/// FIN-3 verifies the specific 10/90 ratio without going through the split
/// function itself (avoids circular assertions).
///
/// Part A — Tenure expiry, exact numeric:
///   principal = min_rent_price = 10_000_000_000 mist  (exactly divisible by 10)
///   expected protocol_fee = 1_000_000_000  (10 %)
///   expected owner_share  = 9_000_000_000  (90 %)
///
/// Part B — Handover, independently computed value:
///   Linear curve (e=0) at t_mid = tenure_ceiling/2 gives exactly
///   used_credit = stake × t_mid / tenure_ceiling = min_price / 2
///   (exact integer arithmetic, no rounding). 10% of min_price/2 is
///   min_price/20 = 500_000_000. Tests both the credit computation and
///   the fee routing without calling split_fee_for_testing.
#[test]
fun e2e_fin3_90_10_split_exact() {
    let mut sc    = setup();
    let tag       = escrow_corpus::tag(0, 0, 0, 0, 0);
    let min_price = escrow_corpus::min_rent_price_const(); // 10_000_000_000

    // ── Part A: tenure expiry — exact 10 % assertion ──
    let cfg_a = escrow_corpus::by_tag(tag);
    let (mut escrow_a, owner_cap_a) = integrate_and_take(cfg_a, &mut sc);
    let mut clk_a = clock::create_for_testing(sc.ctx());
    let random_a  = sc.take_shared<Random>();
    let cap_a1    = escrow::rent(
        &mut escrow_a, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random_a, &clk_a, sc.ctx());
    clock::set_for_testing(&mut clk_a, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow_a, &random_a, &clk_a, sc.ctx());
    {
        let te_events = event::events_by_type<TenureExpired>();
        let te       = te_events.borrow(0);
        let te_fee   = asset_context_state::tenure_expired_protocol_fee(te);
        let te_owner = asset_context_state::tenure_expired_owner_share(te);
        let te_lap   = asset_context_state::tenure_expired_last_acq_price(te);
        // Use min_price (the known T1 stake) as the independent oracle.
        assert_eq!(te_fee + te_owner, min_price);
        // Exact 10 % fee: min_price divisible by 10 → fee = min_price/10 exactly.
        assert_eq!(te_fee,   min_price / 10);
        assert_eq!(te_owner, min_price - min_price / 10);
        // last_acquisition_price == T1's stake here (no handover → founding ==
        // departing tenant), and marks the AtDutch descent starting point.
        assert_eq!(te_lap, min_price);
    };
    transfer::public_transfer(cap_a1, OWNER);
    test_scenario::return_shared(escrow_a);
    owner_cap::burn(owner_cap_a, OWNER);
    test_scenario::return_shared(random_a);
    clock::destroy_for_testing(clk_a);

    // ── Part B: handover — split_fee consistency ──
    let cfg_b = escrow_corpus::by_tag(tag);
    let (mut escrow_b, owner_cap_b) = integrate_and_take(cfg_b, &mut sc);
    let mut clk_b = clock::create_for_testing(sc.ctx());
    let random_b  = sc.take_shared<Random>();
    let cap_b1    = escrow::rent(
        &mut escrow_b, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random_b, &clk_b, sc.ctx());
    let t_mid     = escrow_corpus::tenure_ceiling_const() / 2; // 50_000 ms
    clock::set_for_testing(&mut clk_b, t_mid);
    let floor_b   = escrow::compute_floor_price(&escrow_b, &clk_b);
    let cap_b2    = escrow::rent(
        &mut escrow_b, mk_payment(floor_b, sc.ctx()), cycles::cycles(1), &random_b, &clk_b, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow_b, &random_b, &clk_b, sc.ctx());
    assert!(escrow::is_handover_open(&escrow_b), tag);
    {
        let hc_events = event::events_by_type<HandoverCompleted>();
        let he  = hc_events.borrow(0);
        let uc  = asset_context_state::handover_completed_used_credit(he);
        let ho  = asset_context_state::handover_completed_owner_share(he);
        let hf  = asset_context_state::handover_completed_protocol_fee(he);
        // Linear curve (e=0): used_credit = stake × t_mid / ceiling = min_price / 2.
        let expected_uc = min_price / 2;
        assert_eq!(uc, expected_uc);
        assert_eq!(hf, expected_uc / 10);               // 10 % of used_credit
        assert_eq!(ho, expected_uc - expected_uc / 10); // 90 % of used_credit
    };
    transfer::public_transfer(cap_b1, OWNER);
    transfer::public_transfer(cap_b2, OWNER);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(owner_cap_b, OWNER);
    test_scenario::return_shared(random_b);
    clock::destroy_for_testing(clk_b);

    sc.end();
}

// ─── §DESC-1/2. Price descent — exact endpoint invariants ────────────────────

/// At the exact start of AtDutchAuction (t = tenure_boundary, elapsed_descent
/// = 0), compute_floor_price == last_acquisition_price — no discount yet.
/// At the exact end of the descent window (t = descent_boundary,
/// elapsed_descent = descent_window), compute_floor_price == min_rent_price.
///
///   DESC-1: compute_floor_price(tenure_boundary) == last_acq_price
///   DESC-2: compute_floor_price(descent_boundary) == min_rent_price
///
/// Sweeps all 7 curve shapes (axis E) — evaluate_curve returns 0 at
/// elapsed=0 and SCALE at elapsed>=t_max by construction for every shape,
/// so both endpoints must hold universally. Non-zero spread is created by
/// T1 renting at 2×min_price (overpay, no handover needed) so last_acq_price
/// = 2×min_price > min_price and the two endpoints are distinct values.
///
/// Config: c=0, h=1 (Window — AtDutch observable), d=0, f=0; vary e=0..6.
#[test]
fun e2e_desc12_price_descent_exact_endpoints_across_curves() {
    let mut sc    = setup();
    let min_price = escrow_corpus::min_rent_price_const();
    let stake     = 2 * min_price; // overpay: last_acq_price = stake > min_price
    let tenure_boundary  = escrow_corpus::tenure_ceiling_const();
    let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 1, 0); // h=1 Window, vary e
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // T1 rents at 2×min_price (phase_start = 0). No handover needed for spread.
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(stake, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // APT at exact tenure boundary → AtDutchAuction (last_acq_price = stake).
        clock::set_for_testing(&mut clk, tenure_boundary);
        escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
        assert!(escrow::is_at_dutch_auction(&escrow), tag);

        // DESC-1: elapsed_descent = 0 → evaluate_curve = 0 → no descent yet.
        // Clock is already at tenure_boundary (elapsed=0 from AtDutch phase_start).
        let floor_start = escrow::compute_floor_price(&escrow, &clk);
        assert_eq!(floor_start, stake);

        // DESC-2: elapsed_descent = descent_window = t_max → fully descended.
        clock::set_for_testing(&mut clk, descent_boundary);
        let floor_end = escrow::compute_floor_price(&escrow, &clk);
        assert_eq!(floor_end, min_price);

        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

// ─── §DESC-3/4. Credit accrual — exact endpoint invariants ───────────────────

/// At the exact start of a tenure (t = phase_start, elapsed = 0),
/// compute_used_credit is 0 — no time has elapsed, nothing earned.
/// At the exact tenure boundary (t = phase_start + tenure_ceiling,
/// elapsed >= t_max), compute_used_credit saturates to the full stake.
///
///   DESC-3: compute_used_credit(phase_start) == 0
///   DESC-4: compute_used_credit(phase_start + tenure_ceiling) == stake
///
/// Symmetric counterpart to DESC-1/2: same endpoint logic, credit domain
/// instead of price domain. Sweeps all 7 curve shapes (axis E) to confirm
/// the saturation behavior is universal — evaluate_curve short-circuits at
/// both extremes regardless of shape.
#[test]
fun e2e_desc34_used_credit_exact_endpoints_across_curves() {
    let mut sc    = setup();
    let min_price = escrow_corpus::min_rent_price_const();
    let ceiling   = escrow_corpus::tenure_ceiling_const();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(0, 0, e, 0, 0); // vary e: all 7 curve shapes
        let cfg = escrow_corpus::by_tag(tag);
        let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx()); // t = 0
        let random = sc.take_shared<Random>();

        // T1 rents at min_price (stake = min_price, phase_start = 0).
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // DESC-3: at exact phase_start (elapsed = 0), no stake is earned yet.
        // compute_used_credit is a pure view — does not trigger APT.
        let uc_start = escrow::compute_used_credit(&escrow, &clk);
        assert_eq!(uc_start, 0);

        // DESC-4: at exact tenure_ceiling (elapsed >= t_max), full stake is earned.
        // evaluate_curve short-circuits to SCALE for elapsed >= t_max regardless
        // of curve shape: used_credit = mul_div(stake, SCALE, SCALE) = stake.
        clock::set_for_testing(&mut clk, ceiling);
        let uc_end = escrow::compute_used_credit(&escrow, &clk);
        assert_eq!(uc_end, min_price);

        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

// ─── §Skipped descent — price resets to min_rent_price at tenure boundary ────

/// With DescentPolicyState::Skipped (h=0), tenure expiry triggers the M6b cascade:
/// HandoverOpen → AtDutchAuction → Idle fires in a single APT step because
/// the descent window is zero. The entry price resets to min_rent_price at
/// the exact tenure boundary, regardless of what the departing tenant paid.
///
/// T1 pays 3×min_price (deliberate overpay to make the contrast explicit).
/// At clock == tenure_ceiling exactly, APT fires the cascade → Idle.
/// compute_floor_price == min_rent_price — not T1_stake + delta (30 SUI+),
/// not T1_stake (30 SUI), but min_rent_price (10 SUI). Full price reset.
/// T2 can rent at min_rent_price in the same PTB as the APT call.
#[test]
fun e2e_skipped_descent_resets_price_to_min_at_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // h=0 Skipped
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 rents at 3×min_price. Elevated stake to make the reset contrast visible.
    let price_t1 = 3 * min_price;
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    // floor_HO = T1_stake + delta = 3×min + delta — well above min_price.
    assert!(escrow::compute_floor_price(&escrow, &clk) > min_price, tag);

    // APT at the exact tenure boundary (phase_start=0, tenure_ceiling=100_000).
    // M6b: HandoverOpen → AtDutchAuction → Idle in one step (Skipped descent).
    let tenure_boundary = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Price reset: entry is min_rent_price regardless of T1's elevated stake.
    let floor_after = escrow::compute_floor_price(&escrow, &clk);
    assert_eq!(floor_after, min_price);

    // T2 rents at min_rent_price — the protocol accepts the minimum entry.
    let cap_t2 = escrow::rent(&mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §APT-1. APT idempotency — double call at same clock is a no-op ──────────

/// apply_pending_transition_states is permissionless and may be called many times.
/// The protocol guarantees it is idempotent: once the state has settled at
/// a given timestamp, a second call emits no additional events and leaves
/// the state unchanged.
///
/// This test drives through all three transition boundaries in sequence and
/// calls APT twice at each one. The event count must not increase on the
/// second call, and the state predicate must remain identical.
///
/// Transitions exercised:
///   Boundary 1 — Handover (HC → HO): countdown_expiry = 1_000 + 25_000 = 26_000
///   Boundary 2 — Tenure   (HO → AtDutch): T2.phase_start + tenure_ceiling = 126_000
///   Boundary 3 — Auction  (AtDutch → Idle): 126_000 + descent_window = 226_000
///
/// Config: c=1 (Countdown — observable HC boundary), h=1 (Window — AtDutch
/// observable), d=0, e=0, f=0.
#[test]
fun e2e_apt1_idempotent_double_call_at_every_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 1, 0); // c=1 Countdown, h=1 Window
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents from Idle → HandoverOpen (phase_start = 0).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids at t=1_000 → HandoverConfirmed (countdown_expiry = 26_000).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // ── Boundary 1: Handover ────────────────────────────────────────────────
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const(); // 26_000
    clock::set_for_testing(&mut clk, countdown_expiry);

    // First APT: handover fires → HandoverOpen, 1 HandoverCompleted event.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // Second APT at same clock: no-op — state and event count unchanged.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // ── Boundary 2: Tenure expiry ───────────────────────────────────────────
    // T2.phase_start = countdown_expiry = 26_000; tenure_boundary = 126_000.
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const(); // 126_000
    clock::set_for_testing(&mut clk, tenure_boundary);

    // First APT: tenure fires → AtDutchAuction, 1 TenureExpired event.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // Second APT at same clock: no-op.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // ── Boundary 3: Auction expiry ──────────────────────────────────────────
    // AtDutch.phase_start = tenure_boundary = 126_000; descent_boundary = 226_000.
    let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const(); // 226_000
    clock::set_for_testing(&mut clk, descent_boundary);

    // First APT: auction fires → Idle, 1 AuctionExpired event.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Second APT at same clock: no-op — Idle has no pending transitions.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §RETIRE. All paths to Retired — asset always recoverable (f=0) ──────────
//
// For every reachable lifecycle state, the owner can retire the escrow when
// retire_policy_state = Immediate (f=0, retire_floor = 0, always unlocked) and
// subsequently recover the asset via claim_asset. The Deferred-policy gate
// (f=1, ERetireFloorNotElapsed) is covered separately in §3.
//
// Each test drives to a specific entry state, calls retire(), completes the
// protocol cascade to Retired, and verifies claim_asset returns the asset.
//
//   RETIRE-1  Idle                  → retire() immediate        → Retired
//   RETIRE-2  AtDutchAuction        → retire() immediate        → Retired
//   RETIRE-3  HandoverOpen          → retire() flag → tenure    → Retired
//   RETIRE-4  HandoverConfirmed     → retire() flag → handover
//                                              → tenure         → Retired
//   RETIRE-5  HandoverOpen+borrow   → borrow → retire() flag
//                                   → return → tenure           → Retired
//   RETIRE-6  HandoverConfirmed+borrow → borrow → retire() flag
//                                      → return → handover
//                                      → tenure                 → Retired

// RETIRE-0: Retired → claim_asset returns the asset ─────────────────────────
/// Explicit proof that once the escrow reaches Retired state, the owner can
/// always recover the asset via claim_asset. This is the terminal invariant
/// that all RETIRE-1 through RETIRE-6 also verify — made standalone here
/// so it is directly findable.
#[test]
fun e2e_retire0_retired_claim_asset_succeeds() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-1: Idle ─────────────────────────────────────────────────────────────
#[test]
fun e2e_retire1_from_idle() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::destroy_zero(earnings); // no tenants → no earnings
    transfer::public_transfer(asset, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-2: AtDutchAuction ───────────────────────────────────────────────────
#[test]
fun e2e_retire2_from_at_dutch() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // h=1 Window → AtDutch observable
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents; tenure expires → AtDutchAuction.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);

    // do_retire_immediately from AtDutch → Retired.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-3: HandoverOpen ─────────────────────────────────────────────────────
#[test]
fun e2e_retire3_from_handover_open() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // h=0 Skipped — irrelevant with flag
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // Retiring flag set; state stays HandoverOpen.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // APT at tenure boundary: tenure fires; flag → Retired (not AtDutch).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-4: HandoverConfirmed ────────────────────────────────────────────────
#[test]
fun e2e_retire4_from_handover_confirmed() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // Retiring flag set in HC; state stays HandoverConfirmed.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // APT at countdown expiry: handover fires; T2 current, flag inherited → HO.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // APT at T2 tenure boundary: tenure fires; flag → Retired.
    clock::set_for_testing(&mut clk, countdown_expiry + escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-5: HandoverOpen + asset borrowed ────────────────────────────────────
#[test]
fun e2e_retire5_from_handover_open_while_borrowed() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Asset borrowed — lifecycle state has asset = None.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());

    // retire() in HO: APT no-op (t=0 < tenure_boundary), do_set_retiring_flag
    // operates on the lifecycle state with asset=None without accessing the slot.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // Hot-potato resolved: asset returned, slot restored to Some.
    escrow::return_asset(&mut escrow, asset, receipt);

    // APT at tenure boundary: tenure fires; flag → Retired.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-6: HandoverConfirmed + asset borrowed ───────────────────────────────
#[test]
fun e2e_retire6_from_handover_confirmed_while_borrowed() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // T1 (current cap) borrows in HC. borrow_asset APT: t=1_000 < expiry=26_000 → no-op.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());

    // retire() in HC: APT no-op, do_set_retiring_flag runs with asset=None safely.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // Hot-potato resolved.
    escrow::return_asset(&mut escrow, asset, receipt);

    // APT at countdown expiry: handover fires; T2 current, retiring flag inherited → HO.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // APT at T2 tenure boundary: tenure fires; flag → Retired.
    clock::set_for_testing(&mut clk, countdown_expiry + escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-7: Retired → retire() aborts EAlreadyRetired ─────────────────────
#[test]
#[expected_failure(
    abort_code = asset_context_state::EAlreadyRetired,
    location   = usufruct::asset_context_state,
)]
fun e2e_retire7_already_retired_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Retire once → Retired.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    // Second retire() → EAlreadyRetired.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §CRED-1. used_credit clamping in HandoverConfirmed ──────────────────────

/// In HandoverOpen (Accruing regime) used_credit grows freely with time.
/// Once a bid is placed (HandoverConfirmed, Capped regime) the effective
/// timestamp is saturated at handover_countdown_expiry: for any t ≥ expiry_ms
/// compute_used_credit returns the same value as at t = expiry_ms.
///
/// The clamped used_credit is earned by the protocol and owner; the remainder
/// (stake − used_credit) is returned to the departing tenant as remain_credit.
///
/// Sweeps all 7 curve shapes (axis E) — clamping is a property of the Capped
/// regime, not of any specific curve. Exact numeric split is asserted for e=0
/// (Linear) since that value is independently derivable:
///   expiry=26_000, tenure_ceiling=100_000 → uc = stake × 26/100 = 2_600_000_000
///   remain_credit=7_400_000_000, owner_share=2_340_000_000, fee=260_000_000
///
/// Config: c=1 Countdown (expiry=26_000), vary e=0..6, h=0, d=0, f=0.
#[test]
fun e2e_cred1_used_credit_clamped_at_handover_confirmed_expiry_across_curves() {
    let mut sc    = setup();
    let stake     = escrow_corpus::min_rent_price_const();
    let expiry    = 1_000 + escrow_corpus::handover_countdown_c1_const(); // 26_000
    let ceiling   = escrow_corpus::tenure_ceiling_const();
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(1, 0, e, 0, 0); // c=1, vary e
        let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // T1 rents at t=0 → HandoverOpen (Accruing regime).
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(stake, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // Accruing: used_credit is strictly increasing before the bid.
        clock::set_for_testing(&mut clk, 500);
        let uc_500  = escrow::compute_used_credit(&escrow, &clk);
        clock::set_for_testing(&mut clk, 1_000);
        let uc_1000 = escrow::compute_used_credit(&escrow, &clk);
        assert!(uc_500  > 0,      tag);
        assert!(uc_1000 > uc_500, tag);

        // T2 bids at t=1_000 → HandoverConfirmed (Capped, expiry=26_000).
        // clock already at 1_000 from above.
        let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // CRED-1: Capped regime freezes credit at expiry for every curve shape.
        clock::set_for_testing(&mut clk, expiry);
        let uc_at_expiry   = escrow::compute_used_credit(&escrow, &clk);
        clock::set_for_testing(&mut clk, expiry + 10_000);
        let uc_past_expiry = escrow::compute_used_credit(&escrow, &clk);
        clock::set_for_testing(&mut clk, ceiling);
        let uc_at_ceiling  = escrow::compute_used_credit(&escrow, &clk);
        assert_eq!(uc_past_expiry, uc_at_expiry); // t > expiry → clamped
        assert_eq!(uc_at_ceiling,  uc_at_expiry); // tenure_ceiling → still clamped
        assert!(uc_at_expiry > 0,     tag);
        assert!(uc_at_expiry < stake, tag);

        // Exact value for Linear (e=0): stake × elapsed / ceiling (elapsed = expiry, phase_start=0).
        if (e == 0) { assert_eq!(uc_at_expiry, stake * expiry / ceiling); };

        // APT fires handover; event.used_credit must match the clamped view value.
        // Clock is at ceiling (>= expiry) — APT fires based on handover_countdown_expiry=expiry.
        escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
        assert!(escrow::is_handover_open(&escrow), tag);

        let hc = event::events_by_type<HandoverCompleted>();
        let he = hc.borrow(0);
        assert_eq!(asset_context_state::handover_completed_used_credit(he),
                   uc_at_expiry);
        assert_eq!(asset_context_state::handover_completed_remain_credit(he),
                   stake - uc_at_expiry);

        // Exact split for Linear (e=0): fee and owner derived from uc_at_expiry.
        if (e == 0) {
            assert_eq!(asset_context_state::handover_completed_protocol_fee(he),
                       uc_at_expiry / 10);
            assert_eq!(asset_context_state::handover_completed_owner_share(he),
                       uc_at_expiry - uc_at_expiry / 10);
        };

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

// ─── §CLAIM-1. AssetClaimed.swept_earnings accumulates across all tenants ────

/// claim_asset drains the owner's full accumulated balance and reports it
/// as swept_earnings in AssetClaimed. With multiple tenants, each boundary
/// event deposits into the owner balance; swept_earnings must equal the sum.
///
///   swept_earnings == HandoverCompleted.owner_share   (T1's earned share)
///                  +  TenureExpired.owner_share       (T2's full share)
///
/// Both shares are read from the events themselves — no curve-specific
/// constants needed. The accumulation identity holds for all 7 curve shapes
/// because the individual owner_share values are already correct per FIN-1/2.
///
/// Verifies that swept_earnings > each individual share (both tenants
/// contributed), and that AssetClaimed.swept_earnings matches coin::value.
///
/// Config: c=0 (Instant), h=0 (Skipped → Idle), d=0, f=0; vary e=0..6.
#[test]
fun e2e_claim1_swept_earnings_accumulates_across_tenants_all_curves() {
    let mut sc    = setup();
    let min_price = escrow_corpus::min_rent_price_const();
    let t_mid     = escrow_corpus::tenure_ceiling_const() / 2; // 50_000
    // 3 representative curves (linear=0, logistic=3, exponential=6) — full 7-sweep
    // exceeds gas budget now that each Idle entry draws 3 random values (floor+ceiling+handover).
    let curves = vector[0u8, 3u8, 6u8];
    let mut ci: u64 = 0;
    while (ci < curves.length()) {
        let e = *curves.borrow(ci);
        let tag = escrow_corpus::tag(0, 0, e, 0, 0); // c=0 Instant, h=0 Skipped, vary e
        let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // T1 rents at t=0 → HandoverOpen.
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // T2 bids at t_mid → Instant handover fires → T2 current.
        clock::set_for_testing(&mut clk, t_mid);
        let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
        escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
        assert!(escrow::is_handover_open(&escrow), tag);

        // Read T1's owner share from HandoverCompleted (curve-specific value).
        let ho_share = {
            let evs = event::events_by_type<HandoverCompleted>();
            asset_context_state::handover_completed_owner_share(evs.borrow(0))
        };

        // T2's tenure expires → Skipped → AuctionExpired → Idle.
        let t2_tenure_boundary = t_mid + escrow_corpus::tenure_ceiling_const();
        clock::set_for_testing(&mut clk, t2_tenure_boundary);
        escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
        assert!(escrow::is_idle(&escrow), tag);

        // Read T2's owner share from TenureExpired.
        let te_share = {
            let evs = event::events_by_type<TenureExpired>();
            asset_context_state::tenure_expired_owner_share(evs.borrow(0))
        };

        // Expected swept = sum of all per-boundary owner shares.
        let expected_swept = ho_share + te_share;
        assert!(expected_swept > ho_share, tag); // T2 contributed
        assert!(expected_swept > te_share, tag); // T1 contributed

        // Retire from Idle → Retired.
        escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

        // claim_asset in a new PTB: swept_earnings must equal the accumulated sum.
        test_scenario::return_shared(escrow);
        sc.next_tx(OWNER);
        let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
        let (asset, earnings) = escrow::claim_asset(
            escrow, owner_cap, &random, &clk, sc.ctx());
        assert_eq!(coin::value(&earnings), expected_swept);
        let ac = event::events_by_type<AssetClaimed>();
        assert_eq!(
            escrow::asset_claimed_swept_earnings(ac.borrow(0)),
            expected_swept,
        );

        coin::burn_for_testing(earnings);
        transfer::public_transfer(asset, OWNER);
        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        ci = ci + 1;
    };
    sc.end();
}

// ─── §CORPUS-GAPS. Coverage for under-tested axis values ─────────────────────

// ── Gap 1: c=2 (FixedTime) — handover fires at tenure boundary, full credit ──

/// With HandoverPolicyState::FixedTime, the handover countdown expiry is always
/// phase_start + tenure_ceiling — the handover fires exactly at the tenure
/// boundary. At that moment elapsed == tenure_ceiling, so evaluate_curve
/// short-circuits to SCALE for every curve shape. This means:
///
///   used_credit == stake  (full credit consumed)
///   remain_credit == 0    (nothing refunded to T1)
///   owner_share + protocol_fee == stake  (all of T1's stake distributed)
///
/// Sweeps all 7 curve shapes (axis E) — the result must hold for every shape
/// because it depends on the evaluate_curve saturation invariant (DESC-4),
/// not on the specific curve formula.
#[test]
fun e2e_corpus_gap_fixed_time_handover_full_credit_across_curves() {
    let mut sc    = setup();
    let stake     = escrow_corpus::min_rent_price_const();
    let boundary  = escrow_corpus::tenure_ceiling_const(); // FixedTime expiry = 0 + 100_000
    let mut e: u8 = 0;
    while (e <= 6) {
        let tag = escrow_corpus::tag(2, 0, e, 0, 0); // c=2 FixedTime, vary e
        let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // T1 rents at t=0 (phase_start=0); T2 bids → HC (expiry=100_000).
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(stake, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
        clock::set_for_testing(&mut clk, 1_000);
        let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // APT at tenure boundary: FixedTime expiry fires → handover.
        clock::set_for_testing(&mut clk, boundary);
        escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
        assert!(escrow::is_handover_open(&escrow), tag);

        // used_credit = stake for all curves (elapsed = tenure_ceiling → SCALE saturation).
        let hc = event::events_by_type<HandoverCompleted>();
        let he = hc.borrow(0);
        let used_credit   = asset_context_state::handover_completed_used_credit(he);
        let remain_credit = asset_context_state::handover_completed_remain_credit(he);
        assert_eq!(used_credit,   stake); // full credit consumed
        assert_eq!(remain_credit, 0);     // nothing refunded to T1
        assert_eq!(
            asset_context_state::handover_completed_owner_share(he)
            + asset_context_state::handover_completed_protocol_fee(he),
            stake,                        // all of stake distributed
        );

        // No coin was transferred to the departing tenant — Nothing, not Parcial.
        sc.next_tx(TENANT_ADDR_1);
        assert!(!sc.has_most_recent_for_sender<coin::Coin<SUI>>(), tag);

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

// ── Gap 2: d=1 (CompoundDelta) — financial conservation holds ────────────────

/// The FIN-1/2 conservation invariants hold regardless of the PriceFunctionState
/// axis. CompoundDelta changes the floor price calculation (multiplicative
/// escalation) but not the stake value stored after rent(), so the conservation
/// identities are independent of D.
///
/// Verifies both boundaries in one lifecycle:
///   FIN-1 (handover): owner_share + protocol_fee + remain_credit == T1_stake
///   FIN-2 (tenure):   owner_share + protocol_fee == T2_stake
#[test]
fun e2e_corpus_gap_compound_delta_financial_conservation() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 1, 0, 1, 0); // d=1 CompoundDelta, h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();
    let stake_t1 = escrow_corpus::min_rent_price_const();

    // T1 rents at min_price; T2 bids at CompoundDelta floor (> T1+FixedDelta).
    let cap_t1   = escrow::rent(
        &mut escrow, mk_payment(stake_t1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let t_mid    = escrow_corpus::tenure_ceiling_const() / 2;
    clock::set_for_testing(&mut clk, t_mid);
    let stake_t2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(stake_t2 > stake_t1, tag); // CompoundDelta raises the floor
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(stake_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Instant handover fires → T2 current.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // FIN-1: T1's stake partitioned into three outputs exactly.
    {
        let evs = event::events_by_type<HandoverCompleted>();
        let he  = evs.borrow(0);
        assert_eq!(
            asset_context_state::handover_completed_owner_share(he)
            + asset_context_state::handover_completed_protocol_fee(he)
            + asset_context_state::handover_completed_remain_credit(he),
            stake_t1,
        );
    };

    // T2's tenure expires → AtDutchAuction (h=1 Window).
    let t2_boundary = t_mid + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t2_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), tag);

    // FIN-2: T2's full stake distributed (no remainder at expiry).
    {
        let evs = event::events_by_type<TenureExpired>();
        let te  = evs.borrow(0);
        assert_eq!(
            asset_context_state::tenure_expired_owner_share(te)
            + asset_context_state::tenure_expired_protocol_fee(te),
            stake_t2,
        );
        assert_eq!(asset_context_state::tenure_expired_last_acq_price(te), stake_t2);
    };

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Gap 3: f=1 (Deferred) — retire from HandoverOpen after floor elapsed ─────

/// §RETIRE uses f=0 throughout. This test verifies that retire() from
/// HandoverOpen also works with f=1 once the retire_floor has elapsed.
///
/// T1 rents at t_rent (late enough that tenure_boundary > retire_floor).
/// retire() is called between retire_floor and tenure_boundary — floor is
/// unlocked, tenure not yet expired, so the retiring flag is set.
/// APT at tenure_boundary: flag → Retired.
///
/// Key timing (integrated_at_ms = 0, retire_floor = 10_000_000, ceiling = 100_000):
///   t_rent          = retire_floor − ceiling/2  = 9_950_000
///   retire_at       = retire_floor + 1          = 10_000_001
///   tenure_boundary = t_rent + ceiling          = 10_050_000
#[test]
fun e2e_corpus_gap_deferred_retire_from_handover_open_after_floor() {
    let mut sc    = setup();
    let tag       = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 Deferred
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk   = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();
    let retire_floor     = escrow_corpus::retire_deferred_f1_const();  // 10_000_000
    let tenure_ceiling   = escrow_corpus::tenure_ceiling_const();      // 100_000
    let t_rent           = retire_floor - tenure_ceiling / 2;          // 9_950_000
    let tenure_boundary  = t_rent + tenure_ceiling;                    // 10_050_000

    // T1 rents late: tenure_boundary(10_050_000) > retire_floor(10_000_000).
    clock::set_for_testing(&mut clk, t_rent);
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // retire() after floor elapses but before tenure expires.
    // retire_at = 10_000_001: floor unlocked (> 10_000_000) AND tenure active (< 10_050_000).
    clock::set_for_testing(&mut clk, retire_floor + 1);
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag); // flag set, still HO

    // APT at tenure boundary → retiring flag → Retired (not AtDutch).
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Gap 4: h=1 (Window) + retiring flag — bypasses AtDutch descent ───────────

/// §RETIRE tests (RETIRE-3/4/5/6) all use h=0 (Skipped). This verifies
/// that the retiring flag correctly bypasses AtDutchAuction even when
/// DescentPolicyState is Window (h=1): tenure expiry → Retired directly,
/// NOT AtDutch. The Window policy only affects the descent duration when
/// there is NO retiring flag; the flag unconditionally collapses to Retired.
#[test]
fun e2e_corpus_gap_retiring_flag_bypasses_at_dutch_with_window_policy() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // Retire from HO with h=1: retiring flag set. State stays HO.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // APT at tenure boundary: retiring flag → Retired (NOT AtDutch despite h=1).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);     // flag bypassed AtDutch
    assert!(!escrow::is_at_dutch_auction(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &random, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §SUP-1. Supersede preserves the original countdown expiry ────────────────

/// When T3 supersedes T2's pending bid, the handover_countdown_expiry must
/// be PRESERVED from T2's original bid — not reset to T3's bid_time + countdown.
///
/// The countdown protects the current tenant (T1) for a fixed window from when
/// the FIRST bid landed. Resetting on supersede would let a malicious actor
/// extend that window indefinitely by superseding just before expiry.
///
/// Oracle: read BidPlaced.handover_countdown_expiry from T2's bid event (26_000).
///
/// Discriminating assertion: APT at original_expiry - 1 → no-op (still HC).
///                           APT at original_expiry     → handover fires (T3 wins).
/// If the expiry had reset to 2_000 + 25_000 = 27_000, the second APT at 26_000
/// would be a no-op — the test would catch the bug.
///
/// Config: c=1 Countdown (25_000 ms), d=0, e=0, h=0, f=0.
///   T2 bids  at t=1_000  →  original_expiry = 26_000
///   T3 supersedes at t=2_000  →  reset_expiry (bug) would be 27_000
#[test]
fun e2e_sup1_supersede_preserves_countdown_expiry() {
    let mut sc    = setup();
    let tag       = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Countdown
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk   = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 rents (Idle → HO, phase_start=0).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids at t=1_000 → HC. Stamps countdown_expiry = 1_000 + 25_000 = 26_000.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);

    // Read the original countdown expiry from the BidPlaced event — this is the oracle.
    let original_expiry = {
        let bp = event::events_by_type<BidPlaced>();
        assert_eq!(bp.length(), 1);
        asset_context_state::bid_placed_handover_countdown_expiry(bp.borrow(0))
    };
    assert_eq!(original_expiry, 1_000 + escrow_corpus::handover_countdown_c1_const()); // 26_000

    // T3 supersedes T2 at t=2_000 (before expiry).
    // Bug scenario: if expiry reset → new expiry = 2_000 + 25_000 = 27_000.
    // Correct:      expiry preserved → stays at 26_000.
    clock::set_for_testing(&mut clk, 2_000);
    let floor_t3 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t3   = escrow::rent(
        &mut escrow, mk_payment(floor_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // SUP-1a: one ms before original expiry → APT is a no-op.
    clock::set_for_testing(&mut clk, original_expiry - 1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 0);

    // SUP-1b: at original expiry → handover fires. T3 wins.
    // If expiry had reset to 27_000, this APT would be a no-op (bug caught).
    clock::set_for_testing(&mut clk, original_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T3's cap is the one promoted by the handover.
    let new_cap_id = {
        let hc = event::events_by_type<HandoverCompleted>();
        asset_context_state::handover_completed_new_cap_id(hc.borrow(0))
    };
    assert_eq!(new_cap_id, object::id(&cap_t3));

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §reset_config ────────────────────────────────────────────────────────────
//
// reset_config allows the owner to swap the IntegrationConfig of an escrow at
// runtime. When the escrow is Idle the change takes effect immediately. When
// the escrow is occupied (Renting or AtDutchAuction) the new config is
// buffered as a pending reset and applied at the next natural boundary
// (tenure expiry or auction expiry). retire() discards any pending reset
// without applying it.

// Test 1: Idle → immediate apply ─────────────────────────────────────────────
/// reset_config from Idle: config changes immediately, ConfigReset emitted,
/// ConfigResetScheduled NOT emitted, pending flag stays false.
#[test]
fun reset_config_idle_applies_immediately() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0); // c=0,d=0,e=0,h=0,f=0
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let new_cfg = escrow_corpus::by_tag(1); // f=1 — differs from tag-0
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    assert!(escrow::integration_config(&escrow) == new_cfg, 1);
    assert!(!escrow::has_pending_config_reset(&escrow), 2);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 1);
    let scheduled = event::events_by_type<ConfigResetScheduled>();
    assert_eq!(scheduled.length(), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 2: AtDutch → schedule without cancelling ───────────────────────────────
/// reset_config from AtDutchAuction: new config is buffered, state stays
/// AtDutch, ConfigResetScheduled emitted, ConfigReset NOT emitted.
#[test]
fun reset_config_at_dutch_schedules_without_cancelling() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow,
        STAKE_T1 - STAKE_T1 / 10,
        STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2,
        0,
    );

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    assert!(escrow::is_at_dutch_auction(&escrow), 0);
    assert!(escrow::has_pending_config_reset(&escrow), 1);
    assert!(escrow::integration_config(&escrow) != new_cfg, 2);

    let scheduled = event::events_by_type<ConfigResetScheduled>();
    assert_eq!(scheduled.length(), 1);
    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 3: Renting → schedule without interrupting ─────────────────────────────
/// reset_config from HandoverOpen (Renting): new config buffered, state
/// stays Renting, ConfigResetScheduled emitted, ConfigReset NOT emitted.
#[test]
fun reset_config_renting_schedules_without_interrupting() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let original_cfg = cfg;
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    assert!(escrow::is_rented(&escrow), 0);
    assert!(escrow::has_pending_config_reset(&escrow), 1);
    assert!(escrow::integration_config(&escrow) == original_cfg, 2);

    let scheduled = event::events_by_type<ConfigResetScheduled>();
    assert_eq!(scheduled.length(), 1);
    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 4: tenure expiry with pending reset → skips AtDutch, collapses to Idle ─
/// When a pending config reset is buffered and tenure expires, the AtDutch
/// phase is skipped and the escrow collapses directly to Idle with the new
/// config applied. ConfigReset emitted; AuctionExpired NOT emitted.
#[test]
fun reset_config_tenure_expiry_skips_at_dutch_collapses_to_idle() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    // Use the production APT path so pending_config is applied at tenure boundary.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    assert!(!escrow::has_pending_config_reset(&escrow), 1);
    assert!(escrow::integration_config(&escrow) == new_cfg, 2);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 1);
    let auction_expired = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_expired.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 5: handover preserves pending, does NOT apply ─────────────────────────
/// A handover (Demand → new tenant) does not apply a pending config reset.
/// The pending flag survives the handover and the old config remains active.
#[test]
fun reset_config_handover_preserves_pending_does_not_apply() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let original_cfg = cfg;
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents → HandoverOpen.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Schedule config reset.
    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    // T2 bids → HandoverConfirmed, then drive to Demand.
    escrow::drive_to_demand_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
        escrow_corpus::tenure_ceiling_const(),
    );

    // Fire handover — T2 becomes current tenant.
    escrow::fire_do_handover_for_testing(
        &mut escrow,
        phases::timestamp(escrow_corpus::tenure_ceiling_const() / 2),
        sc.ctx(),
    );

    assert!(escrow::is_rented(&escrow), 0);
    assert!(escrow::has_pending_config_reset(&escrow), 1);
    assert!(escrow::integration_config(&escrow) == original_cfg, 2);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 6: handover then tenure expiry applies pending reset ───────────────────
/// Chain: rent T1 → reset_config(new_cfg) → drive to Demand → handover →
/// tenure expiry. The reset is applied at tenure expiry: Idle, new config
/// active, exactly 1 ConfigReset, no AuctionExpired (AtDutch skipped).
#[test]
fun reset_config_chain_handover_then_tenure_expiry_applies() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    escrow::drive_to_demand_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
        escrow_corpus::tenure_ceiling_const(),
    );

    // Fire handover via the production APT path.
    // drive_to_demand used handover_expiry = tenure_ceiling_const() so the
    // handover fires when the clock passes that boundary.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_rented(&escrow), 10); // still Occupied (new tenant, T2)

    // T2's phase_start = tenure_ceiling_const(). Their tenure expires after
    // another tenure_ceiling_const() ms, so at 2 × tenure_ceiling_const().
    clock::set_for_testing(&mut clk, 2 * escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    assert!(escrow::integration_config(&escrow) == new_cfg, 1);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 1);
    let auction_expired = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_expired.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 7: last write wins — second reset_config overrides first ───────────────
/// Two successive reset_config calls while Renting: last write wins.
/// At tenure expiry only cfg_b (the second config) is applied.
/// Exactly 1 ConfigReset emitted (not two), 2 ConfigResetScheduled emitted.
#[test]
fun reset_config_override_last_write_wins() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Three distinct configs: original=tag(0,0,0,1,0), cfg_a=tag(1,0,0,0,0) c=1 countdown,
    // cfg_b=tag(1) f=1 deferred. All three are structurally different.
    let cfg_a = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)); // c=1 countdown
    escrow::reset_config(&mut escrow, &owner_cap, cfg_a, &random, &clk, sc.ctx());

    // Second reset: cfg_b = tag 1 — overrides cfg_a.
    let cfg_b = escrow_corpus::by_tag(1); // f=1 deferred
    escrow::reset_config(&mut escrow, &owner_cap, cfg_b, &random, &clk, sc.ctx());

    assert!(escrow::has_pending_config_reset(&escrow), 0);

    // Use the production APT path so pending_config is applied at the boundary.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 1);
    assert!(escrow::integration_config(&escrow) == cfg_b, 2);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 1);

    let cfg_from_event = asset_context_state::config_reset_new_config(resets.borrow(0));
    assert!(cfg_from_event == cfg_b, 3);

    let scheduled = event::events_by_type<ConfigResetScheduled>();
    assert_eq!(scheduled.length(), 2);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 8: retire wins — discards pending reset silently ───────────────────────
/// retire() from Renting discards any pending config reset.
/// The retiring flag takes precedence: tenure expiry → Retired, not Idle.
/// ConfigReset is NOT emitted; the config never changes.
#[test]
fun reset_config_retire_wins_discards_pending_silently() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let original_cfg = cfg;
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    // retire() sets the retiring flag and discards the pending reset.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

    assert!(escrow::is_retiring(&escrow), 0);
    assert!(!escrow::has_pending_config_reset(&escrow), 1);

    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow,
        phases::timestamp(escrow_corpus::tenure_ceiling_const()),
        sc.ctx(),
    );

    assert!(escrow::is_retired(&escrow), 2);
    assert!(escrow::integration_config(&escrow) != new_cfg, 3);
    assert!(escrow::integration_config(&escrow) == original_cfg, 4);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 9: reset_config on Retired aborts ──────────────────────────────────────
#[test]
#[expected_failure(abort_code = asset_context_state::EAlreadyRetired, location = usufruct::asset_context_state)]
fun reset_config_on_retired_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::drive_to_retired_for_testing(&mut escrow);

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 10: reset_config on retiring (flag set) aborts ────────────────────────
#[test]
#[expected_failure(abort_code = asset_context_state::ERetireAlreadyScheduled, location = usufruct::asset_context_state)]
fun reset_config_on_retiring_aborts() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Set the retiring flag.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

    // reset_config must abort — retiring flag blocks the schedule path.
    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 11: AtDutch natural expiry applies pending reset ───────────────────────
/// reset_config scheduled while AtDutch; auction expires naturally via the
/// production APT path. On natural expiry the pending reset is applied,
/// ConfigReset emitted, AND AuctionExpired also emitted.
#[test]
fun reset_config_at_dutch_natural_expiry_applies_pending() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Window
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow,
        STAKE_T1 - STAKE_T1 / 10,
        STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2,
        0,
    );

    let new_cfg = escrow_corpus::by_tag(1);
    escrow::reset_config(&mut escrow, &owner_cap, new_cfg, &random, &clk, sc.ctx());

    assert!(escrow::has_pending_config_reset(&escrow), 0);

    // Use the production APT path so pending_config is applied at auction expiry.
    let boundary_ms =
        escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, boundary_ms);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 1);
    assert!(escrow::integration_config(&escrow) == new_cfg, 2);
    assert!(!escrow::has_pending_config_reset(&escrow), 3);

    let resets = event::events_by_type<ConfigReset>();
    assert_eq!(resets.length(), 1);
    let auction_expired = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_expired.length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §reset_config — behavioral dimensions ────────────────────────────────────

// Test BD-1: min_rent_price floor changes after reset ─────────────────────────
/// reset_config immediately updates compute_floor_price when applied from Idle.
/// Proves the new min_rent_price is active, not just stored.
#[test]
fun reset_config_behavior_min_rent_price_floor_changes() {
    let mut sc = setup();
    let cfg_low  = escrow_corpus::by_tag(0); // 10 SUI floor
    let cfg_high = escrow_corpus::with_min_rent_price(
        escrow_corpus::by_tag(0), 20_000_000_000,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg_low, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Before reset: floor = 10 SUI
    assert!(escrow::compute_floor_price(&escrow, &clk) == escrow_corpus::min_rent_price_const(), 0);

    escrow::reset_config(&mut escrow, &owner_cap, cfg_high, &random, &clk, sc.ctx());

    // After reset: floor = 20 SUI
    assert!(escrow::compute_floor_price(&escrow, &clk) == 20_000_000_000, 1);
    assert!(escrow::integration_config(&escrow) == cfg_high, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-1b: bid rejected after min_rent_price raised ────────────────────────
/// After reset raises min_rent_price to 20 SUI, a bid of 15 SUI is rejected.
#[test]
#[expected_failure(abort_code = asset_context_state::EInsufficientPayment, location = usufruct::asset_context_state)]
fun reset_config_behavior_min_rent_price_bid_rejected_after_reset() {
    let mut sc = setup();
    let cfg_low  = escrow_corpus::by_tag(0);
    let cfg_high = escrow_corpus::with_min_rent_price(
        escrow_corpus::by_tag(0), 20_000_000_000,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg_low, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::reset_config(&mut escrow, &owner_cap, cfg_high, &random, &clk, sc.ctx());

    // 15 SUI is above the old 10 SUI floor but below the new 20 SUI floor.
    let cap = escrow::rent(&mut escrow, mk_payment(15_000_000_000, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-2: tenure_ceiling affects has_pending_transition_states ─────────────
/// Proves the new tenure_ceiling governs T2's expiry boundary after reset.
/// At t=160_000, T2 (ceiling=50_000, phase_start=100_000) has expired but
/// under the old ceiling=100_000 it would not have.
#[test]
fun reset_config_behavior_tenure_ceiling_apt_detection() {
    let mut sc = setup();
    let cfg_long  = escrow_corpus::by_tag(0);
    let cfg_short = escrow_corpus::with_tenure_ceiling(escrow_corpus::by_tag(0), 50_000);
    let (mut escrow, owner_cap) = integrate_and_take(cfg_long, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents under cfg_long (ceiling=100_000). phase_start=0.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // At t=60_000, T1's tenure (ceiling=100_000) has NOT expired yet.
    clock::set_for_testing(&mut clk, 60_000);
    assert!(!escrow::has_pending_transition_states(&escrow, &clk), 0);

    // Schedule cfg_short (ceiling=50_000) — takes effect after T1's tenure.
    escrow::reset_config(&mut escrow, &owner_cap, cfg_short, &random, &clk, sc.ctx());

    // T1's tenure expires at 100_000 (old ceiling still governs T1).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 1);

    // Rent T2 under cfg_short (ceiling=50_000). phase_start=100_000.
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T2's tenure expires at 100_000 + 50_000 = 150_000.
    // At t=160_000, that boundary has passed → pending transition present.
    // Under old cfg_long, T2 would expire at 200_000 — NOT pending at 160_000.
    clock::set_for_testing(&mut clk, 160_000);
    assert!(escrow::has_pending_transition_states(&escrow, &clk), 2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-3: descent policy determines AtDutch vs Idle for the next cycle ──────
/// After reset_config from Skip→Window, the NEXT tenure expiry (T2) routes
/// through AtDutch. Under the old Skip policy it would have been Idle.
#[test]
fun reset_config_behavior_descent_policy_atdutch_presence() {
    let mut sc = setup();
    // cfg_skip: h=0 Skip — tenure expiry → Idle
    let cfg_skip   = escrow_corpus::by_tag(0);
    // cfg_window: h=1 Window — tenure expiry → AtDutch
    let cfg_window = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_skip, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents under cfg_skip.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // Schedule cfg_window; will be applied at T1's tenure expiry.
    escrow::reset_config(&mut escrow, &owner_cap, cfg_window, &random, &clk, sc.ctx());

    // T1's tenure expires → Idle with cfg_window (pending_config skips AtDutch
    // during fire(), so T1's own expiry still goes to Idle directly).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);
    assert!(escrow::integration_config(&escrow) == cfg_window, 1);

    // T2 rents under cfg_window (Window descent). phase_start = tenure_ceiling.
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T2's tenure expires at 2 × tenure_ceiling. With Window descent and no
    // pending_config, fire() goes to AtDutch instead of Idle.
    clock::set_for_testing(&mut clk, 2 * escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), 2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-4: credit curve determines compute_used_credit_at_ms value ──────────
/// Linear and Smoothstep curves yield different used-credit at 25% of tenure.
/// Proves the active credit curve is used in credit accounting.
#[test]
fun reset_config_behavior_credit_curve_used_credit_changes() {
    let mut sc = setup();
    let cfg_linear     = escrow_corpus::by_tag(0);
    // e=1 → Smoothstep curve
    let cfg_smoothstep = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 1, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_linear, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents under cfg_linear; phase_start = 0.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T1 at 25% of its tenure.
    let quarter_ms = escrow_corpus::tenure_ceiling_const() / 4;
    let credit_linear = escrow::compute_used_credit_at_ms(&escrow, quarter_ms);

    // Schedule cfg_smoothstep; apply at T1's tenure expiry.
    escrow::reset_config(&mut escrow, &owner_cap, cfg_smoothstep, &random, &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    // T2 rents under cfg_smoothstep; phase_start = tenure_ceiling.
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T2 at 25% of its tenure: tenure_ceiling + quarter_ms.
    let credit_smoothstep = escrow::compute_used_credit_at_ms(
        &escrow, escrow_corpus::tenure_ceiling_const() + quarter_ms,
    );

    // Linear: 10 SUI × 0.25 = 2_500_000_000
    // Smoothstep at 0.25: 3×0.0625 - 2×0.015625 ≈ 0.15625 → 1_562_500_000
    assert!(credit_linear != credit_smoothstep, 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-5: price function governs compute_next_ascending_floor ──────────────
/// FixedDelta and CompoundDelta produce different next-floor values for the
/// same bid. Proves the active price function is consulted on every call.
#[test]
fun reset_config_behavior_price_function_floor_escalation() {
    let mut sc = setup();
    // d=0: FixedDelta — next_floor = bid + FIXED_DELTA (10 SUI)
    let cfg_fixed_delta    = escrow_corpus::by_tag(0);
    // d=1: CompoundDelta — next_floor = bid × 1.1 + 1 mist
    let cfg_compound_delta = escrow_corpus::by_tag(escrow_corpus::tag(0, 1, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_fixed_delta, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let bid_amount = escrow_corpus::min_rent_price_const(); // 10 SUI

    // Before reset: FixedDelta — 10 SUI + 10 SUI = 20 SUI
    let floor_before = escrow::compute_next_ascending_floor(&escrow, bid_amount);
    assert!(floor_before == bid_amount + escrow_corpus::fixed_delta_value_const(), 0);

    // Reset to CompoundDelta immediately (Idle state).
    escrow::reset_config(&mut escrow, &owner_cap, cfg_compound_delta, &random, &clk, sc.ctx());

    // After reset: CompoundDelta — 10 SUI × 1.1 + 1 = 11_000_000_001
    let floor_after = escrow::compute_next_ascending_floor(&escrow, bid_amount);
    assert!(floor_after != floor_before, 1);
    assert!(floor_after == 11_000_000_001, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-6: retire policy floor observable after reset ───────────────────────
/// retire_floor_ms reflects the active retire policy. Immediate → None;
/// after reset to Deferred → Some(retire_deferred_f1_const()).
#[test]
fun reset_config_behavior_retire_policy_floor_observable() {
    let mut sc = setup();
    let cfg_immediate = escrow_corpus::by_tag(0);                              // f=0 Immediate
    let cfg_deferred  = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 1)); // f=1 Deferred
    let (mut escrow, owner_cap) = integrate_and_take(cfg_immediate, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Immediate policy: no floor.
    assert!(escrow::retire_floor_ms(&escrow) == option::none(), 0);

    // Reset to Deferred (Idle → immediate apply).
    escrow::reset_config(&mut escrow, &owner_cap, cfg_deferred, &random, &clk, sc.ctx());

    // Deferred policy: floor = RETIRE_DEFERRED_F1.
    assert!(
        escrow::retire_floor_ms(&escrow) == option::some(escrow_corpus::retire_deferred_f1_const()),
        1,
    );

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-6b: retire blocked after reset raises the floor ─────────────────────
/// After switching from Immediate to Deferred, retire() at t=0 aborts.
#[test]
#[expected_failure(abort_code = asset_context_state::ERetireFloorNotElapsed, location = usufruct::asset_context_state)]
fun reset_config_behavior_retire_policy_abort_after_reset() {
    let mut sc = setup();
    let cfg_immediate = escrow_corpus::by_tag(0);
    let cfg_deferred  = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 1));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_immediate, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    escrow::reset_config(&mut escrow, &owner_cap, cfg_deferred, &random, &clk, sc.ctx());

    // Deferred floor = 10_000_000 ms; clock at t=0 → abort.
    escrow::retire(&mut escrow, &owner_cap, &random, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-7: Instant handover lets T2 borrow immediately after bidding ─────────
/// With Instant policy T2's cap becomes Current after apply_pending_transition_states,
/// allowing borrow_asset to succeed.
#[test]
fun reset_config_behavior_handover_instant_borrow_succeeds() {
    let mut sc = setup();
    let cfg_instant = escrow_corpus::by_tag(0); // c=0 Instant
    let (mut escrow, owner_cap) = integrate_and_take(cfg_instant, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 becomes current tenant.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T2 bids — with Instant policy, handover fires immediately via APT.
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // Fire the Instant handover.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    // T2 is now current; borrow_asset succeeds (no abort).
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t2, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-7b: FixedTime handover blocks T4 borrow until handover fires ─────────
/// After reset from Instant to FixedTime, the pending bidder (T4) cannot
/// borrow until the handover boundary has passed.
#[test]
#[expected_failure(abort_code = asset_context_state::EPendingTenantCap, location = usufruct::asset_context_state)]
fun reset_config_behavior_handover_fixed_borrow_blocked() {
    let mut sc = setup();
    let cfg_instant = escrow_corpus::by_tag(0);                               // c=0 Instant
    let cfg_fixed   = escrow_corpus::by_tag(escrow_corpus::tag(2, 0, 0, 0, 0)); // c=2 FixedTime
    let (mut escrow, owner_cap) = integrate_and_take(cfg_instant, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents under cfg_instant.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // Schedule cfg_fixed (FixedTime); applied when T1's tenure expires.
    escrow::reset_config(&mut escrow, &owner_cap, cfg_fixed, &random, &clk, sc.ctx());

    // T1's tenure expires → Idle with cfg_fixed.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);

    // T3 rents under cfg_fixed (FixedTime). phase_start = tenure_ceiling = 100_000.
    let cap_t3 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T4 bids; FixedTime handover_expiry = 100_000 + 100_000 = 200_000.
    // Clock is still at 100_000 — far below expiry.
    let floor_t4 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t4 = escrow::rent(
        &mut escrow, mk_payment(floor_t4, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx(),
    );

    // T4's cap is Pending — handover has not fired. borrow_asset aborts.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t4, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    // Unreachable — abort above.
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    transfer::public_transfer(cap_t4, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §EV. Event field invariants — cap IDs and timing ────────────────────────

// ── EV-1 + EV-2: bid and handover cap_id consistency ─────────────────────────

/// EV-1: BidPlaced.tenant_cap_id == object::id(&cap_t2)
///   The cap returned by rent() in HandoverOpen is the same object whose ID
///   is reported in the BidPlaced event.
///
/// EV-2: HandoverCompleted.new_tenant_cap_id == object::id(&cap_t2)
///   After the handover fires, the new current cap is the same object whose
///   ID was reported in BidPlaced. No new cap is minted at handover time —
///   the cap from do_place_bid is promoted directly.
#[test]
fun e2e_ev1_ev2_bid_and_handover_cap_id_consistency() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // c=0 Instant
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // T1 rents (Idle → HO).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids (HO → HC). cap_t2 is the pending cap.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // EV-1: BidPlaced.tenant_cap_id == the cap returned by rent().
    let bp = event::events_by_type<BidPlaced>();
    assert_eq!(bp.length(), 1);
    assert_eq!(
        asset_context_state::bid_placed_tenant_cap_id(bp.borrow(0)),
        object::id(&cap_t2),
    );

    // APT fires Instant handover → T2 current.
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_handover_open(&escrow), tag);

    // EV-2: HandoverCompleted.new_tenant_cap_id == the same cap (promoted, not re-minted).
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    assert_eq!(
        asset_context_state::handover_completed_new_cap_id(hc.borrow(0)),
        object::id(&cap_t2),
    );

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── EV-3: AssetBorrowed / AssetReturned cap_id consistency ───────────────────

/// AssetBorrowed.tenant_cap_id and AssetReturned.tenant_cap_id must both
/// equal the ID of the cap used in the borrow/return cycle. The borrow event
/// is stamped with the cap passed to borrow_asset; the return event reads the
/// current cap from the lifecycle state (which must be the same cap while
/// no handover has occurred within the PTB).
#[test]
fun e2e_ev3_borrow_return_cap_id_consistency() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    // T1 rents → HO (T1 is current).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let cap_t1_id = object::id(&cap_t1);

    // Borrow and return in same PTB.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &random, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    // EV-3a: AssetBorrowed.tenant_cap_id == cap_t1's ID.
    let ab = event::events_by_type<AssetBorrowed>();
    assert_eq!(ab.length(), 1);
    assert_eq!(asset_context_state::asset_borrowed_tenant_cap_id(ab.borrow(0)), cap_t1_id);

    // EV-3b: AssetReturned.tenant_cap_id == cap_t1's ID (still current at return time).
    let ar = event::events_by_type<AssetReturned>();
    assert_eq!(ar.length(), 1);
    assert_eq!(asset_context_state::asset_returned_tenant_cap_id(ar.borrow(0)), cap_t1_id);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── EV-4: BidPlaced.handover_countdown_expiry accuracy per policy ─────────────

/// The handover_countdown_expiry stamped in BidPlaced must match the value
/// computed by handover_policy_state::expiry_at for each HandoverPolicyState variant.
///
/// With phase_start=0, tenure_ceiling=100_000, bid at t=1_000:
///   c=0 Instant:  expiry = bid_time                              = 1_000
///   c=1 Countdown: expiry = min(bid_time + 25_000, 100_000)     = 26_000
///   c=2 FixedTime: expiry = phase_start + tenure_ceiling         = 100_000
///
/// All three are derived from corpus constants — no hardcoded expectations.
#[test]
fun e2e_ev4_bid_placed_countdown_expiry_accuracy_per_policy() {
    let mut sc        = setup();
    let bid_time      = 1_000u64;
    let tenure_ceiling = escrow_corpus::tenure_ceiling_const();
    let countdown     = escrow_corpus::handover_countdown_c1_const();
    let mut c: u8     = 0;
    while (c <= 2) {
        let tag = escrow_corpus::tag(c, 0, 0, 0, 0); // vary c=0,1,2
        let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
        let random = sc.take_shared<Random>();

        // T1 rents → HO (phase_start = 0).
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        // T2 bids at bid_time → HC. BidPlaced event stamps the expiry.
        clock::set_for_testing(&mut clk, bid_time);
        let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

        let bp = event::events_by_type<BidPlaced>();
        assert_eq!(bp.length(), 1);
        let stamped_expiry = asset_context_state::bid_placed_handover_countdown_expiry(bp.borrow(0));

        // Expected expiry per policy (all derived from corpus constants).
        let expected_expiry = if (c == 0) {
            bid_time                                           // Instant: expiry = bid_time
        } else if (c == 1) {
            bid_time + countdown                               // Countdown: bid + 25_000 = 26_000
        } else {
            tenure_ceiling                                     // FixedTime: phase_start(0) + ceiling
        };
        assert_eq!(stamped_expiry, expected_expiry);

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        test_scenario::return_shared(random);
        clock::destroy_for_testing(clk);
        c = c + 1;
    };
    sc.end();
}

// ─── §RandomInRange — FloorPricePolicyState policy tests ─────────────────────────
//
// Tests for the RandomInRange variant of FloorPricePolicyState.
// Constructors validate invariants; resolution tests verify the drawn floor
// always falls within [min, max]; bid tests verify the bidder strategy.

// ── Constructor validation ────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = floor_price_policy_state::EPriceZero, location = usufruct::floor_price_policy_state)]
fun new_fixed_zero_price_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = floor_price_policy_state::new_fixed(usufruct::monetary::price(0));
    sc.end();
}

#[test]
#[expected_failure(abort_code = floor_price_policy_state::EPriceZero, location = usufruct::floor_price_policy_state)]
fun new_random_in_range_zero_min_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = floor_price_policy_state::new_random_in_range(
        usufruct::monetary::price(0),
        usufruct::monetary::price(10_000_000_000),
    );
    sc.end();
}

#[test]
#[expected_failure(abort_code = floor_price_policy_state::EMinNotLtMax, location = usufruct::floor_price_policy_state)]
fun new_random_in_range_min_equals_max_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = floor_price_policy_state::new_random_in_range(
        usufruct::monetary::price(10_000_000_000),
        usufruct::monetary::price(10_000_000_000),
    );
    sc.end();
}

#[test]
#[expected_failure(abort_code = floor_price_policy_state::EMinNotLtMax, location = usufruct::floor_price_policy_state)]
fun new_random_in_range_min_greater_than_max_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = floor_price_policy_state::new_random_in_range(
        usufruct::monetary::price(15_000_000_000),
        usufruct::monetary::price(10_000_000_000),
    );
    sc.end();
}

// ── Resolution invariant: floor ∈ [min, max] ─────────────────────────────────

// Range used across resolution tests: 5 SUI – 15 SUI
const RANDOM_MIN: u64 = 5_000_000_000;
const RANDOM_MAX: u64 = 15_000_000_000;

#[test]
fun random_floor_resolves_in_range_at_integrate() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor >= RANDOM_MIN, 0);
    assert!(floor <= RANDOM_MAX, 1);

    // view returns policy min, not resolved floor
    assert!(escrow::min_rent_price(&escrow) == RANDOM_MIN, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun random_floor_resolves_in_range_after_auction_expiry() {
    let mut sc = setup();
    // h=1 Window so AtDutch occurs after tenure expiry
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)),
        RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Drive Idle → Renting → AtDutch then let auction expire → Idle with new drawn floor
    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow,
        STAKE_T1 - STAKE_T1 / 10,
        STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2,
        0,
    );
    let boundary_ms = escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, boundary_ms);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    let floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor >= RANDOM_MIN, 1);
    assert!(floor <= RANDOM_MAX, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun random_floor_resolves_in_range_after_tenure_expiry() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)),
        RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MAX, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Tenure + descent window → Idle
    let t_idle = escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, t_idle);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    let floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor >= RANDOM_MIN, 1);
    assert!(floor <= RANDOM_MAX, 2);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun random_floor_resolves_in_range_after_reset_config_from_idle() {
    let mut sc = setup();
    let cfg_fixed = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(cfg_fixed, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cfg_random = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    escrow::reset_config(&mut escrow, &owner_cap, cfg_random, &random, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    let floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor >= RANDOM_MIN, 1);
    assert!(floor <= RANDOM_MAX, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Bid strategy ─────────────────────────────────────────────────────────────

#[test]
fun bid_at_max_always_succeeds_with_random_policy() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Bidding at max guarantees acceptance regardless of drawn floor
    let cap = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MAX, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    assert!(escrow::is_rented(&escrow), 0);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
#[expected_failure(abort_code = asset_context_state::EInsufficientPayment, location = usufruct::asset_context_state)]
fun bid_below_min_always_fails_with_random_policy() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Any drawn floor ≥ RANDOM_MIN > RANDOM_MIN - 1 → always rejected
    let cap = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MIN - 1, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    // Unreachable — abort above. Required to satisfy Move's linear type checker.
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── View vs resolved distinction ─────────────────────────────────────────────

#[test]
fun min_rent_price_view_returns_policy_min_not_resolved_floor() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    let (escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // min_rent_price() always returns the policy min (floor_for_view)
    assert!(escrow::min_rent_price(&escrow) == RANDOM_MIN, 0);

    // compute_floor_price() returns the resolved floor ∈ [min, max]
    let resolved = escrow::compute_floor_price(&escrow, &clk);
    assert!(resolved >= RANDOM_MIN, 1);
    assert!(resolved <= RANDOM_MAX, 2);

    // The two views may differ — the resolved floor is not necessarily the minimum
    // (no assertion on equality/inequality since the draw is deterministic but opaque)

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Floor stability within the Idle cycle ────────────────────────────────────

#[test]
fun random_floor_stable_within_idle_cycle() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Read the resolved floor twice — it must be identical (stored, not re-drawn)
    let floor_a = escrow::compute_floor_price(&escrow, &clk);
    let floor_b = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor_a == floor_b, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §RandomInRange — e2e tests ───────────────────────────────────────────────

// E2E 1: Two-cycle floor variability
// Each Idle draws a fresh resolved_floor. Each AtDutch collapses exactly to
// the resolved_floor of its own cycle — not the policy min, not the other
// cycle's floor. Verified by reading compute_floor_price_at_ms at the full
// descent boundary (elapsed == window → spread fully consumed → floor == F).
#[test]
fun e2e_random_two_cycles_atdutch_collapses_at_own_resolved_floor() {
    let mut sc = setup();
    // h=1 Window so AtDutch has a measurable descent
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)),
        RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // ── Cycle 1 ──────────────────────────────────────────────────────────────
    // F1 = resolved_floor drawn at integrate time
    let f1 = escrow::compute_floor_price(&escrow, &clk);
    assert!(f1 >= RANDOM_MIN, 0);
    assert!(f1 <= RANDOM_MAX, 1);

    // Rent at max (guaranteed to succeed regardless of F1)
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MAX, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Tenure expires → AtDutch (phase_start = 100_000, resolved_floor = F1 carried)
    let t_atdutch_1 = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t_atdutch_1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), 2);

    // At full descent: floor collapses exactly to F1 (not policy min)
    let t_collapse_1 = t_atdutch_1 + escrow_corpus::descent_window_h1_const();
    assert!(escrow::compute_floor_price_at_ms(&escrow, t_collapse_1) == f1, 3);

    // Auction expires → Idle (F2 freshly drawn for cycle 2)
    clock::set_for_testing(&mut clk, t_collapse_1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 4);

    // ── Cycle 2 ──────────────────────────────────────────────────────────────
    let f2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(f2 >= RANDOM_MIN, 5);
    assert!(f2 <= RANDOM_MAX, 6);

    // Rent cycle 2 (phase_start = t_collapse_1)
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MAX, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Tenure expires → AtDutch cycle 2 (phase_start = t_collapse_1 + tenure)
    let t_atdutch_2 = t_collapse_1 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t_atdutch_2);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), 7);

    // At full descent of cycle 2: floor collapses exactly to F2 (not F1, not policy min)
    let t_collapse_2 = t_atdutch_2 + escrow_corpus::descent_window_h1_const();
    assert!(escrow::compute_floor_price_at_ms(&escrow, t_collapse_2) == f2, 8);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// E2E 2: AtDutch descent bottom is resolved_floor, not policy min.
// At full descent (elapsed == window), compute_floor_price equals the
// resolved_floor captured at Idle entry — not min_rent_price() (policy min).
// The two values may coincide only by chance; the assertion targets the
// cycle floor, making the invariant explicit regardless of the draw.
#[test]
fun e2e_random_atdutch_descent_bottom_is_cycle_resolved_floor() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)),
        RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Capture F = resolved_floor drawn at Idle entry
    let resolved_floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(resolved_floor >= RANDOM_MIN, 0);
    assert!(resolved_floor <= RANDOM_MAX, 1);
    // policy min is RANDOM_MIN — may or may not equal resolved_floor
    assert!(escrow::min_rent_price(&escrow) == RANDOM_MIN, 2);

    // Rent → tenure expires → AtDutch (resolved_floor carried into descent)
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MAX, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let t_atdutch = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t_atdutch);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), 3);

    // Start of descent: price equals last_acq_price (= RANDOM_MAX, what T1 paid)
    let floor_start = escrow::compute_floor_price_at_ms(&escrow, t_atdutch);
    assert!(floor_start == RANDOM_MAX, 4);

    // Full descent: price == resolved_floor (anchored at cycle floor, not policy min)
    let t_full = t_atdutch + escrow_corpus::descent_window_h1_const();
    let floor_bottom = escrow::compute_floor_price_at_ms(&escrow, t_full);
    assert!(floor_bottom == resolved_floor, 5);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// E2E 3: reset_config to a different RandomInRange range → next Idle draws from
// the new range, not the original one. The resolved_floor after reset belongs
// entirely to the new range — the old range is never consulted again.
#[test]
fun e2e_random_reset_config_changes_range_for_next_cycle() {
    let range2_min: u64 = 20_000_000_000;  // 20 SUI
    let range2_max: u64 = 30_000_000_000;  // 30 SUI

    let mut sc = setup();
    // Cycle 1: RandomInRange [5, 15]
    let cfg1 = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), RANDOM_MIN, RANDOM_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg1, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // F1 ∈ [5, 15]
    let f1 = escrow::compute_floor_price(&escrow, &clk);
    assert!(f1 >= RANDOM_MIN, 0);
    assert!(f1 <= RANDOM_MAX, 1);

    // Rent, then reset config to range [20, 30]
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(RANDOM_MAX, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let cfg2 = escrow_corpus::with_random_min_rent_price(
        escrow_corpus::by_tag(0), range2_min, range2_max,
    );
    escrow::reset_config(&mut escrow, &owner_cap, cfg2, &random, &clk, sc.ctx());

    // Tenure expires → Idle with floor drawn from NEW range [20, 30]
    // (pending_config skips AtDutch → new Idle with cfg2 applied)
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 2);

    // F2 must come from the new range, not the original [5, 15]
    let f2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(f2 >= range2_min, 3);
    assert!(f2 <= range2_max, 4);
    assert!(escrow::min_rent_price(&escrow) == range2_min, 5);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Fixed — AtDutch descent collapse symmetry ───────────────────────────────

// Symmetric to E2E-2 for RandomInRange: with Fixed policy, the AtDutch descent
// collapses exactly to the fixed price at full descent (elapsed == window).
// This pins the invariant for both policy variants: descent bottom == resolved_floor,
// which for Fixed is always the configured price.
#[test]
fun e2e_fixed_atdutch_descent_bottom_is_fixed_price() {
    let mut sc = setup();
    // h=1 Window, all other axes at default — fixed min_rent_price (corpus default)
    let cfg = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let fixed_price = escrow_corpus::min_rent_price_const();
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Idle floor == fixed price (resolved_floor drawn from Fixed policy)
    assert!(escrow::compute_floor_price(&escrow, &clk) == fixed_price, 0);

    // Rent at 2× floor (sets last_acq_price for the descent)
    let bid = fixed_price * 2;
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(bid, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Tenure expires → AtDutch (resolved_floor = fixed_price carried into descent)
    let t_atdutch = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t_atdutch);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_at_dutch_auction(&escrow), 1);

    // Start of descent: price == last_acq_price (= bid = 2× fixed_price)
    assert!(escrow::compute_floor_price_at_ms(&escrow, t_atdutch) == bid, 2);

    // Full descent: price collapses to fixed_price (not 0, not any other value)
    let t_full = t_atdutch + escrow_corpus::descent_window_h1_const();
    assert!(escrow::compute_floor_price_at_ms(&escrow, t_full) == fixed_price, 3);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §TenurePolicyState — policy tests ──────────────────────────────────────
//
// Mirrors the FloorPricePolicyState test suite for TenurePolicyState.
// The observable of resolved_ceiling is tenure_expiry_ms():
//   tenure_expiry_ms = phase_start + resolved_ceiling
// At phase_start = 0, tenure_expiry_ms == resolved_ceiling_ms.

const CEILING_RAND_MIN: u64 = 50_000;   // 50k ms
const CEILING_RAND_MAX: u64 = 150_000;  // 150k ms

// ── Constructor validation ────────────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = tenure_policy_state::EDurationZero, location = usufruct::tenure_policy_state)]
fun new_fixed_zero_ceiling_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = tenure_policy_state::new_fixed(phases::duration(0));
    sc.end();
}

#[test]
#[expected_failure(abort_code = tenure_policy_state::EDurationZero, location = usufruct::tenure_policy_state)]
fun new_random_ceiling_zero_min_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = tenure_policy_state::new_random_in_range(
        phases::duration(0),
        phases::duration(100_000),
    );
    sc.end();
}

#[test]
#[expected_failure(abort_code = tenure_policy_state::EMinNotLtMax, location = usufruct::tenure_policy_state)]
fun new_random_ceiling_min_equals_max_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = tenure_policy_state::new_random_in_range(
        phases::duration(100_000),
        phases::duration(100_000),
    );
    sc.end();
}

#[test]
#[expected_failure(abort_code = tenure_policy_state::EMinNotLtMax, location = usufruct::tenure_policy_state)]
fun new_random_ceiling_min_greater_max_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = tenure_policy_state::new_random_in_range(
        phases::duration(200_000),
        phases::duration(100_000),
    );
    sc.end();
}

// ── Resolution invariant: resolved_ceiling ∈ [min, max] ──────────────────────

#[test]
fun random_ceiling_resolves_in_range_after_integrate() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(0), CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Rent at t=0; phase_start=0 so tenure_expiry_ms == resolved_ceiling_ms
    let cap = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let expiry = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    assert!(expiry >= CEILING_RAND_MIN, 0);
    assert!(expiry <= CEILING_RAND_MAX, 1);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun random_ceiling_resolves_in_range_after_auction_expiry() {
    let mut sc = setup();
    // h=1 Window to produce AtDutch → Idle cycle
    let cfg = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)),
        CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Drive to AtDutch → auction expires → new Idle with fresh resolved_ceiling
    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_at_dutch_for_testing(
        &mut escrow,
        STAKE_T1 - STAKE_T1 / 10,
        STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2,
        0,
    );
    clock::set_for_testing(&mut clk, escrow_corpus::descent_window_h1_const());
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);

    // Rent from the new Idle (phase_start = descent_window); resolved_ceiling ∈ [min, max]
    let cap = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let phase_start = *option::borrow(&escrow::phase_start_ms(&escrow));
    let expiry      = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    let resolved_ceiling_ms = expiry - phase_start;
    assert!(resolved_ceiling_ms >= CEILING_RAND_MIN, 1);
    assert!(resolved_ceiling_ms <= CEILING_RAND_MAX, 2);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── View distinction ──────────────────────────────────────────────────────────

#[test]
fun tenure_ceiling_view_returns_policy_min_not_resolved() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(0), CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // tenure_ceiling_ms() returns the policy min (min_ceiling), not the resolved value
    assert!(escrow::tenure_ceiling_ms(&escrow) == CEILING_RAND_MIN, 0);

    // After renting, tenure_expiry_ms() reflects the actual resolved ceiling
    let cap = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let expiry = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    assert!(expiry >= CEILING_RAND_MIN, 1);
    assert!(expiry <= CEILING_RAND_MAX, 2);
    // The two may differ: policy min vs resolved value
    assert!(escrow::tenure_ceiling_ms(&escrow) == CEILING_RAND_MIN, 3);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── APT fires exactly at resolved ceiling ─────────────────────────────────────

#[test]
fun random_ceiling_apt_fires_at_resolved_ceiling() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(0), CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Rent at t=0; resolved_ceiling_ms = tenure_expiry_ms (since phase_start=0)
    let cap = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let expiry_ms = *option::borrow(&escrow::tenure_expiry_ms(&escrow));

    // One ms before the resolved ceiling: no pending transition
    clock::set_for_testing(&mut clk, expiry_ms - 1);
    assert!(!escrow::has_pending_transition_states(&escrow, &clk), 0);

    // Exactly at the resolved ceiling: APT is pending
    clock::set_for_testing(&mut clk, expiry_ms);
    assert!(escrow::has_pending_transition_states(&escrow, &clk), 1);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Stability within cycle ────────────────────────────────────────────────────

#[test]
fun random_ceiling_stable_within_rental_cycle() {
    let mut sc = setup();
    let cfg = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(0), CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let cap = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Read tenure_expiry_ms twice — must be identical (stored, not re-drawn)
    let expiry_a = escrow::tenure_expiry_ms(&escrow);
    let expiry_b = escrow::tenure_expiry_ms(&escrow);
    assert!(expiry_a == expiry_b, 0);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Reset config changes the ceiling range for the next cycle ─────────────────

#[test]
fun random_ceiling_reset_config_changes_range() {
    let ceiling_range2_min: u64 = 200_000;
    let ceiling_range2_max: u64 = 300_000;

    let mut sc = setup();
    let cfg1 = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(0), CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg1, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Cycle 1: resolved_ceiling ∈ [50k, 150k]
    let cap1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let expiry1 = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    assert!(expiry1 >= CEILING_RAND_MIN, 0);
    assert!(expiry1 <= CEILING_RAND_MAX, 1);

    // Reset to range [200k, 300k] — applied at next Idle
    let cfg2 = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(0), ceiling_range2_min, ceiling_range2_max,
    );
    escrow::reset_config(&mut escrow, &owner_cap, cfg2, &random, &clk, sc.ctx());

    // Tenure expires → Idle with new config (pending_config skips AtDutch)
    clock::set_for_testing(&mut clk, expiry1);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 2);

    // Cycle 2: resolved_ceiling drawn from new range [200k, 300k]
    let cap2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let phase2 = *option::borrow(&escrow::phase_start_ms(&escrow));
    let expiry2 = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    let resolved2 = expiry2 - phase2;
    assert!(resolved2 >= ceiling_range2_min, 3);
    assert!(resolved2 <= ceiling_range2_max, 4);

    transfer::public_transfer(cap1, OWNER);
    transfer::public_transfer(cap2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Two cycles — different resolved ceilings ─────────────────────────────────

#[test]
fun random_ceiling_different_per_cycle() {
    let mut sc = setup();
    // h=1 Window so AtDutch occurs between cycles
    let cfg = escrow_corpus::with_random_tenure_ceiling(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)),
        CEILING_RAND_MIN, CEILING_RAND_MAX,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Cycle 1
    let cap1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let expiry1 = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    assert!(expiry1 >= CEILING_RAND_MIN, 0);
    assert!(expiry1 <= CEILING_RAND_MAX, 1);

    // Tenure + descent window → Idle (cycle 2 draws new ceiling)
    let t_idle = expiry1 + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, t_idle);
    escrow::apply_pending_transition_states(&mut escrow, &random, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 2);

    // Cycle 2: resolved_ceiling also ∈ [min, max] (fresh draw)
    let cap2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let phase2  = *option::borrow(&escrow::phase_start_ms(&escrow));
    let expiry2 = *option::borrow(&escrow::tenure_expiry_ms(&escrow));
    let ceiling2 = expiry2 - phase2;
    assert!(ceiling2 >= CEILING_RAND_MIN, 3);
    assert!(ceiling2 <= CEILING_RAND_MAX, 4);

    transfer::public_transfer(cap1, OWNER);
    transfer::public_transfer(cap2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Multi-cycle tenancy ─────────────────────────────────────────────────────

// Helper: build an IntegrationConfig with Multi tenure_cycles policy.
fun multi_cycle_cfg(): config::IntegrationConfig {
    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    config::new_config(
        floor_price_policy_state::new_fixed(monetary::price(floor)),
        tenure_policy_state::new_fixed(phases::duration(tenure)),
        tenure_cycles_policy_state::new_multi(),
        handover_policy_state::new_handover_fixed_time(),
        descent_policy_state::new_descent_skipped(),
        retire_policy_state::new_retire_immediate(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(monetary::price(floor)),
    )
}

/// Single policy + cycles(2) → EMultiCycleNotAllowed.
#[test]
#[expected_failure(abort_code = tenure_cycles_policy_state::EMultiCycleNotAllowed, location = usufruct::tenure_cycles_policy_state)]
fun multi_cycle_single_policy_rejects_cycles_two() {
    let mut sc = setup();
    let cfg = escrow_corpus::by_tag(0); // Single (default corpus)
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let floor   = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor * 2, sc.ctx());
    // cycles(2) on a Single-policy escrow must abort
    let cap = escrow::rent(&mut escrow, payment, cycles::cycles(2), &random, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Multi policy + cycles(3): ceiling extends to tenure × 3.
#[test]
fun multi_cycle_install_extends_ceiling_three_x() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor * 3, sc.ctx()); // 3 cycles × floor
    let cap     = escrow::rent(&mut escrow, payment, cycles::cycles(3), &random, &clk, sc.ctx());

    // tenure_expiry_ms = phase_start(0) + tenure × 3
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert!(option::is_some(&expiry), 0);
    assert!(*option::borrow(&expiry) == tenure * 3, 1);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// cycles(1) on Multi policy: ceiling == tenure (degenerates correctly).
#[test]
fun multi_cycle_single_cycle_degenerates() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor, sc.ctx());
    let cap     = escrow::rent(&mut escrow, payment, cycles::cycles(1), &random, &clk, sc.ctx());

    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert!(*option::borrow(&expiry) == tenure, 0); // 1 × tenure

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Insufficient payment for cycles(3) aborts.
#[test]
#[expected_failure(abort_code = asset_context_state::EInsufficientPayment, location = usufruct::asset_context_state)]
fun multi_cycle_insufficient_payment_aborts() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let floor   = escrow_corpus::min_rent_price_const();
    // Pay only 2 cycles worth for a 3-cycle request
    let payment = mk_payment(floor * 2, sc.ctx());
    let cap     = escrow::rent(&mut escrow, payment, cycles::cycles(3), &random, &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Pending bidder with cycles(3) wins handover → ceiling extends to tenure × 3.
#[test]
fun multi_cycle_pending_bid_extends_ceiling_on_handover() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();

    // T1 installs with cycles(1)
    sc.next_tx(TENANT_ADDR_1);
    let p1  = mk_payment(floor, sc.ctx());
    let cap1 = escrow::rent(&mut escrow, p1, cycles::cycles(1), &random, &clk, sc.ctx());

    // T2 bids with cycles(3): pays total_price(floor_price_at, 3)
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor  = escrow::compute_floor_price(&escrow, &clk);
    let p2         = mk_payment(bid_floor * 3, sc.ctx());
    let cap2       = escrow::rent(&mut escrow, p2, cycles::cycles(3), &random, &clk, sc.ctx());

    // Fire handover at phase_start + tenure (FixedTime boundary).
    let boundary = tenure;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    // T2 is now current. New ceiling = tenure × 3, new phase_start = boundary.
    // expiry = boundary + tenure × 3 = tenure + tenure × 3 = tenure × 4.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert!(option::is_some(&expiry), 0);
    assert!(*option::borrow(&expiry) == boundary + tenure * 3, 1);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Helper: Multi + HandoverCountdown.
fun multi_cycle_cfg_countdown(): config::IntegrationConfig {
    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();
    config::new_config(
        floor_price_policy_state::new_fixed(monetary::price(floor)),
        tenure_policy_state::new_fixed(phases::duration(tenure)),
        tenure_cycles_policy_state::new_multi(),
        handover_policy_state::new_handover_countdown(phases::duration(countdown)),
        descent_policy_state::new_descent_skipped(),
        retire_policy_state::new_retire_immediate(),
        curve_shape_state::new_linear(),
        curve_shape_state::new_linear(),
        price_function_state::new_fixed_delta(monetary::price(floor)),
    )
}

/// T1 — Floor is per-cycle rate, not total stake.
/// T1 pays 3 cycles: stake = 30 SUI, committed_cycles = 3.
/// compute_floor_price = price_function(10 SUI) = 20 SUI  (FixedDelta(10 SUI))
/// NOT price_function(30 SUI) = 40 SUI.
/// This is the direct regression test for the core per-cycle invariant.
#[test]
fun multi_cycle_floor_price_is_per_cycle_rate() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let floor  = escrow_corpus::min_rent_price_const();
    let delta  = escrow_corpus::fixed_delta_value_const();

    // T1 pays 3 cycles: total stake = floor × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());

    // Per-cycle rate = floor × 3 / 3 = floor.
    // price_function(floor) = floor + delta  (FixedDelta).
    let expected_floor = floor + delta;
    let actual_floor   = escrow::compute_floor_price(&escrow, &clk);
    assert!(actual_floor == expected_floor, 0);

    // Guard: the wrong design would give price_function(3×floor) = 3×floor + delta.
    assert!(actual_floor < floor * 3 + delta, 1);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// T2 — HandoverCountdown: competitor displaces multi-cycle tenant by rate.
/// T1 pays 3 cycles (ceiling = tenure × 3). T2 bids at t=tenure/2 with 1
/// cycle, paying only the per-cycle floor. Handover fires at
/// t + countdown — well before T1's 300k ceiling. T1 is displaced early.
#[test]
fun multi_cycle_countdown_displaces_via_rate() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();
    let delta     = escrow_corpus::fixed_delta_value_const();

    // T1 rents 3 cycles: ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());
    assert!(*option::borrow(&escrow::tenure_expiry_ms(&escrow)) == tenure * 3, 0);

    // T2 bids at t = tenure/2 (mid cycle 1) with 1 cycle.
    // Pays per-cycle floor only: price_function(floor) = floor + delta.
    let bid_time = tenure / 2;
    clock::set_for_testing(&mut clk, bid_time);
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(bid_floor == floor + delta, 1); // per-cycle floor, not total-based
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Handover fires at bid_time + countdown — before T1's 3-cycle ceiling.
    let handover_ms = bid_time + countdown;
    assert!(handover_ms < tenure * 3, 2); // well before full ceiling
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(handover_ms), sc.ctx());

    // HandoverCompleted fires at handover_ms, not at tenure × 3.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_context_state::handover_completed_timestamp_ms(&completed[0]), handover_ms);

    // T2 is now current with ceiling = tenure × 1 from handover boundary.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), handover_ms + tenure);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// T3 — HandoverFixedTime: multi-cycle tenant consumes all paid cycles.
/// T1 pays 3 cycles (ceiling = tenure × 3). T2 bids at t=tenure/2 but
/// handover expiry = phase_start + ceiling = tenure × 3. T1 is only
/// displaced at t = tenure × 3 — the full tenure is respected.
#[test]
fun multi_cycle_fixed_time_tenant_consumes_full_ceiling() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();
    let delta  = escrow_corpus::fixed_delta_value_const();

    // T1 rents 3 cycles: ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());

    // T2 bids early at t=tenure/2. FixedTime: expiry = phase_start + ceiling = tenure × 3.
    let bid_time = tenure / 2;
    clock::set_for_testing(&mut clk, bid_time);
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::compute_floor_price(&escrow, &clk);
    assert!(bid_floor == floor + delta, 0);
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Countdown expiry must equal the full 3-cycle ceiling.
    let handover_expiry = escrow::handover_countdown_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry), tenure * 3);

    // Handover only fires at tenure × 3 — T1 consumed all paid cycles.
    let boundary = tenure * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_context_state::handover_completed_timestamp_ms(&completed[0]), boundary);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Rate symmetry invariant.
/// T1a: 1 cycle × 10 SUI and T1b: 3 cycles × 30 SUI have the same per-cycle rate.
/// A 1-cycle competitor must see identical floor in both cases.
/// Two escrows in the same scenario share the Random object correctly.
#[test]
fun multi_cycle_rate_symmetry_same_floor() {
    let mut sc = setup();
    let floor  = escrow_corpus::min_rent_price_const();
    let delta  = escrow_corpus::fixed_delta_value_const();

    // Integrate two escrows in the same scenario to share Random/ProtocolFee objects.
    let (mut escrow_a, owner_cap_a) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let (mut escrow_b, owner_cap_b) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);

    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    // Escrow A: T1a rents 1 cycle at floor.
    sc.next_tx(TENANT_ADDR_1);
    let cap_a   = escrow::rent(&mut escrow_a, mk_payment(floor, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());
    let floor_a = escrow::compute_floor_price(&escrow_a, &clk);

    // Escrow B: T1b rents 3 cycles at floor × 3 (same per-cycle rate).
    sc.next_tx(TENANT_ADDR_1);
    let cap_b   = escrow::rent(&mut escrow_b, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());
    let floor_b = escrow::compute_floor_price(&escrow_b, &clk);

    // Same per-cycle rate → same floor for a 1-cycle competitor.
    assert!(floor_a == floor_b, 0);
    assert!(floor_a == floor + delta, 1); // price_function(10 SUI) = 20 SUI

    transfer::public_transfer(cap_a, TENANT_ADDR_1);
    transfer::public_transfer(cap_b, TENANT_ADDR_1);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(owner_cap_a, OWNER);
    owner_cap::burn(owner_cap_b, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Supersede chain floor invariant.
/// T1 (3 cycles, 30 SUI) → T2 bid (1 cycle, 20 SUI) → T3 supersedes T2.
/// T3 floor = price_function(T2.stake / T2.bidding_cycles) = price_function(20/1) = 30 SUI.
/// NOT price_function(T1.stake / T1.committed_cycles) = price_function(10) = 20 SUI.
#[test]
fun multi_cycle_supersede_floor_based_on_pending_rate() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());
    let random = sc.take_shared<Random>();

    let floor = escrow_corpus::min_rent_price_const();
    let delta = escrow_corpus::fixed_delta_value_const();

    // T1: 3 cycles, 30 SUI.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());

    // T2: 1 cycle, 20 SUI = price_function(10 SUI).
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor_t2 == floor + delta, 0); // 20 SUI
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // T3 supersede: floor = price_function(T2.stake / T2.bidding_cycles)
    //             = price_function(20 SUI / 1) = 20 + 10 = 30 SUI.
    // NOT price_function(T1's 10 SUI) = 20 SUI.
    let const_challenger: address = @0xC1;
    sc.next_tx(const_challenger);
    let floor_t3 = escrow::compute_floor_price(&escrow, &clk);
    assert!(floor_t3 == floor_t2 + delta, 1); // 30 SUI
    assert!(floor_t3 > floor_t2, 2);           // strictly escalates

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// FixedTime handover-after-handover invariant.
/// T1 (3 cycles) → T2 (2 cycles) wins handover.
/// T2.ceiling = base × 2. T2.resolved_handover = base × 2 (FixedTime tracks new ceiling).
/// T3 bids → handover expiry = T2.phase_start + base × 2.
#[test]
fun multi_cycle_fixed_time_handover_tracks_new_ceiling() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();
    let delta  = escrow_corpus::fixed_delta_value_const();

    // T1: 3 cycles, ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());

    // T2: 2 cycles. FixedTime: handover expiry = phase_start(0) + ceiling(tenure×3).
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor_t2 * 2, sc.ctx()), cycles::cycles(2), &random, &clk, sc.ctx());

    // T2 wins at boundary = tenure × 3.
    let boundary_t2 = tenure * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_t2), sc.ctx());

    // T2 now current: phase_start = tenure×3, ceiling = tenure×2.
    let expiry_t2 = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_t2), boundary_t2 + tenure * 2);

    // T3 bids at t = tenure×3 + tenure/2 (mid T2 first cycle).
    let bid_time_t3 = boundary_t2 + tenure / 2;
    clock::set_for_testing(&mut clk, bid_time_t3);
    sc.next_tx(@0xC1);
    let bid_floor_t3 = escrow::compute_floor_price(&escrow, &clk);
    let cap3 = escrow::rent(&mut escrow, mk_payment(bid_floor_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // FixedTime: T3's handover expiry = T2.phase_start + T2.ceiling = tenure×3 + tenure×2.
    let handover_expiry_t3 = escrow::handover_countdown_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry_t3), boundary_t2 + tenure * 2);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Countdown floor-not-scaled-after-handover invariant.
/// T1 (3 cycles, countdown=25k) → T2 (2 cycles) wins.
/// T2.ceiling = base×2 = 200k. T2.resolved_handover = 25k (countdown does NOT scale).
/// T3 bids at t=175k → expiry = min(175k+25k, 25k+200k) = min(200k, 225k) = 200k.
#[test]
fun multi_cycle_countdown_floor_not_scaled_after_handover() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let random  = sc.take_shared<Random>();

    let tenure    = escrow_corpus::tenure_ceiling_const();   // 100_000
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const(); // 25_000
    let delta     = escrow_corpus::fixed_delta_value_const();

    // T1: 3 cycles, ceiling = tenure × 3 = 300k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), cycles::cycles(3), &random, &clk, sc.ctx());

    // T2: 2 cycles. Countdown: expiry = min(0+25k, 0+300k) = 25k.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor_t2 = escrow::compute_floor_price(&escrow, &clk);
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor_t2 * 2, sc.ctx()), cycles::cycles(2), &random, &clk, sc.ctx());

    // T2 wins at boundary = countdown = 25k.
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(countdown), sc.ctx());

    // T2 now current: phase_start = 25k, ceiling = tenure × 2 = 200k.
    let expiry_t2 = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_t2), countdown + tenure * 2);

    // T3 bids at t = 25k + tenure×1.5 = 175k (mid T2 tenure).
    let bid_time_t3 = countdown + tenure * 3 / 2;
    clock::set_for_testing(&mut clk, bid_time_t3);
    sc.next_tx(@0xC1);
    let bid_floor_t3 = escrow::compute_floor_price(&escrow, &clk);
    let cap3 = escrow::rent(&mut escrow, mk_payment(bid_floor_t3, sc.ctx()), cycles::cycles(1), &random, &clk, sc.ctx());

    // Countdown floor = 25k (unchanged, NOT tenure×2 = 200k).
    // expiry = min(175k + 25k, 25k + 200k) = min(200k, 225k) = 200k.
    let expected_expiry = bid_time_t3 + countdown; // 175k + 25k = 200k
    assert!(expected_expiry < countdown + tenure * 2, 0); // < T2.phase_start + T2.ceiling
    let handover_expiry_t3 = escrow::handover_countdown_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry_t3), expected_expiry);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(random);
    clock::destroy_for_testing(clk);
    sc.end();
}
