// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::e2e_scenarios_tests;

// New e2e scenario tests targeting behavioral gaps not covered by the
// unit-level tests in escrow_coordinator_tests.move. All tests exercise
// only the public API of escrow_coordinator; no internal shims used.

use std::unit_test::assert_eq;
use sui::{
    clock,
    coin::{Self, Coin},
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    escrow_coordinator::{
        Self,
        EscrowCoordinator,
        RentStarted,
        HandoverCompleted,
        TenureExpired,
        AuctionExpired,
        BidPlaced,
        BidSuperseded,
        AssetClaimed,
    },
    escrow_corpus,
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox::{Self, ProtocolFeeRef},
};

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const OWNER: address = @0xE2;

public struct E2eAsset has key, store { id: UID }

fun mk_asset(ctx: &mut TxContext): E2eAsset {
    E2eAsset { id: object::new(ctx) }
}

fun mk_payment(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::from_balance(sui::balance::create_for_testing<SUI>(amount), ctx)
}

fun setup(): Scenario {
    let mut sc = test_scenario::begin(OWNER);
    { protocol_fee_inbox::init_for_testing(sc.ctx()); };
    sc
}

fun integrate_and_take(
    cfg: usufruct::config::IntegrationConfig,
    sc:  &mut Scenario,
): (EscrowCoordinator<E2eAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_asset(sc.ctx());
    let cap = escrow_coordinator::integrate<E2eAsset, SUI>(
        asset, cfg, &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<EscrowCoordinator<E2eAsset, SUI>>(escrow_id);
    (escrow, cap)
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

    // T1: rent from Idle at min_rent_price → HandoverOpen.
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    // T2: bid on T1's tenure → HandoverConfirmed.
    let now_t2    = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2  = escrow_coordinator::compute_floor_price(&escrow, now_t2);
    assert!(price_t2 > price_t1, tag); // price escalated
    let cap_t2    = escrow_coordinator::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);

    // APT: Instant handover fires at bid_time_ms=1000 → HandoverOpen (T2 current).
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T3: bid on T2's tenure → HandoverConfirmed.
    let now_t3    = 2_000;
    clock::set_for_testing(&mut clk, now_t3);
    let price_t3  = escrow_coordinator::compute_floor_price(&escrow, now_t3);
    assert!(price_t3 > price_t2, tag); // price escalated again
    let cap_t3    = escrow_coordinator::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), &clk, sc.ctx());

    // APT: second Instant handover → HandoverOpen (T3 current).
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 2);

    // Advance past T3's tenure ceiling (phase_start_T3 = now_t3 = 2_000).
    let tenure_boundary = now_t3 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // h=0 Skipped: TenureExpired + AuctionExpired co-fire → Idle.
    assert!(escrow_coordinator::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Retire from Idle → Retired.
    escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow_coordinator::is_retired(&escrow), tag);

    // Claim: earnings must be positive — both T1 and T2 accumulated used_credit.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    assert!(coin::value(&earnings) > 0, tag);
    assert_eq!(event::events_by_type<AssetClaimed>().length(), 1);

    transfer::public_transfer(asset, OWNER);
    coin::burn_for_testing(earnings);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
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

    // T1: rent from Idle → HandoverOpen at min_rent_price.
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());

    // T2: bid on T1's tenure (HO → HC). floor_price > min_rent_price.
    let now_t2   = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2 = escrow_coordinator::compute_floor_price(&escrow, now_t2);
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), &clk, sc.ctx());

    // APT: Instant handover → HandoverOpen (T2 current, phase_start = now_t2).
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    // APT past T2's tenure ceiling → AtDutchAuction.
    // last_acquisition_price = price_t2 > min_rent_price → non-zero spread.
    let tenure_boundary = now_t2 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // T3 at mid-descent: price is between price_t2 and min_rent_price.
    let now_mid  = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let price_t3 = escrow_coordinator::compute_floor_price(&escrow, now_mid);
    assert!(price_t3 < price_t2, tag);                               // price descended
    assert!(price_t3 >= escrow_corpus::min_rent_price_const(), tag); // never below min

    // T3 rents at the descending price → HandoverOpen.
    let cap_t3 = escrow_coordinator::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §3. Deferred retire floor gate ───────────────────────────────────────────

/// With RetirePolicy::Deferred, retire() aborts if the clock has not
/// reached integrated_at_ms + retire_floor. integrated_at_ms = 0
/// (clock at integration time), retire_floor = 10_000_000.
///
/// Config: c=0, d=0, e=0, h=0, f=1 (Deferred).
#[test]
#[expected_failure(
    abort_code = escrow_coordinator::ERetireFloorNotElapsed,
    location   = usufruct::escrow_coordinator,
)]
fun e2e_deferred_retire_aborts_before_floor() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 Deferred
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    // Clock at 0; retire_floor = 10_000_000 — gate is closed.
    let clk = clock::create_for_testing(sc.ctx());
    escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // Advance past retire_floor (integrated_at_ms=0, floor=10_000_000).
    let past_floor = escrow_corpus::retire_deferred_f1_const() + 1;
    clock::set_for_testing(&mut clk, past_floor);

    escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow_coordinator::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::destroy_zero(earnings); // no tenants → no earnings
    transfer::public_transfer(asset, OWNER);
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

    // T1: rent from Idle → HandoverOpen.
    let cap_t1   = escrow_coordinator::rent(
        &mut escrow,
        mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()),
        &clk,
        sc.ctx(),
    );

    // T2: bid → HandoverConfirmed (countdown starts at now_t2=1_000).
    let now_t2   = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let floor_t2 = escrow_coordinator::compute_floor_price(&escrow, now_t2);
    let cap_t2   = escrow_coordinator::rent(
        &mut escrow,
        mk_payment(floor_t2, sc.ctx()),
        &clk,
        sc.ctx(),
    );
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidPlaced>().length(), 1);

    // T3: supersedes T2 before countdown expires (now_t3=2_000 < 1_000+25_000).
    let now_t3   = 2_000;
    clock::set_for_testing(&mut clk, now_t3);
    let floor_t3 = escrow_coordinator::compute_floor_price(&escrow, now_t3);
    let cap_t3   = escrow_coordinator::rent(
        &mut escrow,
        mk_payment(floor_t3, sc.ctx()),
        &clk,
        sc.ctx(),
    );
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // APT past T3's countdown expiry → HandoverOpen (T3 is current, not T2).
    let t3_countdown_expiry = now_t3 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, t3_countdown_expiry);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T2's cap is stale — burn it.
    escrow_coordinator::burn_tenant_cap(&mut escrow, cap_t2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

        let min_price = escrow_corpus::min_rent_price_const();

        // T1 rents at min_rent_price — no successor.
        let cap_t1 = escrow_coordinator::rent(
            &mut escrow,
            mk_payment(min_price, sc.ctx()),
            &clk,
            sc.ctx(),
        );

        // APT past tenure ceiling → AtDutchAuction.
        // last_acquisition_price = min_rent_price → zero spread.
        let tenure_boundary = escrow_corpus::tenure_ceiling_const();
        clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
        assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);

        // floor at t=0 of descent window: must equal min_rent_price.
        let floor_at_start = escrow_coordinator::compute_floor_price(&escrow, tenure_boundary);
        assert_eq!(floor_at_start, min_price);

        // floor at mid-descent: must still equal min_rent_price.
        let now_mid = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
        let floor_at_mid = escrow_coordinator::compute_floor_price(&escrow, now_mid);
        assert_eq!(floor_at_mid, min_price);

        // floor at descent boundary: must equal min_rent_price.
        let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
        let floor_at_end = escrow_coordinator::compute_floor_price(&escrow, descent_boundary);
        assert_eq!(floor_at_end, min_price);

        // T2 can rent at min_rent_price → HandoverOpen.
        clock::set_for_testing(&mut clk, now_mid);
        let cap_t2 = escrow_coordinator::rent(
            &mut escrow,
            mk_payment(min_price, sc.ctx()),
            &clk,
            sc.ctx(),
        );
        assert!(escrow_coordinator::is_handover_open(&escrow), tag);

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
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
    let cap_t1 = escrow_coordinator::rent(&mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();

    // PTBs 2–5: Tn bids → APT Instant → Tn current → borrow+return.
    let mut ptb: u8 = 2;
    while (ptb <= 5) {
        let mut clk = clock::create_for_testing(sc.ctx());
        let t = (ptb as u64) * 1_000;
        clock::set_for_testing(&mut clk, t);
        let floor = escrow_coordinator::compute_floor_price(&escrow, t);
        let cap = escrow_coordinator::rent(&mut escrow, mk_payment(floor, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
        let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap, &clk, sc.ctx());
        escrow_coordinator::return_asset(&mut escrow, asset, receipt);
        assert!(escrow_coordinator::is_handover_open(&escrow), tag);
        clock::destroy_for_testing(clk);
        transfer::public_transfer(cap, OWNER);
        if (ptb < 5) {
            test_scenario::return_shared(escrow);
            sc.next_tx(OWNER);
            escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
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
fun e2e_b1_instant_borrow_across_curve_shapes() {
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

        // T1 rents from Idle — immediately current — borrows in same PTB.
        let cap_t1 = escrow_coordinator::rent(&mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());
        let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
        escrow_coordinator::return_asset(&mut escrow, asset, receipt);
        assert!(escrow_coordinator::is_handover_open(&escrow), tag);

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
#[expected_failure(abort_code = escrow_coordinator::EStaleTenantCap, location = usufruct::escrow_coordinator)]
fun e2e_b3_stale_tenant_cap_borrow_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // T2 bids → APT Instant → T1 stale.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());

    // T1's cap is now stale — borrow must abort.
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // T1 rents, tenure expires → AtDutchAuction.
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());
    // T2 places a bid and APT fires handover so last_acq_price > min to get a spread.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_b4  = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2_temp = escrow_coordinator::rent(&mut escrow, mk_payment(floor_b4, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // Now T2 holds tenure; advance past T2's tenure ceiling.
    let tenure_boundary = 1_000 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);

    // T3 rents from AtDutchAuction at mid-descent price — immediately current.
    let now_mid  = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let price_t3 = escrow_coordinator::compute_floor_price(&escrow, now_mid);
    let cap_t3   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    // T3 borrows in the same PTB — no APT needed (do_install_new_tenant makes T3 current directly).
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t3, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2_temp, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // Cycle 1
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);
    // Cycle 2
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);
    // Cycle 3
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);

    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());

    let price_t2 = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());

    let price_t3 = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert!(price_t3 > price_t2, tag);

    // Compound growth: each increment is larger than the previous.
    let gap_2_1 = price_t2 - price_t1;
    let gap_3_2 = price_t3 - price_t2;
    assert!(gap_3_2 > gap_2_1, tag);

    let cap_t3 = escrow_coordinator::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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
    let delta   = escrow_corpus::fixed_delta_value_const();

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());

    let price_t2 = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert_eq!(price_t2 - price_t1, delta);
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());

    let price_t3 = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert_eq!(price_t3 - price_t2, delta); // constant gap

    let cap_t3 = escrow_coordinator::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // T1 rents at t=0.
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow_handle, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // T2 bids at t=tenure_ceiling/2 → APT Instant fires handover.
    // T1 held for half the tenure: used_credit > 0 → owner accumulates earnings.
    let t_mid    = escrow_corpus::tenure_ceiling_const() / 2;
    clock::set_for_testing(&mut clk, t_mid);
    let floor_e1 = escrow_coordinator::compute_floor_price(&escrow_handle, t_mid);
    let cap_t2   = escrow_coordinator::rent(&mut escrow_handle, mk_payment(floor_e1, sc.ctx()), &clk, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow_handle), tag);

    // First withdrawal — T1's used_credit share.
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let mut escrow_handle = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    let earnings_1 = escrow_coordinator::withdraw_earnings(&mut escrow_handle, &owner_cap, &clk, sc.ctx());
    assert!(coin::value(&earnings_1) > 0, tag);
    coin::burn_for_testing(earnings_1);

    // T2's tenure expires → Idle (Skipped). T2's full credit → owner earnings.
    let tenure_boundary = t_mid + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow_coordinator::is_idle(&escrow_handle), tag);

    // Second withdrawal — T2's earnings (fresh, first was drained to zero).
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let mut escrow_handle = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    let earnings_2 = escrow_coordinator::withdraw_earnings(&mut escrow_handle, &owner_cap, &clk, sc.ctx());
    assert!(coin::value(&earnings_2) > 0, tag);
    coin::burn_for_testing(earnings_2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow_handle);
    owner_cap::burn(owner_cap, OWNER);
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

    // T1 rents (Idle → HandoverOpen).
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // T2 places a bid (HandoverOpen → HandoverConfirmed).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_r1 = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(floor_r1, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);

    // Owner sets retiring flag while in HandoverConfirmed.
    escrow_coordinator::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    // State stays HandoverConfirmed — retire only lifts the flag here.
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);

    // APT past T2's countdown expiry → APT honors the bid: T2 gets HandoverOpen.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // APT past T2's tenure ceiling → collapses to Retired (not AtDutch).
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_retired(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // Claim the asset.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    let (asset, earnings) = escrow_coordinator::claim_asset(escrow, owner_cap, &clk, sc.ctx());

    transfer::public_transfer(asset, OWNER);
    coin::burn_for_testing(earnings);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §A1. APT fires at exact tenure boundary (>= inclusivity) ────────────────

/// apply_pending_transitions with clock == tenure_boundary_ms fires the
/// tenure expiry transition. Verifies the >= guard in phases::has_passed.
#[test]
fun e2e_a1_apt_fires_at_exact_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // h=0 Skipped → Idle
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // Exact boundary: clock == phase_start(0) + tenure_ceiling.
    let boundary = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, boundary);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // h=0 Skipped: tenure → AtDutch → Idle in one APT step.
    assert!(escrow_coordinator::is_idle(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §A2. APT does not fire one ms before tenure boundary ────────────────────

/// apply_pending_transitions with clock == tenure_boundary_ms - 1 does not
/// fire — state stays HandoverOpen. Verifies the >= guard is not >.
#[test]
fun e2e_a2_apt_noop_one_ms_before_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let cfg     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(cfg, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // One ms before the boundary — nothing should fire.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() - 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // T1 rents (Idle → HandoverOpen, phase_start = 0).
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // T2 bids at t=1000 → HandoverConfirmed.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_f2a = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2    = escrow_coordinator::rent(&mut escrow, mk_payment(floor_f2a, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);
    assert_eq!(event::events_by_type<BidPlaced>().length(), 1);

    // T3 supersedes T2 at t=2000 (before tenure_ceiling=100_000).
    clock::set_for_testing(&mut clk, 2_000);
    let floor_f2b = escrow_coordinator::compute_floor_price(&escrow, 2_000);
    let cap_t3    = escrow_coordinator::rent(&mut escrow, mk_payment(floor_f2b, sc.ctx()), &clk, sc.ctx());
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // APT at tenure_ceiling (= FixedTime handover expiry = phase_start + tenure_ceiling = 100_000).
    // Handover fires → T3 wins → HandoverOpen (T3 current, new phase_start=100_000).
    // T3's tenure ceiling = 100_000 + 100_000 = 200_000 > 100_000 → no tenure expiry yet.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T2's cap is stale — T3 won, T2 was superseded.
    escrow_coordinator::burn_tenant_cap(&mut escrow, cap_t2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();

    // PTB 2: T2 bids at t=1_000 → HandoverConfirmed (T2 pending).
    // APT at same clock — countdown not elapsed (1_000 < 1_000 + 25_000) → no-op.
    let mut clk = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2  = escrow_coordinator::rent(&mut escrow, mk_payment(floor2, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // Countdown has not elapsed — T2 is still pending, state unchanged.
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();

    // PTB 3: clock advances past countdown expiry → APT fires handover → T2 current.
    // T2 borrows in the same PTB — the temporal unlock has occurred.
    let mut clk = clock::create_for_testing(sc.ctx());
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    let (asset, receipt) = escrow_coordinator::borrow_asset(&mut escrow, &cap_t2, &clk, sc.ctx());
    escrow_coordinator::return_asset(&mut escrow, asset, receipt);
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
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 (OWNER) rents from Idle → HandoverOpen (current at min_price).
    let cap_t1_current = escrow_coordinator::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());

    // OWNER bids on own tenure at t=1_000 → HandoverConfirmed (current + pending).
    clock::set_for_testing(&mut clk, 1_000);
    let price_2     = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t1_bid1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(price_2, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);

    // OWNER supersedes own pending bid at t=2_000 (before 1_000+25_000 countdown).
    clock::set_for_testing(&mut clk, 2_000);
    let price_3     = escrow_coordinator::compute_floor_price(&escrow, 2_000);
    assert!(price_3 > price_2, tag);
    let cap_t1_bid2 = escrow_coordinator::rent(
        &mut escrow, mk_payment(price_3, sc.ctx()), &clk, sc.ctx());
    let sup = event::events_by_type<BidSuperseded>();
    assert_eq!(sup.length(), 1);
    let se = sup.borrow(0);
    // Core: same address displaced and re-entered.
    assert_eq!(escrow_coordinator::bid_superseded_displaced_bidder(se),
               escrow_coordinator::bid_superseded_new_bidder(se));
    assert_eq!(escrow_coordinator::bid_superseded_refunded_amount(se), price_2);
    assert_eq!(escrow_coordinator::bid_superseded_new_bid_amount(se), price_3);

    // APT past countdown (1_000+25_000=26_000) → cap_t1_bid2 current.
    // cap_t1_current (original stake, held ~26s) is displaced: remain_credit > 0.
    clock::set_for_testing(&mut clk, 1_000 + escrow_corpus::handover_countdown_c1_const());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    let he = hc.borrow(0);
    assert_eq!(escrow_coordinator::handover_completed_displaced_tenant(he), OWNER);
    // new_rent_price is the next floor (price_3 + delta), not the stake itself.
    assert_eq!(escrow_coordinator::handover_completed_new_rent_price(he),
               price_3 + escrow_corpus::fixed_delta_value_const());
    assert!(escrow_coordinator::handover_completed_remain_credit(he) > 0, tag);

    transfer::public_transfer(cap_t1_current, OWNER);
    transfer::public_transfer(cap_t1_bid1, OWNER);
    transfer::public_transfer(cap_t1_bid2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Current tenant defends against challenger ───────────────────────────────

const CHALLENGER: address = @0xC1;

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
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 (OWNER) rents from Idle → HandoverOpen.
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());

    // T2 (CHALLENGER) bids at t=1_000 → HandoverConfirmed.
    clock::set_for_testing(&mut clk, 1_000);
    test_scenario::return_shared(escrow);
    sc.next_tx(CHALLENGER);
    let mut escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    let floor_2 = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2  = escrow_coordinator::rent(&mut escrow, mk_payment(floor_2, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);
    test_scenario::return_shared(escrow);

    // T1 (OWNER) supersedes CHALLENGER at t=2_000 (before 1_000+25_000 countdown).
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<EscrowCoordinator<E2eAsset, SUI>>();
    clock::set_for_testing(&mut clk, 2_000);
    let floor_3    = escrow_coordinator::compute_floor_price(&escrow, 2_000);
    let cap_t1_new = escrow_coordinator::rent(&mut escrow, mk_payment(floor_3, sc.ctx()), &clk, sc.ctx());
    let sup = event::events_by_type<BidSuperseded>();
    assert_eq!(sup.length(), 1);
    let se = sup.borrow(0);
    assert_eq!(escrow_coordinator::bid_superseded_displaced_bidder(se), CHALLENGER);
    assert_eq!(escrow_coordinator::bid_superseded_new_bidder(se), OWNER);
    assert_eq!(escrow_coordinator::bid_superseded_refunded_amount(se), floor_2);

    // APT past T1_new's countdown → T1 defends tenure at floor_3.
    clock::set_for_testing(&mut clk, 2_000 + escrow_corpus::handover_countdown_c1_const());
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    // new_rent_price = next floor after handover = floor_3 + delta.
    assert_eq!(escrow_coordinator::handover_completed_new_rent_price(hc.borrow(0)),
               floor_3 + escrow_corpus::fixed_delta_value_const());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t1_new, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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
    let min_price = escrow_corpus::min_rent_price_const();
    let delta     = escrow_corpus::fixed_delta_value_const();
    let countdown = escrow_corpus::handover_countdown_c1_const(); // 25_000

    // Idle: pay 2×min_price. Floor after = 2×min + delta (not min + delta).
    let price_t1 = 2 * min_price;
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());
    let rs       = event::events_by_type<RentStarted>();
    assert_eq!(escrow_coordinator::rent_started_price_paid(rs.borrow(0)), price_t1);
    assert!(price_t1 >= escrow_coordinator::rent_started_floor_price(rs.borrow(0)), tag);
    assert_eq!(escrow_coordinator::compute_floor_price(&escrow, 0), price_t1 + delta);

    // HandoverOpen: bid at 2×floor_ho at t=1_000. Floor after reflects full bid.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_ho = price_t1 + delta;
    let price_t2 = 2 * floor_ho;
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), &clk, sc.ctx());
    let bp       = event::events_by_type<BidPlaced>();
    assert_eq!(escrow_coordinator::bid_placed_bid_amount(bp.borrow(0)), price_t2);
    assert!(price_t2 >= escrow_coordinator::bid_placed_floor_price(bp.borrow(0)), tag);
    assert_eq!(escrow_coordinator::compute_floor_price(&escrow, 1_000), price_t2 + delta);

    // HandoverConfirmed (supersede at t=2_000, before 1_000+25_000 countdown): pay 2×floor_hc.
    clock::set_for_testing(&mut clk, 2_000);
    let floor_hc = price_t2 + delta;
    let price_t3 = 2 * floor_hc;
    let cap_t3   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), &clk, sc.ctx());
    let bs       = event::events_by_type<BidSuperseded>();
    assert_eq!(escrow_coordinator::bid_superseded_new_bid_amount(bs.borrow(0)), price_t3);
    assert!(price_t3 > floor_hc, tag);

    // APT past T3's countdown (1_000+25_000=26_000) → T3 current.
    // T3 phase_start = min(2_000+25_000, 0+100_000) = 27_000.
    // T3 tenure expires at 27_000+100_000 = 127_000.
    let t3_expiry = 1_000 + countdown; // = 26_000 (T2's countdown, T3 superseded it)
    clock::set_for_testing(&mut clk, t3_expiry);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());

    // AtDutchAuction: T3's phase_start = t3_expiry=26_000 (handover boundary for Countdown).
    // Actually: expiry_at(bid_time=2_000, phase_start=0, tenure_ceiling=100_000)
    //   = min(2_000+25_000, 0+100_000) = 27_000.
    let t3_phase_start = 27_000u64;
    let tenure_boundary = t3_phase_start + escrow_corpus::tenure_ceiling_const(); // 127_000
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);

    // Pay 2× mid-descent price. RentStarted events: [Idle, AtDutch].
    let now_mid       = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let descent_price = escrow_coordinator::compute_floor_price(&escrow, now_mid);
    let price_t4      = 2 * descent_price;
    let cap_t4        = escrow_coordinator::rent(&mut escrow, mk_payment(price_t4, sc.ctx()), &clk, sc.ctx());
    let rs_all        = event::events_by_type<RentStarted>();
    assert_eq!(rs_all.length(), 2); // Idle + AtDutch
    assert_eq!(escrow_coordinator::rent_started_price_paid(rs_all.borrow(1)), price_t4);
    assert!(price_t4 >= escrow_coordinator::rent_started_floor_price(rs_all.borrow(1)), tag);
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    transfer::public_transfer(cap_t4, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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
    let min_price = escrow_corpus::min_rent_price_const();
    let delta     = escrow_corpus::fixed_delta_value_const();

    // T1 rents from Idle at min_price (10 SUI).
    let cap_t1   = escrow_coordinator::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());
    let floor_ho = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert_eq!(floor_ho, min_price + delta); // = 20 SUI

    // T2 bids at exactly floor_HO (minimal bid) → HandoverConfirmed.
    // T2_stake = floor_HO = min_price + delta = 20 SUI.
    let cap_t2   = escrow_coordinator::rent(
        &mut escrow, mk_payment(floor_ho, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);

    // floor_HC must use T2's pending stake (20 SUI), not T1's current stake (10 SUI).
    let floor_hc = escrow_coordinator::compute_floor_price(&escrow, 0);
    assert_eq!(floor_hc, floor_ho + delta);  // correct:  20 + 10 = 30 SUI
    // assert_eq!(floor_hc, min_price + delta); // WRONG: 10 + 10 = 20 SUI (= floor_HO, no escalation)

    // Confirm the escalation: HC floor strictly exceeds HO floor.
    assert!(floor_hc > floor_ho, tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // T1 rents at min_price (this is the principal we will conserve).
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());

    // T2 bids at mid-tenure so used_credit > 0.
    let t_mid    = escrow_corpus::tenure_ceiling_const() / 2; // 50_000 ms
    clock::set_for_testing(&mut clk, t_mid);
    let floor_t2 = escrow_coordinator::compute_floor_price(&escrow, t_mid);
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), &clk, sc.ctx());

    // Instant handover fires at bid_time = t_mid.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    let hc_events = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc_events.length(), 1);
    let he = hc_events.borrow(0);
    let used_credit   = escrow_coordinator::handover_completed_used_credit(he);
    let owner_share   = escrow_coordinator::handover_completed_owner_share(he);
    let protocol_fee  = escrow_coordinator::handover_completed_protocol_fee(he);
    let remain_credit = escrow_coordinator::handover_completed_remain_credit(he);

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

    // T1 rents at min_price from Idle → HandoverOpen (T1's stake = min_price).
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());

    // T2 bids at t=1_000 → price_t2 = min_price + delta (FixedDelta) > price_t1.
    let now_t2   = 1_000u64;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2 = escrow_coordinator::compute_floor_price(&escrow, now_t2);
    assert!(price_t2 > price_t1, tag); // stakes differ — non-trivial test
    let cap_t2   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), &clk, sc.ctx());

    // Instant handover fires: T2 is now current, T2.phase_start = now_t2.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    // T2's tenure boundary = now_t2 + tenure_ceiling = 1_000 + 100_000 = 101_000.
    let t2_tenure_boundary = now_t2 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t2_tenure_boundary);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    // h=1 Window → TenureExpired fires but AtDutchAuction (not Idle).
    assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);

    let te_events = event::events_by_type<TenureExpired>();
    assert_eq!(te_events.length(), 1);
    let te                     = te_events.borrow(0);
    let owner_share            = escrow_coordinator::tenure_expired_owner_share(te);
    let protocol_fee           = escrow_coordinator::tenure_expired_protocol_fee(te);
    let last_acquisition_price = escrow_coordinator::tenure_expired_last_acq_price(te);

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
    let cap_a1    = escrow_coordinator::rent(
        &mut escrow_a, mk_payment(min_price, sc.ctx()), &clk_a, sc.ctx());
    clock::set_for_testing(&mut clk_a, escrow_corpus::tenure_ceiling_const());
    escrow_coordinator::apply_pending_transitions(&mut escrow_a, &clk_a, sc.ctx());
    {
        let te_events = event::events_by_type<TenureExpired>();
        let te       = te_events.borrow(0);
        let te_fee   = escrow_coordinator::tenure_expired_protocol_fee(te);
        let te_owner = escrow_coordinator::tenure_expired_owner_share(te);
        let te_lap   = escrow_coordinator::tenure_expired_last_acq_price(te);
        // Use min_price (the known T1 stake) as the independent oracle.
        assert_eq!(te_fee + te_owner, min_price);
        // Exact 10 % fee on 10 SUI (min_price = 10_000_000_000, divisible by 10).
        assert_eq!(te_fee,   1_000_000_000);
        assert_eq!(te_owner, 9_000_000_000);
        // last_acquisition_price == T1's stake here (no handover → founding ==
        // departing tenant), and marks the AtDutch descent starting point.
        assert_eq!(te_lap, min_price);
    };
    transfer::public_transfer(cap_a1, OWNER);
    test_scenario::return_shared(escrow_a);
    owner_cap::burn(owner_cap_a, OWNER);
    clock::destroy_for_testing(clk_a);

    // ── Part B: handover — split_fee consistency ──
    let cfg_b = escrow_corpus::by_tag(tag);
    let (mut escrow_b, owner_cap_b) = integrate_and_take(cfg_b, &mut sc);
    let mut clk_b = clock::create_for_testing(sc.ctx());
    let cap_b1    = escrow_coordinator::rent(
        &mut escrow_b, mk_payment(min_price, sc.ctx()), &clk_b, sc.ctx());
    let t_mid     = escrow_corpus::tenure_ceiling_const() / 2; // 50_000 ms
    clock::set_for_testing(&mut clk_b, t_mid);
    let floor_b   = escrow_coordinator::compute_floor_price(&escrow_b, t_mid);
    let cap_b2    = escrow_coordinator::rent(
        &mut escrow_b, mk_payment(floor_b, sc.ctx()), &clk_b, sc.ctx());
    escrow_coordinator::apply_pending_transitions(&mut escrow_b, &clk_b, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow_b), tag);
    {
        let hc_events = event::events_by_type<HandoverCompleted>();
        let he  = hc_events.borrow(0);
        let uc  = escrow_coordinator::handover_completed_used_credit(he);
        let ho  = escrow_coordinator::handover_completed_owner_share(he);
        let hf  = escrow_coordinator::handover_completed_protocol_fee(he);
        // Linear curve (e=0), phase_start=0, t_mid=50_000, tenure_ceiling=100_000:
        //   g = mul_div(50_000, SCALE, 100_000) = SCALE/2
        //   used_credit = mul_div(min_price, SCALE/2, SCALE) = min_price / 2
        // This is computed from the formula independently of the event.
        assert_eq!(uc, min_price / 2);                 // 5_000_000_000
        assert_eq!(hf, min_price / 20);                // 10 % of uc = 500_000_000
        assert_eq!(ho, min_price * 9 / 20);            // 90 % of uc = 4_500_000_000
    };
    transfer::public_transfer(cap_b1, OWNER);
    transfer::public_transfer(cap_b2, OWNER);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(owner_cap_b, OWNER);
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

        // T1 rents at 2×min_price (phase_start = 0). No handover needed for spread.
        let cap_t1 = escrow_coordinator::rent(
            &mut escrow, mk_payment(stake, sc.ctx()), &clk, sc.ctx());

        // APT past tenure boundary → AtDutchAuction (last_acq_price = stake).
        clock::set_for_testing(&mut clk, tenure_boundary + 1);
        escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
        assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);

        // DESC-1: elapsed_descent = 0 → evaluate_curve = 0 → no descent yet.
        let floor_start = escrow_coordinator::compute_floor_price(&escrow, tenure_boundary);
        assert_eq!(floor_start, stake);

        // DESC-2: elapsed_descent = descent_window = t_max → fully descended.
        let floor_end = escrow_coordinator::compute_floor_price(&escrow, descent_boundary);
        assert_eq!(floor_end, min_price);

        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
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
        let clk = clock::create_for_testing(sc.ctx()); // t = 0

        // T1 rents at min_price (stake = min_price, phase_start = 0).
        let cap_t1 = escrow_coordinator::rent(
            &mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());

        // DESC-3: at exact phase_start (elapsed = 0), no stake is earned yet.
        // compute_used_credit is a pure view — does not trigger APT.
        let uc_start = escrow_coordinator::compute_used_credit(&escrow, 0);
        assert_eq!(uc_start, 0);

        // DESC-4: at exact tenure_ceiling (elapsed >= t_max), full stake is earned.
        // evaluate_curve short-circuits to SCALE for elapsed >= t_max regardless
        // of curve shape: used_credit = mul_div(stake, SCALE, SCALE) = stake.
        let uc_end = escrow_coordinator::compute_used_credit(&escrow, ceiling);
        assert_eq!(uc_end, min_price);

        transfer::public_transfer(cap_t1, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
        clock::destroy_for_testing(clk);
        e = e + 1;
    };
    sc.end();
}

// ─── §Skipped descent — price resets to min_rent_price at tenure boundary ────

/// With DescentPolicy::Skipped (h=0), tenure expiry triggers the M6b cascade:
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
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 rents at 3×min_price. Elevated stake to make the reset contrast visible.
    let price_t1 = 3 * min_price;
    let cap_t1   = escrow_coordinator::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), &clk, sc.ctx());
    // floor_HO = T1_stake + delta = 3×min + delta — well above min_price.
    assert!(escrow_coordinator::compute_floor_price(&escrow, 0) > min_price, tag);

    // APT at the exact tenure boundary (phase_start=0, tenure_ceiling=100_000).
    // M6b: HandoverOpen → AtDutchAuction → Idle in one step (Skipped descent).
    let tenure_boundary = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Price reset: entry is min_rent_price regardless of T1's elevated stake.
    let floor_after = escrow_coordinator::compute_floor_price(&escrow, tenure_boundary);
    assert_eq!(floor_after, min_price);

    // T2 rents at min_rent_price — the protocol accepts the minimum entry.
    let cap_t2 = escrow_coordinator::rent(&mut escrow, mk_payment(min_price, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §APT-1. APT idempotency — double call at same clock is a no-op ──────────

/// apply_pending_transitions is permissionless and may be called many times.
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

    // T1 rents from Idle → HandoverOpen (phase_start = 0).
    let cap_t1 = escrow_coordinator::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), &clk, sc.ctx());

    // T2 bids at t=1_000 → HandoverConfirmed (countdown_expiry = 26_000).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow_coordinator::compute_floor_price(&escrow, 1_000);
    let cap_t2   = escrow_coordinator::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_confirmed(&escrow), tag);

    // ── Boundary 1: Handover ────────────────────────────────────────────────
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const(); // 26_000
    clock::set_for_testing(&mut clk, countdown_expiry);

    // First APT: handover fires → HandoverOpen, 1 HandoverCompleted event.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // Second APT at same clock: no-op — state and event count unchanged.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_handover_open(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // ── Boundary 2: Tenure expiry ───────────────────────────────────────────
    // T2.phase_start = countdown_expiry = 26_000; tenure_boundary = 126_000.
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const(); // 126_000
    clock::set_for_testing(&mut clk, tenure_boundary);

    // First APT: tenure fires → AtDutchAuction, 1 TenureExpired event.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // Second APT at same clock: no-op.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_at_dutch_auction(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // ── Boundary 3: Auction expiry ──────────────────────────────────────────
    // AtDutch.phase_start = tenure_boundary = 126_000; descent_boundary = 226_000.
    let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const(); // 226_000
    clock::set_for_testing(&mut clk, descent_boundary);

    // First APT: auction fires → Idle, 1 AuctionExpired event.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Second APT at same clock: no-op — Idle has no pending transitions.
    escrow_coordinator::apply_pending_transitions(&mut escrow, &clk, sc.ctx());
    assert!(escrow_coordinator::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}
}
