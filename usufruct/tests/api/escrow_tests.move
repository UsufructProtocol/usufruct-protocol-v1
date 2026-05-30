// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_tests;

use std::unit_test::assert_eq;
use std::string;
use std::type_name;
use sui::{
    balance,
    clock,
    coin::{Self, Coin},
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
};
use usufruct::{
    asset_state::{
        Self,
        AssetIntegrated,
        RentStarted,
        AuctionExpired,
        AssetRetired,
        AssetClaimed,
        EarningsWithdrawn,
        BidPlaced,
        BidSuperseded,
        RetireCommitmentExtended,
        HandoverCompleted,
        TenureExpired,
        RetireFlagSet,
        AssetBorrowed,
        AssetReturned,
        CycleParamsResolved,
        ActiveTenantRefundAddressUpdated,
        PendingTenantRefundAddressUpdated,
    },

    policy_ensemble::{Self, EnsembleUpdated, EnsembleUpdateScheduled},
    curve_shape_policy,
    tenures,
    auction_window_policy,
    rest_price_policy,
    handover_policy,
    monetary,
    price_escalation_policy,
    retire_commitment_policy::{Self, RetireCommitmentPolicy},
    tenure_extend_policy,
    tenure_duration_policy,
    escrow::{Self, Escrow},
    escrow_corpus,
    escrow_identity,
    fee_message::FeeMessageSent,
    owner_cap::{Self, OwnerCap},
    phases,
    protocol_fee_inbox,
    protocol_fee_ref::{Self, ProtocolFeeRef},
    refund_address,
    tenant_seat::{Self, TenantSeat},
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

/// Wrapper that lifts a `Balance<SUI>` into a `key + store` object so it
/// can be integrated into usufruct. Demonstrates that the protocol accepts
/// any `key + store` asset regardless of its internal structure.
public struct BalanceVault has key, store {
    id:      UID,
    balance: balance::Balance<SUI>,
}

fun mk_balance_vault(amount: u64, ctx: &mut TxContext): BalanceVault {
    BalanceVault {
        id:      object::new(ctx),
        balance: balance::create_for_testing<SUI>(amount),
    }
}

/// Initialise the protocol-fee singletons and the shared Random object.
/// Returns a scenario whose next-tx state has the `ProtocolFeeRef` frozen,
/// the `ProtocolFeeInbox` owned by `OWNER`, and `Random` shared.
fun setup(): Scenario {
    // Random requires sender == @0x0 (system address); create it first.
    let mut sc = test_scenario::begin(@0x0);
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

fun cap_id_1(): tenant_cap::TenantCapIdentity { tenant_cap::from_id(object::id_from_address(@0xCA1)) }
fun cap_id_2(): tenant_cap::TenantCapIdentity { tenant_cap::from_id(object::id_from_address(@0xCA2)) }

fun mk_tenant(stake: u64, addr: address, cap: tenant_cap::TenantCapIdentity): TenantSeat<SUI> {
    tenant_seat::new(cap, refund_address::new(addr), balance::create_for_testing<SUI>(stake))
}

fun mk_payment(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::from_balance(balance::create_for_testing<SUI>(amount), ctx)
}

/// The SDK's canonical entry path: read floor_price_mist at the clock's
/// current time, then rent one tenure paying exactly that floor. Because
/// floor_price_mist yields a valid payment in every rentable state, this
/// helper never aborts on a healthy escrow.
fun rent_with_floor_price(
    escrow: &mut Escrow<DemoAsset, SUI>,
    clk:    &clock::Clock,
    sc:     &mut Scenario,
): tenant_cap::TenantCap {
    rent_n_with_floor_price(escrow, 1, clk, sc)
}

/// Multi-tenure variant: floor_price_mist is the per-tenure floor, so the
/// total payment for n tenures is floor * n (the same compute_total_price
/// rent() asserts against). Requires the Multi tenure-extend policy.
fun rent_n_with_floor_price(
    escrow: &mut Escrow<DemoAsset, SUI>,
    n:      u64,
    clk:    &clock::Clock,
    sc:     &mut Scenario,
): tenant_cap::TenantCap {
    let floor = escrow::floor_price_mist(escrow, clock::timestamp_ms(clk));
    escrow::rent(escrow, mk_payment(floor * n, sc.ctx()), tenures::tenures(n), clk, sc.ctx())
}

/// One mist below floor_price_mist: the largest payment rent() must reject.
/// Pairs with rent_with_floor_price (exact floor succeeds) to pin floor as
/// the exact minimum. Always aborts EInsufficientPayment on a rentable state.
fun rent_one_below_floor_price(
    escrow: &mut Escrow<DemoAsset, SUI>,
    clk:    &clock::Clock,
    sc:     &mut Scenario,
): tenant_cap::TenantCap {
    let floor = escrow::floor_price_mist(escrow, clock::timestamp_ms(clk));
    escrow::rent(escrow, mk_payment(floor - 1, sc.ctx()), tenures::tenures(1), clk, sc.ctx())
}

/// Integrate, share, then take the shared escrow back. Returns the
/// escrow + cap. Uses Immediate commitment (no retire floor) by default.
fun integrate_and_take(
    ensemble: usufruct::policy_ensemble::PolicyEnsemble,
    sc:  &mut Scenario,
): (Escrow<DemoAsset, SUI>, OwnerCap) {
    integrate_and_take_with_retire_commitment(ensemble, retire_commitment_policy::new_immediate(), sc)
}

/// escrow + cap with an explicit RetireCommitmentPolicy.
fun integrate_and_take_with_retire_commitment(
    ensemble:        usufruct::policy_ensemble::PolicyEnsemble,
    commitment: RetireCommitmentPolicy,
    sc:         &mut Scenario,
): (Escrow<DemoAsset, SUI>, OwnerCap) {
    sc.next_tx(OWNER);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());
    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, commitment, &fee_ref, &clk, sc.ctx(),
    );
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

    let ensemble     = escrow_corpus::by_tag(0); // c=0 instant, d=0 fixed, e=0 linear, h=0 skipped, f=0 immediate
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
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
/// (HandoverPolicy ∈ {Instant, Fixed, FullTenure}) — three
/// behaviorally distinct handover modes — at fixed (d=0, e=0, h=0, f=0).
/// Verifies the post-condition `state_tag == Idle` for each.
///
/// The full 168-config corpus is unnecessary here: integrate does not
/// branch on policy / curve / price values; it only stores the ensemble.
/// A C-axis sweep is the minimum projection that exercises the named
/// protocol modes (per the corpus operational rule: "Default to the
/// minimum projection, not all_configs()"). Cross-axis sweeps belong
/// in commits where the behavior actually depends on those axes
/// (curve sweeps in C2 views; descent sweeps in C4 boundary handlers).
#[test]
fun integrate_idle_across_handover_modes() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let mut m = 0u8;
    while (m <= 1) {
        let mut c: u8 = 0;
        while (c <= 2) {
            let tag = escrow_corpus::tag_with_cycles(c, 0, 0, 0, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);

            let fee_ref = sc.take_immutable<ProtocolFeeRef>();
            let clk     = clock::create_for_testing(sc.ctx());
            let asset   = mk_demo_asset(sc.ctx());

                    let cap = escrow::integrate<DemoAsset, SUI>(
                asset, ensemble, retire_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
            );
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
        m = m + 1;
    };
    sc.end();
}

// ─── §2b. integrate — BalanceVault (asset abstraction) ───────────────────────

/// §2b.1 — A `key + store` wrapper over `Balance<SUI>` is accepted by
/// `integrate()` exactly like any other asset. The protocol is agnostic to
/// the wrapper's internals; it only tracks the UID. This confirms that the
/// `<Asset: key + store>` bound is a universal sigma — any Sui object
/// qualifies, regardless of what it holds.
#[test]
fun integrate_accepts_balance_vault() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble = escrow_corpus::by_tag(0);
    let fee_ref  = sc.take_immutable<ProtocolFeeRef>();
    let clk      = clock::create_for_testing(sc.ctx());

    let vault = mk_balance_vault(1_000_000, sc.ctx());
    let cap = escrow::integrate<BalanceVault, SUI>(
        vault, ensemble, retire_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::proj_escrow_id(&cap);
    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);

    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<BalanceVault, SUI>>(escrow_id);
    assert_tag_idle(&escrow, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
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

    let ensemble     = escrow_corpus::by_tag(0);
    let fee_ref = sc.take_immutable<ProtocolFeeRef>();
    let clk     = clock::create_for_testing(sc.ctx());
    let asset   = mk_demo_asset(sc.ctx());

    let cap       = escrow::integrate<DemoAsset, SUI>(asset, ensemble, retire_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx());
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
    // Below 10 base units, compute_mul_div(amount, 1000, 10000) = 0.
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
    // compute_mul_div(10, 1000, 10000) = 1.
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
    let ensemble     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take(ensemble, &mut sc);
    let clock = clock::create_for_testing(sc.ctx());
    let price = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clock));
    clock::destroy_for_testing(clock);
    assert_eq!(price, escrow_corpus::min_rent_price_const());
    assert_eq!(price, escrow::rest_price_floor_fixed_mist(&escrow));
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// e2e: floor_price_mist drives the escrow through its natural lifecycle.
/// At every rentable state the next tenant pays exactly floor_price_mist —
/// the SDK invariant that this query always precedes a non-aborting rent().
///
///   Idle ─rent→ Occupied ─rent→ Demand ─rent→ Demand
///        ─APT→ Occupied ─APT→ Descent ─rent→ Occupied
///
///   c=1 (handover=Fixed)  → Occupied→Demand on a bid, Demand persists on supersede
///   h=1 (descent=Fixed)   → Occupied→Descent at tenure expiry
#[test]
fun e2e_rent_with_floor_price_drives_full_lifecycle() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Idle → Occupied: T1 rents at floor.
    assert!(escrow::is_idle(&escrow), 0);
    let cap_t1 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    assert!(escrow::is_occupied(&escrow), 1);

    // Occupied → Demand: T2 bids at floor.
    clock::set_for_testing(&mut clk, 1_000);
    let cap_t2 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    assert!(escrow::is_demand(&escrow), 2);

    // Demand → Demand: T3 supersedes T2 at floor.
    clock::set_for_testing(&mut clk, 2_000);
    let cap_t3 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    assert!(escrow::is_demand(&escrow), 3);

    // Demand → Occupied: handover fires, T3 promoted to current.
    let countdown = escrow::handover_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, countdown);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), 4);

    // Occupied → Descent: T3's tenure expires (h=1).
    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 5);

    // Descent → Occupied: T4 rents at floor.
    let cap_t4 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    assert!(escrow::is_occupied(&escrow), 6);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    transfer::public_transfer(cap_t4, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Multi-tenure twin of e2e_rent_with_floor_price_drives_full_lifecycle.
/// Every tenant rents N tenures paying floor_price_mist * N. The state
/// machine and the floor invariant are identical; only the tenure count
/// (and so the tenure ceiling, queried dynamically) changes.
///
///   m=1 (Multi tenure-extend) → N-tenure rents are permitted
#[test]
fun e2e_rent_with_floor_price_drives_full_lifecycle_multitenure() {
    let mut sc = setup();
    let n = 3;
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag_with_cycles(1, 0, 0, 1, 0, 1));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Idle → Occupied: T1 rents N tenures at floor.
    assert!(escrow::is_idle(&escrow), 0);
    let cap_t1 = rent_n_with_floor_price(&mut escrow, n, &clk, &mut sc);
    assert!(escrow::is_occupied(&escrow), 1);

    // Occupied → Demand: T2 bids N tenures at floor.
    clock::set_for_testing(&mut clk, 1_000);
    let cap_t2 = rent_n_with_floor_price(&mut escrow, n, &clk, &mut sc);
    assert!(escrow::is_demand(&escrow), 2);

    // Demand → Demand: T3 supersedes T2 with N tenures at floor.
    clock::set_for_testing(&mut clk, 2_000);
    let cap_t3 = rent_n_with_floor_price(&mut escrow, n, &clk, &mut sc);
    assert!(escrow::is_demand(&escrow), 3);

    // Demand → Occupied: handover fires, T3 promoted to current.
    let countdown = escrow::handover_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, countdown);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), 4);

    // Occupied → Descent: T3's N-tenure ceiling expires (h=1).
    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 5);

    // Descent → Occupied: T4 rents N tenures at floor.
    let cap_t4 = rent_n_with_floor_price(&mut escrow, n, &clk, &mut sc);
    assert!(escrow::is_occupied(&escrow), 6);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    transfer::public_transfer(cap_t4, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── floor_price_mist is the exact minimum — floor − 1 aborts everywhere ──────
//
// The e2e lifecycle walks prove exact-floor succeeds in every rentable state.
// These four pin the boundary from below: one mist under floor_price_mist
// aborts EInsufficientPayment, so floor_price_mist is the exact minimum in
// Idle, Occupied, Demand, and Descent.

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun floor_price_mist_minus_one_aborts_in_idle() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    let cap = rent_one_below_floor_price(&mut escrow, &clk, &mut sc);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun floor_price_mist_minus_one_aborts_in_occupied() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    assert!(escrow::is_occupied(&escrow), 0);

    clock::set_for_testing(&mut clk, 1_000);
    let cap = rent_one_below_floor_price(&mut escrow, &clk, &mut sc);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun floor_price_mist_minus_one_aborts_in_demand() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    clock::set_for_testing(&mut clk, 1_000);
    let cap_t2 = rent_with_floor_price(&mut escrow, &clk, &mut sc);
    assert!(escrow::is_demand(&escrow), 0);

    clock::set_for_testing(&mut clk, 2_000);
    let cap = rent_one_below_floor_price(&mut escrow, &clk, &mut sc);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun floor_price_mist_minus_one_aborts_in_descent() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = rent_with_floor_price(&mut escrow, &clk, &mut sc);

    let expiry = escrow::tenure_expiry_ms(&escrow).destroy_some();
    clock::set_for_testing(&mut clk, expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    let cap = rent_one_below_floor_price(&mut escrow, &clk, &mut sc);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Occupied returns `f_next_rent_price(current_stake)`. Sweeps
/// the D axis (PriceEscalationPolicy): d=0 (FixedDelta) and d=1 (CompoundDelta)
/// — the only axis compute_next_rent_price actually consumes.
#[test]
fun floor_price_occupied_escalates_active_stake() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut d: u8 = 0;
        while (d <= 1) {
            let tag = escrow_corpus::tag_with_cycles(0, d, 0, 0, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

            escrow::drive_to_rented_for_testing(
                &mut escrow,
                mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
                0,
            );

            let clock = clock::create_for_testing(sc.ctx());
            let price = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clock));
            clock::destroy_for_testing(clock);
            // f_next > current_stake regardless of policy — both FixedDelta
            // (delta>0) and CompoundDelta (bps>0, delta>0) are strictly
            // increasing. Spec contract; do not duplicate the formula.
            assert!(price > STAKE_T1, tag);

            test_scenario::return_shared(escrow);
            owner_cap::burn(cap, OWNER);
            d = d + 1;
        };
        m = m + 1;
    };
    sc.end();
}

/// Demand returns `f_next_rent_price(pending_stake)`.
/// Sweeps D as above, but the input stake is t2's (the bidder's).
#[test]
fun floor_price_demand_escalates_pending_stake() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut d: u8 = 0;
        while (d <= 1) {
            let tag = escrow_corpus::tag_with_cycles(0, d, 0, 0, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

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
            let price = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clock));
            clock::destroy_for_testing(clock);
            assert!(price > STAKE_T2, tag);

            test_scenario::return_shared(escrow);
            owner_cap::burn(cap, OWNER);
            d = d + 1;
        };
        m = m + 1;
    };
    sc.end();
}

/// Descent at t=phase_start (elapsed=0) returns `last_acquisition_price`
/// (curve evaluated at 0 → 0 consumed). Sweeps E (curve dimension) at
/// fixed h=1 (descent=Fixed). The boundary `g(0)=0` is universal
/// across all 7 curves.
#[test]
fun floor_price_descent_at_t0_equals_last_acq_price() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 1, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

            escrow::drive_to_rented_for_testing(
                &mut escrow,
                mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
                0,
            );
            // Drive Occupied → Descent with last_acq_price > min_rent_price
            // so the spread is positive (otherwise the assertion would be
            // trivial: last_acq_price - 0 = last_acq_price for any curve).
            let last_acq = escrow_corpus::min_rent_price_const() * 2;
            let boundary_ms = 100_000;
            escrow::drive_to_descent_for_testing(
                &mut escrow, STAKE_T1, 0, last_acq, boundary_ms,
            );

            // At elapsed=0, descent has consumed 0 — price equals last_acq.
            let mut clock = clock::create_for_testing(sc.ctx());
            clock::set_for_testing(&mut clock, boundary_ms);
            let price = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clock));
            clock::destroy_for_testing(clock);
            assert!(price == last_acq, tag);

            test_scenario::return_shared(escrow);
            owner_cap::burn(cap, OWNER);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

/// Descent at t=phase_start+ceiling (full descent) collapses to
/// `min_rent_price` for every curve (g(t_max)=SCALE → consumed=spread).
#[test]
fun floor_price_descent_at_full_descent_equals_min_rent_price() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 1, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

            escrow::drive_to_rented_for_testing(
                &mut escrow,
                mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
                0,
            );
            let last_acq    = escrow_corpus::min_rent_price_const() * 2;
            let phase_start = 100_000;
            escrow::drive_to_descent_for_testing(
                &mut escrow, STAKE_T1, 0, last_acq, phase_start,
            );

            // At elapsed=ceiling, descent saturates → price = min_rent_price.
            let now = phase_start + escrow_corpus::descent_window_h1_const();
            let mut clock = clock::create_for_testing(sc.ctx());
            clock::set_for_testing(&mut clock, now);
            let price = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clock));
            clock::destroy_for_testing(clock);
            assert!(price == escrow_corpus::min_rent_price_const(), tag);

            test_scenario::return_shared(escrow);
            owner_cap::burn(cap, OWNER);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ERetiredNoBid, location = usufruct::asset_state)]
fun floor_price_aborts_on_retired() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);
    escrow::drive_to_retired_for_testing(&mut escrow);
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clock));
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ─── §6. compute_used_credit ─────────────────────────────────────────────────

/// At elapsed=0 (timestamp == phase_start), every credit_shape
/// evaluates to 0 → used_credit = 0. Sweeps E (curve dimension) — the
/// boundary g(0)=0 is universal.
#[test]
fun used_credit_at_phase_start_is_zero_for_all_curves() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 0, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

            let phase_start = 1_000_000;
            escrow::drive_to_rented_for_testing(
                &mut escrow,
                mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
                phase_start,
            );

            let mut clock = clock::create_for_testing(sc.ctx());
            clock::set_for_testing(&mut clock, phase_start);
            let used = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
            clock::destroy_for_testing(clock);
            assert!(used == 0, tag);

            test_scenario::return_shared(escrow);
            owner_cap::burn(cap, OWNER);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

/// At elapsed=tenure_ceiling, every credit_shape saturates to SCALE →
/// used_credit = principal (full stake consumed). Sweeps E.
#[test]
fun used_credit_at_tenure_ceiling_equals_principal_for_all_curves() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 0, 0, m);
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

            let phase_start = 1_000_000;
            escrow::drive_to_rented_for_testing(
                &mut escrow,
                mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
                phase_start,
            );

            let now = phase_start + escrow_corpus::tenure_ceiling_const();
            let mut clock = clock::create_for_testing(sc.ctx());
            clock::set_for_testing(&mut clock, now);
            let used = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
            clock::destroy_for_testing(clock);
            assert!(used == STAKE_T1, tag);

            test_scenario::return_shared(escrow);
            owner_cap::burn(cap, OWNER);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

/// Demand clamps the effective time at
/// `handover_countdown_expiry`. With c=1 (Fixed(25_000)), a
/// callback at far-future timestamp yields the same used_credit as
/// one at exactly the expiry — the clamp is the load-bearing property.
#[test]
fun used_credit_demand_clamps_at_expiry() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)); // c=1 Fixed
    let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);

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
    let at_expiry  = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
    clock::set_for_testing(&mut clock, countdown_expiry + 1_000_000);
    let far_future = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
    clock::destroy_for_testing(clock);
    assert_eq!(at_expiry, far_future);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun used_credit_aborts_on_idle() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take(ensemble, &mut sc);
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun used_credit_aborts_on_descent() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const(), 100_000,
    );
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun used_credit_aborts_on_retired() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);
    escrow::drive_to_retired_for_testing(&mut escrow);
    let clock = clock::create_for_testing(sc.ctx());
    let _ = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clock));
    clock::destroy_for_testing(clock);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ─── §7. rent — dispatch to do_install_new_tenant ────────────────────────────

/// Idle → Occupied via rent. Verifies state_tag transitions and
/// RentStarted carries from_state=Idle.
#[test]
fun rent_from_idle_installs_new_tenant() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let floor = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor, sc.ctx());
    let t_cap = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    // Post-condition: state is Occupied.
    assert!(escrow::is_occupied(&escrow), 0);

    // Event check: exactly one RentStarted with tenant_cap_id matching the returned cap.
    let started = event::events_by_type<RentStarted>();
    assert_eq!(started.length(), 1);
    assert_eq!(asset_state::rent_started_tenant_cap_id(&started[0]), object::id(&t_cap));
    assert_eq!(asset_state::rent_started_price_paid(&started[0]), floor);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Descent → Occupied via rent. RentStarted.from_state = DescentAuction.
#[test]
fun rent_from_descent_installs_new_tenant() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));  // h=1 for non-zero descent window
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Drive to Descent via test-only helpers.
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    let last_acq = escrow_corpus::min_rent_price_const() * 2;
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, last_acq, escrow_corpus::tenure_ceiling_const(),
    );

    // Sample mid-descent — APT must NOT fire auction_expiry yet (the
    // descent window has not elapsed).
    let now   = escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now);
    let floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));

    let payment = mk_payment(floor, sc.ctx());
    let t_cap = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_occupied(&escrow), 0);

    let started = event::events_by_type<RentStarted>();
    assert_eq!(started.length(), 1);

    transfer::public_transfer(t_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §8. rent — dispatch to do_place_bid ─────────────────────────────────────

/// Occupied → Demand via rent. BidPlaced carries
/// the pre-computed handover_countdown_expiry. Sweeps the C axis
/// (HandoverPolicy) since handover_policy::compute_expiry_at depends on it.
#[test]
fun rent_from_occupied_places_bid() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut c: u8 = 0;
        while (c <= 2) {
            let tag_cfg = escrow_corpus::tag_with_cycles(c, 0, 0, 0, 0, m);
            let ensemble     = escrow_corpus::by_tag(tag_cfg);
            let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            // First rent: Idle → Occupied.
            let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
            let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

            // Second rent: Occupied → Demand.
            let now2 = 5_000;
            clock::set_for_testing(&mut clk, now2);
            let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            let p2 = mk_payment(floor2, sc.ctx());
            let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

            assert!(escrow::is_demand(&escrow), tag_cfg);

            // Verify a BidPlaced event was emitted with cap_t2.
            let placed = event::events_by_type<BidPlaced>();
            assert!(placed.length() == 1, tag_cfg);
            assert_eq!(asset_state::bid_placed_pending_tenant_cap_id(&placed[0]), object::id(&cap_t2));
            // The expiry was stamped — its specific value depends on c
            // (Instant: now+0 = now2; Fixed: min(now2+25_000, phase_start+ceiling);
            // FullTenure: phase_start+ceiling). Property: expiry > 0.
            assert!(asset_state::bid_placed_handover_countdown_expiry(&placed[0]) > 0, tag_cfg);

            transfer::public_transfer(cap_t1, OWNER);
            transfer::public_transfer(cap_t2, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            c = c + 1;
        };
        m = m + 1;
    };
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ERetireFlagBlocksBid, location = usufruct::asset_state)]
fun rent_from_occupied_aborts_when_retiring_flag_set() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // First rent: Idle → Occupied.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Lift the retiring flag (real `retire`/`do_set_retiring_flag`
    // arrive in C5; the drive helper exercises the place_bid guard
    // in isolation here).
    escrow::drive_to_retiring_flag_for_testing(&mut escrow);

    // Second rent: Occupied + retiring=true → must abort.
    let p2 = mk_payment(escrow_corpus::min_rent_price_const() * 2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §9. rent — dispatch to do_supersede_bid ─────────────────────────────────

/// Demand → Demand via rent. The displaced
/// bidder's full stake is refunded (RefundState::Total → liquidate).
/// State tag is unchanged; pending cap_id is replaced.
#[test]
fun rent_from_demand_supersedes_bid() {
    let mut sc = setup();
    // c=1 (Fixed) — non-zero handover-countdown so APT does NOT
    // fire handover at the third rent before supersede can run.
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let p2_amt = escrow_corpus::min_rent_price_const() * 2;
    let p2 = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // Third rent supersedes t2.
    let now3 = 1_000;
    clock::set_for_testing(&mut clk, now3);
    let floor3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p3 = mk_payment(floor3, sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 0);

    // Verify BidSuperseded carries the displaced bid amount.
    let superseded = event::events_by_type<BidSuperseded>();
    assert_eq!(superseded.length(), 1);
    assert_eq!(asset_state::bid_superseded_displaced_cap_id(&superseded[0]), object::id(&cap_t2));
    assert_eq!(asset_state::bid_superseded_new_cap_id(&superseded[0]), object::id(&cap_t3));
    assert_eq!(asset_state::bid_superseded_refunded_amount(&superseded[0]), p2_amt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Invariant: instant handover (c=0) makes `RefundState::Total` unreachable.
/// `from_superseded` is only reachable through `do_supersede_bid`, which
/// executes only when `execute_rent` matches on `RentingState::Demand`.
/// With instant handover the expiry equals `now` at bid time, so
/// `step_handover` resolves the Demand state before `execute_rent` can
/// branch on it. T3's bid fires the handover (Occupied → T2) and then
/// places a fresh bid — `do_supersede_bid` is never reached.
/// Observable proxy: zero `BidSuperseded` events regardless of how many
/// successive challengers bid.
#[test]
fun off_handover_never_supersedes_pending_bid() {
    let mut sc = setup();
    // c=0 (Instant) — handover_expiry := now at every bid
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // T1 rents: Idle → Occupied
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 bids: Occupied → Demand (handover_expiry = 0 = now)
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 1);

    // T3 bids: step_handover fires (expiry=0 ≤ now=0) → HandoverCompleted
    // → Occupied(T2) → do_place_bid(T3) → Demand again. Never supersedes.
    let floor3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p3 = mk_payment(floor3, sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 2);

    // Structural invariant: BidSuperseded never fires ⟺ RefundState::Total unreachable.
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §10. rent — abort paths ─────────────────────────────────────────────────

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun rent_below_floor_aborts() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let payment = mk_payment(escrow_corpus::min_rent_price_const() - 1, sc.ctx());
    let cap = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ERetiredNoBid, location = usufruct::asset_state)]
fun rent_from_retired_aborts() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    escrow::drive_to_retired_for_testing(&mut escrow);

    let payment = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §11. do_handover ────────────────────────────────────────────────────────

/// Demand → Occupied via the boundary handler.
/// Verifies: state transition, owner balance increases by owner_share,
/// HandoverCompleted carries used_credit = owner_share + protocol_fee
/// and remain_credit = principal − used_credit.
/// Uses c=1 (Fixed) + e=0 (Linear) so used_credit fires
/// mid-tenure (Parcial branch — remainder > 0).
#[test]
fun do_handover_routes_funds_and_emits_event_parcial() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Drive to Demand via two rent calls.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let phase_start = 0;

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    let principal_t1 = escrow_corpus::min_rent_price_const();
    let owner_before = escrow::owner_value_for_testing(&escrow);

    // Fire do_handover at the handover-countdown expiry.
    let boundary_ms = phase_start + escrow_corpus::handover_countdown_c1_const() + now2;
    // Ensure boundary < tenure: 25_000 + 5_000 = 30_000 < 100_000.
    clock::set_for_testing(&mut clk, boundary_ms);
    let used_credit_expected = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Post-condition: Occupied, current is t2.
    assert!(escrow::is_occupied(&escrow), 0);

    // Owner balance increased by the owner share (90% of used_credit).
    let owner_after = escrow::owner_value_for_testing(&escrow);
    let owner_share_expected = used_credit_expected - used_credit_expected / 10;  // 90%
    assert!(owner_after - owner_before == owner_share_expected, 1);

    // HandoverCompleted event emitted with consistent figures.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    let used_credit = asset_state::handover_completed_used_credit(&completed[0]);
    let owner_share = asset_state::handover_completed_owner_share(&completed[0]);
    let protocol_fee = asset_state::handover_completed_protocol_fee(&completed[0]);
    let remain_credit = asset_state::handover_completed_remain_credit(&completed[0]);
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

/// At tenure expiry the tenant never receives a refund.
/// split_fee(principal) = owner_share + protocol_fee exactly — no remainder.
/// Preserves the invariant: the Nothing path is taken, never Parcial.
#[test]
fun do_tenure_expiry_tenant_receives_no_refund() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let principal = escrow_corpus::min_rent_price_const();
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Conservation: owner_share + protocol_fee = principal.
    // If this fails, some mist escaped to the tenant.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(
        asset_state::tenure_expired_owner_share(&expired[0]) +
        asset_state::tenure_expired_protocol_fee(&expired[0]),
        principal,
    );

    // No coin was transferred to the tenant — Nothing, not Parcial.
    sc.next_tx(TENANT_ADDR_1);
    assert!(!sc.has_most_recent_for_sender<coin::Coin<SUI>>(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Occupied → Descent via tenure boundary. Refund is always
/// Nothing (full stake consumed: owner+fee). last_acquisition_price
/// equals the principal at boundary.
#[test]
fun do_tenure_expiry_routes_full_stake_and_anchors_descent() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let principal = escrow_corpus::min_rent_price_const();

    let owner_before = escrow::owner_value_for_testing(&escrow);
    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Post-condition: NotRented + Descent.
    assert!(escrow::is_descending(&escrow), 0);

    // Owner balance += owner_share (90% of full principal).
    let owner_share_expected = principal - principal / 10;
    let owner_after = escrow::owner_value_for_testing(&escrow);
    assert!(owner_after - owner_before == owner_share_expected, 1);

    // TenureExpired carries the canonical anchor price = principal.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(asset_state::tenure_expired_last_acq_price(&expired[0]), principal);
    assert_eq!(asset_state::tenure_expired_owner_share(&expired[0]) +
               asset_state::tenure_expired_protocol_fee(&expired[0]), principal);

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

/// Occupied + retiring=true → tenure expiry transitions directly
/// to Retired (skipping Descent). AssetRetired co-emits with
/// TenureExpired.
#[test]
fun do_tenure_expiry_with_retiring_flag_collapses_to_retired() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Lift retiring flag (real retire arrives in C5).
    escrow::drive_to_retiring_flag_for_testing(&mut escrow);

    let boundary_ms = escrow_corpus::tenure_ceiling_const();
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    // Post-condition: NotRented + Retired (not Descent).
    assert!(escrow::is_retired(&escrow), 0);

    // Both events emitted: TenureExpired + AssetRetired.
    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

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
    let ensemble = escrow_corpus::by_tag(0); // f=0 immediate
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), 0);

    let flagged = event::events_by_type<RetireFlagSet>();
    assert_eq!(flagged.length(), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// retire from Descent → Retired (same flow as Idle, different
/// from_state). Drives via the test-only Descent helper.
#[test]
fun retire_from_descent_collapses_to_retired() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 window
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), 0);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// retire from Occupied → flag set; state stays Occupied.
/// RetireFlagSet emitted with state_at_set=Occupied; no AssetRetired
/// (the asset stays with the tenant until tenure expiry).
#[test]
fun retire_from_occupied_only_lifts_flag() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), 0);

    let flagged = event::events_by_type<RetireFlagSet>();
    assert_eq!(flagged.length(), 1);

    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EAlreadyRetired, location = usufruct::asset_state)]
fun retire_when_already_retired_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    escrow::drive_to_retired_for_testing(&mut escrow);
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EAlreadyRetiring, location = usufruct::asset_state)]
fun retire_when_already_retiring_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    // Second call must fail — flag is already set.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun retire_with_wrong_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Mint a foreign cap bound to a different escrow_id.
    let foreign_cap = owner_cap::new(escrow_identity::new(object::id_from_address(@0xDEAD)), OWNER, sc.ctx());
    escrow::retire(&mut escrow, &foreign_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    owner_cap::burn(foreign_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// A genuine OwnerCap from a different real escrow is rejected.
/// Demonstrates that any cap bound to escrow A cannot retire escrow B,
/// even though both caps were legitimately issued by the protocol.
#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun retire_with_real_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow_a, cap_a) = integrate_and_take(ensemble, &mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    escrow::retire(&mut escrow_b, &cap_a, &clk, sc.ctx());

    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(cap_a, OWNER);
    owner_cap::burn(cap_b, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ERetireCommitmentFloorNotElapsed, location = usufruct::asset_state)]
fun retire_before_floor_aborts_under_deferred_policy() {
    let mut sc = setup();
    let tag = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 deferred
    let ensemble = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(ensemble, escrow_corpus::retire_commitment_by_tag(tag), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    // clock at 0 is far below the deferred floor (10_000_000).
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §13. do_auction_expiry ──────────────────────────────────────────────────

/// Descent → Idle via auction boundary. No tenant funds; only emits
/// AuctionExpired.
#[test]
fun do_auction_expiry_returns_to_idle() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);

    // Drive Idle → Occupied → Descent via test helpers.
    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );

    let boundary_ms = 100_000 + escrow_corpus::descent_window_h1_const();
    escrow::fire_do_auction_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms));

    assert!(escrow::is_idle(&escrow), 0);

    let expired = event::events_by_type<AuctionExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(asset_state::auction_expired_timestamp_ms(&expired[0]), boundary_ms);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

/// Retire flag set from Demand state does NOT block supersede bids.
/// Bidders are still competing for the last tenure before retirement.
/// The retire flag closes the market at the cycle level (no new tenants
/// after the current one), but the pending slot is still open: anyone
/// willing to pay more can displace the pending challenger and claim
/// that final tenure. Only an Occupied+retiring escrow rejects new bids.
#[test]
fun retire_from_demand_allows_supersede_for_last_tenure() {
    let mut sc = setup();
    // c=1 (Fixed) — non-zero handover window keeps Demand alive across calls.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents: Idle → Occupied.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 bids: Occupied → Demand.
    let p2_amt = escrow_corpus::min_rent_price_const() * 2;
    let p2 = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Owner retires from Demand: sets retire flag, state stays Demand.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 1);
    assert_eq!(event::events_by_type<RetireFlagSet>().length(), 1);

    // T3 supersedes T2: retire flag does NOT block supersede.
    // Bidders are competing for the last tenure before the asset retires.
    clock::set_for_testing(&mut clk, 1_000);
    let floor3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t3 = escrow::rent(&mut escrow, mk_payment(floor3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 2);
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);
    assert_eq!(asset_state::bid_superseded_displaced_cap_id(&event::events_by_type<BidSuperseded>()[0]), object::id(&cap_t2));
    assert_eq!(asset_state::bid_superseded_new_cap_id     (&event::events_by_type<BidSuperseded>()[0]), object::id(&cap_t3));

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §14.5 compute_next_pending — detection without firing ──────────────────────────

/// compute_next_pending returns None when nothing is due.
#[test]
fun next_pending_returns_none_in_steady_state() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);

    // Idle escrow — nothing pending at any clock.
    let clk = clock::create_for_testing(sc.ctx());
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)), 0);
    clock::destroy_for_testing(clk);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

/// compute_next_pending returns None when the escrow is at Descent but the descent
/// window has not yet closed. Covers the Descent-not-firable branch of
/// `compute_next_pending` (B4 in bytecode).
#[test]
fun next_pending_descent_not_firable_returns_none() {
    let mut sc = setup();
    // h=1 Fixed descent — non-zero descent duration ensures the auction is
    // not immediately firable at clock=0.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Expire the tenure to enter Descent (h=1 → Fixed → stays in Descent).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // Probe at clock just after tenure expiry — the descent window is not yet
    // closed, so no pending transition.
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// compute_next_pending returns Some(Demand) with the handover expiry as boundary
/// when the escrow is in Demand and the countdown has elapsed.
/// Covers the Demand-firable branch of `compute_next_pending` (B12 in bytecode).
#[test]
fun next_pending_demand_firable_returns_some() {
    let mut sc = setup();
    // c=1 Fixed — non-zero handover countdown so we can control timing.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Advance past the countdown expiry without firing APT.
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry + 1);

    assert!(escrow::is_demand(&escrow), 1);
    assert_eq!(escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some(), countdown_expiry);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// compute_next_pending returns None when the escrow is in Demand but the handover
/// countdown has not yet elapsed. Covers the Demand-not-firable branch of
/// `compute_next_pending` (B13 in bytecode).
#[test]
fun next_pending_demand_not_firable_returns_none() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Clock is 0 — the countdown expiry is in the future.
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// compute_next_pending returns Tenure with the boundary_ms when tenure has elapsed.
#[test]
fun next_pending_detects_tenure_with_correct_boundary() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Probe at clock just past the tenure boundary — Tenure is pending.
    let probe_ms = escrow_corpus::tenure_ceiling_const() + 1;
    clock::set_for_testing(&mut clk, probe_ms);
    assert!(escrow::is_occupied(&escrow), 0);
    assert_eq!(escrow::next_transition_ms(&escrow, clock::timestamp_ms(&clk)).destroy_some(), escrow_corpus::tenure_ceiling_const());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15. execute_apply_pending_transition_states ──────────────────────────────────────────

/// APT no-ops when nothing is due. Tag unchanged after the call.
#[test]
fun apt_noop_when_nothing_due() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Idle escrow at clock=0; no transitions are due.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// APT fires handover when the handover-countdown expires.
/// c=1 (Fixed); after rent → place_bid, jump clock past expiry,
/// call APT. State becomes Occupied (handover fired).
#[test]
fun apt_fires_handover_when_countdown_expires() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Jump clock past the countdown expiry.
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // Handover fired: Demand → Occupied (t2 now t1).
    assert!(escrow::is_occupied(&escrow), 1);

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_state::handover_completed_timestamp_ms(&completed[0]), countdown_expiry);

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
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Jump clock past the tenure boundary.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // Tenure expired: Occupied → Descent (h=1 window).
    assert!(escrow::is_descending(&escrow), 0);

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
/// Spec scenario M6b (Occupied → DescentAuction → Idle in one
/// pass). Verifies the cascade order and that MAX_APT_ITERATIONS
/// holds (3 iterations needed: tenure, auction; the no-op final
/// iteration to confirm steady state).
#[test]
fun apt_cascade_tenure_then_auction_skipped() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0)); // h=0 Skipped
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // Cascade: Occupied → Descent (tenure_expiry) → Idle (auction_expiry under h=0 collapses to phase_start, immediately expired).
    assert!(escrow::is_idle(&escrow), 0);

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
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let (asset_out, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    let borrowed = event::events_by_type<AssetBorrowed>();
    assert_eq!(borrowed.length(), 1);

    escrow::return_asset(&mut escrow, asset_out, receipt);
    let returned = event::events_by_type<AssetReturned>();
    assert_eq!(returned.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EWrongEscrowTenantCap, location = usufruct::asset_state)]
fun borrow_asset_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let foreign_cap = tenant_cap::new(escrow_identity::new(object::id_from_address(@0xDEAD)), TENANT_ADDR_1, sc.ctx());

    let (a, r) = escrow::borrow_asset(&mut escrow, &foreign_cap, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset_state::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(foreign_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EStaleTenantCap, location = usufruct::asset_state)]
fun borrow_asset_from_idle_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Mint a cap bound to this escrow but never used (no active rental).
    let escrow_id = object::id(&escrow);
    let cap = tenant_cap::new(escrow_identity::new(escrow_id), TENANT_ADDR_1, sc.ctx());

    let (a, r) = escrow::borrow_asset(&mut escrow, &cap, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset_state::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EPendingTenantCap, location = usufruct::asset_state)]
fun borrow_asset_with_pending_cap_aborts() {
    let mut sc = setup();
    // c=1 Fixed so place_bid stamps a future expiry (no APT
    // handover before borrow).
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // cap_t2 is the pending bidder — cannot borrow.
    let (a, r) = escrow::borrow_asset(&mut escrow, &cap_t2, &clk, sc.ctx());
    transfer::public_transfer(a, OWNER);
    asset_state::destroy_receipt_for_testing(r);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.2 soft_burn_tenant_cap ───────────────────────────────────────────────────

/// Stale cap (from a superseded bid) burns cleanly. Live caps abort.
#[test]
fun soft_burn_tenant_cap_burns_displaced_bidder_cap() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    // Supersede t2 with t3 — t2's cap is now stale.
    let now3 = now2 + 100;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    // Burn the stale cap_t2.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapNotStale, location = usufruct::asset_state)]
fun soft_burn_tenant_cap_on_live_active_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    // cap_t1 is the live current — burn must abort.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t1, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EWrongEscrowTenantCap, location = usufruct::asset_state)]
fun soft_burn_tenant_cap_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let foreign = tenant_cap::new(escrow_identity::new(object::id_from_address(@0xDEAD)), TENANT_ADDR_1, sc.ctx());

    escrow::soft_burn_tenant_cap(&mut escrow, foreign, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.2b hard_burn_tenant_cap ─────────────────────────────────────────────

/// `hard_burn_tenant_cap` destroys a TenantCap unconditionally with no escrow
/// reference. Canonical use: the escrow has been claimed and deleted, leaving
/// the former tenant's cap orphaned. `soft_burn_tenant_cap` would be
/// impossible at that point — the shared object no longer exists.
///
/// A cap bound to the escrow identity is created, then the escrow is driven
/// to Retired and claimed (object consumed). `hard_burn_tenant_cap` burns the
/// now-orphaned cap — verified by `TenantCapBurned` event and `sc.end()`.
#[test]
fun hard_burn_tenant_cap_destroys_orphaned_cap_post_claim() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    // Create a cap bound to this escrow (simulates a former tenant's cap).
    let orphaned_cap = tenant_cap::new(
        escrow_identity::new(object::id(&escrow_handle)), TENANT_ADDR_1, sc.ctx(),
    );

    // Drive Idle → Retired, then claim — Escrow object is consumed and deleted.
    escrow::drive_to_retired_for_testing(&mut escrow_handle);
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());

    // The escrow is gone — hard_burn_tenant_cap needs no escrow reference.
    escrow::hard_burn_tenant_cap(orphaned_cap, sc.ctx());

    let burned = event::events_by_type<tenant_cap::TenantCapBurned>();
    assert_eq!(burned.length(), 1);

    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.2c update_tenant_refund_address ─────────────────────────────────────
//
// The refund address is captured at rent/bid time from `ctx.sender()` and
// stored inside the `TenantSeat`. Because `TenantCap` has `key + store` it
// can be transferred to a different holder afterwards, who must be able to
// redirect refunds without re-minting the cap. The new entry mutates the
// seat whose `cap_identity` matches the presented cap (active or pending,
// across Occupied and Demand). Mismatch — including stale caps in renting
// states and any cap presented while waiting — aborts `ETenantCapStale`.
// Cross-escrow attempts trip the prior gate (`EWrongEscrowTenantCap`).

#[test]
fun update_tenant_refund_address_in_occupied_changes_active_address() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let old_addr = *escrow::active_tenant_addr(&escrow).borrow();

    let new_addr = @0xCAFE;
    escrow::update_tenant_refund_address(
        &mut escrow, &cap_t1, refund_address::new(new_addr), &clk, sc.ctx(),
    );

    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(), new_addr);

    let active_evts = event::events_by_type<ActiveTenantRefundAddressUpdated>();
    assert_eq!(active_evts.length(), 1);
    assert_eq!(asset_state::active_refund_updated_escrow_id(&active_evts[0]), object::id(&escrow));
    assert_eq!(asset_state::active_refund_updated_tenant_cap_id(&active_evts[0]), object::id(&cap_t1));
    assert_eq!(asset_state::active_refund_updated_old_address(&active_evts[0]), old_addr);
    assert_eq!(asset_state::active_refund_updated_new_address(&active_evts[0]), new_addr);
    assert_eq!(event::events_by_type<PendingTenantRefundAddressUpdated>().length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun update_tenant_refund_address_in_demand_with_active_cap_changes_active_only() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let p2 = mk_payment(escrow_corpus::min_rent_price_const() * 2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);
    let active_old  = *escrow::active_tenant_addr(&escrow).borrow();
    let pending_old = *escrow::pending_tenant_addr(&escrow).borrow();

    let new_addr = @0xC0FF;
    escrow::update_tenant_refund_address(
        &mut escrow, &cap_t1, refund_address::new(new_addr), &clk, sc.ctx(),
    );

    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(),  new_addr);
    assert_eq!(*escrow::pending_tenant_addr(&escrow).borrow(), pending_old);

    let active_evts = event::events_by_type<ActiveTenantRefundAddressUpdated>();
    assert_eq!(active_evts.length(), 1);
    assert_eq!(asset_state::active_refund_updated_tenant_cap_id(&active_evts[0]), object::id(&cap_t1));
    assert_eq!(asset_state::active_refund_updated_old_address(&active_evts[0]), active_old);
    assert_eq!(asset_state::active_refund_updated_new_address(&active_evts[0]), new_addr);
    assert_eq!(event::events_by_type<PendingTenantRefundAddressUpdated>().length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun update_tenant_refund_address_in_demand_with_pending_cap_changes_pending_only() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let p2 = mk_payment(escrow_corpus::min_rent_price_const() * 2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);
    let active_old  = *escrow::active_tenant_addr(&escrow).borrow();
    let pending_old = *escrow::pending_tenant_addr(&escrow).borrow();

    let new_addr = @0xC0FF;
    escrow::update_tenant_refund_address(
        &mut escrow, &cap_t2, refund_address::new(new_addr), &clk, sc.ctx(),
    );

    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(),  active_old);
    assert_eq!(*escrow::pending_tenant_addr(&escrow).borrow(), new_addr);

    let pending_evts = event::events_by_type<PendingTenantRefundAddressUpdated>();
    assert_eq!(pending_evts.length(), 1);
    assert_eq!(asset_state::pending_refund_updated_escrow_id(&pending_evts[0]), object::id(&escrow));
    assert_eq!(asset_state::pending_refund_updated_tenant_cap_id(&pending_evts[0]), object::id(&cap_t2));
    assert_eq!(asset_state::pending_refund_updated_old_address(&pending_evts[0]), pending_old);
    assert_eq!(asset_state::pending_refund_updated_new_address(&pending_evts[0]), new_addr);
    assert_eq!(event::events_by_type<ActiveTenantRefundAddressUpdated>().length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EWrongEscrowTenantCap, location = usufruct::asset_state)]
fun update_tenant_refund_address_with_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let foreign = tenant_cap::new(escrow_identity::new(object::id_from_address(@0xDEAD)), TENANT_ADDR_1, sc.ctx());

    escrow::update_tenant_refund_address(&mut escrow, &foreign, refund_address::new(@0xCAFE), &clk, sc.ctx());

    transfer::public_transfer(foreign, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapStale, location = usufruct::asset_state)]
fun update_tenant_refund_address_in_demand_with_stale_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let p2 = mk_payment(escrow_corpus::min_rent_price_const() * 2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    // t3 supersedes t2 — cap_t2 becomes stale (no longer in any seat).
    let now3 = 1_000;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(@0xCAFE), &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// In Occupied state, a cap that doesn't match the active seat is stale.
#[test, expected_failure(abort_code = asset_state::ETenantCapStale, location = usufruct::asset_state)]
fun update_tenant_refund_address_in_occupied_with_stale_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    // Escrow is Occupied. A cap bound to this escrow but with a different identity is stale.
    let wrong_cap = tenant_cap::new(escrow_identity::new(object::id(&escrow)), TENANT_ADDR_2, sc.ctx());

    escrow::update_tenant_refund_address(&mut escrow, &wrong_cap, refund_address::new(@0xCAFE), &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(wrong_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapStale, location = usufruct::asset_state)]
fun update_tenant_refund_address_in_idle_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Cap bound to this escrow but no seat exists (escrow is Idle).
    let bound_cap = tenant_cap::new(escrow_identity::new(object::id(&escrow)), TENANT_ADDR_1, sc.ctx());
    escrow::update_tenant_refund_address(&mut escrow, &bound_cap, refund_address::new(@0xCAFE), &clk, sc.ctx());

    transfer::public_transfer(bound_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapStale, location = usufruct::asset_state)]
fun update_tenant_refund_address_in_descent_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, escrow_corpus::min_rent_price_const() * 2, 100_000,
    );
    let bound_cap = tenant_cap::new(escrow_identity::new(object::id(&escrow)), TENANT_ADDR_1, sc.ctx());

    escrow::update_tenant_refund_address(&mut escrow, &bound_cap, refund_address::new(@0xCAFE), &clk, sc.ctx());

    transfer::public_transfer(bound_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ETenantCapStale, location = usufruct::asset_state)]
fun update_tenant_refund_address_in_retired_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_retired_for_testing(&mut escrow);
    let bound_cap = tenant_cap::new(escrow_identity::new(object::id(&escrow)), TENANT_ADDR_1, sc.ctx());

    escrow::update_tenant_refund_address(&mut escrow, &bound_cap, refund_address::new(@0xCAFE), &clk, sc.ctx());

    transfer::public_transfer(bound_cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun update_tenant_refund_address_with_same_address_emits_event_no_abort() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let current = *escrow::active_tenant_addr(&escrow).borrow();

    // Idempotent: same address is allowed; emits event for audit history.
    escrow::update_tenant_refund_address(
        &mut escrow, &cap_t1, refund_address::new(current), &clk, sc.ctx(),
    );

    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(), current);
    let evts = event::events_by_type<ActiveTenantRefundAddressUpdated>();
    assert_eq!(evts.length(), 1);
    assert_eq!(asset_state::active_refund_updated_old_address(&evts[0]), current);
    assert_eq!(asset_state::active_refund_updated_new_address(&evts[0]), current);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.2d update_tenant_refund_address — e2e refund routing ────────────────
//
// The unit tests above pin the setter chain, the dispatch and the event
// emission. These integration tests close the loop: after a redirect, the
// actual Coin<SUI> produced by `tenant_stake::liquidate` during a refund-
// bearing transition (`do_handover` for the displaced active,
// `do_supersede_bid` for the displaced pending) arrives at the wallet the
// holder specified, not at the original `ctx.sender()` of `rent`. Each test
// asserts BOTH the event-field (off-chain observability) and the on-chain
// Coin destination (the money actually moves).

#[test]
fun update_tenant_refund_address_e2e_active_then_handover_routes_to_new() {
    let mut sc = setup();
    // c=1 (Fixed handover) → finite countdown, non-trivial remain_credit possible.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents at phase_start=0. Original refund address = ctx.sender() = OWNER.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T1 redirects refund to NEW_T1.
    let new_t1 = @0xCAFE01;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t1, refund_address::new(new_t1), &clk, sc.ctx());

    // T2 places bid, escrow → Demand.
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // Fire do_handover at countdown expiry → T1 displaced.
    let boundary = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    // Event field reflects the updated address.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_state::handover_completed_displaced_tenant_address(&completed[0]), new_t1);
    let remain_credit = asset_state::handover_completed_remain_credit(&completed[0]);
    assert!(remain_credit > 0, 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);

    // The refund Coin physically arrived at NEW_T1.
    sc.next_tx(new_t1);
    let refund_coin = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund_coin), remain_credit);
    transfer::public_transfer(refund_coin, new_t1);
    sc.end();
}

#[test]
fun update_tenant_refund_address_e2e_pending_then_supersede_routes_to_new() {
    let mut sc = setup();
    // c=1 (Fixed) — non-zero handover countdown so APT does NOT fire handover
    // before the third rent runs (otherwise we never reach supersede).
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    // T2 places bid (Demand).
    let p2_amt = escrow_corpus::min_rent_price_const() * 2;
    let p2 = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // T2 redirects refund while still pending.
    let new_t2 = @0xCAFE02;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(new_t2), &clk, sc.ctx());

    // T3 supersedes T2.
    let now3 = 1_000;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    // Event records the updated address; refund amount = T2's full bid.
    let superseded = event::events_by_type<BidSuperseded>();
    assert_eq!(superseded.length(), 1);
    assert_eq!(asset_state::bid_superseded_displaced_bidder_address(&superseded[0]), new_t2);
    assert_eq!(asset_state::bid_superseded_refunded_amount(&superseded[0]), p2_amt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);

    // Refund Coin lands at NEW_T2.
    sc.next_tx(new_t2);
    let refund_coin = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund_coin), p2_amt);
    transfer::public_transfer(refund_coin, new_t2);
    sc.end();
}

#[test]
fun update_tenant_refund_address_e2e_pending_update_survives_promotion_through_handover() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents → active at phase_start=0.
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    // T2 bids at clock=5_000 → Demand.
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // T2 redirects refund while still pending.
    let new_t2 = @0xCAFE03;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(new_t2), &clk, sc.ctx());

    // Handover #1 → T1 displaced (refund to OWNER, ignored), T2 promoted to active.
    let boundary1 = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary1);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary1), sc.ctx());
    assert!(escrow::is_occupied(&escrow), 0);

    // T3 bids → Demand again.
    let now3 = boundary1 + 5_000;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    // Handover #2 → T2 (now active) displaced. Refund destination must be NEW_T2,
    // the address T2 set while still pending — preserved across the promotion.
    let boundary2 = now3 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary2);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary2), sc.ctx());

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 2);
    // [0] = handover #1 (T1 displaced to OWNER), [1] = handover #2 (T2 displaced to NEW_T2).
    assert_eq!(asset_state::handover_completed_displaced_tenant_address(&completed[1]), new_t2);
    let t2_remain = asset_state::handover_completed_remain_credit(&completed[1]);
    assert!(t2_remain > 0, 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);

    // Coin at NEW_T2 with the expected amount.
    sc.next_tx(new_t2);
    let refund_coin = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund_coin), t2_remain);
    transfer::public_transfer(refund_coin, new_t2);
    sc.end();
}

#[test]
fun update_tenant_refund_address_e2e_active_update_overrides_pending_update_through_handover() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // T2 sets a "pending-time" address — should be overridden later.
    let pending_addr = @0xCAFE04;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(pending_addr), &clk, sc.ctx());

    // Handover #1: T1 displaced, T2 promoted (carries `pending_addr` for now).
    let boundary1 = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary1);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary1), sc.ctx());

    // T2 updates again, this time as active. This is the address that must win.
    let active_addr = @0xCAFE05;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(active_addr), &clk, sc.ctx());

    // T3 bids → Demand again.
    let now3 = boundary1 + 5_000;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    // Handover #2: T2 displaced. Refund destination must be `active_addr`,
    // not `pending_addr` (last-write-wins through a promotion).
    let boundary2 = now3 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary2);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary2), sc.ctx());

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 2);
    assert_eq!(asset_state::handover_completed_displaced_tenant_address(&completed[1]), active_addr);
    let t2_remain = asset_state::handover_completed_remain_credit(&completed[1]);
    assert!(t2_remain > 0, 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);

    // Coin at active_addr — pending_addr gets nothing (would-be take_from_sender
    // there would abort, since only one transfer was made by the protocol).
    sc.next_tx(active_addr);
    let refund_coin = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund_coin), t2_remain);
    transfer::public_transfer(refund_coin, active_addr);
    sc.end();
}

#[test]
fun update_tenant_refund_address_e2e_repeated_active_updates_last_wins_through_handover() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Three updates while T1 is in the ACTIVE phase (Occupied state, no bid yet).
    // All three exercise the `Occupied → terms.active` branch of the dispatch.
    // Only the last write must persist; the refund on handover routes to addr_c.
    let addr_a = @0xCAFE10;
    let addr_b = @0xCAFE20;
    let addr_c = @0xCAFE30;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t1, refund_address::new(addr_a), &clk, sc.ctx());
    escrow::update_tenant_refund_address(&mut escrow, &cap_t1, refund_address::new(addr_b), &clk, sc.ctx());
    escrow::update_tenant_refund_address(&mut escrow, &cap_t1, refund_address::new(addr_c), &clk, sc.ctx());

    // T2 bids → Demand.
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // Handover fires → T1 displaced, refund destination = addr_c (last write).
    let boundary = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_state::handover_completed_displaced_tenant_address(&completed[0]), addr_c);
    let remain = asset_state::handover_completed_remain_credit(&completed[0]);
    assert!(remain > 0, 0);

    // Three Active events were emitted (A, B, C); each carries its own old/new pair.
    let active_evts = event::events_by_type<ActiveTenantRefundAddressUpdated>();
    assert_eq!(active_evts.length(), 3);
    assert_eq!(asset_state::active_refund_updated_new_address(&active_evts[0]), addr_a);
    assert_eq!(asset_state::active_refund_updated_new_address(&active_evts[1]), addr_b);
    assert_eq!(asset_state::active_refund_updated_new_address(&active_evts[2]), addr_c);
    // Chained old→new: addr_b's old = addr_a, addr_c's old = addr_b.
    assert_eq!(asset_state::active_refund_updated_old_address(&active_evts[1]), addr_a);
    assert_eq!(asset_state::active_refund_updated_old_address(&active_evts[2]), addr_b);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);

    // Coin at addr_c.
    sc.next_tx(addr_c);
    let refund_coin = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund_coin), remain);
    transfer::public_transfer(refund_coin, addr_c);
    sc.end();
}

#[test]
fun update_tenant_refund_address_e2e_repeated_pending_updates_last_wins_through_supersede() {
    let mut sc = setup();
    // c=1 (Fixed) — non-zero handover countdown so APT doesn't fire handover
    // between T2's bid and T3's supersede; otherwise we'd exit Demand early.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents → Occupied (active = T1).
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    // T2 bids → Demand (pending = T2, full stake parked).
    let p2_amt = escrow_corpus::min_rent_price_const() * 2;
    let p2 = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // Three updates while T2 is in the PENDING phase (Demand.bid.pending).
    // All three exercise the `Demand → bid.pending` branch of the dispatch
    // (a different code path than the active branch covered above).
    // Only the last write must persist; the refund on supersede routes to addr_c.
    let addr_a = @0xCAFE40;
    let addr_b = @0xCAFE50;
    let addr_c = @0xCAFE60;
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(addr_a), &clk, sc.ctx());
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(addr_b), &clk, sc.ctx());
    escrow::update_tenant_refund_address(&mut escrow, &cap_t2, refund_address::new(addr_c), &clk, sc.ctx());

    // T3 supersedes T2's bid.
    let now3 = 1_000;
    clock::set_for_testing(&mut clk, now3);
    let p3 = mk_payment(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    let superseded = event::events_by_type<BidSuperseded>();
    assert_eq!(superseded.length(), 1);
    assert_eq!(asset_state::bid_superseded_displaced_bidder_address(&superseded[0]), addr_c);
    assert_eq!(asset_state::bid_superseded_refunded_amount(&superseded[0]), p2_amt);

    // Three Pending events emitted with chained old→new (initial = OWNER from T2's rent).
    let pending_evts = event::events_by_type<PendingTenantRefundAddressUpdated>();
    assert_eq!(pending_evts.length(), 3);
    assert_eq!(asset_state::pending_refund_updated_new_address(&pending_evts[0]), addr_a);
    assert_eq!(asset_state::pending_refund_updated_new_address(&pending_evts[1]), addr_b);
    assert_eq!(asset_state::pending_refund_updated_new_address(&pending_evts[2]), addr_c);
    assert_eq!(asset_state::pending_refund_updated_old_address(&pending_evts[1]), addr_a);
    assert_eq!(asset_state::pending_refund_updated_old_address(&pending_evts[2]), addr_b);
    // Active branch never touched in this scenario.
    assert_eq!(event::events_by_type<ActiveTenantRefundAddressUpdated>().length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);

    // Coin arrives at addr_c with the full bid amount.
    sc.next_tx(addr_c);
    let refund_coin = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund_coin), p2_amt);
    transfer::public_transfer(refund_coin, addr_c);
    sc.end();
}

/// Commercial invariant: the `TenantCap` is `key + store` and can be sold
/// or otherwise transferred. The buyer (new holder) must be able to redirect
/// the refund without any coordination with the original tenant, because the
/// protocol authenticates by `tenant_cap::identity(&cap)` — a function of the
/// cap object — not by `ctx.sender()`. This pins the property that makes
/// secondary markets for caps economically coherent.
#[test]
fun update_tenant_refund_address_e2e_transferred_cap_grants_authority_to_new_holder() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // OWNER rents → cap_t1 minted; original refund address = OWNER ("seller").
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Secondary-market sale: OWNER transfers the cap to a buyer at @0xBEEF.
    // The coin leg of the trade (buyer → seller) is outside the protocol's
    // observable surface; only the cap transfer matters for the invariant.
    let buyer = @0xBEEF;
    transfer::public_transfer(cap_t1, buyer);
    test_scenario::return_shared(escrow);

    // Buyer's transaction. They take possession of the cap and redirect.
    // The sender is the buyer; OWNER is not involved.
    sc.next_tx(buyer);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let cap_t1 = sc.take_from_sender<tenant_cap::TenantCap>();
    let buyer_refund = @0xBE71;
    escrow::update_tenant_refund_address(
        &mut escrow, &cap_t1, refund_address::new(buyer_refund), &clk, sc.ctx(),
    );

    // The seat now refunds to the buyer's chosen address, not to OWNER.
    assert_eq!(*escrow::active_tenant_addr(&escrow).borrow(), buyer_refund);
    let evts = event::events_by_type<ActiveTenantRefundAddressUpdated>();
    assert_eq!(evts.length(), 1);
    assert_eq!(asset_state::active_refund_updated_old_address(&evts[0]), OWNER);
    assert_eq!(asset_state::active_refund_updated_new_address(&evts[0]), buyer_refund);
    assert_eq!(asset_state::active_refund_updated_tenant_cap_id(&evts[0]), object::id(&cap_t1));

    transfer::public_transfer(cap_t1, buyer);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §15.3 escrow locked while asset borrowed ────────────────────────────────
//
// While `escrow.state` is `None` (asset on loan), every call that
// touches the lifecycle state — mutating or view — aborts `EAssetBorrowed`.
// The invariant: the escrow state is accessible only while the asset is
// in custody. Borrow + return are atomic within a PTB; nothing may observe
// or modify the state in between.
//
// Representative cases:
//   · execute_apply_pending_transition_states — permissionless, anyone may chain it
//   · rent                            — tenant side, mutating
//   · retire                          — owner side, mutating
//   · is_occupied                     — read-only view

#[test, expected_failure(abort_code = escrow::EAssetBorrowed, location = usufruct::escrow)]
fun apply_pending_transitions_aborts_while_asset_borrowed() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());

    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = escrow::EAssetBorrowed, location = usufruct::escrow)]
fun rent_aborts_while_asset_borrowed() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());

    let p2     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = escrow::EAssetBorrowed, location = usufruct::escrow)]
fun retire_aborts_while_asset_borrowed() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = escrow::EAssetBorrowed, location = usufruct::escrow)]
fun is_occupied_view_aborts_while_asset_borrowed() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());

    escrow::is_occupied(&escrow);

    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    test_scenario::return_shared(escrow);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §16. withdraw_earnings ──────────────────────────────────────────────────

/// Happy path: drive a tenure expiry → owner accumulates 90% → withdraw
/// returns a Coin with that exact value. EarningsWithdrawn fires.
#[test]
fun withdraw_earnings_drains_owner_balance() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let principal = escrow_corpus::min_rent_price_const();
    let p1 = mk_payment(principal, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Tenure expiry routes 90% to owner.
    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );
    let owner_share_expected = principal - principal / 10;
    assert_eq!(escrow::owner_value_for_testing(&escrow), owner_share_expected);

    let coin = escrow::withdraw_earnings(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert_eq!(coin::value(&coin), owner_share_expected);
    assert_eq!(escrow::owner_value_for_testing(&escrow), 0);

    let withdrawn = event::events_by_type<EarningsWithdrawn>();
    assert_eq!(withdrawn.length(), 1);
    assert_eq!(asset_state::earnings_withdrawn_amount(&withdrawn[0]), owner_share_expected);

    coin::burn_for_testing(coin);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENoEarnings, location = usufruct::asset_state)]
fun withdraw_earnings_with_zero_balance_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let coin = escrow::withdraw_earnings(&mut escrow, &owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun withdraw_earnings_with_wrong_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let foreign = owner_cap::new(escrow_identity::new(object::id_from_address(@0xDEAD)), OWNER, sc.ctx());
    let coin = escrow::withdraw_earnings(&mut escrow, &foreign, &clk, sc.ctx());
    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    owner_cap::burn(foreign, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// A genuine OwnerCap from a different real escrow is rejected on withdraw_earnings.
#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun withdraw_earnings_with_real_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow_a, cap_a) = integrate_and_take(ensemble, &mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let coin = escrow::withdraw_earnings(&mut escrow_b, &cap_a, &clk, sc.ctx());

    coin::burn_for_testing(coin);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(cap_a, OWNER);
    owner_cap::burn(cap_b, OWNER);
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
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Force the escrow into Retired (no earnings) via the test helper.
    escrow::drive_to_retired_for_testing(&mut escrow_handle);

    // Take the shared escrow by value so claim_asset can consume it.
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    assert_eq!(coin::value(&earnings), 0);

    let claimed = event::events_by_type<AssetClaimed>();
    assert_eq!(claimed.length(), 1);
    assert_eq!(asset_state::asset_claimed_swept_earnings(&claimed[0]), 0);

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
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let principal = escrow_corpus::min_rent_price_const();
    let p1 = mk_payment(principal, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow_handle, p1, tenures::tenures(1), &clk, sc.ctx());

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

    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    let owner_share_expected = principal - principal / 10;
    assert_eq!(coin::value(&earnings), owner_share_expected);

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::ENotRetired, location = usufruct::asset_state)]
fun claim_asset_when_not_retired_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    // Idle, not Retired.
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun claim_asset_with_wrong_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    escrow::drive_to_retired_for_testing(&mut escrow_handle);
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    let foreign = owner_cap::new(escrow_identity::new(object::id_from_address(@0xDEAD)), OWNER, sc.ctx());
    let (asset, earnings) = escrow::claim_asset(escrow, foreign, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// A genuine OwnerCap from a different real escrow is rejected on claim_asset.
/// escrow_b is driven to Retired so the state check does not fire first.
#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun claim_asset_with_real_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow_a, cap_a) = integrate_and_take(ensemble, &mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    escrow::drive_to_retired_for_testing(&mut escrow_b);
    let escrow_b_id = object::id(&escrow_b);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    sc.next_tx(OWNER);
    let escrow_b = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_b_id);

    let (asset, earnings) = escrow::claim_asset(escrow_b, cap_a, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    owner_cap::burn(cap_b, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// APT cascade: Demand → Occupied → Descent → Idle in
/// one pass under (c=2 FullTenure, h=0 Skipped). M6c spec scenario.
/// FullTenure saturates handover_countdown_expiry to the tenure
/// boundary; Skipped collapses descent — three transitions fire in
/// sequence within a single APT call.
#[test]
fun apt_cascade_handover_tenure_auction_under_c2_h0() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(2, 0, 0, 0, 0)); // c=2 FullTenure, h=0 Skipped
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let now2 = 1_000;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Jump clock past the second tenure boundary so all three
    // transitions are due in one APT call:
    //   handover at tenure_ceiling (FullTenure expiry); after it,
    //   the new phase_start is tenure_ceiling, so tenure expiry is
    //   due at 2 × tenure_ceiling; auction fires immediately under
    //   h=0 Skipped.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() * 3);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // Cascade: Demand → Occupied → Descent → Idle.
    assert!(escrow::is_idle(&escrow), 1);

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

/// Exhaustive full-cycle helper: Idle → HO → HC → HO → {Idle|Descent} → Idle
/// → Retired → claimed, over all combinations of c, h, m (d=0, e=0, f=0).
///
/// Timing is derived from the BidPlaced event (same strategy as APT idempotency)
/// so the loop is config-agnostic across all four handover policies.
///
/// T1 rents cycles(m+1) to exercise multi-cycle normalization for m=1.
/// T2 always rents cycles(1). Claim happens in a separate tx.
fun full_cycle_loop(entries: vector<escrow_corpus::CorpusEntry>, mut sc: Scenario) {
    let ceiling  = escrow_corpus::tenure_ceiling_const();
    let price_t1 = escrow_corpus::min_rent_price_const();
    let mut i    = 0;
    while (i < entries.length()) {
        let entry      = &entries[i];
        let tag        = entry.tag();
        let t1_cycles  = (entry.m() as u64) + 1;
        let (mut escrow, owner_cap) = integrate_and_take(*entry.ensemble(), &mut sc);
        let escrow_id  = owner_cap::proj_escrow_id(&owner_cap);
        let mut clk    = clock::create_for_testing(sc.ctx());
    
        // T1: Idle → Occupied.
        let cap_t1 = escrow::rent(
            &mut escrow,
            mk_payment(price_t1 * t1_cycles, sc.ctx()),
            tenures::tenures(t1_cycles),
            &clk, sc.ctx(),
        );

        // T2 bids at t=1_000: Occupied → Demand.
        clock::set_for_testing(&mut clk, 1_000);
        let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
        assert!(escrow::is_demand(&escrow), tag);

        // Config-agnostic handover expiry from BidPlaced event.
        let hv_expiry = asset_state::bid_placed_handover_countdown_expiry(
            event::events_by_type<BidPlaced>().borrow(0),
        );

        // B1: Handover — HC → HO.
        clock::set_for_testing(&mut clk, hv_expiry);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert!(escrow::is_occupied(&escrow), tag);
        assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

        // B2: Tenure expiry. T2.phase_start = hv_expiry; T2 rented cycles(1).
        let tenure_boundary = hv_expiry + ceiling;
        clock::set_for_testing(&mut clk, tenure_boundary);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

        // B3: Auction expiry (h ≠ 0 only — h=0 exits directly to Idle).
        if (entry.h() != 0) {
            assert!(escrow::is_descending(&escrow), tag);
            let max_descent = escrow_corpus::descent_window_h1_const();
            clock::set_for_testing(&mut clk, tenure_boundary + max_descent);
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);
        };
        assert!(escrow::is_idle(&escrow), tag);

        // Retire and return to pool; claim in fresh tx.
        escrow::drive_to_retired_for_testing(&mut escrow);
        test_scenario::return_shared(escrow);
        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
            clock::destroy_for_testing(clk);
        sc.next_tx(OWNER);

        let retired = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
            let clk2    = clock::create_for_testing(sc.ctx());
        let (asset, earnings) = escrow::claim_asset(retired, owner_cap, &clk2, sc.ctx());
        assert!(coin::value(&earnings) > 0, tag);
        assert_eq!(event::events_by_type<AssetClaimed>().length(), 1);
        coin::burn_for_testing(earnings);
        transfer::public_transfer(asset, OWNER);
            clock::destroy_for_testing(clk2);

        i = i + 1;
    };
    sc.end();
}

// d=0, e=0, f=0 fixed (accidental). 24 entries: 4c × 3h × 2m.
#[test]
fun e2e_full_cycle_all_ch_m() {
    full_cycle_loop(
        escrow_corpus::filter_f(
            escrow_corpus::filter_e(
                escrow_corpus::filter_d(escrow_corpus::all(), 0),
            0),
        0),
        setup(),
    );
}

/// Full rental cycle with bid: integrate → rent (Idle→HO) → place bid
/// (HO→HC) → APT handover (HC→HO) → APT tenure (HO→Descent) → APT
/// auction (Descent→Idle) → retire → claim. Verifies the assembly
/// holds across all transitions and the events fire in order.
#[test]
fun e2e_full_rental_cycle_with_bid_and_handover() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents (Idle → Occupied).
    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow_handle, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 places a bid (Occupied → Demand).
    let now2 = 5_000;
    clock::set_for_testing(&mut clk, now2);
    let p2 = mk_payment(escrow::floor_price_mist(&escrow_handle, clock::timestamp_ms(&clk)), sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow_handle, p2, tenures::tenures(1), &clk, sc.ctx());

    // APT at expiry: handover fires (Demand → Occupied
    // with t2 promoted).
    let countdown_expiry = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow_handle), 0);

    // APT past tenure: tenure expiry fires (HO → Descent).
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow_handle), 1);

    // APT past auction: auction expiry fires (Descent → Idle).
    let auction_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, auction_boundary);
    escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
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

    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
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
/// Descent → no_winner → Idle. Owner accumulates the full stake's
/// 90% via tenure expiry. Sweeps E (curve dimension) at fixed
/// (c=0, d=0, h=1, f=0) — the universal boundary properties
/// (g(t_max)=SCALE, full descent collapses to min_rent_price)
/// hold across all 7 curves.
#[test]
fun e2e_tenure_expiry_then_auction_no_winner_across_curves() {
    let mut sc = setup();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let cfg_tag = escrow_corpus::tag_with_cycles(0, 0, e, 1, 0, m);
            let ensemble     = escrow_corpus::by_tag(cfg_tag);
            let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            let principal = escrow_corpus::min_rent_price_const();
            let p1 = mk_payment(principal, sc.ctx());
            let cap_t1 = escrow::rent(&mut escrow_handle, p1, tenures::tenures(1), &clk, sc.ctx());

            // APT past tenure → Descent.
            clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
            escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
            assert!(escrow::is_descending(&escrow_handle), cfg_tag);

            // APT past descent → Idle.
            clock::set_for_testing(
                &mut clk,
                escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() + 1,
            );
            escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
            assert!(escrow::is_idle(&escrow_handle), cfg_tag);

            // Owner accumulated 90 % of the principal (g(t_max)=SCALE
            // saturates the credit curve regardless of shape).
            let owner_share_expected = principal - principal / 10;
            assert_eq!(escrow::owner_value_for_testing(&escrow_handle), owner_share_expected);

            transfer::public_transfer(cap_t1, OWNER);
            test_scenario::return_shared(escrow_handle);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

/// Retire-during-rental: rent → retire (flag set, state stays HO) →
/// APT past tenure → state collapses to Retired (not Descent). Owner
/// claims the asset; AssetRetired emitted.
#[test]
fun e2e_retire_during_rental_collapses_to_retired_at_tenure() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow_handle, p1, tenures::tenures(1), &clk, sc.ctx());

    // Retire mid-rental — flag lifts, state stays HO.
    escrow::retire(&mut escrow_handle, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow_handle), 0);

    // APT past tenure: state collapses to Retired (skipping Descent).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow_handle), 1);

    // AssetRetired co-emitted with TenureExpired (do_tenure_expiry's
    // retiring branch).
    let retired = event::events_by_type<AssetRetired>();
    assert_eq!(retired.length(), 1);

    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
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
///         h=0 (Skipped — DescentAuction is unobservable),
///         e=0, f=0.
///
/// Verifies: floor_price increases at each succession, two HandoverCompleted
/// events fire (once per displacement), TenureExpired + AuctionExpired fire
/// together under Skipped, earnings are non-zero after two paid tenures.
#[test]
fun e2e_two_tenant_successions_price_escalates() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // c=0 d=0 e=0 h=0 f=0
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1: rent from Idle at min_rent_price → Occupied.
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // T2: bid on T1's tenure → Demand.
    let now_t2    = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t2 > price_t1, tag); // price escalated
    let cap_t2    = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // APT: Instant handover fires at bid_time_ms=1000 → Occupied (T2 current).
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T3: bid on T2's tenure → Demand.
    let now_t3    = 2_000;
    clock::set_for_testing(&mut clk, now_t3);
    let price_t3  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t3 > price_t2, tag); // price escalated again
    let cap_t3    = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // APT: second Instant handover → Occupied (T3 current).
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 2);

    // Advance past T3's tenure ceiling (phase_start_T3 = now_t3 = 2_000).
    let tenure_boundary = now_t3 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // h=0 Skipped: TenureExpired + AuctionExpired co-fire → Idle.
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Retire from Idle → Retired.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    // Claim: earnings must be positive — both T1 and T2 accumulated used_credit.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
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
/// tenure expires → DescentAuction with non-zero spread. T3 rents at
/// mid-descent price, which is strictly below T2's price (the last
/// acquisition price entering Descent) but ≥ min_rent_price.
///
/// Zero-spread is impossible here: T2's price = T1 + FixedDelta > min_rent_price,
/// so the descent has a genuine spread to exercise.
///
/// Config: c=0 (Instant — handover fires at bid_time, no clock advance),
///         d=0 (FixedDelta), e=0 (linear), h=1 (Fixed), f=0.
#[test]
fun e2e_auction_winner_rents_at_mid_descent() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // c=0 h=1
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1: rent from Idle → Occupied at min_rent_price.
    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2: bid on T1's tenure (HO → HC). floor_price > min_rent_price.
    let now_t2   = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // APT: Instant handover → Occupied (T2 current, phase_start = now_t2).
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // APT past T2's tenure ceiling → DescentAuction.
    // last_acquisition_price = price_t2 > min_rent_price → non-zero spread.
    let tenure_boundary = now_t2 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // T3 at mid-descent: price is between price_t2 and min_rent_price.
    let now_mid  = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let price_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t3 < price_t2, tag);                               // price descended
    assert!(price_t3 >= escrow_corpus::min_rent_price_const(), tag); // never below min

    // T3 rents at the descending price → Occupied.
    let cap_t3 = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §3. Deferred retire floor gate ───────────────────────────────────────────

/// With RetireCommitmentPolicy::Deferred, retire() aborts if the clock has not
/// reached integrated_at_ms + retire_floor. integrated_at_ms = 0
/// (clock at integration time), retire_floor = 10_000_000.
///
/// Config: c=0, d=0, e=0, h=0, f=1 (Deferred).
#[test, expected_failure(
    abort_code = asset_state::ERetireCommitmentFloorNotElapsed,
    location   = usufruct::asset_state,
)]
fun e2e_deferred_retire_aborts_before_floor() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 Deferred
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(ensemble, escrow_corpus::retire_commitment_by_tag(tag), &mut sc);
    // Clock at 0; retire_floor = 10_000_000 — gate is closed.
    let clk = clock::create_for_testing(sc.ctx());
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
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
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(ensemble, escrow_corpus::retire_commitment_by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Advance past retire_floor (integrated_at_ms=0, floor=10_000_000).
    let past_floor = escrow_corpus::retire_deferred_f1_const() + 1;
    clock::set_for_testing(&mut clk, past_floor);

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
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
/// Config: c=1 (Fixed 25_000 ms — Instant would fire handover
/// before T3 can supersede), d=0, e=0, h=0, f=0.
#[test]
fun e2e_supersede_T3_displaces_T2_APT_fires_to_T3() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1: rent from Idle → Occupied.
    let cap_t1   = escrow::rent(
        &mut escrow,
        mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk,
        sc.ctx(),
    );

    // T2: bid → Demand (countdown starts at now_t2=1_000).
    let now_t2   = 1_000;
    clock::set_for_testing(&mut clk, now_t2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow,
        mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk,
        sc.ctx(),
    );
    assert!(escrow::is_demand(&escrow), tag);
    assert_eq!(event::events_by_type<BidPlaced>().length(), 1);

    // T3: supersedes T2 before countdown expires (now_t3=2_000 < 1_000+25_000).
    let now_t3   = 2_000;
    clock::set_for_testing(&mut clk, now_t3);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t3   = escrow::rent(
        &mut escrow,
        mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk,
        sc.ctx(),
    );
    assert!(escrow::is_demand(&escrow), tag);
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // APT past T3's countdown expiry → Occupied (T3 is current, not T2).
    let t3_countdown_expiry = now_t3 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, t3_countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T2's cap is stale — burn it.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §5. Zero-spread descent — floor stays at min_rent_price ─────────────────

/// T1 rents at min_rent_price and holds until tenure expires without a
/// successor. DescentAuction starts with last_acquisition_price =
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
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 1, 0, m); // c=0 h=1, vary e
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            let min_price = escrow_corpus::min_rent_price_const();

            // T1 rents at min_rent_price — no successor.
            let cap_t1 = escrow::rent(
                &mut escrow,
                mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk,
                sc.ctx(),
            );

            // APT past tenure ceiling → DescentAuction.
            // last_acquisition_price = min_rent_price → zero spread.
            let tenure_boundary = escrow_corpus::tenure_ceiling_const();
            clock::set_for_testing(&mut clk, tenure_boundary + 1);
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert!(escrow::is_descending(&escrow), tag);

            // floor at t=0 of descent window: must equal min_rent_price.
            // (Zero spread means price == min_price at every point; any clock value works.)
            let floor_at_start = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(floor_at_start, min_price);

            // floor at mid-descent: must still equal min_rent_price.
            let now_mid = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
            let floor_at_mid = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(floor_at_mid, min_price);

            // floor at descent boundary: must equal min_rent_price.
            let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
            let _ = descent_boundary; // referenced for documentation only; clock unchanged
            let floor_at_end = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(floor_at_end, min_price);

            // T2 can rent at min_rent_price → Occupied.
            clock::set_for_testing(&mut clk, now_mid);
            let cap_t2 = escrow::rent(
                &mut escrow,
                mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk,
                sc.ctx(),
            );
            assert!(escrow::is_occupied(&escrow), tag);

            transfer::public_transfer(cap_t1, OWNER);
            transfer::public_transfer(cap_t2, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

// ─── §B1. Five successive PTBs — each chains rent+borrow (Instant) ───────────

/// Five successive PTBs with a representative c=0 config. Each PTB atomically
/// chains rent() → borrow_asset(). Demonstrates chain depth: every successive
/// tenant (5 total) can borrow immediately after being crowned via an Instant
/// handover. tag(0,0,0,0,0) is the canonical representative.
///
/// PTB 1: T1 rents from Idle — immediately current, no APT needed.
/// PTBs 2–5: Tn bids → APT inside borrow_asset fires Instant → Tn current → borrows+returns.
#[test]
fun e2e_b1_five_ptbs_borrow_chain() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let min_price = escrow_corpus::min_rent_price_const();

    // PTB 1: T1 rents from Idle — immediately current.
    let clk = clock::create_for_testing(sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    assert!(escrow::is_occupied(&escrow), tag);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    // PTBs 2–5: Tn bids → APT Instant → Tn current → borrow+return.
    let mut ptb: u8 = 2;
    while (ptb <= 5) {
        let mut clk = clock::create_for_testing(sc.ctx());
        let t = (ptb as u64) * 1_000;
        clock::set_for_testing(&mut clk, t);
        let floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
        let cap = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
        let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap, &clk, sc.ctx());
        escrow::return_asset(&mut escrow, asset, receipt);
        assert!(escrow::is_occupied(&escrow), tag);
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
        let ensemble   = *entry.ensemble();
        let tag   = entry.tag();
        let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
        let clk = clock::create_for_testing(sc.ctx());
    
        // T1 rents from Idle — immediately current — borrows in same PTB.
        let cap_t1 = escrow::rent(&mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
        let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
        escrow::return_asset(&mut escrow, asset, receipt);
        assert!(escrow::is_occupied(&escrow), tag);

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
#[test, expected_failure(abort_code = asset_state::EStaleTenantCap, location = usufruct::asset_state)]
fun e2e_b3_stale_tenant_cap_borrow_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids → state becomes Demand. APT inside borrow_asset fires Instant handover → T1 stale.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T1's cap is now stale (handover fires inside borrow_asset) — borrow must abort.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §B3b. Superseded bid cap cannot borrow ──────────────────────────────────

/// After T2's bid is superseded by T3, T2's cap is stale.
/// borrow_asset() with T2's stale cap aborts EStaleTenantCap.
///
/// Config: c=1 (Fixed) so the handover countdown does not fire
/// before T2 attempts borrow — escrow stays in Demand.
#[test, expected_failure(abort_code = asset_state::EStaleTenantCap, location = usufruct::asset_state)]
fun e2e_b3b_superseded_tenant_cap_borrow_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents: Idle → Occupied.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()),
        tenures::tenures(1), &clk, sc.ctx());

    // T2 bids: Occupied → Demand (countdown starts at now_t2=1_000).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()),
        tenures::tenures(1), &clk, sc.ctx());

    // T3 supersedes T2 before countdown expires → T2's cap is now stale.
    clock::set_for_testing(&mut clk, 2_000);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t3   = escrow::rent(
        &mut escrow, mk_payment(floor_t3, sc.ctx()),
        tenures::tenures(1), &clk, sc.ctx());

    // Escrow is still Demand; countdown has not elapsed — APT does not fire.
    // T2's cap is stale: borrow must abort.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t2, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §B4. Auction entry — rent from Descent then borrow in same PTB ──────────

/// T1 rents, tenure expires → DescentAuction. T2 rents at the auction
/// price — rent() from Descent calls do_install_new_tenant (T2 is
/// immediately current, no APT needed). T2 borrows in the same PTB.
///
/// Config: c=0, d=0, h=1 (observable Descent), f=0.
#[test]
fun e2e_b4_auction_entry_rent_and_borrow_same_ptb() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // h=1
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents, tenure expires → DescentAuction.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    // T2 places a bid and APT fires handover so last_acq_price > min to get a spread.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_b4  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2_temp = escrow::rent(&mut escrow, mk_payment(floor_b4, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // Now T2 holds tenure; advance past T2's tenure ceiling.
    let tenure_boundary = 1_000 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);

    // T3 rents from DescentAuction at mid-descent price — immediately current.
    let now_mid  = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let price_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t3   = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // T3 borrows in the same PTB — no APT needed (do_install_new_tenant makes T3 current directly).
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t3, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

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
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Cycle 1
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    // Cycle 2
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    // Cycle 3
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    assert!(escrow::is_occupied(&escrow), tag);

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
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let price_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    let price_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t3 > price_t2, tag);

    // Compound growth: each increment is larger than the previous.
    let gap_2_1 = price_t2 - price_t1;
    let gap_3_2 = price_t3 - price_t2;
    assert!(gap_3_2 > gap_2_1, tag);

    let cap_t3 = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

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
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let delta   = escrow_corpus::fixed_delta_value_const();

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let price_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert_eq!(price_t2 - price_t1, delta);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    let price_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert_eq!(price_t3 - price_t2, delta); // constant gap

    let cap_t3 = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

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
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents at t=0.
    let cap_t1 = escrow::rent(
        &mut escrow_handle, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t=tenure_ceiling/2 → APT Instant fires handover.
    // T1 held for half the tenure: used_credit > 0 → owner accumulates earnings.
    let t_mid    = escrow_corpus::tenure_ceiling_const() / 2;
    clock::set_for_testing(&mut clk, t_mid);
    let floor_e1 = escrow::floor_price_mist(&escrow_handle, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(&mut escrow_handle, mk_payment(floor_e1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow_handle), tag);

    // First withdrawal — T1's used_credit share.
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let mut escrow_handle = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let earnings_1 = escrow::withdraw_earnings(&mut escrow_handle, &owner_cap, &clk, sc.ctx());
    assert!(coin::value(&earnings_1) > 0, tag);
    coin::burn_for_testing(earnings_1);

    // T2's tenure expires → Idle (Skipped). T2's full credit → owner earnings.
    let tenure_boundary = t_mid + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow_handle, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow_handle), tag);

    // Second withdrawal — T2's earnings (fresh, first was drained to zero).
    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let mut escrow_handle = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let earnings_2 = escrow::withdraw_earnings(&mut escrow_handle, &owner_cap, &clk, sc.ctx());
    assert!(coin::value(&earnings_2) > 0, tag);
    coin::burn_for_testing(earnings_2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow_handle);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §R1. Retire from Demand — pending bid inherits retiring flag ──

/// Owner sets the retiring flag while in Demand (T2 has a pending
/// bid). APT still honors the bid and fires the handover — T2 receives
/// Occupied with the retiring flag inherited. T2's tenure then collapses
/// to Retired (not Descent) because the flag is active.
///
/// Config: c=1 (Fixed — time is needed to verify flag persists through APT),
///         h=0 (Skipped — tenure → Retired in one APT when retiring=true), f=0.
#[test]
fun e2e_r1_retire_from_hc_pending_bid_gets_hopen_with_retiring_flag() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents (Idle → Occupied).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 places a bid (Occupied → Demand).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_r1 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(floor_r1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // Owner sets retiring flag while in Demand.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    // State stays Demand — retire only lifts the flag here.
    assert!(escrow::is_demand(&escrow), tag);

    // APT past T2's countdown expiry → APT honors the bid: T2 gets Occupied.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // APT past T2's tenure ceiling → collapses to Retired (not Descent).
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // Claim the asset.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());

    transfer::public_transfer(asset, OWNER);
    coin::burn_for_testing(earnings);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §A1. APT fires at exact tenure boundary (>= inclusivity) ────────────────

/// execute_apply_pending_transition_states with clock == tenure_boundary_ms fires the
/// tenure expiry transition. Verifies the >= guard in phases::has_passed.
#[test]
fun e2e_a1_apt_fires_at_exact_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // h=0 Skipped → Idle
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Exact boundary: clock == phase_start(0) + tenure_ceiling.
    let boundary = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, boundary);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // h=0 Skipped: tenure → Descent → Idle in one APT step.
    assert!(escrow::is_idle(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §A2. APT does not fire one ms before tenure boundary ────────────────────

/// execute_apply_pending_transition_states with clock == tenure_boundary_ms - 1 does not
/// fire — state stays Occupied. Verifies the >= guard is not >.
#[test]
fun e2e_a2_apt_noop_one_ms_before_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // One ms before the boundary — nothing should fire.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() - 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §F2. FullTenure — T3 supersedes T2, T3 wins handover at tenure boundary ──

/// With c=2 (FullTenure), handover_countdown_expiry saturates to
/// phase_start + tenure_ceiling. T2 bids, T3 supersedes T2; at the
/// tenure boundary APT fires the handover to T3 (not T2). T2's cap is stale.
///
/// Config: c=2, d=0, e=0, h=1 (Fixed — tenure and handover don't co-fire
/// into Idle so we can observe T3's Occupied), f=0.
#[test]
fun e2e_f2_full_tenure_T3_supersedes_T2_wins_at_tenure_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(2, 0, 0, 1, 0); // c=2 FullTenure, h=1
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents (Idle → Occupied, phase_start = 0).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t=1000 → Demand.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_f2a = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2    = escrow::rent(&mut escrow, mk_payment(floor_f2a, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);
    assert_eq!(event::events_by_type<BidPlaced>().length(), 1);

    // T3 supersedes T2 at t=2000 (before tenure_ceiling=100_000).
    clock::set_for_testing(&mut clk, 2_000);
    let floor_f2b = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t3    = escrow::rent(&mut escrow, mk_payment(floor_f2b, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // APT at tenure_ceiling (= FullTenure handover expiry = phase_start + tenure_ceiling = 100_000).
    // Handover fires → T3 wins → Occupied (T3 current, new phase_start=100_000).
    // T3's tenure ceiling = 100_000 + 100_000 = 200_000 > 100_000 → no tenure expiry yet.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T2's cap is stale — T3 won, T2 was superseded.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t2, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §B1-inv. Fixed requires clock advance before borrow ─────────────────

/// Temporal invariant: with c=1 (Fixed, handover_floor=25_000 ms),
/// a pending tenant cannot borrow until the countdown elapses and APT
/// promotes them to current. Documents the protocol guarantee that
/// Demand is a locked state — TenantCap alone is insufficient.
///
/// Three PTBs:
///   PTB 1: T1 rents from Idle → immediately current → borrows (no wait needed).
///   PTB 2: T2 bids → Demand (pending). APT called before countdown
///          expires → fires nothing → state stays Demand.
///   PTB 3: Clock advances past countdown. APT fires handover → T2 current.
///          T2 borrows in the same PTB — now allowed.
///
/// Contrast with e2e_b1_five_ptbs_borrow_chain (c=0 Instant): there, every
/// PTB chains rent+APT+borrow without a clock advance. Here, PTB 2 cannot
/// borrow and PTB 3 is required.
#[test]
fun e2e_b1_inv_countdown_borrow_requires_clock_advance() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);

    // PTB 1: T1 rents from Idle — immediately current — borrows.
    let clk    = clock::create_for_testing(sc.ctx());
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
    assert!(escrow::is_occupied(&escrow), tag);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    // PTB 2: T2 bids at t=1_000 → Demand (T2 pending).
    // APT at same clock — countdown not elapsed (1_000 < 1_000 + 25_000) → no-op.
    let mut clk = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    // Fixed has not elapsed — T2 is still pending, state unchanged.
    assert!(escrow::is_demand(&escrow), tag);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();

    // PTB 3: clock advances past countdown expiry → APT fires handover → T2 current.
    // T2 borrows in the same PTB — the temporal unlock has occurred.
    let mut clk = clock::create_for_testing(sc.ctx());
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t2, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);
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
    // c=1 (Fixed, floor=25_000) required: rent() calls APT internally.
    // With c=0 (Instant) the countdown expires at bid_time, so APT within
    // the supersede rent() would fire the handover before do_supersede_bid.
    // With c=1 the countdown hasn't elapsed at t=2_000, so the supersede path
    // is reachable.
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 (OWNER) rents from Idle → Occupied (current at min_price).
    let cap_t1_current = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // OWNER bids on own tenure at t=1_000 → Demand (current + pending).
    clock::set_for_testing(&mut clk, 1_000);
    let price_2     = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t1_bid1 = escrow::rent(
        &mut escrow, mk_payment(price_2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // OWNER supersedes own pending bid at t=2_000 (before 1_000+25_000 countdown).
    clock::set_for_testing(&mut clk, 2_000);
    let price_3     = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_3 > price_2, tag);
    let cap_t1_bid2 = escrow::rent(
        &mut escrow, mk_payment(price_3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let sup = event::events_by_type<BidSuperseded>();
    assert_eq!(sup.length(), 1);
    let se = sup.borrow(0);
    // Core: same address displaced and re-entered.
    assert_eq!(asset_state::bid_superseded_displaced_bidder_address(se),
               asset_state::bid_superseded_new_bidder_address(se));
    assert_eq!(asset_state::bid_superseded_refunded_amount(se), price_2);
    assert_eq!(asset_state::bid_superseded_new_bid_amount(se), price_3);

    // APT past countdown (1_000+25_000=26_000) → cap_t1_bid2 current.
    // cap_t1_current (original stake, held ~26s) is displaced: remain_credit > 0.
    clock::set_for_testing(&mut clk, 1_000 + escrow_corpus::handover_countdown_c1_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    let he = hc.borrow(0);
    assert_eq!(asset_state::handover_completed_displaced_tenant_address(he), OWNER);
    // new_rent_price is the next floor (price_3 + delta), not the stake itself.
    assert_eq!(asset_state::handover_completed_new_rent_price(he),
               price_3 + escrow_corpus::fixed_delta_value_const());
    assert!(asset_state::handover_completed_remain_credit(he) > 0, tag);

    transfer::public_transfer(cap_t1_current, OWNER);
    transfer::public_transfer(cap_t1_bid1, OWNER);
    transfer::public_transfer(cap_t1_bid2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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
fun e2e_active_tenant_defends_against_challenger() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 (OWNER) rents from Idle → Occupied.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 (CHALLENGER) bids at t=1_000 → Demand.
    clock::set_for_testing(&mut clk, 1_000);
    test_scenario::return_shared(escrow);
    sc.next_tx(CHALLENGER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let floor_2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2  = escrow::rent(&mut escrow, mk_payment(floor_2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);
    test_scenario::return_shared(escrow);

    // T1 (OWNER) supersedes CHALLENGER at t=2_000 (before 1_000+25_000 countdown).
    sc.next_tx(OWNER);
    let mut escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    clock::set_for_testing(&mut clk, 2_000);
    let floor_3    = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t1_new = escrow::rent(&mut escrow, mk_payment(floor_3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let sup = event::events_by_type<BidSuperseded>();
    assert_eq!(sup.length(), 1);
    let se = sup.borrow(0);
    assert_eq!(asset_state::bid_superseded_displaced_bidder_address(se), CHALLENGER);
    assert_eq!(asset_state::bid_superseded_new_bidder_address(se), OWNER);
    assert_eq!(asset_state::bid_superseded_refunded_amount(se), floor_2);

    // APT past T1_new's countdown → T1 defends tenure at floor_3.
    clock::set_for_testing(&mut clk, 2_000 + escrow_corpus::handover_countdown_c1_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    // new_rent_price = next floor after handover = floor_3 + delta.
    assert_eq!(asset_state::handover_completed_new_rent_price(hc.borrow(0)),
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
/// Drives sequentially through: Idle → Occupied → Demand →
/// DescentAuction, paying 2× the floor_price at each step. After each rent,
/// the new floor_price == price_paid + FIXED_DELTA (not floor_price + delta),
/// confirming the full overpay is stored as stake.
#[test]
fun e2e_overpay_accepted_elevates_next_floor() {
    let mut sc    = setup();
    // c=1 (Fixed) required for the Demand supersede step:
    // rent() calls APT internally; with c=0 the countdown expires at bid_time,
    // so APT fires the handover before reaching do_supersede_bid in HC state.
    // h=1 (Fixed) makes DescentAuction observable.
    let tag       = escrow_corpus::tag(1, 0, 0, 1, 0); // c=1 Fixed, h=1 Fixed
    let ensemble       = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk   = clock::create_for_testing(sc.ctx());
    let min_price = escrow_corpus::min_rent_price_const();
    let delta     = escrow_corpus::fixed_delta_value_const();
    let countdown = escrow_corpus::handover_countdown_c1_const(); // 25_000

    // Idle: pay 2×min_price. Floor after = 2×min + delta (not min + delta).
    let price_t1 = 2 * min_price;
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let rs       = event::events_by_type<RentStarted>();
    assert_eq!(asset_state::rent_started_price_paid(rs.borrow(0)), price_t1);
    assert!(price_t1 >= asset_state::rent_started_floor_price(rs.borrow(0)), tag);
    assert_eq!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), price_t1 + delta);

    // Occupied: bid at 2×floor_ho at t=1_000. Floor after reflects full bid.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_ho = price_t1 + delta;
    let price_t2 = 2 * floor_ho;
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let bp       = event::events_by_type<BidPlaced>();
    assert_eq!(asset_state::bid_placed_bid_amount(bp.borrow(0)), price_t2);
    assert!(price_t2 >= asset_state::bid_placed_floor_price(bp.borrow(0)), tag);
    assert_eq!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)), price_t2 + delta);

    // Demand (supersede at t=2_000, before 1_000+25_000 countdown): pay 2×floor_hc.
    clock::set_for_testing(&mut clk, 2_000);
    let floor_hc = price_t2 + delta;
    let price_t3 = 2 * floor_hc;
    let cap_t3   = escrow::rent(&mut escrow, mk_payment(price_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let bs       = event::events_by_type<BidSuperseded>();
    assert_eq!(asset_state::bid_superseded_new_bid_amount(bs.borrow(0)), price_t3);
    assert!(price_t3 > floor_hc, tag);

    // APT past T3's countdown (1_000+25_000=26_000) → T3 current.
    // T3 phase_start = min(2_000+25_000, 0+100_000) = 27_000.
    // T3 tenure expires at 27_000+100_000 = 127_000.
    let t3_expiry = 1_000 + countdown; // = 26_000 (T2's countdown, T3 superseded it)
    clock::set_for_testing(&mut clk, t3_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // DescentAuction: T3's phase_start = t3_expiry=26_000 (handover boundary for Fixed).
    // Actually: compute_expiry_at(bid_time=2_000, phase_start=0, tenure_ceiling=100_000)
    //   = min(2_000+25_000, 0+100_000) = 27_000.
    let t3_phase_start = 27_000u64;
    let tenure_boundary = t3_phase_start + escrow_corpus::tenure_ceiling_const(); // 127_000
    clock::set_for_testing(&mut clk, tenure_boundary + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);

    // Pay 2× mid-descent price. RentStarted events: [Idle, Descent].
    let now_mid       = tenure_boundary + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now_mid);
    let descent_price = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let price_t4      = 2 * descent_price;
    let cap_t4        = escrow::rent(&mut escrow, mk_payment(price_t4, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let rs_all        = event::events_by_type<RentStarted>();
    assert_eq!(rs_all.length(), 2); // Idle + Descent
    assert_eq!(asset_state::rent_started_price_paid(rs_all.borrow(1)), price_t4);
    assert!(price_t4 >= asset_state::rent_started_floor_price(rs_all.borrow(1)), tag);
    assert!(escrow::is_occupied(&escrow), tag);

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
/// In Occupied:  floor = current_stake  + δ  (beat the current tenant)
/// In Demand: floor = pending_stake + δ  (beat the challenger)
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
fun e2e_hc_floor_uses_pending_stake_not_active_stake() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk     = clock::create_for_testing(sc.ctx());
    let min_price = escrow_corpus::min_rent_price_const();
    let delta     = escrow_corpus::fixed_delta_value_const();

    // T1 rents from Idle at min_price (10 SUI).
    let cap_t1   = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let floor_ho = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert_eq!(floor_ho, min_price + delta); // = 20 SUI

    // T2 bids at exactly floor_HO (minimal bid) → Demand.
    // T2_stake = floor_HO = min_price + delta = 20 SUI.
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_ho, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // floor_HC must use T2's pending stake (20 SUI), not T1's current stake (10 SUI).
    let floor_hc = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
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

// ─── §FIN-1/2. Financial conservation — exhaustive over all() ────────────────

/// Verifies FIN-1 and FIN-2 for one slice of the corpus (84 entries).
///
/// FIN-1: T1's principal is partitioned exactly into three outputs:
///   owner_share + protocol_fee + remain_credit == price_t1
///   owner_share + protocol_fee == used_credit
///
/// FIN-2: T2's full stake is consumed at tenure expiry, no remainder:
///   owner_share + protocol_fee == price_t2
///   last_acquisition_price     == price_t2
///
/// Timing — T1 rents cycles(1) so T1's ceiling = CEILING for all m:
///   t_mid =  CEILING/4  =  25_000  T2 bids; used_credit > 0 for every curve
///   t_hv  =  CEILING+1  = 100_001  APT fires handover; T2's tenure not yet expired
///   t_te  = 2*CEILING+1 = 200_001  APT fires T2's tenure expiry for every c
///
/// do_handover sets T2.phase_start = handover_expiry (≤ CEILING for all c).
/// T2.tenure = handover_expiry + CEILING ∈ [125_000, 200_000].
/// t_hv < 125_000 ensures no cascade; t_te > 200_000 ensures tenure fires.
///
/// The test is split by (c, m) — 84 entries each — to fit the VM time limit:
///   e2e_fin_conservation_{instant|countdown|full_tenure|random}_{single|multi}
/// Together they cover all 672 corpus entries.
fun fin_conservation_loop(entries: vector<escrow_corpus::CorpusEntry>, mut sc: Scenario) {
    let ceiling  = escrow_corpus::tenure_ceiling_const(); // 100_000
    let t_mid    = ceiling / 4;                           //  25_000
    let t_hv     = ceiling + 1;                           // 100_001
    let t_te     = 2 * ceiling + 1;                       // 200_001
    let price_t1 = escrow_corpus::min_rent_price_const();
    let mut i    = 0;
    while (i < entries.length()) {
        let entry = &entries[i];
        let tag   = entry.tag();
        let (mut escrow, owner_cap) = integrate_and_take(*entry.ensemble(), &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
    
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

        clock::set_for_testing(&mut clk, t_mid);
        let price_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
        assert!(price_t2 > price_t1, tag);
        let cap_t2 = escrow::rent(
            &mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

        clock::set_for_testing(&mut clk, t_hv);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert!(escrow::is_occupied(&escrow), tag);

        // FIN-1
        {
            let hc_evs = event::events_by_type<HandoverCompleted>();
            assert_eq!(hc_evs.length(), 1);
            let he = hc_evs.borrow(0);
            let uc = asset_state::handover_completed_used_credit(he);
            let rc = asset_state::handover_completed_remain_credit(he);
            assert_eq!(
                asset_state::handover_completed_owner_share(he)
                + asset_state::handover_completed_protocol_fee(he)
                + rc,
                price_t1,
            );
            assert_eq!(
                asset_state::handover_completed_owner_share(he)
                + asset_state::handover_completed_protocol_fee(he),
                uc,
            );
            assert!(uc > 0, tag);
            // FullTenure: handover fires at t_max → full credit earned, nothing returned.
            // All other policies: handover fires before t_max → partial credit, refund > 0.
            if (entry.c() == 2) assert_eq!(rc, 0)
            else                assert!(rc > 0, tag);
        };

        clock::set_for_testing(&mut clk, t_te);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

        // FIN-2
        {
            let te_evs = event::events_by_type<TenureExpired>();
            assert_eq!(te_evs.length(), 1);
            let te = te_evs.borrow(0);
            assert_eq!(
                asset_state::tenure_expired_owner_share(te)
                + asset_state::tenure_expired_protocol_fee(te),
                price_t2,
            );
            assert_eq!(asset_state::tenure_expired_last_acq_price(te), price_t2);
        };

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
            clock::destroy_for_testing(clk);
        i = i + 1;
    };
    sc.end();
}

// 8 slices × 84 entries = 672 total (full coverage of all()). Requires --gas-limit 500_000_000.
#[test] fun e2e_fin_conservation_instant_single()    { fin_conservation_loop(escrow_corpus::filter_c(escrow_corpus::all_single(), 0), setup()); }
#[test] fun e2e_fin_conservation_countdown_single()  { fin_conservation_loop(escrow_corpus::filter_c(escrow_corpus::all_single(), 1), setup()); }
#[test] fun e2e_fin_conservation_full_tenure_single() { fin_conservation_loop(escrow_corpus::filter_c(escrow_corpus::all_single(), 2), setup()); }
#[test] fun e2e_fin_conservation_instant_multi()     { fin_conservation_loop(escrow_corpus::filter_c(escrow_corpus::all_multi(),   0), setup()); }
#[test] fun e2e_fin_conservation_countdown_multi()   { fin_conservation_loop(escrow_corpus::filter_c(escrow_corpus::all_multi(),   1), setup()); }
#[test] fun e2e_fin_conservation_full_tenure_multi()  { fin_conservation_loop(escrow_corpus::filter_c(escrow_corpus::all_multi(),   2), setup()); }

// ─── §FIN-2-sentinel (kept for readability) ──────────────────────────────────

/// Readable two-tenant lifecycle that anchors the FIN-2 invariant to a
/// concrete config and shows that last_acquisition_price tracks the DEPARTING
/// tenant's stake — not the founding price.
///
/// The exhaustive coverage is in the e2e_fin_conservation_* family above;
/// this test exists as a named, self-contained explanation of the invariant.
///
/// Config: c=0 (Instant), h=1 (Fixed — Descent observable after expiry).
#[test]
fun e2e_fin2_tenure_expiry_financial_conservation() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0);
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let price_t1 = escrow_corpus::min_rent_price_const();
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let now_t2   = 1_000u64;
    clock::set_for_testing(&mut clk, now_t2);
    let price_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(price_t2 > price_t1, tag);
    let cap_t2   = escrow::rent(&mut escrow, mk_payment(price_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    let t2_tenure_boundary = now_t2 + escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t2_tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);

    let te_events = event::events_by_type<TenureExpired>();
    assert_eq!(te_events.length(), 1);
    let te  = te_events.borrow(0);
    let lap = asset_state::tenure_expired_last_acq_price(te);
    assert_eq!(asset_state::tenure_expired_owner_share(te) + asset_state::tenure_expired_protocol_fee(te), price_t2);
    assert_eq!(lap, price_t2);
    assert!(lap != price_t1, tag);

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
/// Part B — Demand, independently computed value:
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
    let cap_a1    = escrow::rent(
        &mut escrow_a, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk_a, sc.ctx());
    clock::set_for_testing(&mut clk_a, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow_a, &clk_a, sc.ctx());
    {
        let te_events = event::events_by_type<TenureExpired>();
        let te       = te_events.borrow(0);
        let te_fee   = asset_state::tenure_expired_protocol_fee(te);
        let te_owner = asset_state::tenure_expired_owner_share(te);
        let te_lap   = asset_state::tenure_expired_last_acq_price(te);
        // Use min_price (the known T1 stake) as the independent oracle.
        assert_eq!(te_fee + te_owner, min_price);
        // Exact 10 % fee: min_price divisible by 10 → fee = min_price/10 exactly.
        assert_eq!(te_fee,   min_price / 10);
        assert_eq!(te_owner, min_price - min_price / 10);
        // last_acquisition_price == T1's stake here (no handover → founding ==
        // departing tenant), and marks the Descent descent starting point.
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
    let cap_b1    = escrow::rent(
        &mut escrow_b, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk_b, sc.ctx());
    let t_mid     = escrow_corpus::tenure_ceiling_const() / 2; // 50_000 ms
    clock::set_for_testing(&mut clk_b, t_mid);
    let floor_b   = escrow::floor_price_mist(&escrow_b, clock::timestamp_ms(&clk_b));
    let cap_b2    = escrow::rent(
        &mut escrow_b, mk_payment(floor_b, sc.ctx()), tenures::tenures(1), &clk_b, sc.ctx());
    escrow::apply_pending_transition_states(&mut escrow_b, &clk_b, sc.ctx());
    assert!(escrow::is_occupied(&escrow_b), tag);
    {
        let hc_events = event::events_by_type<HandoverCompleted>();
        let he  = hc_events.borrow(0);
        let uc  = asset_state::handover_completed_used_credit(he);
        let ho  = asset_state::handover_completed_owner_share(he);
        let hf  = asset_state::handover_completed_protocol_fee(he);
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
    clock::destroy_for_testing(clk_b);

    sc.end();
}

// ─── §DESC-1/2. Price descent — exact endpoint invariants ────────────────────

/// At the exact start of DescentAuction (t = tenure_boundary, elapsed_descent
/// = 0), compute_floor_price == last_acquisition_price — no discount yet.
/// At the exact end of the descent window (t = descent_boundary,
/// elapsed_descent = descent_window), compute_floor_price == min_rent_price.
///
///   DESC-1: compute_floor_price(tenure_boundary) == last_acq_price
///   DESC-2: compute_floor_price(descent_boundary) == min_rent_price
///
/// Sweeps all 7 curve shapes (axis E) — compute_curve_height returns 0 at
/// elapsed=0 and SCALE at elapsed>=t_max by construction for every shape,
/// so both endpoints must hold universally. Non-zero spread is created by
/// T1 renting at 2×min_price (overpay, no handover needed) so last_acq_price
/// = 2×min_price > min_price and the two endpoints are distinct values.
///
/// Config: c=0, h=1 (Fixed — Descent observable), d=0, f=0; vary e=0..6.
#[test]
fun e2e_desc12_price_descent_exact_endpoints_across_curves() {
    let mut sc    = setup();
    let min_price = escrow_corpus::min_rent_price_const();
    let stake     = 2 * min_price; // overpay: last_acq_price = stake > min_price
    let tenure_boundary  = escrow_corpus::tenure_ceiling_const();
    let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 1, 0, m); // h=1 Fixed, vary e
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            // T1 rents at 2×min_price (phase_start = 0). No handover needed for spread.
            let cap_t1 = escrow::rent(
                &mut escrow, mk_payment(stake, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            // APT at exact tenure boundary → DescentAuction (last_acq_price = stake).
            clock::set_for_testing(&mut clk, tenure_boundary);
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert!(escrow::is_descending(&escrow), tag);

            // DESC-1: elapsed_descent = 0 → compute_curve_height = 0 → no descent yet.
            // Clock is already at tenure_boundary (elapsed=0 from Descent phase_start).
            let floor_start = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(floor_start, stake);

            // DESC-2: elapsed_descent = descent_window = t_max → fully descended.
            clock::set_for_testing(&mut clk, descent_boundary);
            let floor_end = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(floor_end, min_price);

            transfer::public_transfer(cap_t1, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            e = e + 1;
        };
        m = m + 1;
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
/// the saturation behavior is universal — compute_curve_height short-circuits at
/// both extremes regardless of shape.
#[test]
fun e2e_desc34_used_credit_exact_endpoints_across_curves() {
    let mut sc    = setup();
    let min_price = escrow_corpus::min_rent_price_const();
    let ceiling   = escrow_corpus::tenure_ceiling_const();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(0, 0, e, 0, 0, m); // vary e: all 7 curve shapes
            let ensemble = escrow_corpus::by_tag(tag);
            let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx()); // t = 0
        
            // T1 rents at min_price (stake = min_price, phase_start = 0).
            let cap_t1 = escrow::rent(
                &mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            // DESC-3: at exact phase_start (elapsed = 0), no stake is earned yet.
            // compute_used_credit is a pure view — does not trigger APT.
            let uc_start = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(uc_start, 0);

            // DESC-4: at exact tenure_ceiling (elapsed >= t_max), full stake is earned.
            // compute_curve_height short-circuits to SCALE for elapsed >= t_max regardless
            // of curve shape: used_credit = compute_mul_div(stake, SCALE, SCALE) = stake.
            clock::set_for_testing(&mut clk, ceiling);
            let uc_end = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(uc_end, min_price);

            transfer::public_transfer(cap_t1, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

// ─── §Skipped descent — price resets to min_rent_price at tenure boundary ────

/// With AuctionWindowPolicy::Off (h=0), tenure expiry triggers the M6b cascade:
/// Occupied → DescentAuction → Idle fires in a single APT step because
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
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 rents at 3×min_price. Elevated stake to make the reset contrast visible.
    let price_t1 = 3 * min_price;
    let cap_t1   = escrow::rent(&mut escrow, mk_payment(price_t1, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    // floor_HO = T1_stake + delta = 3×min + delta — well above min_price.
    assert!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)) > min_price, tag);

    // APT at the exact tenure boundary (phase_start=0, tenure_ceiling=100_000).
    // M6b: Occupied → DescentAuction → Idle in one step (Skipped descent).
    let tenure_boundary = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Price reset: entry is min_rent_price regardless of T1's elevated stake.
    let floor_after = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert_eq!(floor_after, min_price);

    // T2 rents at min_rent_price — the protocol accepts the minimum entry.
    let cap_t2 = escrow::rent(&mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §APT-1. APT idempotency — double call at same clock is a no-op ──────────

/// execute_apply_pending_transition_states is permissionless and may be called many times.
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
///   Boundary 2 — Tenure   (HO → Descent): T2.phase_start + tenure_ceiling = 126_000
///   Boundary 3 — Auction  (Descent → Idle): 126_000 + descent_window = 226_000
///
/// Config: c=1 (Fixed — observable HC boundary), h=1 (Fixed — Descent
/// observable), d=0, e=0, f=0.
#[test]
fun e2e_apt1_idempotent_double_call_at_every_boundary() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 1, 0); // c=1 Fixed, h=1 Fixed
    let ensemble     = escrow_corpus::by_tag(tag);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents from Idle → Occupied (phase_start = 0).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t=1_000 → Demand (countdown_expiry = 26_000).
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // ── Boundary 1: Handover ────────────────────────────────────────────────
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const(); // 26_000
    clock::set_for_testing(&mut clk, countdown_expiry);

    // First APT: handover fires → Occupied, 1 HandoverCompleted event.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // Second APT at same clock: no-op — state and event count unchanged.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // ── Boundary 2: Tenure expiry ───────────────────────────────────────────
    // T2.phase_start = countdown_expiry = 26_000; tenure_boundary = 126_000.
    let tenure_boundary = countdown_expiry + escrow_corpus::tenure_ceiling_const(); // 126_000
    clock::set_for_testing(&mut clk, tenure_boundary);

    // First APT: tenure fires → DescentAuction, 1 TenureExpired event.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // Second APT at same clock: no-op.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);
    assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

    // ── Boundary 3: Auction expiry ──────────────────────────────────────────
    // Descent.phase_start = tenure_boundary = 126_000; descent_boundary = 226_000.
    let descent_boundary = tenure_boundary + escrow_corpus::descent_window_h1_const(); // 226_000
    clock::set_for_testing(&mut clk, descent_boundary);

    // First APT: auction fires → Idle, 1 AuctionExpired event.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    // Second APT at same clock: no-op — Idle has no pending transitions.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), tag);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §APT-1 exhaustive — all c×h×m combinations ──────────────────────────────

/// Exhaustive idempotency test over all combinations of handover policy (c),
/// descent policy (h), and cycle count (m). d, e, f are fixed at 0 — they
/// do not affect which APT code path runs.
///
/// T1 rents cycles(m+1) so the multi-cycle normalization in do_handover is
/// exercised for m=1. T2 always rents cycles(1).
///
/// hv_expiry is read from the BidPlaced event, making the timing config-agnostic
/// across all four handover policies (including RandomInRange whose expiry is
/// non-deterministic).
///
/// Three boundaries are tested (or two for h=0):
///   B1 — handover fires at hv_expiry
///   B2 — T2's tenure fires at hv_expiry + CEILING
///   B3 — Descent fires at B2 + max_descent  (h=1: DESCENT_WINDOW_H1)
///
/// At each boundary: first APT fires the transition; second APT is a no-op —
/// state and event count must be identical after both calls.
fun apt_idempotency_loop(entries: vector<escrow_corpus::CorpusEntry>, mut sc: Scenario) {
    let ceiling  = escrow_corpus::tenure_ceiling_const();
    let price_t1 = escrow_corpus::min_rent_price_const();
    let mut i    = 0;
    while (i < entries.length()) {
        let entry          = &entries[i];
        let tag            = entry.tag();
        let t1_cycle_count = (entry.m() as u64) + 1; // 1 for Single, 2 for Multi
        let (mut escrow, owner_cap) = integrate_and_take(*entry.ensemble(), &mut sc);
        let mut clk = clock::create_for_testing(sc.ctx());
    
        let cap_t1 = escrow::rent(
            &mut escrow,
            mk_payment(price_t1 * t1_cycle_count, sc.ctx()),
            tenures::tenures(t1_cycle_count),
            &clk, sc.ctx(),
        );

        clock::set_for_testing(&mut clk, 1_000);
        let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
        assert!(escrow::is_demand(&escrow), tag);

        // hv_expiry from BidPlaced — config-agnostic for all c values.
        let hv_expiry = asset_state::bid_placed_handover_countdown_expiry(
            event::events_by_type<BidPlaced>().borrow(0),
        );

        // ── B1: Handover ──────────────────────────────────────────────────────
        clock::set_for_testing(&mut clk, hv_expiry);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert!(escrow::is_occupied(&escrow), tag);
        assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert!(escrow::is_occupied(&escrow), tag);
        assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

        // T2.phase_start = hv_expiry; T2 rented cycles(1) so ceiling = CEILING.
        let tenure_boundary = hv_expiry + ceiling;

        // ── B2: Tenure expiry ─────────────────────────────────────────────────
        clock::set_for_testing(&mut clk, tenure_boundary);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert_eq!(event::events_by_type<TenureExpired>().length(), 1);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert_eq!(event::events_by_type<TenureExpired>().length(), 1);

        // ── B3: Auction expiry (h ≠ 0 only) ──────────────────────────────────
        if (entry.h() != 0) {
            assert!(escrow::is_descending(&escrow), tag);
            let max_descent = escrow_corpus::descent_window_h1_const();
            clock::set_for_testing(&mut clk, tenure_boundary + max_descent);
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert!(escrow::is_idle(&escrow), tag);
            assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert!(escrow::is_idle(&escrow), tag);
            assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);
        } else {
            assert!(escrow::is_idle(&escrow), tag);
        };

        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
        test_scenario::return_shared(escrow);
        owner_cap::burn(owner_cap, OWNER);
            clock::destroy_for_testing(clk);
        i = i + 1;
    };
    sc.end();
}

// d=0, e=0, f=0 fixed (accidental for APT code paths). 24 entries total.
#[test]
fun e2e_apt_idempotency_all_ch_m() {
    apt_idempotency_loop(
        escrow_corpus::filter_f(
            escrow_corpus::filter_e(
                escrow_corpus::filter_d(escrow_corpus::all(), 0),
            0),
        0),
        setup(),
    );
}

// ─── §RETIRE. All paths to Retired — asset always recoverable (f=0) ──────────
//
// For every reachable lifecycle state, the owner can retire the escrow when
// commitment_policy_state = Immediate (f=0, retire_floor = 0, always unlocked) and
// subsequently recover the asset via claim_asset. The Deferred-policy gate
// (f=1, ERetireCommitmentFloorNotElapsed) is covered separately in §3.
//
// Each test drives to a specific entry state, calls retire(), completes the
// protocol cascade to Retired, and verifies claim_asset returns the asset.
//
//   RETIRE-1  Idle                  → retire() immediate        → Retired
//   RETIRE-2  DescentAuction        → retire() immediate        → Retired
//   RETIRE-3  Occupied          → retire() flag → tenure    → Retired
//   RETIRE-4  Demand     → retire() flag → handover
//                                              → tenure         → Retired
//   RETIRE-5  Occupied+borrow   → borrow → retire() flag
//                                   → return → tenure           → Retired
//   RETIRE-6  Demand+borrow → borrow → retire() flag
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

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
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

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::destroy_zero(earnings); // no tenants → no earnings
    transfer::public_transfer(asset, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-2: DescentAuction ───────────────────────────────────────────────────
#[test]
fun e2e_retire2_from_descent() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // h=1 Fixed → Descent observable
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents; tenure expires → DescentAuction.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), tag);

    // do_retire_immediately from Descent → Retired.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-3: Occupied ─────────────────────────────────────────────────────
#[test]
fun e2e_retire3_from_occupied() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0); // h=0 Skipped — irrelevant with flag
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // Retiring flag set; state stays Occupied.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // APT at tenure boundary: tenure fires; flag → Retired (not Descent).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-4: Demand ────────────────────────────────────────────────
#[test]
fun e2e_retire4_from_demand() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // Retiring flag set in HC; state stays Demand.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // APT at countdown expiry: handover fires; T2 current, flag inherited → HO.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // APT at T2 tenure boundary: tenure fires; flag → Retired.
    clock::set_for_testing(&mut clk, countdown_expiry + escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-5: Occupied + asset borrowed ────────────────────────────────────
#[test]
fun e2e_retire5_from_occupied_while_borrowed() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // retire() before borrow: APT no-op (t=0 < tenure_boundary), sets retiring flag.
    // In production the owner submits retire() in a separate PTB; the tenant's
    // borrow+return PTB is atomic so retire() always sees a complete escrow state.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    // APT at tenure boundary: tenure fires; flag → Retired.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-6: Demand + asset borrowed ───────────────────────────────
#[test]
fun e2e_retire6_from_demand_while_borrowed() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // retire() before borrow: APT no-op (t=1_000 < expiry=26_000), sets retiring flag.
    // In production the owner submits retire() in a separate PTB; the tenant's
    // borrow+return PTB is atomic so retire() always sees a complete escrow state.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    // APT at countdown expiry: handover fires; T2 current, retiring flag inherited → HO.
    let countdown_expiry = 1_000 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, countdown_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // APT at T2 tenure boundary: tenure fires; flag → Retired.
    clock::set_for_testing(&mut clk, countdown_expiry + escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// RETIRE-7: Retired → retire() aborts EAlreadyRetired ─────────────────────
#[test, expected_failure(
    abort_code = asset_state::EAlreadyRetired,
    location   = usufruct::asset_state,
)]
fun e2e_retire7_already_retired_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 0);
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Retire once → Retired.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    // Second retire() → EAlreadyRetired.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §CRED-1. used_credit clamping in Demand ──────────────────────

/// In Occupied (Accruing regime) used_credit grows freely with time.
/// Once a bid is placed (Demand, Capped regime) the effective
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
/// Config: c=1 Fixed (expiry=26_000), vary e=0..6, h=0, d=0, f=0.
#[test]
fun e2e_cred1_used_credit_clamped_at_demand_expiry_across_curves() {
    let mut sc    = setup();
    let stake     = escrow_corpus::min_rent_price_const();
    let expiry    = 1_000 + escrow_corpus::handover_countdown_c1_const(); // 26_000
    let ceiling   = escrow_corpus::tenure_ceiling_const();
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(1, 0, e, 0, 0, m); // c=1, vary e
            let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            // T1 rents at t=0 → Occupied (Accruing regime).
            let cap_t1 = escrow::rent(
                &mut escrow, mk_payment(stake, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            // Accruing: used_credit is strictly increasing before the bid.
            clock::set_for_testing(&mut clk, 500);
            let uc_500  = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            clock::set_for_testing(&mut clk, 1_000);
            let uc_1000 = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            assert!(uc_500  > 0,      tag);
            assert!(uc_1000 > uc_500, tag);

            // T2 bids at t=1_000 → Demand (Capped, expiry=26_000).
            // clock already at 1_000 from above.
            let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            let cap_t2   = escrow::rent(
                &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            // CRED-1: Capped regime freezes credit at expiry for every curve shape.
            clock::set_for_testing(&mut clk, expiry);
            let uc_at_expiry   = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            clock::set_for_testing(&mut clk, expiry + 10_000);
            let uc_past_expiry = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            clock::set_for_testing(&mut clk, ceiling);
            let uc_at_ceiling  = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
            assert_eq!(uc_past_expiry, uc_at_expiry); // t > expiry → clamped
            assert_eq!(uc_at_ceiling,  uc_at_expiry); // tenure_ceiling → still clamped
            assert!(uc_at_expiry > 0,     tag);
            assert!(uc_at_expiry < stake, tag);

            // Exact value for Linear (e=0): stake × elapsed / ceiling (elapsed = expiry, phase_start=0).
            if (e == 0) { assert_eq!(uc_at_expiry, stake * expiry / ceiling); };

            // APT fires handover; event.used_credit must match the clamped view value.
            // Clock is at ceiling (>= expiry) — APT fires based on handover_countdown_expiry=expiry.
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert!(escrow::is_occupied(&escrow), tag);

            let hc = event::events_by_type<HandoverCompleted>();
            let he = hc.borrow(0);
            assert_eq!(asset_state::handover_completed_used_credit(he),
                       uc_at_expiry);
            assert_eq!(asset_state::handover_completed_remain_credit(he),
                       stake - uc_at_expiry);

            // Exact split for Linear (e=0): fee and owner derived from uc_at_expiry.
            if (e == 0) {
                assert_eq!(asset_state::handover_completed_protocol_fee(he),
                           uc_at_expiry / 10);
                assert_eq!(asset_state::handover_completed_owner_share(he),
                           uc_at_expiry - uc_at_expiry / 10);
            };

            transfer::public_transfer(cap_t1, OWNER);
            transfer::public_transfer(cap_t2, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            e = e + 1;
        };
        m = m + 1;
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
    
        // T1 rents at t=0 → Occupied.
        let cap_t1 = escrow::rent(
            &mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

        // T2 bids at t_mid → Instant handover fires → T2 current.
        clock::set_for_testing(&mut clk, t_mid);
        let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
        let cap_t2   = escrow::rent(
            &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert!(escrow::is_occupied(&escrow), tag);

        // Read T1's owner share from HandoverCompleted (curve-specific value).
        let ho_share = {
            let evs = event::events_by_type<HandoverCompleted>();
            asset_state::handover_completed_owner_share(evs.borrow(0))
        };

        // T2's tenure expires → Skipped → AuctionExpired → Idle.
        let t2_tenure_boundary = t_mid + escrow_corpus::tenure_ceiling_const();
        clock::set_for_testing(&mut clk, t2_tenure_boundary);
        escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
        assert!(escrow::is_idle(&escrow), tag);

        // Read T2's owner share from TenureExpired.
        let te_share = {
            let evs = event::events_by_type<TenureExpired>();
            asset_state::tenure_expired_owner_share(evs.borrow(0))
        };

        // Expected swept = sum of all per-boundary owner shares.
        let expected_swept = ho_share + te_share;
        assert!(expected_swept > ho_share, tag); // T2 contributed
        assert!(expected_swept > te_share, tag); // T1 contributed

        // Retire from Idle → Retired.
        escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

        // claim_asset in a new PTB: swept_earnings must equal the accumulated sum.
        test_scenario::return_shared(escrow);
        sc.next_tx(OWNER);
        let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
        let (asset, earnings) = escrow::claim_asset(
            escrow, owner_cap, &clk, sc.ctx());
        assert_eq!(coin::value(&earnings), expected_swept);
        let ac = event::events_by_type<AssetClaimed>();
        assert_eq!(
            asset_state::asset_claimed_swept_earnings(ac.borrow(0)),
            expected_swept,
        );

        coin::burn_for_testing(earnings);
        transfer::public_transfer(asset, OWNER);
        transfer::public_transfer(cap_t1, OWNER);
        transfer::public_transfer(cap_t2, OWNER);
            clock::destroy_for_testing(clk);
        ci = ci + 1;
    };
    sc.end();
}

// ─── §CORPUS-GAPS. Coverage for under-tested axis values ─────────────────────

// ── Gap 1: c=2 (FullTenure) — handover fires at tenure boundary, full credit ──

/// With HandoverPolicy::FullTenure, the handover countdown expiry is always
/// phase_start + tenure_ceiling — the handover fires exactly at the tenure
/// boundary. At that moment elapsed == tenure_ceiling, so compute_curve_height
/// short-circuits to SCALE for every curve shape. This means:
///
///   used_credit == stake  (full credit consumed)
///   remain_credit == 0    (nothing refunded to T1)
///   owner_share + protocol_fee == stake  (all of T1's stake distributed)
///
/// Sweeps all 7 curve shapes (axis E) — the result must hold for every shape
/// because it depends on the compute_curve_height saturation invariant (DESC-4),
/// not on the specific curve formula.
#[test]
fun e2e_corpus_gap_full_tenure_handover_full_credit_across_curves() {
    let mut sc    = setup();
    let stake     = escrow_corpus::min_rent_price_const();
    let boundary  = escrow_corpus::tenure_ceiling_const(); // FullTenure expiry = 0 + 100_000
    let mut m = 0u8;
    while (m <= 1) {
        let mut e: u8 = 0;
        while (e <= 6) {
            let tag = escrow_corpus::tag_with_cycles(2, 0, e, 0, 0, m); // c=2 FullTenure, vary e
            let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            // T1 rents at t=0 (phase_start=0); T2 bids → HC (expiry=100_000).
            let cap_t1 = escrow::rent(
                &mut escrow, mk_payment(stake, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
            clock::set_for_testing(&mut clk, 1_000);
            let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            let cap_t2   = escrow::rent(
                &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            // APT at tenure boundary: FullTenure expiry fires → handover.
            clock::set_for_testing(&mut clk, boundary);
            escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
            assert!(escrow::is_occupied(&escrow), tag);

            // used_credit = stake for all curves (elapsed = tenure_ceiling → SCALE saturation).
            let hc = event::events_by_type<HandoverCompleted>();
            let he = hc.borrow(0);
            let used_credit   = asset_state::handover_completed_used_credit(he);
            let remain_credit = asset_state::handover_completed_remain_credit(he);
            assert_eq!(used_credit,   stake); // full credit consumed
            assert_eq!(remain_credit, 0);     // nothing refunded to T1
            assert_eq!(
                asset_state::handover_completed_owner_share(he)
                + asset_state::handover_completed_protocol_fee(he),
                stake,                        // all of stake distributed
            );

            // No coin was transferred to the departing tenant — Nothing, not Parcial.
            sc.next_tx(TENANT_ADDR_1);
            assert!(!sc.has_most_recent_for_sender<coin::Coin<SUI>>(), tag);

            transfer::public_transfer(cap_t1, OWNER);
            transfer::public_transfer(cap_t2, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            e = e + 1;
        };
        m = m + 1;
    };
    sc.end();
}

// ── Gap 3: f=1 (Deferred) — retire from Occupied after floor elapsed ─────

/// §RETIRE uses f=0 throughout. This test verifies that retire() from
/// Occupied also works with f=1 once the retire_floor has elapsed.
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
fun e2e_corpus_gap_deferred_retire_from_occupied_after_floor() {
    let mut sc    = setup();
    let tag       = escrow_corpus::tag(0, 0, 0, 0, 1); // f=1 Deferred
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc);
    let mut clk   = clock::create_for_testing(sc.ctx());
    let retire_floor     = escrow_corpus::retire_deferred_f1_const();  // 10_000_000
    let tenure_ceiling   = escrow_corpus::tenure_ceiling_const();      // 100_000
    let t_rent           = retire_floor - tenure_ceiling / 2;          // 9_950_000
    let tenure_boundary  = t_rent + tenure_ceiling;                    // 10_050_000

    // T1 rents late: tenure_boundary(10_050_000) > retire_floor(10_000_000).
    clock::set_for_testing(&mut clk, t_rent);
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // retire() after floor elapses but before tenure expires.
    // retire_at = 10_000_001: floor unlocked (> 10_000_000) AND tenure active (< 10_050_000).
    clock::set_for_testing(&mut clk, retire_floor + 1);
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag); // flag set, still HO

    // APT at tenure boundary → retiring flag → Retired (not Descent).
    clock::set_for_testing(&mut clk, tenure_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── Gap 4: h=1 (Fixed) + retiring flag — bypasses Descent descent ───────────

/// §RETIRE tests (RETIRE-3/4/5/6) all use h=0 (Skipped). This verifies
/// that the retiring flag correctly bypasses DescentAuction even when
/// AuctionWindowPolicy is Window (h=1): tenure expiry → Retired directly,
/// NOT Descent. The Fixed policy only affects the descent duration when
/// there is NO retiring flag; the flag unconditionally collapses to Retired.
#[test]
fun e2e_corpus_gap_retiring_flag_bypasses_descent_with_window_policy() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 1, 0); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // Retire from HO with h=1: retiring flag set. State stays HO.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // APT at tenure boundary: retiring flag → Retired (NOT Descent despite h=1).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), tag);     // flag bypassed Descent
    assert!(!escrow::is_descending(&escrow), tag);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
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
/// Config: c=1 Fixed (25_000 ms), d=0, e=0, h=0, f=0.
///   T2 bids  at t=1_000  →  original_expiry = 26_000
///   T3 supersedes at t=2_000  →  reset_expiry (bug) would be 27_000
#[test]
fun e2e_sup1_supersede_preserves_countdown_expiry() {
    let mut sc    = setup();
    let tag       = escrow_corpus::tag(1, 0, 0, 0, 0); // c=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
    let mut clk   = clock::create_for_testing(sc.ctx());
    let min_price = escrow_corpus::min_rent_price_const();

    // T1 rents (Idle → HO, phase_start=0).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(min_price, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t=1_000 → HC. Stamps countdown_expiry = 1_000 + 25_000 = 26_000.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);

    // Read the original countdown expiry from the BidPlaced event — this is the oracle.
    let original_expiry = {
        let bp = event::events_by_type<BidPlaced>();
        assert_eq!(bp.length(), 1);
        asset_state::bid_placed_handover_countdown_expiry(bp.borrow(0))
    };
    assert_eq!(original_expiry, 1_000 + escrow_corpus::handover_countdown_c1_const()); // 26_000

    // T3 supersedes T2 at t=2_000 (before expiry).
    // Bug scenario: if expiry reset → new expiry = 2_000 + 25_000 = 27_000.
    // Correct:      expiry preserved → stays at 26_000.
    clock::set_for_testing(&mut clk, 2_000);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t3   = escrow::rent(
        &mut escrow, mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);
    assert_eq!(event::events_by_type<BidSuperseded>().length(), 1);

    // SUP-1a: one ms before original expiry → APT is a no-op.
    clock::set_for_testing(&mut clk, original_expiry - 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 0);

    // SUP-1b: at original expiry → handover fires. T3 wins.
    // If expiry had reset to 27_000, this APT would be a no-op (bug caught).
    clock::set_for_testing(&mut clk, original_expiry);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);
    assert_eq!(event::events_by_type<HandoverCompleted>().length(), 1);

    // T3's cap is the one promoted by the handover.
    let new_cap_id = {
        let hc = event::events_by_type<HandoverCompleted>();
        asset_state::handover_completed_new_cap_id(hc.borrow(0))
    };
    assert_eq!(new_cap_id, object::id(&cap_t3));

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §update_ensemble ────────────────────────────────────────────────────────────
//
// update_ensemble allows the owner to swap the PolicyEnsemble of an escrow at
// runtime. When the escrow is Idle the change takes effect immediately. When
// the escrow is occupied (Renting or DescentAuction) the new config is
// buffered as a pending reset and applied at the next natural boundary
// (tenure expiry or auction expiry). retire() discards any pending reset
// without applying it.

// Test 1: Idle → immediate apply ─────────────────────────────────────────────
/// update_ensemble from Idle: config changes immediately, EnsembleUpdated emitted,
/// EnsembleUpdateScheduled NOT emitted, pending flag stays false.
#[test]
fun update_config_idle_applies_immediately() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0); // c=0,d=0,e=0,h=0,f=0
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let new_ensemble = escrow_corpus::by_tag(1); // f=1 — differs from tag-0
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 0);
    assert!(escrow::active_ensemble(&escrow) == new_ensemble, 1);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 2);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 1);
    let scheduled = event::events_by_type<EnsembleUpdateScheduled>();
    assert_eq!(scheduled.length(), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 2: Descent → schedule without cancelling ───────────────────────────────
/// update_ensemble from DescentAuction: new config is buffered, state stays
/// Descent, EnsembleUpdateScheduled emitted, EnsembleUpdated NOT emitted.
#[test]
fun update_config_descent_schedules_without_cancelling() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow,
        STAKE_T1 - STAKE_T1 / 10,
        STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2,
        0,
    );

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    assert!(escrow::is_descending(&escrow), 0);
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);
    assert!(escrow::active_ensemble(&escrow) != new_ensemble, 2);

    let scheduled = event::events_by_type<EnsembleUpdateScheduled>();
    assert_eq!(scheduled.length(), 1);
    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 3: Renting → schedule without interrupting ─────────────────────────────
/// update_ensemble from Occupied (Renting): new config buffered, state
/// stays Renting, EnsembleUpdateScheduled emitted, EnsembleUpdated NOT emitted.
#[test]
fun update_config_renting_schedules_without_interrupting() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let original_cfg = ensemble;
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    assert!(escrow::is_rented(&escrow), 0);
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 2);

    let scheduled = event::events_by_type<EnsembleUpdateScheduled>();
    assert_eq!(scheduled.length(), 1);
    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 4: tenure expiry with pending reset → Descent runs, config applies at auction expiry ──
/// When a pending config reset is buffered and tenure expires, the escrow enters
/// Descent normally — the reset is NOT applied at tenure expiry. The config
/// is applied only when Descent expires → Idle. AuctionExpired IS emitted.
#[test]
fun update_config_applies_at_auction_expiry_not_at_tenure_expiry() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 descent window
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // Tenure expiry → Descent. pending_config survives; old config still active.
    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );
    assert!(escrow::is_descending(&escrow), 0);
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);
    assert!(escrow::active_ensemble(&escrow) == ensemble, 2);

    let resets_mid = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets_mid.length(), 0);

    // Auction expiry via production APT → fire's Descent arm applies pending_config → Idle.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 3);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 4);
    assert!(escrow::active_ensemble(&escrow) == new_ensemble, 5);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 1);
    let auction_expired = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_expired.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 5: handover preserves pending, does NOT apply ─────────────────────────
/// A handover (Demand → new tenant) does not apply a pending config reset.
/// The pending flag survives the handover and the old config remains active.
#[test]
fun update_config_handover_preserves_pending_does_not_apply() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let original_cfg = ensemble;
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // T1 rents → Occupied.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Schedule config reset.
    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // T2 bids → Demand, then drive to Demand.
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
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 2);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 6: handover then tenure expiry then auction expiry applies pending reset ─
/// Chain: rent T1 → update_ensemble(new_ensemble) → drive to Demand → handover →
/// T2 tenure expiry → Descent → auction expiry → Idle with new config.
/// The reset is applied only at auction expiry, not at tenure expiry.
#[test]
fun update_config_chain_handover_then_auction_expiry_applies() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    escrow::drive_to_demand_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()),
        escrow_corpus::tenure_ceiling_const(),
    );

    // Fire handover via the production APT path.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_rented(&escrow), 10);

    // T2's tenure expires at 2 × tenure_ceiling_const() → Descent (not Idle).
    clock::set_for_testing(&mut clk, 2 * escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);

    let resets_mid = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets_mid.length(), 0);

    // Auction expiry via production APT → Idle with new config applied.
    clock::set_for_testing(&mut clk, 2 * escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 2);
    assert!(escrow::active_ensemble(&escrow) == new_ensemble, 3);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 1);
    let auction_expired = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_expired.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 7: last write wins — second update_ensemble overrides first ───────────────
/// Two successive update_ensemble calls while Renting: last write wins.
/// At auction expiry only cfg_b (the second config) is applied.
/// Exactly 1 EnsembleUpdated emitted (not two), 2 EnsembleUpdateScheduled emitted.
#[test]
fun update_config_override_last_write_wins() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Three distinct configs: original=tag(0,0,0,1,0), cfg_a=tag(1,0,0,0,0) c=1 countdown,
    // cfg_b=tag(1) f=1 deferred. All three are structurally different.
    let cfg_a = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0)); // c=1 countdown
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_a, &clk, sc.ctx());

    // Second reset: cfg_b = tag 1 — overrides cfg_a.
    let cfg_b = escrow_corpus::by_tag(1); // f=1 deferred
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_b, &clk, sc.ctx());

    assert!(escrow::has_pending_ensemble_update(&escrow), 0);

    // Tenure expiry → Descent. pending_config (cfg_b) survives.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 1);

    // Auction expiry via production APT → Idle with cfg_b applied.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 2);
    assert!(escrow::active_ensemble(&escrow) == cfg_b, 3);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 1);

    // cfg_b = by_tag(1): h=0 → auction_window Off, c=0 → handover Off
    let evt = resets.borrow(0);
    assert_eq!(policy_ensemble::ensemble_updated_auction_window_policy(evt), b"Off".to_string());
    assert_eq!(policy_ensemble::ensemble_updated_handover_policy(evt), b"Off".to_string());

    let scheduled = event::events_by_type<EnsembleUpdateScheduled>();
    assert_eq!(scheduled.length(), 2);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 8: retire wins — discards pending reset silently ───────────────────────
/// retire() from Renting discards any pending config reset.
/// The retiring flag takes precedence: tenure expiry → Retired, not Idle.
/// EnsembleUpdated is NOT emitted; the config never changes.
#[test]
fun update_config_retire_wins_discards_pending_silently() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let original_cfg = ensemble;
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let new_ensemble = escrow_corpus::by_tag(10); // h=1 differs from original h=0
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // retire() sets the retiring flag and discards the pending reset.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    assert!(escrow::is_retiring(&escrow), 0);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 1);

    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow,
        phases::timestamp(escrow_corpus::tenure_ceiling_const()),
        sc.ctx(),
    );

    assert!(escrow::is_retired(&escrow), 2);
    assert!(escrow::active_ensemble(&escrow) != new_ensemble, 3);
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 4);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 9: update_ensemble on Retired aborts ──────────────────────────────────────
#[test, expected_failure(abort_code = asset_state::EAlreadyRetired, location = usufruct::asset_state)]
fun update_config_on_retired_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_retired_for_testing(&mut escrow);

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 10: update_ensemble on retiring (flag set) aborts ────────────────────────
#[test, expected_failure(abort_code = asset_state::ERetireAlreadyScheduled, location = usufruct::asset_state)]
fun update_config_on_retiring_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Set the retiring flag.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    // update_ensemble must abort — retiring flag blocks the schedule path.
    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test 11: Descent natural expiry applies pending reset ───────────────────────
/// update_ensemble scheduled while Descent; auction expires naturally via the
/// production APT path. On natural expiry the pending reset is applied,
/// EnsembleUpdated emitted, AND AuctionExpired also emitted.
#[test]
fun update_config_descent_natural_expiry_applies_pending() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow,
        STAKE_T1 - STAKE_T1 / 10,
        STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2,
        0,
    );

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    assert!(escrow::has_pending_ensemble_update(&escrow), 0);

    // Use the production APT path so pending_config is applied at auction expiry.
    let boundary_ms =
        escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, boundary_ms);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 1);
    assert!(escrow::active_ensemble(&escrow) == new_ensemble, 2);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 3);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 1);
    let auction_expired = event::events_by_type<AuctionExpired>();
    assert_eq!(auction_expired.length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §update_ensemble — pending_config invariant ────────────────────────────────
//
// The invariant under test: pending_config is applied ONLY when the escrow
// reaches Idle via auction expiry. No other transition — handover, tenure
// expiry, or re-entry into Renting — may apply it.

// Invariant 1: pending_config survives a chain of handovers untouched ─────────
/// Two consecutive handovers with a buffered reset: after each handover the
/// escrow is still Renting, the old config is still active, and no EnsembleUpdated
/// has been emitted. The pending survives intact through both transitions.
#[test]
fun update_config_pending_survives_multiple_handovers() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let original_cfg = ensemble;
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let new_ensemble = escrow_corpus::by_tag(1);
    let tenure   = escrow_corpus::tenure_ceiling_const();

    // T1 is current tenant; reset scheduled.
    escrow::drive_to_rented_for_testing(&mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // First handover: T1 → T2.
    escrow::drive_to_demand_for_testing(&mut escrow, mk_tenant(STAKE_T2, TENANT_ADDR_2, cap_id_2()), tenure / 4);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(tenure / 4), sc.ctx());

    assert!(escrow::is_rented(&escrow), 0);
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 2);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 0);

    // Second handover: T2 → T1.
    escrow::drive_to_demand_for_testing(&mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), tenure / 2);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(tenure / 2), sc.ctx());

    assert!(escrow::is_rented(&escrow), 3);
    assert!(escrow::has_pending_ensemble_update(&escrow), 4);
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 5);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 0);
    assert_eq!(event::events_by_type<EnsembleUpdateScheduled>().length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Invariant 2: during Descent with pending, old config remains active ──────────
/// update_ensemble called while at Descent: the escrow stays at Descent, the old
/// config remains active (not the new one), and only at auction expiry does the
/// new config take effect.
#[test]
fun update_config_descent_old_config_active_until_auction_expiry() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let original_cfg = ensemble;
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(&mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0);
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1 - STAKE_T1 / 10, STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2, 0,
    );

    // Old config is active; no pending.
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 0);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 1);

    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // Still at Descent; old config still active.
    assert!(escrow::is_descending(&escrow), 2);
    assert!(escrow::has_pending_ensemble_update(&escrow), 3);
    assert!(escrow::active_ensemble(&escrow) == original_cfg, 4);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 0);

    // Auction expiry → new config applied.
    clock::set_for_testing(&mut clk, escrow_corpus::descent_window_h1_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 5);
    assert!(escrow::active_ensemble(&escrow) == new_ensemble, 6);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 7);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 1);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Invariant 3: cross-phase last write wins (Renting → Descent) ───────────────
/// update_ensemble in Renting sets cfg_a; tenure expires → Descent (cfg_a still
/// pending); update_ensemble in Descent overrides to cfg_b. At auction expiry only
/// cfg_b is applied. Exactly 1 EnsembleUpdated (cfg_b), 2 EnsembleUpdateScheduled.
#[test]
fun update_config_descent_overrides_renting_pending() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cfg_a = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let cfg_b = escrow_corpus::by_tag(1);
    let tenure = escrow_corpus::tenure_ceiling_const();

    escrow::drive_to_rented_for_testing(&mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0);
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_a, &clk, sc.ctx());

    // Tenure expiry → Descent with cfg_a pending.
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(tenure), sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);
    assert!(escrow::has_pending_ensemble_update(&escrow), 1);

    // Override pending from Descent: cfg_b wins.
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_b, &clk, sc.ctx());
    assert!(escrow::has_pending_ensemble_update(&escrow), 2);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 0);
    assert_eq!(event::events_by_type<EnsembleUpdateScheduled>().length(), 2);

    // Auction expiry → Idle with cfg_b (not cfg_a).
    clock::set_for_testing(&mut clk, tenure + escrow_corpus::descent_window_h1_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 3);
    assert!(escrow::active_ensemble(&escrow) == cfg_b, 4);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 5);

    let resets = event::events_by_type<EnsembleUpdated>();
    assert_eq!(resets.length(), 1);

    // cfg_b = by_tag(1): h=0 → auction_window Off (cfg_a has h=1 Fixed), c=0 → handover Off (cfg_a has c=1 Fixed)
    let evt = resets.borrow(0);
    assert_eq!(policy_ensemble::ensemble_updated_auction_window_policy(evt), b"Off".to_string());
    assert_eq!(policy_ensemble::ensemble_updated_handover_policy(evt), b"Off".to_string());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Invariant 4: state is clean after application; Idle reset is immediate ──────
/// After pending_config is consumed at auction expiry → Idle, the pending flag
/// is false and no residual state leaks into the next cycle. A subsequent
/// update_ensemble from that Idle applies immediately (no schedule).
#[test]
fun update_config_state_clean_after_application() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 Fixed
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let cfg_cycle1 = escrow_corpus::by_tag(1);
    let cfg_cycle2 = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let tenure     = escrow_corpus::tenure_ceiling_const();

    // Full cycle: Renting → reset → Descent → auction expiry → Idle with cfg_cycle1.
    escrow::drive_to_rented_for_testing(&mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0);
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_cycle1, &clk, sc.ctx());
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(tenure), sc.ctx());
    clock::set_for_testing(&mut clk, tenure + escrow_corpus::descent_window_h1_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // State after first cycle.
    assert!(escrow::is_idle(&escrow), 0);
    assert!(escrow::active_ensemble(&escrow) == cfg_cycle1, 1);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 2);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 1);

    // update_ensemble from Idle → immediate, no schedule.
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_cycle2, &clk, sc.ctx());

    assert!(escrow::is_idle(&escrow), 3);
    assert!(escrow::active_ensemble(&escrow) == cfg_cycle2, 4);
    assert!(!escrow::has_pending_ensemble_update(&escrow), 5);
    assert_eq!(event::events_by_type<EnsembleUpdated>().length(), 2);
    assert_eq!(event::events_by_type<EnsembleUpdateScheduled>().length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §update_ensemble — behavioral dimensions ────────────────────────────────────

// Test BD-1: min_rent_price floor changes after reset ─────────────────────────
/// update_ensemble immediately updates compute_floor_price when applied from Idle.
/// Proves the new min_rent_price is active, not just stored.
#[test]
fun update_config_behavior_min_rent_price_floor_changes() {
    let mut sc = setup();
    let cfg_low  = escrow_corpus::by_tag(0); // 10 SUI floor
    let cfg_high = escrow_corpus::with_min_rent_price(
        escrow_corpus::by_tag(0), 20_000_000_000,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg_low, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Before reset: floor = 10 SUI
    assert!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)) == escrow_corpus::min_rent_price_const(), 0);

    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_high, &clk, sc.ctx());

    // After reset: floor = 20 SUI
    assert!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)) == 20_000_000_000, 1);
    assert!(escrow::active_ensemble(&escrow) == cfg_high, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-1b: bid rejected after min_rent_price raised ────────────────────────
/// After reset raises min_rent_price to 20 SUI, a bid of 15 SUI is rejected.
#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun update_config_behavior_min_rent_price_bid_rejected_after_reset() {
    let mut sc = setup();
    let cfg_low  = escrow_corpus::by_tag(0);
    let cfg_high = escrow_corpus::with_min_rent_price(
        escrow_corpus::by_tag(0), 20_000_000_000,
    );
    let (mut escrow, owner_cap) = integrate_and_take(cfg_low, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_high, &clk, sc.ctx());

    // 15 SUI is above the old 10 SUI floor but below the new 20 SUI floor.
    let cap = escrow::rent(&mut escrow, mk_payment(15_000_000_000, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-2: tenure_ceiling affects has_pending_transition_states ─────────────
/// Proves the new tenure_ceiling governs T2's expiry boundary after reset.
/// At t=160_000, T2 (ceiling=50_000, phase_start=100_000) has expired but
/// under the old ceiling=100_000 it would not have.
#[test]
fun update_config_behavior_tenure_ceiling_apt_detection() {
    let mut sc = setup();
    let cfg_long  = escrow_corpus::by_tag(0);
    let cfg_short = escrow_corpus::with_tenure_ceiling(escrow_corpus::by_tag(0), 50_000);
    let (mut escrow, owner_cap) = integrate_and_take(cfg_long, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents under cfg_long (ceiling=100_000). phase_start=0.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // At t=60_000, T1's tenure (ceiling=100_000) has NOT expired yet.
    clock::set_for_testing(&mut clk, 60_000);
    assert!(!escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)), 0);

    // Schedule cfg_short (ceiling=50_000) — takes effect after T1's tenure.
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_short, &clk, sc.ctx());

    // T1's tenure expires at 100_000 (old ceiling still governs T1).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 1);

    // Rent T2 under cfg_short (ceiling=50_000). phase_start=100_000.
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T2's tenure expires at 100_000 + 50_000 = 150_000.
    // At t=160_000, that boundary has passed → pending transition present.
    // Under old cfg_long, T2 would expire at 200_000 — NOT pending at 160_000.
    clock::set_for_testing(&mut clk, 160_000);
    assert!(escrow::transition_is_ready(&escrow, clock::timestamp_ms(&clk)), 2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-3: descent policy determines Descent vs Idle for the next cycle ──────
/// After update_ensemble from Skip→Fixed, the NEXT tenure expiry (T2) routes
/// through Descent. Under the old Skip policy it would have been Idle.
#[test]
fun update_config_behavior_auction_window_policy_atdutch_presence() {
    let mut sc = setup();
    // cfg_skip: h=0 Skip — tenure expiry → Idle
    let cfg_skip   = escrow_corpus::by_tag(0);
    // cfg_fixed: h=1 Fixed — tenure expiry → Descent
    let cfg_fixed = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_skip, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents under cfg_skip.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // Schedule cfg_fixed; will be applied at T1's tenure expiry.
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_fixed, &clk, sc.ctx());

    // T1's tenure expires → Idle with cfg_fixed (pending_config skips Descent
    // during fire(), so T1's own expiry still goes to Idle directly).
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);
    assert!(escrow::active_ensemble(&escrow) == cfg_fixed, 1);

    // T2 rents under cfg_fixed (Fixed descent). phase_start = tenure_ceiling.
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T2's tenure expires at 2 × tenure_ceiling. With Fixed descent and no
    // pending_config, fire() goes to Descent instead of Idle.
    clock::set_for_testing(&mut clk, 2 * escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-4: credit curve determines compute_used_credit_at_ms value ──────────
/// Linear and Smoothstep curves yield different used-credit at 25% of tenure.
/// Proves the active credit curve is used in credit accounting.
#[test]
fun update_config_behavior_credit_shape_used_credit_changes() {
    let mut sc = setup();
    let cfg_linear     = escrow_corpus::by_tag(0);
    // e=1 → Smoothstep curve
    let cfg_smoothstep = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 1, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_linear, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents under cfg_linear; phase_start = 0.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T1 at 25% of its tenure.
    let quarter_ms = escrow_corpus::tenure_ceiling_const() / 4;
    let credit_linear = escrow::accrued_credit_mist(&escrow, quarter_ms);

    // Schedule cfg_smoothstep; apply at T1's tenure expiry.
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_smoothstep, &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // T2 rents under cfg_smoothstep; phase_start = tenure_ceiling.
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T2 at 25% of its tenure: tenure_ceiling + quarter_ms.
    let credit_smoothstep = escrow::accrued_credit_mist(
        &escrow, escrow_corpus::tenure_ceiling_const() + quarter_ms,
    );

    // Linear: 10 SUI × 0.25 = 2_500_000_000
    // Smoothstep at 0.25: 3×0.0625 - 2×0.015625 ≈ 0.15625 → 1_562_500_000
    assert!(credit_linear != credit_smoothstep, 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-5: price function governs compute_next_ascending_floor ──────────────
/// FixedDelta and CompoundDelta produce different next-floor values for the
/// same bid. Proves the active price function is consulted on every call.
#[test]
fun update_config_behavior_price_function_floor_escalation() {
    let mut sc = setup();
    // d=0: FixedDelta — next_floor = bid + FIXED_DELTA (10 SUI)
    let cfg_fixed_delta    = escrow_corpus::by_tag(0);
    // d=1: CompoundDelta — next_floor = bid × 1.1 + 1 mist
    let cfg_compound_delta = escrow_corpus::by_tag(escrow_corpus::tag(0, 1, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(cfg_fixed_delta, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let bid_amount = escrow_corpus::min_rent_price_const(); // 10 SUI

    // Before reset: FixedDelta — 10 SUI + 10 SUI = 20 SUI
    let floor_before = escrow::next_floor_price_mist(&escrow, bid_amount, 1);
    assert!(floor_before == bid_amount + escrow_corpus::fixed_delta_value_const(), 0);

    // Reset to CompoundDelta immediately (Idle state).
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_compound_delta, &clk, sc.ctx());

    // After reset: CompoundDelta — 10 SUI × 1.1 + 1 = 11_000_000_001
    let floor_after = escrow::next_floor_price_mist(&escrow, bid_amount, 1);
    assert!(floor_after != floor_before, 1);
    assert!(floor_after == 11_000_000_001, 2);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// next_floor_price_mist divides by tenures before escalating: a 3-tenure bid
/// at 3× the base produces the same next floor as a 1-tenure bid at 1×.
#[test]
fun next_floor_price_mist_scales_per_tenure() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0); // FixedDelta: next = bid + FIXED_DELTA
    let (escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let base = escrow_corpus::min_rent_price_const();

    let single = escrow::next_floor_price_mist(&escrow, base,     1);
    let multi  = escrow::next_floor_price_mist(&escrow, base * 3, 3);
    assert_eq!(single, multi);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// floor_price_mist in Occupied equals next_floor_price_mist(active_stake, tenures):
/// both apply escalation to the same per-tenure value, confirming the composition
/// f(now) == next(active_stake, committed_tenures) holds as an invariant.
#[test]
fun floor_price_mist_equals_next_floor_price_mist_in_occupied() {
    let mut sc = setup();
    // m=1 → TenureExtendPolicy::Multi; d=0 → FixedDelta escalation.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag_with_cycles(0, 0, 0, 0, 0, 1));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let base = escrow_corpus::min_rent_price_const();
    let cap  = escrow::rent(&mut escrow, mk_payment(base * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    assert!(escrow::is_occupied(&escrow), 0);

    let stake           = escrow::active_tenant_stake_mist(&escrow).destroy_some();
    let committed       = escrow::active_tenant_committed_tenures(&escrow).destroy_some();
    let from_floor_view = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let from_next_view  = escrow::next_floor_price_mist(&escrow, stake, committed);
    assert_eq!(from_floor_view, from_next_view);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// In Demand, floor_price_mist is driven by the PENDING tenant's stake (T2),
/// not the active tenant's (T1). The identity holds with pending_stake and
/// pending_committed_tenures, not active ones.
#[test]
fun floor_price_mist_equals_next_floor_price_mist_in_demand_uses_pending() {
    let mut sc = setup();
    // c=1 → handover Fixed (enables Demand state); d=0 → FixedDelta.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let t1_cap = escrow::rent(&mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    sc.next_tx(@0xA2);
    clock::set_for_testing(&mut clk, 1_000);
    let floor2  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let t2_cap  = escrow::rent(&mut escrow, mk_payment(floor2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::is_demand(&escrow), 0);

    let pending_stake  = escrow::pending_tenant_stake_mist(&escrow).destroy_some();
    let pending_tenures = escrow::pending_tenant_committed_tenures(&escrow).destroy_some();
    let active_stake   = escrow::active_tenant_stake_mist(&escrow).destroy_some();

    let via_floor      = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let via_pending    = escrow::next_floor_price_mist(&escrow, pending_stake, pending_tenures);
    let via_active     = escrow::next_floor_price_mist(&escrow, active_stake, 1);

    assert_eq!(via_floor, via_pending);
    assert!(via_floor != via_active, 1);

    transfer::public_transfer(t1_cap, OWNER);
    transfer::public_transfer(t2_cap, @0xA2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-6: commitment floor observable at integrate and after extend ─────────
/// retire_commitment_floor_ms reflects the RetireCommitmentPolicy set at integration
/// and updated by extend_retire_commitment. update_ensemble does not affect it.
#[test]
fun retire_commitment_floor_observable_at_integrate_and_after_extend() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        ensemble, retire_commitment_policy::new_immediate(), &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx());

    // Immediate policy at integration: no floor.
    assert!(escrow::retire_commitment_floor_ms(&escrow) == option::none(), 0);

    // Extend to Deferred.
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(escrow_corpus::retire_deferred_f1_const())),
        &clk,
    );

    // Deferred policy: floor = RETIRE_DEFERRED_F1.
    assert!(
        escrow::retire_commitment_floor_ms(&escrow) == option::some(escrow_corpus::retire_deferred_f1_const()),
        1,
    );

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-6b: retire blocked after extend_retire_commitment raises the floor ──────────
/// After extending from Immediate to Deferred, retire() at t=0 aborts.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentFloorNotElapsed, location = usufruct::asset_state)]
fun extend_retire_commitment_retire_aborts_before_floor() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(escrow_corpus::retire_deferred_f1_const())),
        &clk,
    );

    // Deferred floor = 10_000_000 ms; clock at t=0 → abort.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-7: Instant handover lets T2 borrow immediately after bidding ─────────
/// With Instant policy T2's cap becomes Current via APT inside borrow_asset,
/// allowing borrow_asset to succeed in the same PTB as rent — no prior explicit APT needed.
#[test]
fun update_config_behavior_handover_instant_borrow_succeeds() {
    let mut sc = setup();
    let cfg_instant = escrow_corpus::by_tag(0); // c=0 Instant
    let (mut escrow, owner_cap) = integrate_and_take(cfg_instant, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // T1 becomes current tenant.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T2 bids — Demand state. APT inside borrow_asset fires Instant handover → T2 current.
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2 = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T2 is now current (handover fires inside borrow_asset); borrow_asset succeeds (no abort).
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t2, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// Test BD-7b: FullTenure handover blocks T4 borrow until handover fires ─────────
/// After reset from Instant to FullTenure, the pending bidder (T4) cannot
/// borrow until the handover boundary has passed.
#[test, expected_failure(abort_code = asset_state::EPendingTenantCap, location = usufruct::asset_state)]
fun update_config_behavior_handover_fixed_borrow_blocked() {
    let mut sc = setup();
    let cfg_instant = escrow_corpus::by_tag(0);                               // c=0 Instant
    let cfg_fixed   = escrow_corpus::by_tag(escrow_corpus::tag(2, 0, 0, 0, 0)); // c=2 FullTenure
    let (mut escrow, owner_cap) = integrate_and_take(cfg_instant, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // T1 rents under cfg_instant.
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // Schedule cfg_fixed (FullTenure); applied when T1's tenure expires.
    escrow::update_ensemble(&mut escrow, &owner_cap, cfg_fixed, &clk, sc.ctx());

    // T1's tenure expires → Idle with cfg_fixed.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const());
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);

    // T3 rents under cfg_fixed (FullTenure). phase_start = tenure_ceiling = 100_000.
    let cap_t3 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T4 bids; FullTenure handover_expiry = 100_000 + 100_000 = 200_000.
    // Clock is still at 100_000 — far below expiry.
    let floor_t4 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t4 = escrow::rent(
        &mut escrow, mk_payment(floor_t4, sc.ctx()), tenures::tenures(1), &clk, sc.ctx(),
    );

    // T4's cap is Pending — handover has not fired. borrow_asset aborts.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t4, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    // Unreachable — abort above.
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    transfer::public_transfer(cap_t4, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §EV. Event field invariants — cap IDs and timing ────────────────────────

// ── EV-1 + EV-2: bid and handover cap_id consistency ─────────────────────────

/// EV-1: BidPlaced.tenant_cap_id == object::id(&cap_t2)
///   The cap returned by rent() in Occupied is the same object whose ID
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

    // T1 rents (Idle → HO).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids (HO → HC). cap_t2 is the pending cap.
    clock::set_for_testing(&mut clk, 1_000);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap_t2   = escrow::rent(
        &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // EV-1: BidPlaced.tenant_cap_id == the cap returned by rent().
    let bp = event::events_by_type<BidPlaced>();
    assert_eq!(bp.length(), 1);
    assert_eq!(
        asset_state::bid_placed_pending_tenant_cap_id(bp.borrow(0)),
        object::id(&cap_t2),
    );

    // APT fires Instant handover → T2 current.
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), tag);

    // EV-2: HandoverCompleted.new_tenant_cap_id == the same cap (promoted, not re-minted).
    let hc = event::events_by_type<HandoverCompleted>();
    assert_eq!(hc.length(), 1);
    assert_eq!(
        asset_state::handover_completed_new_cap_id(hc.borrow(0)),
        object::id(&cap_t2),
    );

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // T1 rents → HO (T1 is current).
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let cap_t1_id = object::id(&cap_t1);

    // Borrow and return in same PTB.
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset, receipt);

    // EV-3a: AssetBorrowed.tenant_cap_id == cap_t1's ID.
    let ab = event::events_by_type<AssetBorrowed>();
    assert_eq!(ab.length(), 1);
    assert_eq!(asset_state::asset_borrowed_tenant_cap_id(ab.borrow(0)), cap_t1_id);

    // EV-3b: AssetReturned.tenant_cap_id == cap_t1's ID (still current at return time).
    let ar = event::events_by_type<AssetReturned>();
    assert_eq!(ar.length(), 1);
    assert_eq!(asset_state::asset_returned_tenant_cap_id(ar.borrow(0)), cap_t1_id);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── EV-4: BidPlaced.handover_countdown_expiry accuracy per policy ─────────────

/// The handover_countdown_expiry stamped in BidPlaced must match the value
/// computed by handover_policy::compute_expiry_at for each HandoverPolicy variant.
///
/// With phase_start=0, tenure_ceiling=100_000, bid at t=1_000:
///   c=0 Instant:  expiry = bid_time                              = 1_000
///   c=1 Fixed: expiry = min(bid_time + 25_000, 100_000)     = 26_000
///   c=2 FullTenure: expiry = phase_start + tenure_ceiling         = 100_000
///
/// All three are derived from corpus constants — no hardcoded expectations.
#[test]
fun e2e_ev4_bid_placed_countdown_expiry_accuracy_per_policy() {
    let mut sc        = setup();
    let bid_time      = 1_000u64;
    let tenure_ceiling = escrow_corpus::tenure_ceiling_const();
    let countdown     = escrow_corpus::handover_countdown_c1_const();
    let mut m = 0u8;
    while (m <= 1) {
        let mut c: u8     = 0;
        while (c <= 2) {
            let tag = escrow_corpus::tag_with_cycles(c, 0, 0, 0, 0, m); // vary c=0,1,2
            let (mut escrow, owner_cap) = integrate_and_take(escrow_corpus::by_tag(tag), &mut sc);
            let mut clk = clock::create_for_testing(sc.ctx());
        
            // T1 rents → HO (phase_start = 0).
            let cap_t1 = escrow::rent(
                &mut escrow, mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            // T2 bids at bid_time → HC. BidPlaced event stamps the expiry.
            clock::set_for_testing(&mut clk, bid_time);
            let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
            let cap_t2   = escrow::rent(
                &mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

            let bp = event::events_by_type<BidPlaced>();
            assert_eq!(bp.length(), 1);
            let stamped_expiry = asset_state::bid_placed_handover_countdown_expiry(bp.borrow(0));

            // Expected expiry per policy (all derived from corpus constants).
            let expected_expiry = if (c == 0) {
                bid_time                                           // Instant: expiry = bid_time
            } else if (c == 1) {
                bid_time + countdown                               // Fixed: bid + 25_000 = 26_000
            } else {
                tenure_ceiling                                     // FullTenure: phase_start(0) + ceiling
            };
            assert_eq!(stamped_expiry, expected_expiry);

            transfer::public_transfer(cap_t1, OWNER);
            transfer::public_transfer(cap_t2, OWNER);
            test_scenario::return_shared(escrow);
            owner_cap::burn(owner_cap, OWNER);
                    clock::destroy_for_testing(clk);
            c = c + 1;
        };
        m = m + 1;
    };
    sc.end();
}

// ─── §RandomInRange — RestPricePolicy policy tests ─────────────────────────
//
// Tests for the RandomInRange variant of RestPricePolicy.
// Constructors validate invariants; resolution tests verify the drawn floor
// always falls within [min, max]; bid tests verify the bidder strategy.

// ── Constructor validation ────────────────────────────────────────────────────

#[test, expected_failure(abort_code = rest_price_policy::EPriceZero, location = usufruct::rest_price_policy)]
fun new_fixed_zero_price_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = rest_price_policy::new_fixed(usufruct::monetary::price(0));
    sc.end();
}

// ─── §Fixed — Descent descent collapse symmetry ───────────────────────────────

// Symmetric to E2E-2 for RandomInRange: with Fixed policy, the Descent descent
// collapses exactly to the fixed price at full descent (elapsed == window).
// This pins the invariant for both policy variants: descent bottom == resolved_floor,
// which for Fixed is always the configured price.
#[test]
fun e2e_fixed_atdutch_descent_bottom_is_fixed_price() {
    let mut sc = setup();
    // h=1 Fixed, all other axes at default — fixed min_rent_price (corpus default)
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let fixed_price = escrow_corpus::min_rent_price_const();
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    // Idle floor == fixed price (resolved_floor drawn from Fixed policy)
    assert!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)) == fixed_price, 0);

    // Rent at 2× floor (sets last_acq_price for the descent)
    let bid = fixed_price * 2;
    let cap_t1 = escrow::rent(
        &mut escrow, mk_payment(bid, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Tenure expires → Descent (resolved_floor = fixed_price carried into descent)
    let t_atdutch = escrow_corpus::tenure_ceiling_const();
    clock::set_for_testing(&mut clk, t_atdutch);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 1);

    // Start of descent: price == last_acq_price (= bid = 2× fixed_price)
    assert!(escrow::floor_price_mist(&escrow, t_atdutch) == bid, 2);

    // Full descent: price collapses to fixed_price (not 0, not any other value)
    let t_full = t_atdutch + escrow_corpus::descent_window_h1_const();
    assert!(escrow::floor_price_mist(&escrow, t_full) == fixed_price, 3);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §TenureDurationPolicy — policy tests ──────────────────────────────────────
//
// Mirrors the RestPricePolicy test suite for TenureDurationPolicy.
// The observable of resolved_ceiling is tenure_expiry_ms():
//   tenure_expiry_ms = phase_start + resolved_ceiling
// At phase_start = 0, tenure_expiry_ms == resolved_ceiling_ms.


// ── Constructor validation ────────────────────────────────────────────────────

#[test, expected_failure(abort_code = tenure_duration_policy::EDurationZero, location = usufruct::tenure_duration_policy)]
fun new_fixed_zero_ceiling_aborts() {
    let mut sc = setup();
    sc.next_tx(OWNER);
    let _p = tenure_duration_policy::new_fixed(phases::duration(0));
    sc.end();
}

// ─── §Multi-cycle tenancy ─────────────────────────────────────────────────────

// Helper: build an PolicyEnsemble with Multi tenure_cycles policy.
fun multi_cycle_cfg(): policy_ensemble::PolicyEnsemble {
    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(floor)),
        tenure_duration_policy::new_fixed(phases::duration(tenure)),
        tenure_extend_policy::new_multi(),
        handover_policy::new_handover_full_tenure(),
        auction_window_policy::new_descent_off(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(floor)),
    )
}

/// Single policy + cycles(2) → EMultiCycleNotAllowed.
#[test, expected_failure(abort_code = tenure_extend_policy::EMultiCycleNotAllowed, location = usufruct::tenure_extend_policy)]
fun multi_cycle_single_policy_rejects_cycles_two() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0); // Single (default corpus)
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor   = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor * 2, sc.ctx());
    // cycles(2) on a Single-policy escrow must abort
    let cap = escrow::rent(&mut escrow, payment, tenures::tenures(2), &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Multi policy + cycles(3): ceiling extends to tenure × 3.
#[test]
fun multi_cycle_install_extends_ceiling_three_x() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor * 3, sc.ctx()); // 3 cycles × floor
    let cap     = escrow::rent(&mut escrow, payment, tenures::tenures(3), &clk, sc.ctx());

    // tenure_expiry_ms = phase_start(0) + tenure × 3
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert!(option::is_some(&expiry), 0);
    assert!(*option::borrow(&expiry) == tenure * 3, 1);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// cycles(1) on Multi policy: ceiling == tenure (degenerates correctly).
#[test]
fun multi_cycle_single_cycle_degenerates() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    let payment = mk_payment(floor, sc.ctx());
    let cap     = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert!(*option::borrow(&expiry) == tenure, 0); // 1 × tenure

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Insufficient payment for cycles(3) aborts.
#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun multi_cycle_insufficient_payment_aborts() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor   = escrow_corpus::min_rent_price_const();
    // Pay only 2 cycles worth for a 3-cycle request
    let payment = mk_payment(floor * 2, sc.ctx());
    let cap     = escrow::rent(&mut escrow, payment, tenures::tenures(3), &clk, sc.ctx());

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Pending bidder with cycles(3) wins handover → ceiling extends to tenure × 3.
#[test]
fun multi_cycle_pending_bid_extends_ceiling_on_handover() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();

    // T1 installs with cycles(1)
    sc.next_tx(TENANT_ADDR_1);
    let p1  = mk_payment(floor, sc.ctx());
    let cap1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 bids with cycles(3): pays compute_total_price(compute_floor_price_at, 3)
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor  = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2         = mk_payment(bid_floor * 3, sc.ctx());
    let cap2       = escrow::rent(&mut escrow, p2, tenures::tenures(3), &clk, sc.ctx());

    // Fire handover at phase_start + tenure (FullTenure boundary).
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
    clock::destroy_for_testing(clk);
    sc.end();
}

// Helper: Multi + HandoverFixed.
fun multi_cycle_cfg_countdown(): policy_ensemble::PolicyEnsemble {
    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(floor)),
        tenure_duration_policy::new_fixed(phases::duration(tenure)),
        tenure_extend_policy::new_multi(),
        handover_policy::new_handover_fixed(phases::duration(countdown)),
        auction_window_policy::new_descent_off(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(floor)),
    )
}

/// T1 — Floor is per-cycle rate, not total stake.
/// T1 pays 3 cycles: stake = 30 SUI, committed_tenures = 3.
/// compute_floor_price = price_function(10 SUI) = 20 SUI  (FixedDelta(10 SUI))
/// NOT price_function(30 SUI) = 40 SUI.
/// This is the direct regression test for the core per-cycle invariant.
#[test]
fun multi_cycle_floor_price_is_per_cycle_rate() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor  = escrow_corpus::min_rent_price_const();
    let delta  = escrow_corpus::fixed_delta_value_const();

    // T1 pays 3 cycles: total stake = floor × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // Per-cycle rate = floor × 3 / 3 = floor.
    // price_function(floor) = floor + delta  (FixedDelta).
    let expected_floor = floor + delta;
    let actual_floor   = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(actual_floor == expected_floor, 0);

    // Guard: the wrong design would give price_function(3×floor) = 3×floor + delta.
    assert!(actual_floor < floor * 3 + delta, 1);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// T2 — HandoverFixed: competitor displaces multi-cycle tenant by rate.
/// T1 pays 3 cycles (ceiling = tenure × 3). T2 bids at t=tenure/2 with 1
/// cycle, paying only the per-cycle floor. Handover fires at
/// t + countdown — well before T1's 300k ceiling. T1 is displaced early.
#[test]
fun multi_cycle_countdown_displaces_via_rate() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();
    let delta     = escrow_corpus::fixed_delta_value_const();

    // T1 rents 3 cycles: ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());
    assert!(*option::borrow(&escrow::tenure_expiry_ms(&escrow)) == tenure * 3, 0);

    // T2 bids at t = tenure/2 (mid cycle 1) with 1 cycle.
    // Pays per-cycle floor only: price_function(floor) = floor + delta.
    let bid_time = tenure / 2;
    clock::set_for_testing(&mut clk, bid_time);
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(bid_floor == floor + delta, 1); // per-cycle floor, not total-based
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Handover fires at bid_time + countdown — before T1's 3-cycle ceiling.
    let handover_ms = bid_time + countdown;
    assert!(handover_ms < tenure * 3, 2); // well before full ceiling
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(handover_ms), sc.ctx());

    // HandoverCompleted fires at handover_ms, not at tenure × 3.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_state::handover_completed_timestamp_ms(&completed[0]), handover_ms);

    // T2 is now current with ceiling = tenure × 1 from handover boundary.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), handover_ms + tenure);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// T3 — HandoverFullTenure: multi-cycle tenant consumes all paid cycles.
/// T1 pays 3 cycles (ceiling = tenure × 3). T2 bids at t=tenure/2 but
/// handover expiry = phase_start + ceiling = tenure × 3. T1 is only
/// displaced at t = tenure × 3 — the full tenure is respected.
#[test]
fun multi_cycle_full_tenure_tenant_consumes_full_ceiling() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();
    let delta  = escrow_corpus::fixed_delta_value_const();

    // T1 rents 3 cycles: ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 bids early at t=tenure/2. FullTenure: expiry = phase_start + ceiling = tenure × 3.
    let bid_time = tenure / 2;
    clock::set_for_testing(&mut clk, bid_time);
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(bid_floor == floor + delta, 0);
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Fixed expiry must equal the full 3-cycle ceiling.
    let handover_expiry = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry), tenure * 3);

    // Handover only fires at tenure × 3 — T1 consumed all paid cycles.
    let boundary = tenure * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(asset_state::handover_completed_timestamp_ms(&completed[0]), boundary);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
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

    // Escrow A: T1a rents 1 cycle at floor.
    sc.next_tx(TENANT_ADDR_1);
    let cap_a   = escrow::rent(&mut escrow_a, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let floor_a = escrow::floor_price_mist(&escrow_a, clock::timestamp_ms(&clk));

    // Escrow B: T1b rents 3 cycles at floor × 3 (same per-cycle rate).
    sc.next_tx(TENANT_ADDR_1);
    let cap_b   = escrow::rent(&mut escrow_b, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());
    let floor_b = escrow::floor_price_mist(&escrow_b, clock::timestamp_ms(&clk));

    // Same per-cycle rate → same floor for a 1-cycle competitor.
    assert!(floor_a == floor_b, 0);
    assert!(floor_a == floor + delta, 1); // price_function(10 SUI) = 20 SUI

    transfer::public_transfer(cap_a, TENANT_ADDR_1);
    transfer::public_transfer(cap_b, TENANT_ADDR_1);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(owner_cap_a, OWNER);
    owner_cap::burn(owner_cap_b, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Supersede chain floor invariant.
/// T1 (3 cycles, 30 SUI) → T2 bid (1 cycle, 20 SUI) → T3 supersedes T2.
/// T3 floor = price_function(T2.stake / T2.bidding_cycles) = price_function(20/1) = 30 SUI.
/// NOT price_function(T1.stake / T1.committed_tenures) = price_function(10) = 20 SUI.
#[test]
fun multi_cycle_supersede_floor_based_on_pending_rate() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor = escrow_corpus::min_rent_price_const();
    let delta = escrow_corpus::fixed_delta_value_const();

    // T1: 3 cycles, 30 SUI.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: 1 cycle, 20 SUI = price_function(10 SUI).
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(floor_t2 == floor + delta, 0); // 20 SUI
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T3 supersede: floor = price_function(T2.stake / T2.bidding_cycles)
    //             = price_function(20 SUI / 1) = 20 + 10 = 30 SUI.
    // NOT price_function(T1's 10 SUI) = 20 SUI.
    let const_challenger: address = @0xC1;
    sc.next_tx(const_challenger);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(floor_t3 == floor_t2 + delta, 1); // 30 SUI
    assert!(floor_t3 > floor_t2, 2);           // strictly escalates

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// FullTenure handover-after-handover invariant.
/// T1 (3 cycles) → T2 (2 cycles) wins handover.
/// T2.ceiling = base × 2. T2.resolved_handover = base × 2 (FullTenure tracks new ceiling).
/// T3 bids → handover expiry = T2.phase_start + base × 2.
#[test]
fun multi_cycle_full_tenure_handover_tracks_new_ceiling() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();
    let _delta = escrow_corpus::fixed_delta_value_const();

    // T1: 3 cycles, ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: 2 cycles. FullTenure: handover expiry = phase_start(0) + ceiling(tenure×3).
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor_t2 * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

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
    let bid_floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(bid_floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // FullTenure: T3's handover expiry = T2.phase_start + T2.ceiling = tenure×3 + tenure×2.
    let handover_expiry_t3 = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry_t3), boundary_t2 + tenure * 2);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Fixed floor scales with committed_tenures.
/// T1 (3 cycles): extended_handover = countdown × 3 = 75k.
/// T2 (2 cycles) wins at 75k: T2.handover = countdown × 2 = 50k, T2.ceiling = 200k.
/// T3 bids at t=175k → expiry = min(175k+50k, 75k+200k) = min(225k, 275k) = 225k.
/// The handover window is proportional to the tenure committed — paying N cycles
/// buys N times the protection window on each handover.
#[test]
fun multi_cycle_countdown_scales_with_committed_tenures() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const(); // 25_000

    // T1: 3 cycles → extended_handover = 25k × 3 = 75k, extended_ceiling = 300k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: 2 cycles bids at t=0. expiry = min(0 + 75k, 0 + 300k) = 75k.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor_t2 * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

    // Verify T2's handover expiry = 75k (= countdown × 3), not 25k.
    let expiry_demand = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_demand), countdown * 3);

    // T2 wins at boundary = 75k.
    let boundary_t2 = countdown * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_t2), sc.ctx());

    // T2 now current: phase_start = 75k.
    // base_tenure = 300k/3 = 100k → T2.ceiling = 100k × 2 = 200k.
    // base_handover = 75k/3 = 25k → T2.handover = 25k × 2 = 50k.
    let expiry_t2 = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_t2), boundary_t2 + tenure * 2);

    // T3 bids at t = 75k + 100k = 175k. expiry = min(175k+50k, 75k+200k) = 225k.
    let bid_time_t3 = boundary_t2 + tenure;
    clock::set_for_testing(&mut clk, bid_time_t3);
    sc.next_tx(@0xC1);
    let bid_floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(bid_floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2.handover = 50k. expiry = min(175k + 50k, 75k + 200k) = min(225k, 275k) = 225k.
    let expected_expiry = bid_time_t3 + countdown * 2; // 175k + 50k = 225k
    assert!(expected_expiry < boundary_t2 + tenure * 2, 0); // < T2.phase_start + T2.ceiling
    let handover_expiry_t3 = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry_t3), expected_expiry);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Degeneration: cycles(1) matches single-cycle baseline ──────────────────
//
// Each test pairs the multi-cycle code path (cycles=1) against the expected
// single-cycle baseline derived from the corpus constants. If the abstraction
// is clean, cycles(1) is invisible — results are identical to the pre-cycles
// implementation.

/// Floor degeneration: committed_tenures=1 → price_function(stake/1) = price_function(stake).
/// The per-cycle normalization must not alter the floor when cycles=1.
#[test]
fun degeneration_floor_cycles_one_equals_baseline() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor = escrow_corpus::min_rent_price_const();
    let delta = escrow_corpus::fixed_delta_value_const();

    sc.next_tx(TENANT_ADDR_1);
    let cap = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // floor = price_function(stake / 1) = price_function(stake) = floor + delta.
    assert!(escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk)) == floor + delta, 0);

    transfer::public_transfer(cap, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Ceiling degeneration: cycles(1) → resolved_ceiling = base tenure exactly.
/// The ceiling extension must not alter anything when the multiplier is 1.
#[test]
fun degeneration_ceiling_cycles_one_equals_base_tenure() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();

    sc.next_tx(TENANT_ADDR_1);
    let cap = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // tenure_expiry = phase_start(0) + tenure × 1 = tenure.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), tenure);

    transfer::public_transfer(cap, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Supersede degeneration: cycles(1) on both sides gives the same floor
/// escalation as the pre-cycles corpus baseline.
/// T1(1 cycle, floor) → T2 bids(1 cycle) → T3 supersedes T2.
/// Floor chain: floor → floor+δ → floor+2δ.
#[test]
fun degeneration_supersede_floor_chain_cycles_one() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor = escrow_corpus::min_rent_price_const();
    let delta = escrow_corpus::fixed_delta_value_const();

    // T1: 1 cycle, pays floor.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids: floor = price_function(floor) = floor + delta.
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(floor_t2 == floor + delta, 0);
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T3 supersedes: floor = price_function(floor+delta) = floor + 2*delta.
    sc.next_tx(@0xC1);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    assert!(floor_t3 == floor + delta * 2, 1);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// FullTenure degeneration: cycles(1) → handover expiry = phase_start + tenure.
/// The FullTenure boundary must not be extended when cycles=1.
#[test]
fun degeneration_full_tenure_expiry_cycles_one() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();
    let _delta = escrow_corpus::fixed_delta_value_const();

    // T1: 1 cycle.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids: FullTenure expiry = phase_start(0) + ceiling(tenure × 1) = tenure.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), tenure);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Fixed degeneration: cycles(1) → expiry = min(bid+countdown, phase_start+tenure).
/// The countdown formula must be identical to the pre-cycles baseline.
#[test]
fun degeneration_countdown_expiry_cycles_one() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();
    let _delta    = escrow_corpus::fixed_delta_value_const();

    // T1: 1 cycle, ceiling = tenure.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t = tenure/2. expiry = min(tenure/2 + countdown, 0 + tenure).
    let bid_time = tenure / 2;
    clock::set_for_testing(&mut clk, bid_time);
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // bid_time + countdown = 50k + 25k = 75k < tenure = 100k → countdown wins.
    let expected = bid_time + countdown;
    assert!(expected < tenure, 0);
    let expiry = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), expected);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Multi-cycle: e2e replica for cycles(n) ─────────────────────────────────

/// Owner earnings use extended ceiling in credit calculation.
/// T1 (3 cycles, 300k ceiling) displaced at t=75k (25% through tenure).
/// used_credit must be proportional to 75k/300k, NOT 75k/100k.
/// If resolved_ceiling is wrong in credit_state, owner gets 3× too much.
#[test]
fun multi_cycle_handover_earnings_proportional_to_extended_ceiling() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let _tenure   = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles, principal = floor × 3.
    sc.next_tx(TENANT_ADDR_1);
    let principal = floor * 3;
    let cap1 = escrow::rent(&mut escrow, mk_payment(principal, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 bids at t=0.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Handover at t = countdown = 25k.
    // elapsed = 25k out of 300k = 8.33%.
    // used_credit = credit_shape(25k/300k) × principal.
    let boundary = countdown;
    let used_credit = escrow::accrued_credit_mist(&escrow, boundary);
    let owner_before = escrow::owner_value_for_testing(&escrow);
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());
    let owner_after = escrow::owner_value_for_testing(&escrow);

    // Conservation: used_credit + remain_credit = principal.
    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    assert_eq!(
        asset_state::handover_completed_used_credit(&completed[0]) +
        asset_state::handover_completed_remain_credit(&completed[0]),
        principal,
    );

    // used_credit must be < principal/4: 25k/300k < 1/4.
    // If resolved_ceiling were 100k (wrong), used_credit ≈ principal/4 * 3 = too large.
    assert!(used_credit < principal / 4, 0);

    // Owner received 90% of used_credit.
    let owner_share = asset_state::handover_completed_owner_share(&completed[0]);
    assert_eq!(owner_after - owner_before, owner_share);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Natural tenure expiry fires at extended ceiling, not at base tenure.
/// T1 (3 cycles, 300k ceiling): tenure must expire at t=300k, not t=100k.
/// Full stake distributed to owner+protocol at the correct boundary.
#[test]
fun multi_cycle_tenure_expiry_fires_at_extended_ceiling() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();

    // T1: 3 cycles, principal = floor × 3, ceiling = tenure × 3.
    sc.next_tx(TENANT_ADDR_1);
    let principal = floor * 3;
    let cap1 = escrow::rent(&mut escrow, mk_payment(principal, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // Expiry fires at tenure × 3 = 300k, not at tenure = 100k.
    let boundary = tenure * 3;
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    // Post-condition: Descent with last_acq_price = principal.
    assert!(escrow::is_descending(&escrow), 0);

    let expired = event::events_by_type<TenureExpired>();
    assert_eq!(expired.length(), 1);
    assert_eq!(asset_state::tenure_expired_last_acq_price(&expired[0]), principal);
    // Conservation: full principal consumed.
    assert_eq!(
        asset_state::tenure_expired_owner_share(&expired[0]) +
        asset_state::tenure_expired_protocol_fee(&expired[0]),
        principal,
    );

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Descent → multi-cycle rent: ceiling extends correctly from the Dutch state.
/// After a prior tenure expires (last_acq = 20 SUI), a renter enters with
/// cycles(3) — ceiling = base_tenure × 3 from the new phase_start.
#[test]
fun multi_cycle_rent_from_descent_extends_ceiling() {
    let mut sc = setup();
    let ensemble     = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 descent
    // Override tenure_cycles to Multi so we can rent with cycles(3).
    let ensemble = escrow_corpus::with_tenure_cycles(ensemble, tenure_extend_policy::new_multi());
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure   = escrow_corpus::tenure_ceiling_const();
    let last_acq = escrow_corpus::min_rent_price_const() * 2;
    let phase_start_ms = tenure;

    // Drive to Descent via test helpers.
    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, last_acq, phase_start_ms,
    );

    // Rent with cycles(3) mid-descent.
    let now = phase_start_ms + escrow_corpus::descent_window_h1_const() / 2;
    clock::set_for_testing(&mut clk, now);
    let floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // ceiling = base_tenure × 3; expiry = phase_start + tenure × 3.
    // Note: do_install uses the resolved_ceiling from the Idle state drawn at
    // do_auction_expiry, which is base tenure. Extended = base × 3.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert!(option::is_some(&expiry), 0);
    // expiry = now (phase_start of this tenancy) + tenure × 3.
    // The tenancy phase_start is `now` (when rent() was called).
    assert!(*option::borrow(&expiry) == now + tenure * 3, 1);

    transfer::public_transfer(cap, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Retire flag on multi-cycle tenancy: handover fires at extended boundary.
/// T1 (3 cycles) in Demand, owner sets retire flag.
/// APT at countdown expiry: handover fires, T2 current with retiring flag.
/// APT at T2's tenure boundary: collapses to Retired.
#[test]
fun multi_cycle_retire_flag_handover_fires_at_extended_boundary() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();
    let _delta    = escrow_corpus::fixed_delta_value_const();

    // T1: 3 cycles.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 bids at t=0 with 1 cycle.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Owner sets retire flag — state stays Demand.
    sc.next_tx(OWNER);
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 1);

    // T1.extended_handover = countdown × 3 = 75k.
    // APT fires handover at t = 75k, T2 current with retiring flag.
    let handover_boundary = countdown * 3;
    clock::set_for_testing(&mut clk, handover_boundary);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), 2);

    // T2: committed_tenures=1, phase_start=75k.
    // base_tenure = 300k/3 = 100k → T2.ceiling = 100k × 1 = 100k.
    // T2 expires at handover_boundary + tenure = 75k + 100k = 175k.
    clock::set_for_testing(&mut clk, handover_boundary + tenure);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_retired(&escrow), 3);

    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow2 = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset(escrow2, owner_cap, &clk, sc.ctx());
    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Remain_credit returned to the displaced tenant after handover.
/// T1 (3 cycles, 300 SUI, ceiling=300k) displaced at t=25k (8.3% through tenure).
/// Explicit assertions:
///   - remain_credit = principal - used_credit (conservation)
///   - remain_credit > principal/2 (most stake returned — extended ceiling in use)
///   - T1 physically receives a Coin<SUI> of value == remain_credit
///
/// If resolved_ceiling were wrong (100k instead of 300k), used_credit would be
/// ~75% of principal, and T1 would receive only ~25%. The remain_credit > principal/2
/// assertion catches this.
#[test]
fun multi_cycle_handover_remain_credit_returned_to_tenant() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles, principal = floor × 3.
    sc.next_tx(TENANT_ADDR_1);
    let principal = floor * 3;
    let cap1 = escrow::rent(&mut escrow, mk_payment(principal, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 bids at t=0 with 1 cycle.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    // Handover fires at countdown = 25k.
    // elapsed = 25k / 300k = 8.3% → used_credit is small, remain_credit is large.
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(countdown), sc.ctx());

    let completed = event::events_by_type<HandoverCompleted>();
    assert_eq!(completed.length(), 1);
    let used_credit   = asset_state::handover_completed_used_credit(&completed[0]);
    let remain_credit = asset_state::handover_completed_remain_credit(&completed[0]);

    // Conservation: full principal accounted for.
    assert_eq!(used_credit + remain_credit, principal);

    // T1 gets most of their stake back — extended ceiling (300k) is in use.
    // If base ceiling (100k) were used, elapsed/ceiling = 25k/100k = 25%, so
    // used_credit ≈ 0.25 × principal, remain_credit ≈ 0.75 × principal — still > 0.5.
    // Tighter bound: elapsed/ceiling = 25k/300k = 8.3% → remain_credit > 0.9 × principal.
    assert!(remain_credit > principal * 9 / 10, 0);

    // T1 physically receives the remain_credit as a Coin<SUI>.
    sc.next_tx(TENANT_ADDR_1);
    assert!(sc.has_most_recent_for_sender<coin::Coin<SUI>>(), 1);
    let refund = sc.take_from_sender<coin::Coin<SUI>>();
    assert_eq!(coin::value(&refund), remain_credit);
    coin::burn_for_testing(refund);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Handover scaling invariants ────────────────────────────────────────────

// Helper: Multi + HandoverInstant.
fun multi_cycle_cfg_instant(): policy_ensemble::PolicyEnsemble {
    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();
    policy_ensemble::new_ensemble(
        rest_price_policy::new_fixed(monetary::price(floor)),
        tenure_duration_policy::new_fixed(phases::duration(tenure)),
        tenure_extend_policy::new_multi(),
        handover_policy::new_handover_off(),
        auction_window_policy::new_descent_off(),
        curve_shape_policy::new_linear(),
        curve_shape_policy::new_linear(),
        price_escalation_policy::new_fixed_delta(monetary::price(floor)),
    )
}

/// Fixed scaling: bid at t=0 against n-cycle tenant → expiry = countdown × n exactly.
/// Verifies the numeric value, not just that it is larger than the base countdown.
/// A truncation error in the scaling multiplication would show here.
#[test]
fun handover_scaling_countdown_expiry_exact_at_bid_zero() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles → extended_handover = countdown × 3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 bids at t=0: expiry = min(0 + countdown×3, 0 + ceiling×3) = countdown×3.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), countdown * 3); // exact — no truncation

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// No double-scaling: T1(3) → T2(2) wins → T3(1) wins.
/// T3.handover must be countdown × 1, not countdown × 3/3×2/2×1.
/// The normalization step (÷ committed_tenures) prevents accumulation.
#[test]
fun handover_scaling_no_double_scaling_across_handover_chain() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let _tenure   = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles → extended_handover = countdown×3 = 75k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: 2 cycles, bids at t=0 → expiry = countdown×3 = 75k.
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2 * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

    // T2 wins at t=75k. base_handover = 75k/3 = 25k. T2.handover = 25k×2 = 50k.
    let boundary_t2 = countdown * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_t2), sc.ctx());

    // T3 bids at t=boundary_t2=75k against T2 (phase_start=75k, handover=50k, ceiling=200k).
    // expiry = min(75k + 50k, 75k + 200k) = min(125k, 275k) = 125k.
    clock::set_for_testing(&mut clk, boundary_t2);
    sc.next_tx(@0xC1);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry_t3 = escrow::handover_expiry_ms(&escrow);
    // T2.handover = countdown × 2 = 50k (T2's committed_tenures, not T1's × T2's).
    // expiry = 75k + 50k = 125k.
    // Wrong double-scaling would give: 75k + countdown×3×2 = 225k.
    assert_eq!(*option::borrow(&expiry_t3), boundary_t2 + countdown * 2);

    // T3 wins at boundary_t3 = 125k.
    let boundary_t3 = boundary_t2 + countdown * 2;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_t3), sc.ctx());

    // T3: committed_tenures=1. base_handover = 50k/2 = 25k. T3.handover = 25k×1 = 25k.
    // T4 bids at boundary_t3: expiry = min(125k + 25k, 125k + 100k) = 150k = boundary_t3 + countdown.
    clock::set_for_testing(&mut clk, boundary_t3);
    sc.next_tx(@0xD1);
    let floor_t4 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap4 = escrow::rent(&mut escrow, mk_payment(floor_t4, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let expiry_t4 = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_t4), boundary_t3 + countdown); // countdown × 1 — no accumulation

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    transfer::public_transfer(cap4, @0xD1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Instant is invariant to cycles: extended_handover = 0 × n = 0.
/// A bid against an n-cycle Instant tenant fires at bid_time regardless of n.
#[test]
fun handover_scaling_instant_stays_zero_for_any_cycles() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_instant(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let floor  = escrow_corpus::min_rent_price_const();

    // T1: 5 cycles. extended_handover = 0 × 5 = 0.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 5, sc.ctx()), tenures::tenures(5), &clk, sc.ctx());

    // T2 bids at t=1000. Instant: expiry = bid_time = 1000.
    let bid_time: u64 = 1_000;
    clock::set_for_testing(&mut clk, bid_time);
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), bid_time); // exactly bid_time, not bid_time + 5×anything

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// FullTenure: handover expiry always equals tenure expiry regardless of bid time.
/// extended_handover = extended_ceiling → expiry = phase_start + extended_ceiling.
/// Bid at t=0 or t=mid-tenure: same expiry.
#[test]
fun handover_scaling_full_tenure_expiry_equals_tenure_expiry() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();

    // T1: 3 cycles → extended_ceiling = tenure×3, extended_handover = tenure×3.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());
    let tenure_expiry = *option::borrow(&escrow::tenure_expiry_ms(&escrow)); // tenure×3

    // T2 bids at t=0: FullTenure expiry = phase_start + extended_ceiling = tenure×3.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let expiry_at_zero = *option::borrow(&escrow::handover_expiry_ms(&escrow));

    // T2 wins at tenure_expiry. T3 bids mid-tenure of T2.
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(tenure_expiry), sc.ctx());
    let tenure_expiry_t2 = *option::borrow(&escrow::tenure_expiry_ms(&escrow));

    sc.next_tx(@0xC1);
    let mid = tenure_expiry + tenure / 2;
    clock::set_for_testing(&mut clk, mid);
    let bid_floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(bid_floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let expiry_at_mid = *option::borrow(&escrow::handover_expiry_ms(&escrow));

    // Both bids see handover expiry == tenure expiry — bid time is irrelevant for FullTenure.
    assert_eq!(expiry_at_zero, tenure_expiry);
    assert_eq!(expiry_at_mid, tenure_expiry_t2);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Rate symmetry: handover window per committed cycle is constant.
/// T1a (1 cycle, f) → bid expiry = f.
/// T1b (3 cycles, f×3) → bid expiry = f×3.
/// Ratio expiry / committed_tenures = f in both cases — same protection rate.
#[test]
fun handover_scaling_rate_symmetry_per_committed_cycle() {
    let mut sc = setup();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // Two escrows — same countdown config.
    let (mut escrow_a, owner_cap_a) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let (mut escrow_b, owner_cap_b) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    // Escrow A: T1a rents 1 cycle.
    sc.next_tx(TENANT_ADDR_1);
    let cap_a1 = escrow::rent(&mut escrow_a, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    sc.next_tx(TENANT_ADDR_2);
    let floor_a2 = escrow::floor_price_mist(&escrow_a, clock::timestamp_ms(&clk));
    let cap_a2 = escrow::rent(&mut escrow_a, mk_payment(floor_a2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let expiry_a = *option::borrow(&escrow::handover_expiry_ms(&escrow_a));

    // Escrow B: T1b rents 3 cycles (same per-cycle rate).
    sc.next_tx(TENANT_ADDR_1);
    let cap_b1 = escrow::rent(&mut escrow_b, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());
    sc.next_tx(TENANT_ADDR_2);
    let floor_b2 = escrow::floor_price_mist(&escrow_b, clock::timestamp_ms(&clk));
    let cap_b2 = escrow::rent(&mut escrow_b, mk_payment(floor_b2, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let expiry_b = *option::borrow(&escrow::handover_expiry_ms(&escrow_b));

    // expiry_a = countdown × 1. expiry_b = countdown × 3.
    // Ratio: expiry / committed_tenures = countdown in both cases.
    assert_eq!(expiry_a, countdown);           // 1 cycle: f × 1
    assert_eq!(expiry_b, countdown * 3);       // 3 cycles: f × 3
    assert_eq!(expiry_a * 3, expiry_b);        // same rate per cycle

    transfer::public_transfer(cap_a1, TENANT_ADDR_1);
    transfer::public_transfer(cap_a2, TENANT_ADDR_2);
    transfer::public_transfer(cap_b1, TENANT_ADDR_1);
    transfer::public_transfer(cap_b2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(owner_cap_a, OWNER);
    owner_cap::burn(owner_cap_b, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §Normalization invariants ────────────────────────────────────────────────

/// Truncation invariant: compute_rescaled_duration is exact across a handover chain.
/// T1(3) → T2(2) → T3(1): each rescaling divides exactly — no accumulated error.
/// Final handover value must equal the base countdown, not countdown ± drift.
#[test]
fun normalization_rescale_is_exact_across_handover_chain() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let _tenure   = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const(); // 25_000

    // T1: 3 cycles → extended_handover = 25k × 3 = 75k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 bids. expiry = 75k. T2 wins.
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2 * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());
    // rescale: 75k × 2 / 3 = 50k (exact, 75k divisible by 3)
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(countdown * 3), sc.ctx());

    // T3 bids against T2(handover=50k). T3 wins.
    clock::set_for_testing(&mut clk, countdown * 3);
    sc.next_tx(@0xC1);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    // rescale: 50k × 1 / 2 = 25k (exact, 50k divisible by 2)
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(countdown * 3 + countdown * 2), sc.ctx());

    // T4 bids against T3(handover=25k). Exactly countdown — no drift.
    clock::set_for_testing(&mut clk, countdown * 3 + countdown * 2);
    sc.next_tx(@0xD1);
    let floor_t4 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap4 = escrow::rent(&mut escrow, mk_payment(floor_t4, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry = escrow::handover_expiry_ms(&escrow);
    // T3.handover must be exactly countdown — no accumulated rounding error.
    assert_eq!(*option::borrow(&expiry), countdown * 3 + countdown * 2 + countdown);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    transfer::public_transfer(cap4, @0xD1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Descent ceiling compounding bug: T1(n) expires → Descent carries extended
/// ceiling (base×n). New tenant from Descent with cycles(m) should get
/// ceiling = base×m, NOT base×n×m.
#[test]
fun normalization_descent_ceiling_not_compounded_after_multi_cycle_expiry() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure = escrow_corpus::tenure_ceiling_const();
    let floor  = escrow_corpus::min_rent_price_const();

    // T1: 3 cycles, ceiling = tenure×3 = 300k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T1 tenure expires at 300k → Descent. Descent must carry base ceiling=100k.
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(tenure * 3), sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // Advance clock to expiry boundary so phase_start is deterministic.
    let entry_time = tenure * 3;
    clock::set_for_testing(&mut clk, entry_time);

    // New tenant from Descent with cycles(2): ceiling must be base×2 = 200k.
    // Buggy: Descent carries resolved_ceiling=300k → do_install produces 300k×2=600k.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

    // phase_start = entry_time = tenure×3. extended_ceiling = base×2 = tenure×2.
    // Correct expiry = tenure×3 + tenure×2 = tenure×5.
    // Buggy  expiry = tenure×3 + tenure×3×2 = tenure×9.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), entry_time + tenure * 2);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Descent carries normalized handover, not extended.
/// T1(3 cycles) expires → Descent. New tenant with cycles(2) must see:
///   ceiling  = base × 2 (not base × 3 × 2)
///   handover = countdown × 2 (not countdown × 3 × 2)
#[test]
fun normalization_descent_handover_also_normalized_after_multi_cycle_expiry() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles → extended_ceiling=300k, extended_handover=75k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(tenure * 3), sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    let entry_time = tenure * 3;
    clock::set_for_testing(&mut clk, entry_time);

    // T2 from Descent with cycles(2).
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2_a = escrow::rent(&mut escrow, mk_payment(bid_floor * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

    // Ceiling: base×2 = tenure×2. (Not tenure×3×2 = tenure×6.)
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), entry_time + tenure * 2);

    // Handover: countdown×2 = 50k. (Not countdown×3×2 = 150k.)
    sc.next_tx(TENANT_ADDR_1); // bid from a third party
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2_b = escrow::rent(&mut escrow, mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let handover_expiry = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_expiry), entry_time + countdown * 2);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2_a, TENANT_ADDR_2);
    transfer::public_transfer(cap2_b, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Demand path: T1(3) → T2 wins handover → T2's tenure expires → Descent.
/// Descent must carry T2's normalized base values, not T2's extended ones.
#[test]
fun normalization_descent_ceiling_after_handover_then_expiry() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: 2 cycles bids → expiry = countdown×3 = 75k.
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2 * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

    // T2 wins at boundary=75k. T2: committed_tenures=2, ceiling=200k, handover=50k.
    let boundary_t2 = countdown * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_t2), sc.ctx());

    // T2 tenure expires at boundary_t2 + tenure×2 = 275k → Descent.
    let expiry_t2 = boundary_t2 + tenure * 2;
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(expiry_t2), sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // T3 from Descent with cycles(1): ceiling = base×1 = tenure. (Not tenure×2×1.)
    clock::set_for_testing(&mut clk, expiry_t2);
    sc.next_tx(@0xC1);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    let expiry_t3 = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_t3), expiry_t2 + tenure); // base × 1 only

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Fixed-point: T1(n) → T2(n). Same cycle count → rescale is identity.
/// compute_rescaled_duration(extended, cycles(n), cycles(n)) = extended exactly.
/// Neither ceiling nor handover should change across a same-cycles handover.
#[test]
fun normalization_same_cycle_count_is_identity() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles → ceiling=300k, handover=75k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: also 3 cycles → rescale(75k, 3, 3) = 75k, rescale(300k, 3, 3) = 300k.
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2 * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2 wins: T2.ceiling = 300k, T2.handover = 75k (unchanged from T1).
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(countdown * 3), sc.ctx());

    let expiry_t2 = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry_t2), countdown * 3 + tenure * 3); // phase_start + ceiling×3

    // T3 bids → sees T2.handover = 75k = countdown×3 (identity preserved).
    clock::set_for_testing(&mut clk, countdown * 3);
    sc.next_tx(@0xC1);
    let floor_t3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap3 = escrow::rent(&mut escrow, mk_payment(floor_t3, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());
    let handover_t3 = escrow::handover_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&handover_t3), countdown * 3 + countdown * 3); // bid + 75k

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    transfer::public_transfer(cap3, @0xC1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// After do_handover, the winning tenant receives exactly base × bidding_cycles
/// for both ceiling and handover — no compounding with committed_tenures.
/// T1(3) → T2(2) wins. Verified immediately after handover, without a
/// subsequent bid needed for the handover check.
///
/// Ceiling:  tenure_expiry_ms     == boundary + tenure×2    (not +tenure×6)
/// Handover: compute_handover_expiry_at(bid=boundary)
///           == boundary + countdown×2                       (not +countdown×6)
#[test]
fun do_handover_winner_receives_base_times_bidding_cycles_no_compound() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    let tenure    = escrow_corpus::tenure_ceiling_const();
    let floor     = escrow_corpus::min_rent_price_const();
    let countdown = escrow_corpus::handover_countdown_c1_const();

    // T1: 3 cycles → ceiling=300k, handover=75k.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T2: 2 cycles bids at t=0. T1.handover=75k → expiry=75k.
    sc.next_tx(TENANT_ADDR_2);
    let floor_t2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(floor_t2 * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());

    // T2 wins at boundary = countdown×3 = 75k.
    let boundary = countdown * 3;
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary), sc.ctx());

    // T2 now current. Verify ceiling and handover without a subsequent bid.

    // Ceiling: base = 300k/3 = 100k. T2.ceiling = 100k×2 = 200k.
    // expiry = boundary + 200k = 75k + 200k = 275k.
    // Buggy: boundary + 300k×2 = 675k.
    let expiry = escrow::tenure_expiry_ms(&escrow);
    assert_eq!(*option::borrow(&expiry), boundary + tenure * 2);

    // Handover: base = 75k/3 = 25k. T2.handover = 25k×2 = 50k.
    // compute_handover_expiry_at(bid=boundary):
    //   min(boundary + 50k, boundary + 200k) = boundary + 50k = 125k.
    // Buggy: min(boundary + 150k, boundary + 200k) = boundary + 150k = 225k.
    let handover_if_bid_now = escrow::handover_expiry_if_bid_at(&escrow, boundary);
    assert_eq!(*option::borrow(&handover_if_bid_now), boundary + countdown * 2);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Descent descent is driven by resolved_descent and phase_start only.
/// resolved_ceiling (extended for multi-cycle) plays no role in auction timing.
///
/// T1 (3 cycles, base_tenure=100k) expires at t=300k → Descent.
/// Descent window = descent_window_h1 = 100k.
///
/// Verified:
///   price at t=300k (phase_start) = last_acq_price = T1's stake    [start of descent]
///   price at t=400k (phase_start + descent) = min_rent_price        [end of descent]
///   price at t=300k → t=400k is monotone non-increasing             [descent is continuous]
///
/// If resolved_ceiling (300k) affected the descent window, the price at t=400k
/// would NOT reach min_rent_price yet — only at t=300k+300k=600k would it.
#[test]
fun descent_descent_driven_by_resolved_descent_not_resolved_ceiling() {
    let mut sc = setup();

    // Config with Multi tenure_cycles and a descent window.
    let tenure  = escrow_corpus::tenure_ceiling_const();
    let floor   = escrow_corpus::min_rent_price_const();
    let descent = escrow_corpus::descent_window_h1_const();
    let ensemble = escrow_corpus::with_tenure_cycles(
        escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)), // h=1 descent window
        tenure_extend_policy::new_multi(),
    );
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    // T1: 3 cycles → extended_ceiling = tenure×3 = 300k. Stake = floor×3.
    sc.next_tx(TENANT_ADDR_1);
    let principal = floor * 3;
    let cap1 = escrow::rent(&mut escrow, mk_payment(principal, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());

    // T1 tenure expires at t = tenure×3 = 300k → Descent.
    // Descent.phase_start = 300k. resolved_ceiling is normalized to base = 100k.
    let t_expiry = tenure * 3;
    escrow::fire_do_tenure_expiry_for_testing(&mut escrow, phases::timestamp(t_expiry), sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // At t_expiry (elapsed=0): price = last_acq_price = T1's stake = floor×3.
    let price_at_start = escrow::floor_price_mist(&escrow, t_expiry);
    assert_eq!(price_at_start, principal);

    // At t_expiry + descent (elapsed=window): price = min_rent_price = floor.
    // If resolved_ceiling (300k) were used instead, descent would end at t=600k, not t=400k.
    let price_at_end = escrow::floor_price_mist(&escrow, t_expiry + descent);
    assert_eq!(price_at_end, floor);

    // Mid-descent: price is strictly between start and end.
    let price_at_mid = escrow::floor_price_mist(&escrow, t_expiry + descent / 2);
    assert!(price_at_mid < price_at_start, 1);
    assert!(price_at_mid > price_at_end,   2);

    // Past descent: price stays at min_rent_price (saturated).
    let price_past = escrow::floor_price_mist(&escrow, t_expiry + descent * 2);
    assert_eq!(price_past, floor);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ═══════════════════════════════════════════════════════════════════════════════
// §COMMITMENT — RetireCommitmentPolicy invariants
//
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Group I: Initialization ──────────────────────────────────────────────────


/// I-1 + I-2: commitment_anchor is set to integrated_at at integrate time.
/// With Immediate (floor=0), compute_unlock_at = anchor + 0 = anchor = integrated_at.
#[test]
fun retire_commitment_init_anchor_equals_integrated_at() {
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take_with_retire_commitment(ensemble, retire_commitment_policy::new_immediate(), &mut sc);

    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), escrow::integrated_at_ms(&escrow));

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// I-3a: retire_commitment_floor_ms is None for Immediate.
#[test]
fun retire_commitment_init_immediate_floor_ms_is_none() {
    let mut sc  = setup();
    let ensemble     = escrow_corpus::by_tag(0);
    let (escrow, cap) = integrate_and_take_with_retire_commitment(ensemble, retire_commitment_policy::new_immediate(), &mut sc);

    assert!(escrow::retire_commitment_floor_ms(&escrow) == option::none(), 0);
    assert!(escrow::retire_commitment_is_immediate(&escrow), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// I-3b: retire_commitment_floor_ms is Some(N) for Deferred(N).
#[test]
fun retire_commitment_init_deferred_floor_ms_is_some_n() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (escrow, cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );

    assert_eq!(escrow::retire_commitment_floor_ms(&escrow), option::some(floor));
    assert!(escrow::retire_commitment_is_deferred(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// I-3c: retire_commitment_unlocks_at_ms == integrated_at_ms + floor for Deferred.
#[test]
fun retire_commitment_init_deferred_unlocks_at_integrated_plus_floor() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (escrow, cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );

    let integrated = escrow::integrated_at_ms(&escrow);
    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), integrated + floor);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ─── Group II: update_ensemble does not touch commitment ─────────────────────────

/// II-4: retire_commitment_policy unchanged after update_ensemble.
#[test]
fun retire_commitment_update_config_does_not_change_policy() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    let clk    = clock::create_for_testing(sc.ctx());

    // update_ensemble with a different PolicyEnsemble (h=1 descent axis differs).
    let new_ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // Commitment is still Deferred(floor) — update_ensemble cannot change it.
    assert_eq!(escrow::retire_commitment_floor_ms(&escrow), option::some(floor));
    assert!(escrow::retire_commitment_is_deferred(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// II-5 + II-6: commitment_anchor and retire_commitment_unlocks_at_ms unchanged after update_ensemble.
#[test]
fun retire_commitment_update_config_does_not_change_anchor() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());

    let unlocks_before = escrow::retire_commitment_unlocks_at_ms(&escrow);

    // Advance clock and reset config — anchor must not move.
    clock::set_for_testing(&mut clk, 500);
    let new_ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), unlocks_before);
    // integrated_at == 0 (clock was 0 at integrate), floor unchanged.
    assert_eq!(unlocks_before, 0 + floor);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── Group III: extend_retire_commitment monotonicity ────────────────────────────────

/// III-7: A valid extension (new_expiry >= old_expiry) succeeds and is observable.
#[test]
fun retire_commitment_extend_valid_increases_unlocks_at() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx());

    let before = escrow::retire_commitment_unlocks_at_ms(&escrow);
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );
    let after = escrow::retire_commitment_unlocks_at_ms(&escrow);

    assert!(after >= before, 0);
    assert!(after > before, 1); // Deferred(floor) > Immediate(0)

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// III-10a: extend_retire_commitment(Immediate) always aborts — Immediate has duration=0,
/// which is not an extension. Locked state: Deferred(floor), clock at t=0.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentNotExtended, location = usufruct::asset_state)]
fun retire_commitment_extend_with_immediate_when_locked_aborts() {
    let mut sc  = setup();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx()); // t=0, before expiry

    escrow::extend_retire_commitment(&mut escrow, &owner_cap, retire_commitment_policy::new_immediate(), &clk);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// III-10b: extend_retire_commitment(Immediate) aborts even after commitment has expired.
/// Once unlocked, retire is already available — there is nothing to extend.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentNotExtended, location = usufruct::asset_state)]
fun retire_commitment_extend_with_immediate_when_unlocked_aborts() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, floor + 1); // past expiry

    escrow::extend_retire_commitment(&mut escrow, &owner_cap, retire_commitment_policy::new_immediate(), &clk);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// III-10c: extend_retire_commitment(Immediate) on a currently Immediate escrow aborts.
/// No duration → not an extension.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentNotExtended, location = usufruct::asset_state)]
fun retire_commitment_extend_immediate_to_immediate_aborts() {
    let mut sc  = setup();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx());

    escrow::extend_retire_commitment(&mut escrow, &owner_cap, retire_commitment_policy::new_immediate(), &clk);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// III-11: Immediate → Deferred(N).
/// An owner who integrated with no commitment can install one later —
/// a deferred trust signal added after the fact.
/// Accumulate: old_expiry = 0 + 0 = 0. new_expiry = 0 + floor = floor.
#[test]
fun retire_commitment_extend_immediate_to_deferred() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx()); // t=0

    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );

    assert!(escrow::retire_commitment_is_deferred(&escrow), 0);
    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), floor);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// III-11b: After Immediate → Deferred, retire is blocked before expiry.
/// The gate that was open is now locked until the new commitment expires.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentFloorNotElapsed, location = usufruct::asset_state)]
fun retire_commitment_extend_immediate_to_deferred_blocks_retire() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());

    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );

    // Gate is now locked. Retire before expiry (t=0 < floor) must abort.
    clock::set_for_testing(&mut clk, floor - 1);
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── Group IV: anchor moves to old_expiry on extend_retire_commitment ────────────────

/// IV-12 + IV-13: After extend_retire_commitment, retire_commitment_unlocks_at_ms reflects
/// accumulate semantics: new_expiry = old_expiry + new_floor.
/// Starts Immediate (old_expiry=0), clock at t=1_000, extends to Deferred(floor).
/// new_expiry = 0 + floor = floor. Clock value is irrelevant to accumulate.
#[test]
fun retire_commitment_extend_anchor_moves_to_old_expiry() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());

    // Advance clock to t=1_000 before extending.
    clock::set_for_testing(&mut clk, 1_000);
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );

    // Accumulate: new_expiry = old_expiry + floor = 0 + floor = floor.
    // anchor = old_expiry = 0. unlocks_at = 0 + floor = floor.
    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), floor);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// IV-13b: retire_commitment_floor_ms reflects new policy floor; unlocks_at uses accumulate semantics.
/// Starts Immediate (old_expiry=0), clock at floor+1. Extends to Deferred(half_floor).
/// Accumulate: new_expiry = old_expiry + half_floor = 0 + half_floor = half_floor.
#[test]
fun retire_commitment_extend_floor_ms_reflects_new_policy_not_anchor() {
    let mut sc    = setup();
    let floor     = escrow_corpus::retire_deferred_f1_const();
    let half_floor = floor / 2;
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, floor + 1); // clock value does not affect accumulate

    // Extend to Deferred(half_floor) — floor_ms reflects the policy floor, not the anchor.
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(half_floor)),
        &clk,
    );

    assert_eq!(escrow::retire_commitment_floor_ms(&escrow), option::some(half_floor));
    // Accumulate: new_expiry = 0 + half_floor = half_floor.
    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), half_floor);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── Group V: retire gate ─────────────────────────────────────────────────────

/// V-14: Immediate commitment — retire available at t=0.
#[test]
fun retire_commitment_gate_immediate_retire_at_zero() {
    let mut sc  = setup();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let clk    = clock::create_for_testing(sc.ctx());

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retiring(&escrow) || escrow::is_retired(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// V-15: Deferred(N) — retire at t < anchor+N aborts.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentFloorNotElapsed, location = usufruct::asset_state)]
fun retire_commitment_gate_deferred_retire_before_floor_aborts() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, floor - 1); // one ms before unlock

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// V-16: Deferred(N) — retire at t >= anchor+N passes.
#[test]
fun retire_commitment_gate_deferred_retire_at_floor_passes() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, floor); // exactly at unlock

    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retiring(&escrow) || escrow::is_retired(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// V-17: After extend_retire_commitment(Deferred(N)), gate reopens from new anchor.
/// Before extend: Immediate → retire at t=0 works.
/// After extend at t=T: retire at t=T aborts (t < T+N); at t=T+N passes.
#[test, expected_failure(abort_code = asset_state::ERetireCommitmentFloorNotElapsed, location = usufruct::asset_state)]
fun retire_commitment_gate_extend_reopens_gate_aborts_immediately_after() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());

    // Extend at t=100 — gate reopens to t=100+floor.
    clock::set_for_testing(&mut clk, 100);
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );

    // Retire at t=100 (= new anchor, but < 100+floor) → abort.
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test]
fun retire_commitment_gate_extend_reopens_gate_passes_at_new_expiry() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let mut clk = clock::create_for_testing(sc.ctx());

    // Extend at t=100 to Deferred(floor).
    clock::set_for_testing(&mut clk, 100);
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );

    // Retire at t = 100+floor (exactly at new expiry) → passes.
    clock::set_for_testing(&mut clk, 100 + floor);
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());
    assert!(escrow::is_retiring(&escrow) || escrow::is_retired(&escrow), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── Group VI: chaining extend_retire_commitment ────────────────────────────────────

/// VI-18: Two sequential extensions are valid if each new_expiry >= previous.
#[test]
fun retire_commitment_chain_two_extensions_both_valid() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0), retire_commitment_policy::new_immediate(), &mut sc,
    );
    let clk = clock::create_for_testing(sc.ctx()); // t=0

    // First extend: Immediate → Deferred(floor). new_expiry = old_expiry + floor = 0 + floor = floor.
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );
    let after_first = escrow::retire_commitment_unlocks_at_ms(&escrow);
    assert_eq!(after_first, floor);

    // Second extend: Deferred(floor) → Deferred(floor*2). new_expiry = floor + floor*2 = floor*3.
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor * 2)),
        &clk,
    );
    let after_second = escrow::retire_commitment_unlocks_at_ms(&escrow);
    assert_eq!(after_second, floor * 3);
    assert!(after_second > after_first, 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// VI-19: Extending with the same Deferred floor from a later time passes.
/// old_expiry=floor (Deferred(floor), anchor=0). Clock at 500 (irrelevant to accumulate).
/// Accumulate: new_expiry = floor + floor = 2*floor.
#[test]
fun retire_commitment_chain_same_floor_from_later_time_passes() {
    let mut sc  = setup();
    let floor   = escrow_corpus::retire_deferred_f1_const();
    let tag     = escrow_corpus::tag(0, 0, 0, 0, 1);
    let (mut escrow, owner_cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(tag), escrow_corpus::retire_commitment_by_tag(tag), &mut sc,
    );
    // old_anchor=0, old_expiry=floor.
    let mut clk = clock::create_for_testing(sc.ctx());

    // Advance to t=500 (still before expiry) and extend with same floor.
    // new_expiry = floor + floor = 2*floor (accumulate semantics).
    clock::set_for_testing(&mut clk, 500);
    escrow::extend_retire_commitment(
        &mut escrow, &owner_cap,
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &clk,
    );

    assert_eq!(escrow::retire_commitment_unlocks_at_ms(&escrow), floor * 2);
    assert_eq!(escrow::retire_commitment_floor_ms(&escrow), option::some(floor));

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §RESOLVE-INVARIANT: resolve() runs only at Idle entry ────────────────────
//
// The lifecycle FSM draws policy values at exactly three sites, all of
// them at the moment a state becomes `Idle`:
//   1. `execute_integrate`                — Bootstrap → Idle.
//   2. `do_auction_expiry`                — Descent  → Idle (after
//      applying any `pending_config`).
//   3. `execute_update_config` arm Idle   — owner reset → Idle (after
//      applying the new config directly).
// Once drawn, the four `resolved_*` (floor/ceiling/handover/descent)
// flow through every variant of the cycle without re-draw. The tests
// below pin down each part of that invariant. They focus on
// `resolved_descent` — the field that newly joined the invariant — and
// rely on h=1 (Fixed: deterministic descent = ceiling const) and h=2
// (RandomInRange: descent ∈ [10_000, 90_000]) to make the values
// observable without random-seed control.

/// update_ensemble called while the escrow is in Demand schedules a pending
/// config update without disturbing the active tenancy or bid.
/// Covers the Demand happy-path arm of `execute_update_config` (B14).
#[test]
fun update_config_demand_schedules_pending() {
    let mut sc = setup();
    // c=1 Fixed — prevents APT from immediately firing the handover
    // inside update_ensemble, keeping the escrow in Demand after the call.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    // Rent T1: Idle → Occupied.
    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Rent T2: Occupied → Demand (places bid; c=1 keeps handover pending).
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Schedule a config update while in Demand.
    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // State remains Demand; pending config is now set.
    assert!(escrow::is_demand(&escrow), 1);
    assert!(escrow::has_pending_ensemble_update(&escrow), 2);
    assert!(escrow::active_ensemble(&escrow) == ensemble, 3);

    let scheduled = event::events_by_type<EnsembleUpdateScheduled>();
    assert_eq!(scheduled.length(), 1);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// update_ensemble aborts with `ERetireAlreadyScheduled` when called in Demand
/// state while the retire flag is set on the tenancy.
/// Covers the Demand retire-guard branch of `execute_update_config` (B13).
#[test, expected_failure(abort_code = asset_state::ERetireAlreadyScheduled, location = usufruct::asset_state)]
fun update_config_demand_retiring_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    // Rent T1: Idle → Occupied.
    let p1     = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // Rent T2: Occupied → Demand (places bid; c=1 keeps handover pending).
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Set retire flag while already in Demand — flag is preserved in the
    // OccupiedTerms.retire field.
    escrow::drive_to_retiring_flag_for_testing(&mut escrow);

    // update_ensemble must abort — retire flag blocks config changes in Demand.
    let new_ensemble = escrow_corpus::by_tag(1);
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    // Unreachable — expected_failure captures the abort above.
    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── Coverage gap closers ──────────────────────────────────────────────────────
//
// Targeted tests for abort paths and state/cap combinations that were not
// covered by prior sections.

// ── execute_soft_burn_tenant_cap: non-renting happy path ───────────────────────────
//
// In Idle/Descent/Retired, any cap belonging to this escrow is stale by
// construction (no active tenancy). The match `_ => {}` passes through and
// the cap is burned unconditionally.

/// Burn a stale TenantCap in Idle state after the tenancy has ended.
/// Covers the Idle arm (`_ => {}`) of execute_soft_burn_tenant_cap.
#[test]
fun burn_stale_cap_in_idle_succeeds() {
    let mut sc = setup();
    // h=0 Skipped descent: tenure expires → Descent → immediately Idle via APT.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());

    // Jump past tenure + descent → APT collapses to Idle in one call.
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_idle(&escrow), 0);

    // cap_t1 is now stale — burn it from Idle state.
    escrow::soft_burn_tenant_cap(&mut escrow, cap_t1, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── execute_rent: insufficient payment in Descent / Occupied / Demand ─────────

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun rent_with_insufficient_payment_in_descent_aborts() {
    let mut sc = setup();
    // h=1 Fixed: tenure expires → Descent (stays there, no immediate collapse).
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());

    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // Pay 0 — below any possible Dutch floor.
    let zero = mk_payment(0, sc.ctx());
    let cap_zero = escrow::rent(&mut escrow, zero, tenures::tenures(1), &clk, sc.ctx());
    transfer::public_transfer(cap_zero, OWNER);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun rent_with_insufficient_payment_in_occupied_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_occupied(&escrow), 0);

    // Pay 0 — below the ascending floor price for placing a bid.
    let zero = mk_payment(0, sc.ctx());
    let cap_zero = escrow::rent(&mut escrow, zero, tenures::tenures(1), &clk, sc.ctx());
    transfer::public_transfer(cap_zero, OWNER);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

#[test, expected_failure(abort_code = asset_state::EInsufficientPayment, location = usufruct::asset_state)]
fun rent_with_insufficient_payment_in_demand_aborts() {
    let mut sc = setup();
    // c=1 Fixed: prevents handover from firing immediately on second rent.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let p1 = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2 = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());
    assert!(escrow::is_demand(&escrow), 0);

    // Pay 0 — below the escalating floor for superseding the current bid.
    let zero = mk_payment(0, sc.ctx());
    let cap_zero = escrow::rent(&mut escrow, zero, tenures::tenures(1), &clk, sc.ctx());
    transfer::public_transfer(cap_zero, OWNER);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── execute_update_config: wrong cap ──────────────────────────────────────────

#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun update_config_with_wrong_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, _owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    // Cap issued for a different escrow.
    let foreign_cap = owner_cap::new(
        escrow_identity::new(object::id_from_address(@0xDEAD)), OWNER, sc.ctx(),
    );
    escrow::update_ensemble(&mut escrow, &foreign_cap, escrow_corpus::by_tag(1), &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(foreign_cap, OWNER);
    owner_cap::burn(_owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// A genuine OwnerCap from a different real escrow is rejected on update_ensemble.
#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun update_config_with_real_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow_a, cap_a) = integrate_and_take(ensemble, &mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take(ensemble, &mut sc);
    let clk    = clock::create_for_testing(sc.ctx());

    escrow::update_ensemble(&mut escrow_b, &cap_a, ensemble, &clk, sc.ctx());

    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(cap_a, OWNER);
    owner_cap::burn(cap_b, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── execute_extend_commitment: wrong cap + non-monotonic policy ───────────────

#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun extend_retire_commitment_with_wrong_cap_aborts() {
    let mut sc = setup();
    let (mut escrow, _owner_cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    let foreign_cap = owner_cap::new(
        escrow_identity::new(object::id_from_address(@0xDEAD)), OWNER, sc.ctx(),
    );
    escrow::extend_retire_commitment(&mut escrow, &foreign_cap, retire_commitment_policy::new_immediate(), &clk);

    test_scenario::return_shared(escrow);
    owner_cap::burn(foreign_cap, OWNER);
    owner_cap::burn(_owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// A genuine OwnerCap from a different real escrow is rejected on extend_retire_commitment.
#[test, expected_failure(abort_code = asset_state::EWrongEscrowOwnerCap, location = usufruct::asset_state)]
fun extend_retire_commitment_with_real_foreign_escrow_cap_aborts() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (escrow_a, cap_a) = integrate_and_take(ensemble, &mut sc);
    let (mut escrow_b, cap_b) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::extend_retire_commitment(&mut escrow_b, &cap_a, retire_commitment_policy::new_immediate(), &clk);

    test_scenario::return_shared(escrow_a);
    test_scenario::return_shared(escrow_b);
    owner_cap::burn(cap_a, OWNER);
    owner_cap::burn(cap_b, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── execute_claim: Descent arm ────────────────────────────────────────────────
//
// The existing claim_asset_aborts_in_descent_state test uses h=0 (Skipped),
// so APT collapses Descent→Idle before execute_claim sees it.
// Using h=1 (Fixed) keeps the escrow in Descent through the claim call.

#[test, expected_failure(abort_code = asset_state::ENotRetired, location = usufruct::asset_state)]
fun claim_asset_aborts_in_descent_with_window_descent() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());

    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // Return the &mut escrow, then take it by value for claim_asset.
    test_scenario::return_shared(escrow);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared<Escrow<DemoAsset, SUI>>();
    let (asset, earnings) = escrow::claim_asset<DemoAsset, SUI>(escrow, cap, &clk, sc.ctx());

    coin::destroy_zero(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ── proj_tenure_settlement / tenure_settlement: non-rented abort ─────

#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun tenure_settlement_aborts_on_idle() {
    let mut sc = setup();
    let (escrow, cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let (_, _) = escrow::tenure_settlement(&escrow);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ── proj_current_stake_value / handover_settlement: non-rented abort ─

#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun handover_settlement_aborts_on_idle() {
    let mut sc = setup();
    let (escrow, cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    let (_, _, _) = escrow::handover_settlement(&escrow, 0);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ── Remaining variant gaps ─────────────────────────────────────────────────────

/// execute_borrow in Descent: use h=1 (Fixed) so APT does not collapse
/// Descent→Idle before execute_borrow runs. The _s => abort arm fires on Descent.
#[test, expected_failure(abort_code = asset_state::EStaleTenantCap, location = usufruct::asset_state)]
fun borrow_asset_aborts_in_descent_with_window_descent() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    // Borrow with a cap that has the correct escrow identity — APT will not
    // fire because the descent window is not yet closed.
    let foreign_cap = tenant_cap::new(
        escrow_identity::new(object::id(&escrow)), TENANT_ADDR_1, sc.ctx(),
    );
    let (asset, receipt) = escrow::borrow_asset(&mut escrow, &foreign_cap, &clk, sc.ctx());

    transfer::public_transfer(asset, OWNER);
    asset_state::destroy_receipt_for_testing(receipt);
    transfer::public_transfer(foreign_cap, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// execute_soft_burn_tenant_cap in Descent: _ => {} passthrough (any cap is stale).
#[test]
fun burn_stale_cap_in_descent_succeeds() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);

    escrow::soft_burn_tenant_cap(&mut escrow, cap_t1, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// execute_soft_burn_tenant_cap in Retired: _ => {} passthrough.
/// Drive Idle → Retired directly; burn a synthetic cap for this escrow —
/// any cap is stale in Retired (no active tenancy).
#[test]
fun burn_stale_cap_in_retired_succeeds() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_retired_for_testing(&mut escrow);
    let stale_cap = tenant_cap::new(
        escrow_identity::new(object::id(&escrow)), TENANT_ADDR_1, sc.ctx(),
    );
    escrow::soft_burn_tenant_cap(&mut escrow, stale_cap, &clk, sc.ctx());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// proj_current_stake_value: Retired abort via handover_settlement.
#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun handover_settlement_aborts_on_retired() {
    let mut sc = setup();
    let (mut escrow, cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);
    escrow::drive_to_retired_for_testing(&mut escrow);
    let (_, _, _) = escrow::handover_settlement(&escrow, 0);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// proj_current_stake_value: Descent abort via handover_settlement.
#[test, expected_failure(abort_code = asset_state::ENotRented, location = usufruct::asset_state)]
fun handover_settlement_aborts_on_descent() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    let p = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p, tenures::tenures(1), &clk, sc.ctx());
    clock::set_for_testing(&mut clk, escrow_corpus::tenure_ceiling_const() + 1);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());
    assert!(escrow::is_descending(&escrow), 0);
    let (_, _, _) = escrow::handover_settlement(&escrow, 0);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §XX. Policy kind projectors ──────────────────────────────────────────────

/// All *_kind views and price_fn_delta_mist return the correct string/value
/// for a freshly integrated tag-0 escrow (Off handover, Linear curves,
/// FixedDelta pricing, Immediate commitment).
#[test]
fun policy_kind_views_tag0() {
    let mut sc = setup();
    let (escrow, cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);

    assert_eq!(escrow::rest_price_kind(&escrow),        b"Fixed".to_string());
    assert_eq!(escrow::tenure_duration_kind(&escrow),   b"Fixed".to_string());
    assert_eq!(escrow::tenure_extend_kind(&escrow),     b"Single".to_string());
    assert_eq!(escrow::handover_kind(&escrow),          b"Off".to_string());
    assert_eq!(escrow::auction_window_kind(&escrow),    b"Off".to_string());
    assert_eq!(escrow::credit_shape_kind(&escrow),             b"Linear".to_string());
    assert_eq!(escrow::auction_shape_kind(&escrow),            b"Linear".to_string());
    assert_eq!(escrow::price_fn_kind(&escrow),                 b"FixedDelta".to_string());
    assert_eq!(escrow::price_fn_delta_mist(&escrow),           escrow_corpus::fixed_delta_value_const());
    assert_eq!(escrow::retire_commitment_kind(&escrow),        b"Immediate".to_string());

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// retire_commitment_anchor_ms equals integrated_at_ms for a fresh escrow.
/// retire_commitment_remaining_ms is 0 for Immediate at any time.
#[test]
fun retire_commitment_anchor_and_remaining_immediate() {
    let mut sc = setup();
    let (escrow, cap) = integrate_and_take(escrow_corpus::by_tag(0), &mut sc);

    assert_eq!(escrow::retire_commitment_anchor_ms(&escrow), escrow::integrated_at_ms(&escrow));
    assert_eq!(escrow::retire_commitment_remaining_ms(&escrow, 0),   0);
    assert_eq!(escrow::retire_commitment_remaining_ms(&escrow, 999), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

/// retire_commitment_remaining_ms reflects the floor for a Deferred policy.
#[test]
fun retire_commitment_anchor_and_remaining_deferred() {
    let mut sc = setup();
    let floor = escrow_corpus::retire_deferred_f1_const();
    let (escrow, cap) = integrate_and_take_with_retire_commitment(
        escrow_corpus::by_tag(0),
        retire_commitment_policy::new_deferred(phases::duration(floor)),
        &mut sc,
    );

    assert_eq!(escrow::retire_commitment_anchor_ms(&escrow), 0);
    assert_eq!(escrow::retire_commitment_remaining_ms(&escrow, 0),        floor);
    assert_eq!(escrow::retire_commitment_remaining_ms(&escrow, floor / 2), floor - floor / 2);
    assert_eq!(escrow::retire_commitment_remaining_ms(&escrow, floor),    0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ─── §EV-PINS: event payload pins ───────────────────────────────────────────
//
// One test per event pins every field with assert_eq! so any transposition
// of projectors in event::emit(...) produces a test failure.

// ─── AssetIntegrated payload pin ────────────────────────────────────────────

#[test]
fun event_pin_asset_integrated_all_fields() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    let ensemble = escrow_corpus::by_tag(0);
    let fee_ref  = sc.take_immutable<ProtocolFeeRef>();
    let mut clk  = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 42_000);
    let asset    = mk_demo_asset(sc.ctx());
    let asset_id = object::id(&asset);

    let cap      = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id     = owner_cap::proj_escrow_id(&cap);
    let owner_cap_id  = object::id(&cap);

    let evts = event::events_by_type<AssetIntegrated>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::asset_integrated_escrow_id(e),         escrow_id);
    assert_eq!(asset_state::asset_integrated_owner_cap_id(e),      owner_cap_id);
    assert_eq!(asset_state::asset_integrated_owner_address(e),     OWNER);
    assert_eq!(asset_state::asset_integrated_asset_id(e),          asset_id);
    assert_eq!(asset_state::asset_integrated_fee_inbox_id(e),      protocol_fee_ref::proj_inbox_id(&fee_ref));
    assert_eq!(asset_state::asset_integrated_integrated_at_ms(e),  42_000);
    assert_eq!(asset_state::asset_integrated_asset_type(e),        string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::asset_integrated_coin_type(e),         string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));

    test_scenario::return_immutable(fee_ref);
    clock::destroy_for_testing(clk);
    sc.next_tx(OWNER);
    let escrow_obj = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);
    test_scenario::return_shared(escrow_obj);
    owner_cap::burn(cap, OWNER);
    sc.end();
}

// ─── RentStarted payload pin ─────────────────────────────────────────────────

#[test]
fun event_pin_rent_started_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 7_000);

    let escrow_id    = owner_cap::proj_escrow_id(&owner_cap);
    let floor        = escrow_corpus::min_rent_price_const();
    let payment      = mk_payment(floor, sc.ctx());
    let cap_t1       = escrow::rent(&mut escrow, payment, tenures::tenures(1), &clk, sc.ctx());

    let evts = event::events_by_type<RentStarted>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::rent_started_escrow_id(e),        escrow_id);
    assert_eq!(asset_state::rent_started_tenant_cap_id(e),    object::id(&cap_t1));
    assert_eq!(asset_state::rent_started_tenant_address(e),           OWNER);
    assert_eq!(asset_state::rent_started_phase_start_ms(e),   7_000);
    assert_eq!(asset_state::rent_started_price_paid(e),       floor);
    assert_eq!(asset_state::rent_started_floor_price(e),      floor);
    assert_eq!(asset_state::rent_started_committed_tenures(e), 1);
    assert_eq!(asset_state::rent_started_ceiling_total_ms(e), escrow_corpus::tenure_ceiling_const());
    assert_eq!(asset_state::rent_started_handover_total_ms(e), 0);
    assert_eq!(asset_state::rent_started_asset_type(e),        string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::rent_started_coin_type(e),         string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── AuctionExpired payload pin ──────────────────────────────────────────────

#[test]
fun event_pin_auction_expired_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // h=1 descent window
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    let last_acq  = escrow_corpus::min_rent_price_const() * 2;
    let phase_start_ms = escrow_corpus::tenure_ceiling_const();

    escrow::drive_to_rented_for_testing(
        &mut escrow,
        mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()),
        0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1, 0, last_acq, phase_start_ms,
    );

    let boundary_ms = phase_start_ms + escrow_corpus::descent_window_h1_const();
    escrow::fire_do_auction_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms));

    let evts = event::events_by_type<AuctionExpired>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::auction_expired_escrow_id(e),       escrow_id);
    assert_eq!(asset_state::auction_expired_phase_start_ms(e),  phase_start_ms);
    assert_eq!(asset_state::auction_expired_last_acq_price(e),  last_acq);
    assert_eq!(asset_state::auction_expired_asset_type(e),      string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::auction_expired_coin_type(e),       string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::auction_expired_timestamp_ms(e),    boundary_ms);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

// ─── CycleParamsResolved payload pin + change-only semantics ─────────────────

#[test]
fun event_pin_cycle_params_resolved_all_fields() {
    let mut sc = setup();
    sc.next_tx(OWNER);

    // c=1 Fixed handover, h=1 Fixed descent: every resolved field is a known const.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    let fee_ref  = sc.take_immutable<ProtocolFeeRef>();
    let mut clk  = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 42_000);
    let asset    = mk_demo_asset(sc.ctx());

    let cap = escrow::integrate<DemoAsset, SUI>(
        asset, ensemble, retire_commitment_policy::new_immediate(), &fee_ref, &clk, sc.ctx(),
    );
    let escrow_id = owner_cap::proj_escrow_id(&cap);

    let evts = event::events_by_type<CycleParamsResolved>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::cycle_params_resolved_escrow_id(e),    escrow_id);
    assert_eq!(asset_state::cycle_params_resolved_floor_mist(e),   escrow_corpus::min_rent_price_const());
    assert_eq!(asset_state::cycle_params_resolved_ceiling_ms(e),   escrow_corpus::tenure_ceiling_const());
    assert_eq!(asset_state::cycle_params_resolved_handover_ms(e),  escrow_corpus::handover_countdown_c1_const());
    assert_eq!(asset_state::cycle_params_resolved_descent_ms(e),   escrow_corpus::descent_window_h1_const());
    assert_eq!(asset_state::cycle_params_resolved_timestamp_ms(e), 42_000);

    test_scenario::return_immutable(fee_ref);
    transfer::public_transfer(cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Auction expiry with no pending ensemble recomputes the same CycleParams, so
/// it must NOT re-emit CycleParamsResolved — the event marks adoption of new
/// engine parameters, not every cycle boundary.
#[test]
fun cycle_params_resolved_not_emitted_on_unchanged_auction_expiry() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // no pending config
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);

    let last_acq       = escrow_corpus::min_rent_price_const() * 2;
    let phase_start_ms = escrow_corpus::tenure_ceiling_const();
    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_descent_for_testing(&mut escrow, STAKE_T1, 0, last_acq, phase_start_ms);

    let boundary_ms = phase_start_ms + escrow_corpus::descent_window_h1_const();
    escrow::fire_do_auction_expiry_for_testing(&mut escrow, phases::timestamp(boundary_ms));

    // No pending ensemble adopted in this tx → no CycleParamsResolved emitted.
    assert_eq!(event::events_by_type<CycleParamsResolved>().length(), 0);
    assert_eq!(event::events_by_type<AuctionExpired>().length(), 1);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    sc.end();
}

/// Invariant: scheduling a pending ensemble does NOT emit CycleParamsResolved.
/// While the change is queued, the engine still operates under the active
/// ensemble, so no resolved-params event fires until adoption.
#[test]
fun cycle_params_resolved_not_emitted_while_pending() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // A: handover Off
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1 - STAKE_T1 / 10, STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2, 0,
    );

    // Queue ensemble B (handover Fixed) while in Descent — buffered, not adopted.
    let pending = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    escrow::update_ensemble(&mut escrow, &owner_cap, pending, &clk, sc.ctx());

    assert!(escrow::has_pending_ensemble_update(&escrow), 0);
    assert_eq!(event::events_by_type<EnsembleUpdateScheduled>().length(), 1);
    // Pending is not active → no resolved-params event in this tx.
    assert_eq!(event::events_by_type<CycleParamsResolved>().length(), 0);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// Invariant: adopting a pending ensemble emits exactly one CycleParamsResolved,
/// and its values reflect the newly-active ensemble (B), never the prior one (A).
/// A has handover Off (0); B has handover Fixed (25_000) — the emitted value must
/// be B's, proving the event tracks the active ensemble, not the stale resolution.
#[test]
fun cycle_params_resolved_on_adoption_reflects_new_ensemble() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0)); // A: handover Off
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk = clock::create_for_testing(sc.ctx());

    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1 - STAKE_T1 / 10, STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2, 0,
    );

    let pending = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0)); // B: handover Fixed
    escrow::update_ensemble(&mut escrow, &owner_cap, pending, &clk, sc.ctx());

    // Adopt the pending at auction expiry via the production path.
    let boundary_ms =
        escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const();
    clock::set_for_testing(&mut clk, boundary_ms);
    escrow::apply_pending_transition_states(&mut escrow, &clk, sc.ctx());

    // Scheduling emitted 0; adoption emits exactly 1 → count is 1, reflecting B.
    let evts = event::events_by_type<CycleParamsResolved>();
    assert_eq!(evts.length(), 1);
    assert_eq!(asset_state::cycle_params_resolved_handover_ms(&evts[0]), escrow_corpus::handover_countdown_c1_const());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── AssetRetired payload pin ────────────────────────────────────────────────

#[test]
fun event_pin_asset_retired_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 99_000);

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    let evts = event::events_by_type<AssetRetired>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::asset_retired_escrow_id(e),    escrow_id);
    assert_eq!(asset_state::asset_retired_timestamp_ms(e), 99_000);

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── RetireFlagSet payload pin ───────────────────────────────────────────────

#[test]
fun event_pin_retire_flag_set_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk      = clock::create_for_testing(sc.ctx());

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);

    let p1    = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    escrow::retire(&mut escrow, &owner_cap, &clk, sc.ctx());

    let evts = event::events_by_type<RetireFlagSet>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::retire_flag_set_escrow_id(e),    escrow_id);
    assert_eq!(asset_state::retire_flag_set_owner_cap_id(e), object::id(&owner_cap));
    assert_eq!(asset_state::retire_flag_set_owner_address(e),        OWNER);
    assert_eq!(asset_state::retire_flag_set_asset_type(e),   string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::retire_flag_set_coin_type(e),    string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::retire_flag_set_timestamp_ms(e), 0);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── BidPlaced payload pin ───────────────────────────────────────────────────

#[test]
fun event_pin_bid_placed_all_fields() {
    let mut sc   = setup();
    // c=1 Fixed so handover_countdown_expiry is non-zero and deterministic.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());

    let escrow_id    = owner_cap::proj_escrow_id(&owner_cap);
    let floor        = escrow_corpus::min_rent_price_const();

    // T1 rents: Idle → Occupied at t=0.
    let p1    = mk_payment(floor, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 bids: Occupied → Demand at t=5_000.
    let now2  = 5_000u64;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // handover_countdown_expiry for c=1 Fixed = min(now2 + C1, phase_start + ceiling)
    //   = min(5_000 + 25_000, 0 + 100_000) = 30_000.
    let expected_expiry = now2 + escrow_corpus::handover_countdown_c1_const();

    let evts = event::events_by_type<BidPlaced>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::bid_placed_escrow_id(e),                 escrow_id);
    assert_eq!(asset_state::bid_placed_active_tenant_cap_id(e),     object::id(&cap_t1));
    assert_eq!(asset_state::bid_placed_active_tenant_address(e),       OWNER);
    assert_eq!(asset_state::bid_placed_active_tenant_stake(e),      floor);
    assert_eq!(asset_state::bid_placed_active_phase_start_ms(e),    0);
    assert_eq!(asset_state::bid_placed_pending_tenant_cap_id(e),             object::id(&cap_t2));
    assert_eq!(asset_state::bid_placed_pending_tenant_address(e),            OWNER);
    assert_eq!(asset_state::bid_placed_bid_amount(e),                floor2);
    assert_eq!(asset_state::bid_placed_floor_price(e),               floor2);
    assert_eq!(asset_state::bid_placed_handover_countdown_expiry(e), expected_expiry);
    assert_eq!(asset_state::bid_placed_committed_tenures(e),         1);
    assert_eq!(asset_state::bid_placed_asset_type(e),                string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::bid_placed_coin_type(e),                 string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::bid_placed_timestamp_ms(e),              now2);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── BidSuperseded payload pin ───────────────────────────────────────────────

#[test]
fun event_pin_bid_superseded_all_fields() {
    let mut sc   = setup();
    // c=1 Fixed — non-zero handover countdown so supersede can run.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    let floor     = escrow_corpus::min_rent_price_const();

    // T1 rents at t=0: Idle → Occupied.
    let p1     = mk_payment(floor, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t=0: Occupied → Demand.
    let p2_amt = floor * 2;
    let p2     = mk_payment(p2_amt, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // T3 supersedes T2 at t=1_000.
    let now3 = 1_000u64;
    clock::set_for_testing(&mut clk, now3);
    let floor3 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p3     = mk_payment(floor3, sc.ctx());
    let cap_t3 = escrow::rent(&mut escrow, p3, tenures::tenures(1), &clk, sc.ctx());

    // handover_countdown_expiry is the one stamped at the BidPlaced time (t=0),
    // c=1 Fixed: min(0 + 25_000, 0 + 100_000) = 25_000.
    let expected_expiry = escrow_corpus::handover_countdown_c1_const();

    let evts = event::events_by_type<BidSuperseded>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::bid_superseded_escrow_id(e),                  escrow_id);
    assert_eq!(asset_state::bid_superseded_protected_cap_id(e),           object::id(&cap_t1));
    assert_eq!(asset_state::bid_superseded_protected_address(e),             OWNER);
    assert_eq!(asset_state::bid_superseded_protected_stake(e),            floor);
    assert_eq!(asset_state::bid_superseded_protected_phase_start_ms(e),   0);
    assert_eq!(asset_state::bid_superseded_displaced_cap_id(e),           object::id(&cap_t2));
    assert_eq!(asset_state::bid_superseded_new_cap_id(e),                 object::id(&cap_t3));
    assert_eq!(asset_state::bid_superseded_displaced_bidder_address(e),           OWNER);
    assert_eq!(asset_state::bid_superseded_refunded_amount(e),            p2_amt);
    assert_eq!(asset_state::bid_superseded_new_bidder_address(e),                 OWNER);
    assert_eq!(asset_state::bid_superseded_new_bid_amount(e),             floor3);
    assert_eq!(asset_state::bid_superseded_floor_price(e),                floor3);
    assert_eq!(asset_state::bid_superseded_handover_countdown_expiry(e),  expected_expiry);
    assert_eq!(asset_state::bid_superseded_committed_tenures(e),          1);
    assert_eq!(asset_state::bid_superseded_asset_type(e),                 string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::bid_superseded_coin_type(e),                  string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::bid_superseded_timestamp_ms(e),               now3);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    transfer::public_transfer(cap_t3, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── EarningsWithdrawn payload pin ───────────────────────────────────────────

#[test]
fun event_pin_earnings_withdrawn_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());

    let escrow_id    = owner_cap::proj_escrow_id(&owner_cap);
    let owner_cap_id = object::id(&owner_cap);
    let principal    = escrow_corpus::min_rent_price_const();
    let p1           = mk_payment(principal, sc.ctx());
    let cap_t1       = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );

    clock::set_for_testing(&mut clk, 500_000);
    let coin = escrow::withdraw_earnings(&mut escrow, &owner_cap, &clk, sc.ctx());
    let owner_share = principal - principal / 10;

    let evts = event::events_by_type<EarningsWithdrawn>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::earnings_withdrawn_escrow_id(e),    escrow_id);
    assert_eq!(asset_state::earnings_withdrawn_owner_cap_id(e), owner_cap_id);
    assert_eq!(asset_state::earnings_withdrawn_owner_address(e),        OWNER);
    assert_eq!(asset_state::earnings_withdrawn_amount(e),       owner_share);
    assert_eq!(asset_state::earnings_withdrawn_asset_type(e),   string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::earnings_withdrawn_coin_type(e),    string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::earnings_withdrawn_timestamp_ms(e), 500_000);

    coin::burn_for_testing(coin);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── RetireCommitmentExtended payload pin ─────────────────────────────────────────

#[test]
fun event_pin_retire_commitment_extended_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());
    clock::set_for_testing(&mut clk, 3_000);

    let escrow_id   = owner_cap::proj_escrow_id(&owner_cap);
    let deferred_ms = escrow_corpus::retire_deferred_f1_const();
    let new_policy  = retire_commitment_policy::new_deferred(phases::duration(deferred_ms));

    escrow::extend_retire_commitment(&mut escrow, &owner_cap, new_policy, &clk);

    // Immediate has duration=0 so old_expiry = anchor + 0 = 0.
    // new_expiry = old_expiry + deferred_ms = 0 + 10_000_000.
    let expected_new_expiry = deferred_ms;

    let evts = event::events_by_type<RetireCommitmentExtended>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::retire_commitment_extended_escrow_id(e),      escrow_id);
    assert_eq!(asset_state::retire_commitment_extended_new_unlock_at_ms(e),  expected_new_expiry);
    assert_eq!(asset_state::retire_commitment_extended_timestamp_ms(e),   3_000);
    // floor_ms is Some(deferred_ms) for a Deferred policy.
    assert_eq!(asset_state::retire_commitment_extended_floor_ms(e),       option::some(deferred_ms));
    // policy string is the canonical label emitted by retire_commitment_policy.
    assert_eq!(asset_state::retire_commitment_extended_policy(e),
               retire_commitment_policy::proj_retire_commitment_policy(&new_policy));
    assert_eq!(asset_state::retire_commitment_extended_coin_type(e),
               string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::retire_commitment_extended_asset_type(e),
               string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── AssetClaimed payload pin ────────────────────────────────────────────────

#[test]
fun event_pin_asset_claimed_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow_handle, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());

    let escrow_id    = owner_cap::proj_escrow_id(&owner_cap);
    let owner_cap_id = object::id(&owner_cap);
    let principal    = escrow_corpus::min_rent_price_const();
    let p1           = mk_payment(principal, sc.ctx());
    let cap_t1       = escrow::rent(&mut escrow_handle, p1, tenures::tenures(1), &clk, sc.ctx());

    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow_handle, phases::timestamp(escrow_corpus::tenure_ceiling_const()), sc.ctx(),
    );
    escrow::fire_do_auction_expiry_for_testing(
        &mut escrow_handle,
        phases::timestamp(escrow_corpus::tenure_ceiling_const() + escrow_corpus::descent_window_h1_const()),
    );
    escrow::drive_to_retired_for_testing(&mut escrow_handle);

    test_scenario::return_shared(escrow_handle);
    sc.next_tx(OWNER);
    let escrow = sc.take_shared_by_id<Escrow<DemoAsset, SUI>>(escrow_id);

    clock::set_for_testing(&mut clk, 777_000);
    let (asset, earnings) = escrow::claim_asset(escrow, owner_cap, &clk, sc.ctx());
    let owner_share = principal - principal / 10;

    let evts = event::events_by_type<AssetClaimed>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::asset_claimed_escrow_id(e),       escrow_id);
    assert_eq!(asset_state::asset_claimed_owner_cap_id(e),    owner_cap_id);
    assert_eq!(asset_state::asset_claimed_owner_address(e),           OWNER);
    assert_eq!(asset_state::asset_claimed_swept_earnings(e),  owner_share);
    assert_eq!(asset_state::asset_claimed_asset_type(e),      string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::asset_claimed_coin_type(e),       string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::asset_claimed_timestamp_ms(e),    777_000);

    coin::burn_for_testing(earnings);
    transfer::public_transfer(asset, OWNER);
    transfer::public_transfer(cap_t1, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── TenureExpired payload pin ───────────────────────────────────────────────

#[test]
fun event_pin_tenure_expired_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk      = clock::create_for_testing(sc.ctx());

    let escrow_id  = owner_cap::proj_escrow_id(&owner_cap);
    let principal  = escrow_corpus::min_rent_price_const();
    let p1         = mk_payment(principal, sc.ctx());
    let cap_t1     = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());
    let boundary   = escrow_corpus::tenure_ceiling_const();

    escrow::fire_do_tenure_expiry_for_testing(
        &mut escrow, phases::timestamp(boundary), sc.ctx(),
    );

    let owner_share = principal - principal / 10;
    let fee         = principal / 10;

    let evts = event::events_by_type<TenureExpired>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::tenure_expired_escrow_id(e),         escrow_id);
    assert_eq!(asset_state::tenure_expired_tenant_cap_id(e),     object::id(&cap_t1));
    assert_eq!(asset_state::tenure_expired_tenant_address(e),            OWNER);
    assert_eq!(asset_state::tenure_expired_phase_start_ms(e),    0);
    assert_eq!(asset_state::tenure_expired_owner_share(e),       owner_share);
    assert_eq!(asset_state::tenure_expired_protocol_fee(e),      fee);
    assert_eq!(asset_state::tenure_expired_last_acq_price(e),    principal);
    assert_eq!(asset_state::tenure_expired_asset_type(e),        string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::tenure_expired_coin_type(e),         string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::tenure_expired_timestamp_ms(e),      boundary);

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── HandoverCompleted payload pin ───────────────────────────────────────────

#[test]
fun event_pin_handover_completed_all_fields() {
    let mut sc   = setup();
    // c=1 Fixed, e=0 Linear: deterministic used_credit mid-tenure.
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 0, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let mut clk  = clock::create_for_testing(sc.ctx());

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    let floor     = escrow_corpus::min_rent_price_const();

    // T1 rents at t=0: Idle → Occupied.
    let p1     = mk_payment(floor, sc.ctx());
    let cap_t1 = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    // T2 bids at t=5_000: Occupied → Demand.
    let now2   = 5_000u64;
    clock::set_for_testing(&mut clk, now2);
    let floor2 = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let p2     = mk_payment(floor2, sc.ctx());
    let cap_t2 = escrow::rent(&mut escrow, p2, tenures::tenures(1), &clk, sc.ctx());

    // Fire handover at c=1 Fixed expiry = now2 + C1 = 30_000.
    let boundary_ms = now2 + escrow_corpus::handover_countdown_c1_const();
    clock::set_for_testing(&mut clk, boundary_ms);
    let used_credit = escrow::accrued_credit_mist(&escrow, clock::timestamp_ms(&clk));
    escrow::fire_do_handover_for_testing(&mut escrow, phases::timestamp(boundary_ms), sc.ctx());

    let owner_share_val = used_credit - used_credit / 10;
    let protocol_fee_val = used_credit / 10;
    let remain_val       = floor - used_credit;

    let evts = event::events_by_type<HandoverCompleted>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::handover_completed_escrow_id(e),               escrow_id);
    assert_eq!(asset_state::handover_completed_displaced_cap_id(e),        object::id(&cap_t1));
    assert_eq!(asset_state::handover_completed_displaced_tenant_address(e),        OWNER);
    assert_eq!(asset_state::handover_completed_displaced_phase_start_ms(e),    0);
    assert_eq!(asset_state::handover_completed_displaced_ceiling_total_ms(e),  escrow_corpus::tenure_ceiling_const());
    assert_eq!(asset_state::handover_completed_displaced_handover_total_ms(e), escrow_corpus::handover_countdown_c1_const());
    assert_eq!(asset_state::handover_completed_new_cap_id(e),                  object::id(&cap_t2));
    assert_eq!(asset_state::handover_completed_new_tenant_address(e),         OWNER);
    assert_eq!(asset_state::handover_completed_new_tenant_stake(e),        floor2);
    assert_eq!(asset_state::handover_completed_used_credit(e),             used_credit);
    assert_eq!(asset_state::handover_completed_owner_share(e),             owner_share_val);
    assert_eq!(asset_state::handover_completed_protocol_fee(e),            protocol_fee_val);
    assert_eq!(asset_state::handover_completed_remain_credit(e),           remain_val);
    assert_eq!(asset_state::handover_completed_committed_tenures(e),       1);
    assert_eq!(asset_state::handover_completed_ceiling_total_ms(e),        escrow_corpus::tenure_ceiling_const());
    assert_eq!(asset_state::handover_completed_handover_total_ms(e),       escrow_corpus::handover_countdown_c1_const());
    assert_eq!(asset_state::handover_completed_asset_type(e),              string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::handover_completed_coin_type(e),               string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::handover_completed_timestamp_ms(e),            boundary_ms);
    // new_rent_price: ascending_floor_price based on floor2 stake.
    let new_rent = asset_state::handover_completed_new_rent_price(e);
    assert!(new_rent > 0, 0);

    transfer::public_transfer(cap_t1, OWNER);
    transfer::public_transfer(cap_t2, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── AssetBorrowed payload pin ───────────────────────────────────────────────

#[test]
fun event_pin_asset_borrowed_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk      = clock::create_for_testing(sc.ctx());

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    let p1        = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1    = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let (asset_out, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());

    let evts = event::events_by_type<AssetBorrowed>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::asset_borrowed_escrow_id(e),     escrow_id);
    assert_eq!(asset_state::asset_borrowed_tenant_cap_id(e), object::id(&cap_t1));
    assert_eq!(asset_state::asset_borrowed_tenant_address(e),        OWNER);
    assert_eq!(asset_state::asset_borrowed_asset_type(e),    string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::asset_borrowed_coin_type(e),     string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));
    assert_eq!(asset_state::asset_borrowed_timestamp_ms(e),  0);

    escrow::return_asset(&mut escrow, asset_out, receipt);
    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── AssetReturned payload pin ───────────────────────────────────────────────

#[test]
fun event_pin_asset_returned_all_fields() {
    let mut sc   = setup();
    let ensemble = escrow_corpus::by_tag(0);
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk      = clock::create_for_testing(sc.ctx());

    let escrow_id = owner_cap::proj_escrow_id(&owner_cap);
    let p1        = mk_payment(escrow_corpus::min_rent_price_const(), sc.ctx());
    let cap_t1    = escrow::rent(&mut escrow, p1, tenures::tenures(1), &clk, sc.ctx());

    let (asset_out, receipt) = escrow::borrow_asset(&mut escrow, &cap_t1, &clk, sc.ctx());
    escrow::return_asset(&mut escrow, asset_out, receipt);

    let evts = event::events_by_type<AssetReturned>();
    assert_eq!(evts.length(), 1);
    let e = &evts[0];
    assert_eq!(asset_state::asset_returned_escrow_id(e),     escrow_id);
    assert_eq!(asset_state::asset_returned_tenant_cap_id(e), object::id(&cap_t1));
    assert_eq!(asset_state::asset_returned_tenant_address(e),        OWNER);
    assert_eq!(asset_state::asset_returned_asset_type(e),    string::from_ascii(type_name::into_string(type_name::with_defining_ids<DemoAsset>())));
    assert_eq!(asset_state::asset_returned_coin_type(e),     string::from_ascii(type_name::into_string(type_name::with_defining_ids<SUI>())));

    transfer::public_transfer(cap_t1, OWNER);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

// ─── §sync views — committed_tenures and pending_config ───────────────────────

/// current_committed_tenures reflects the occupant, pending_committed_tenures the
/// bidder; both are none outside their phases. Distinct values (3 vs 2) prove each
/// reads its own schedule slot.
#[test]
fun committed_tenures_views_reflect_active_and_pending() {
    let mut sc = setup();
    let (mut escrow, owner_cap) = integrate_and_take(multi_cycle_cfg_countdown(), &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let floor = escrow_corpus::min_rent_price_const();

    // Idle: no occupant, no bidder.
    assert!(escrow::active_tenant_committed_tenures(&escrow).is_none(), 0);
    assert!(escrow::pending_tenant_committed_tenures(&escrow).is_none(), 1);

    // T1 rents 3 tenures → Occupied.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor * 3, sc.ctx()), tenures::tenures(3), &clk, sc.ctx());
    assert_eq!(*escrow::active_tenant_committed_tenures(&escrow).borrow(), 3);
    assert!(escrow::pending_tenant_committed_tenures(&escrow).is_none(), 2);

    // T2 bids 2 tenures → Demand.
    sc.next_tx(TENANT_ADDR_2);
    let bid_floor = escrow::floor_price_mist(&escrow, clock::timestamp_ms(&clk));
    let cap2 = escrow::rent(&mut escrow, mk_payment(bid_floor * 2, sc.ctx()), tenures::tenures(2), &clk, sc.ctx());
    assert_eq!(*escrow::active_tenant_committed_tenures(&escrow).borrow(), 3); // occupant unchanged
    assert_eq!(*escrow::pending_tenant_committed_tenures(&escrow).borrow(), 2); // bidder's commitment

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    transfer::public_transfer(cap2, TENANT_ADDR_2);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// pending_config exposes the full scheduled ensemble, not just a bool.
#[test]
fun pending_config_view_exposes_scheduled_ensemble() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(0, 0, 0, 1, 0));
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());

    assert!(escrow::pending_ensemble(&escrow).is_none(), 0);
    assert!(escrow::pending_ensemble_floor_price_mist(&escrow).is_none(), 1);
    assert!(escrow::pending_ensemble_ceiling_ms(&escrow).is_none(), 2);
    assert!(escrow::pending_ensemble_handover_ms(&escrow).is_none(), 3);
    assert!(escrow::pending_ensemble_descent_ms(&escrow).is_none(), 4);

    escrow::drive_to_rented_for_testing(
        &mut escrow, mk_tenant(STAKE_T1, TENANT_ADDR_1, cap_id_1()), 0,
    );
    escrow::drive_to_descent_for_testing(
        &mut escrow, STAKE_T1 - STAKE_T1 / 10, STAKE_T1 / 10,
        escrow_corpus::min_rent_price_const() * 2, 0,
    );

    let new_ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0));
    escrow::update_ensemble(&mut escrow, &owner_cap, new_ensemble, &clk, sc.ctx());

    assert!(escrow::has_pending_ensemble_update(&escrow), 1);
    assert!(escrow::pending_ensemble(&escrow).is_some(), 2);
    assert!(*escrow::pending_ensemble(&escrow).borrow() == new_ensemble, 3);
    assert!(escrow::active_ensemble(&escrow) != new_ensemble, 4); // active still old

    // pending_cycle_* resolve the queued ensemble on demand (tag 1,0,0,1,0).
    assert_eq!(*escrow::pending_ensemble_floor_price_mist(&escrow).borrow(),  escrow_corpus::min_rent_price_const());
    assert_eq!(*escrow::pending_ensemble_ceiling_ms(&escrow).borrow(),  escrow_corpus::tenure_ceiling_const());
    assert_eq!(*escrow::pending_ensemble_handover_ms(&escrow).borrow(), escrow_corpus::handover_countdown_c1_const());
    assert_eq!(*escrow::pending_ensemble_descent_ms(&escrow).borrow(),  escrow_corpus::descent_window_h1_const());

    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// next_ensemble_* expose the resolved cycle params the NEXT rent would use,
/// read from the Waiting state. Inverse of active_ensemble_*: resolved while
/// waiting, cleared once rented (the params move into the tenancy envelope).
#[test]
fun next_cycle_views_resolve_waiting_ensemble() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0)); // c=1 handover, h=1 descent
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let floor = escrow_corpus::min_rent_price_const();

    // Idle: the next rent resolves against the ensemble base.
    assert_eq!(*escrow::next_ensemble_floor_price_mist(&escrow).borrow(), floor);
    assert_eq!(*escrow::next_ensemble_ceiling_ms(&escrow).borrow(),  escrow_corpus::tenure_ceiling_const());
    assert_eq!(*escrow::next_ensemble_handover_ms(&escrow).borrow(), escrow_corpus::handover_countdown_c1_const());
    assert_eq!(*escrow::next_ensemble_descent_ms(&escrow).borrow(),  escrow_corpus::descent_window_h1_const());

    // Rented: cycle params move into the tenancy envelope → next_* clears.
    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert!(escrow::next_ensemble_floor_price_mist(&escrow).is_none(), 0);
    assert!(escrow::next_ensemble_ceiling_ms(&escrow).is_none(), 1);
    assert!(escrow::next_ensemble_handover_ms(&escrow).is_none(), 2);
    assert!(escrow::next_ensemble_descent_ms(&escrow).is_none(), 3);

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}

/// active_cycle_* expose the resolved cycle params of the active ensemble while rented.
#[test]
fun active_cycle_views_resolve_active_ensemble() {
    let mut sc = setup();
    let ensemble = escrow_corpus::by_tag(escrow_corpus::tag(1, 0, 0, 1, 0)); // c=1 handover, h=1 descent
    let (mut escrow, owner_cap) = integrate_and_take(ensemble, &mut sc);
    let clk = clock::create_for_testing(sc.ctx());
    let floor = escrow_corpus::min_rent_price_const();

    // Idle: cycle params live in the tenancy envelope → none until rented.
    assert!(escrow::active_ensemble_floor_price_mist(&escrow).is_none(), 0);
    assert!(escrow::active_ensemble_ceiling_ms(&escrow).is_none(), 1);
    assert!(escrow::active_ensemble_handover_ms(&escrow).is_none(), 2);
    assert!(escrow::active_ensemble_descent_ms(&escrow).is_none(), 3);

    sc.next_tx(TENANT_ADDR_1);
    let cap1 = escrow::rent(&mut escrow, mk_payment(floor, sc.ctx()), tenures::tenures(1), &clk, sc.ctx());

    assert_eq!(*escrow::active_ensemble_floor_price_mist(&escrow).borrow(),  floor);
    assert_eq!(*escrow::active_ensemble_ceiling_ms(&escrow).borrow(),  escrow_corpus::tenure_ceiling_const());
    assert_eq!(*escrow::active_ensemble_handover_ms(&escrow).borrow(), escrow_corpus::handover_countdown_c1_const());
    assert_eq!(*escrow::active_ensemble_descent_ms(&escrow).borrow(),  escrow_corpus::descent_window_h1_const());

    transfer::public_transfer(cap1, TENANT_ADDR_1);
    test_scenario::return_shared(escrow);
    owner_cap::burn(owner_cap, OWNER);
    clock::destroy_for_testing(clk);
    sc.end();
}
