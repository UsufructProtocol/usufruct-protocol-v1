// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::rental_escrow;

// === Imports ===

use std::u64;
use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape,
    fee_message,
    math,
    owner_cap::{Self, OwnerCap},
    price_function,
    protocol_fee_inbox::{Self, ProtocolFeeRef},
    tenant_cap::{Self, TenantCap},
};

// === Errors ===
// spec: §1.1

const ENotRented:               u64 = 0;   // spec: E_NOT_RENTED
const EInsufficientPayment:     u64 = 1;   // spec: E_INSUFFICIENT_PAYMENT
const ERetireFlagBlocksBid:     u64 = 2;   // spec: E_RETIRE_FLAG_BLOCKS_BID
const ERetiredNoBid:            u64 = 3;   // spec: E_RETIRED_NO_BID
const ERetireFloorNotElapsed:   u64 = 4;   // spec: E_RETIRE_FLOOR_NOT_ELAPSED
const EAlreadyRetired:          u64 = 5;   // spec: E_ALREADY_RETIRED
const ENotRetired:              u64 = 6;   // spec: E_NOT_RETIRED
const EReceiptEscrowMismatch:   u64 = 7;   // spec: E_RECEIPT_ESCROW_MISMATCH
const EReceiptAssetMismatch:    u64 = 8;   // spec: E_RECEIPT_ASSET_MISMATCH
const ENoEarnings:              u64 = 9;   // spec: E_NO_EARNINGS
const EAssetAlreadyBorrowed:    u64 = 10;  // spec: E_ASSET_ALREADY_BORROWED
const EWrongEscrowOwnerCap:     u64 = 11;  // spec: E_WRONG_ESCROW_OWNER_CAP
const EWrongEscrowTenantCap:    u64 = 12;  // spec: E_WRONG_ESCROW_TENANT_CAP
const EPendingTenantCap:        u64 = 13;  // spec: E_PENDING_TENANT_CAP
const EStaleTenantCap:          u64 = 14;  // spec: E_STALE_TENANT_CAP
const ETenantCapNotStale:       u64 = 15;  // spec: E_TENANT_CAP_NOT_STALE
const EInvariantViolation:      u64 = 0xDEADC0DE; // = 3_735_929_054 — unreachable in correct operation; programmer error, not user error

// === Constants ===
// spec: §1.2

const PROTOCOL_FEE_BPS: u64 = 1_000;
const BPS_PER_UNIT:     u64 = 10_000;

/// Canary upper bound on APT loop iterations. The state lattice
/// (HandoverConfirmed → HandoverOpen → {Retired | AtDutchAuction → Idle})
/// admits at most 3 transitions plus one terminal no-op iteration = 4.
/// A higher count signals a `do_*` bug producing a non-progressive state;
/// the loop aborts with `EInvariantViolation` instead of silently spinning
/// to gas exhaustion.
const MAX_APT_ITERATIONS: u64 = 4;

// === Structs ===

/// spec: §2.1 — payload-free discriminator. Returned by APT and `retire`,
/// used as event field type for `from_state` / `next_state` /
/// `state_at_set`. Mirrors `EscrowState`'s five variants.
public enum EscrowStateTag has copy, drop, store {
    Idle,
    AtDutchAuction,
    HandoverOpen,
    HandoverConfirmed,
    Retired,
}

/// spec: §2.2 — atomic grouping of (cap_id, address, stake) for a tenant
/// slot. Embedded inside `EscrowState::HandoverOpen.current` and inside
/// both `current` and `pending` of `HandoverConfirmed`.
public struct Tenant<phantom CoinType> has store {
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
}

/// spec: §2.3 — single public state type. Variants embed all
/// state-dependent payload (asset, tenant data, phase timestamps,
/// retiring flag, last_acquisition_price, handover_countdown_expiry).
/// `store` only — `Asset` and `Balance` lack `copy`/`drop`.
public enum EscrowState<Asset: key + store, phantom CoinType> has store {
    Idle {
        asset: Asset,
    },
    AtDutchAuction {
        asset:                  Asset,
        phase_start_ms:         u64,
        last_acquisition_price: u64,
    },
    HandoverOpen {
        asset:           Option<Asset>,
        phase_start_ms:  u64,
        current:         Tenant<CoinType>,
        retiring:        bool,
    },
    HandoverConfirmed {
        asset:                     Option<Asset>,
        phase_start_ms:            u64,
        current:                   Tenant<CoinType>,
        pending:                   Tenant<CoinType>,
        retiring:                  bool,
        handover_countdown_expiry: u64,
    },
    Retired {
        asset: Asset,
    },
}

/// spec: §2.4 — one shared object per integrated asset. Six fields:
/// configuration snapshot, inbox-id snapshot, integration timestamp,
/// owner-earnings accumulator, and the variant-typed state cell wrapped
/// in `Option` for the swap pattern (see §2.6).
public struct RentalEscrow<Asset: key + store, phantom CoinType> has key {
    id:                UID,
    config:            IntegrationConfig,
    fee_inbox_id:      ID,
    integrated_at_ms:  u64,
    owner_earnings:    Balance<CoinType>,
    state:             Option<EscrowState<Asset, CoinType>>,
}

/// spec: §2.5 — hot potato; consumed by `return_asset` in the same PTB
/// that created it via `borrow_asset`.
public struct AssetReceipt {
    escrow_id: ID,
    asset_id:  ID,
}

/// spec: §2.6 — internal hot potato. Produced by `take_state`, consumed
/// by `put_state`. Lifts P13 ("Option<EscrowState> is Some at every tx
/// boundary") to a compile-time invariant.
public struct StateReceipt {}

// === Events ===
// spec: §3

public struct AssetIntegrated<phantom Asset, phantom CoinType> has copy, drop {
    escrow_id:    ID,
    owner_cap_id: ID,
    asset_id:     ID,
}

public struct RentStarted has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    price_paid:    u64,
    floor_price:   u64,
    from_state:    EscrowStateTag,
}

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    tenant_cap_id:             ID,
    pending_tenant:            address,
    bid_amount:                u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:               ID,
    displaced_tenant_cap_id: ID,
    new_tenant_cap_id:       ID,
    displaced_bidder:        address,
    refunded_amount:         u64,
    new_bidder:              address,
    new_bid_amount:          u64,
    floor_price:             u64,
}

public struct HandoverCompleted has copy, drop {
    escrow_id:         ID,
    displaced_tenant:  address,
    new_tenant_cap_id: ID,
    used_credit:       u64,
    owner_share:       u64,
    protocol_fee:      u64,
    remain_credit:     u64,
    new_rent_price:    u64,
    timestamp_ms:      u64,
}

public struct TenureExpired has copy, drop {
    escrow_id:               ID,
    tenant:                  address,
    owner_share:             u64,
    protocol_fee:            u64,
    last_acquisition_price:  u64,
    next_state:              EscrowStateTag,
    timestamp_ms:            u64,
}

public struct AuctionExpired has copy, drop {
    escrow_id:    ID,
    timestamp_ms: u64,
}

public struct RetireFlagSet has copy, drop {
    escrow_id:    ID,
    owner:        address,
    state_at_set: EscrowStateTag,
}

public struct AssetRetired has copy, drop {
    escrow_id:  ID,
    from_state: EscrowStateTag,
}

public struct AssetBorrowed has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
}

public struct AssetReturned has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
}

public struct AssetClaimed has copy, drop {
    escrow_id:      ID,
    owner_cap_id:   ID,
    swept_earnings: u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:    ID,
    owner_cap_id: ID,
    owner:        address,
    amount:       u64,
}

// === Method Aliases ===

// === Public Functions ===

/// spec: §4.1
public fun integrate<Asset: key + store, CoinType>(
    asset:    Asset,
    cfg:      IntegrationConfig,
    fee_ref:  &ProtocolFeeRef,
    clock:    &Clock,
    ctx:      &mut TxContext,
): OwnerCap {
    let uid           = object::new(ctx);
    let escrow_id     = object::uid_to_inner(&uid);
    let owner         = ctx.sender();
    let cap           = owner_cap::new(escrow_id, owner, ctx);
    let owner_cap_id  = object::id(&cap);
    let fee_inbox_id  = protocol_fee_inbox::inbox_id(fee_ref);
    let asset_id      = object::id(&asset);
    let escrow = RentalEscrow<Asset, CoinType> {
        id:                uid,
        config:            cfg,
        fee_inbox_id,
        integrated_at_ms:  clock::timestamp_ms(clock),
        owner_earnings:    balance::zero<CoinType>(),
        state:             option::some(EscrowState::Idle { asset }),
    };
    config::emit_registration(&escrow.config, escrow_id);
    transfer::share_object(escrow);
    event::emit(AssetIntegrated<Asset, CoinType> { escrow_id, owner_cap_id, asset_id });
    cap
}

/// spec: §5.1 — dispatch over the current state to the appropriate
/// transition helper. Each helper handles its own take_state/put_state
/// and event emission.
public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    apply_pending_transitions(escrow, clock, ctx);
    let now   = clock::timestamp_ms(clock);
    let floor = compute_floor_price(escrow, now);
    assert!(coin::value(&payment) >= floor, EInsufficientPayment);
    match (read_state(escrow)) {
        EscrowState::Idle { .. }
        | EscrowState::AtDutchAuction { .. } =>
            do_install_new_tenant(escrow, payment, floor, now, ctx),
        EscrowState::HandoverOpen { .. } =>
            do_place_bid(escrow, payment, floor, now, ctx),
        EscrowState::HandoverConfirmed { .. } =>
            do_supersede_bid(escrow, payment, floor, ctx),
        // Unreachable: compute_floor_price aborts ERetiredNoBid on Retired
        // before this match runs.
        EscrowState::Retired { .. } => abort EInvariantViolation,
    }
}

/// spec: §4.2 — dispatch over the current state to either immediate
/// retirement (Idle / AtDutchAuction) or deferred retirement via the
/// `retiring` flag (HandoverOpen / HandoverConfirmed).
public fun retire<Asset: key + store, CoinType>(
    escrow:    &mut RentalEscrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): EscrowStateTag {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(escrow, clock, ctx);
    assert!(
        clock::timestamp_ms(clock) >= escrow.integrated_at_ms + config::retire_floor(&escrow.config),
        ERetireFloorNotElapsed,
    );
    match (read_state(escrow)) {
        EscrowState::Idle { .. }
        | EscrowState::AtDutchAuction { .. } => do_retire_immediately(escrow, ctx),
        EscrowState::HandoverOpen { .. }
        | EscrowState::HandoverConfirmed { .. } => do_set_retiring_flag(escrow, ctx),
        EscrowState::Retired { .. } => abort EAlreadyRetired,
    }
}

/// spec: §4.3
public fun claim_asset<Asset: key + store, CoinType>(
    mut escrow: RentalEscrow<Asset, CoinType>,
    owner_cap:  OwnerCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, Coin<CoinType>) {
    assert!(owner_cap::escrow_id(&owner_cap) == object::id(&escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(&mut escrow, clock, ctx);
    let RentalEscrow {
        id, config: _, fee_inbox_id: _, integrated_at_ms: _,
        owner_earnings, state,
    } = escrow;
    // Unwrap Option<EscrowState> — guaranteed Some by P13 (state-cell
    // invariant: always Some at tx boundary; see Design Conventions).
    assert!(option::is_some(&state), EInvariantViolation);
    let inner_state = option::destroy_some(state);
    let asset = match (inner_state) {
        EscrowState::Retired { asset } => asset,
        EscrowState::Idle              { asset: _a }                       => abort ENotRetired,
        EscrowState::AtDutchAuction    { asset: _a, .. }                   => abort ENotRetired,
        EscrowState::HandoverOpen      { asset: _a, current: _c, .. }      => abort ENotRetired,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. } => abort ENotRetired,
    };
    let earnings = coin::from_balance(owner_earnings, ctx);
    let escrow_id      = object::uid_to_inner(&id);
    let owner_cap_id   = object::id(&owner_cap);
    let swept_earnings = coin::value(&earnings);
    let owner          = ctx.sender();
    owner_cap::burn(owner_cap, owner);
    object::delete(id);
    event::emit(AssetClaimed { escrow_id, owner_cap_id, swept_earnings });
    (asset, earnings)
}

/// spec: §4.4
public fun withdraw_earnings<Asset: key + store, CoinType>(
    escrow:    &mut RentalEscrow<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Coin<CoinType> {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(escrow, clock, ctx);
    let amount = balance::value(&escrow.owner_earnings);
    assert!(amount > 0, ENoEarnings);
    let withdrawn = balance::withdraw_all(&mut escrow.owner_earnings);
    event::emit(EarningsWithdrawn {
        escrow_id:    object::id(escrow),
        owner_cap_id: object::id(owner_cap),
        owner:        ctx.sender(),
        amount,
    });
    coin::from_balance(withdrawn, ctx)
}

/// spec: §6.1
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut RentalEscrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt) {
    apply_pending_transitions(escrow, clock, ctx);
    let escrow_id = object::id(escrow);
    assert!(tenant_cap::escrow_id(tenant_cap) == escrow_id, EWrongEscrowTenantCap);
    let cap_id = object::id(tenant_cap);
    let asset = match (read_state(escrow)) {
        EscrowState::HandoverOpen { .. }
        | EscrowState::HandoverConfirmed { .. } => do_extract_asset(escrow, cap_id),
        EscrowState::Idle { .. }
        | EscrowState::AtDutchAuction { .. }
        | EscrowState::Retired { .. } => abort EStaleTenantCap,
    };
    let asset_id = object::id(&asset);
    event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id });
    (asset, AssetReceipt { escrow_id, asset_id })
}

/// spec: §6.2
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut RentalEscrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let AssetReceipt { escrow_id, asset_id } = receipt_in;
    assert!(escrow_id == object::id(escrow), EReceiptEscrowMismatch);
    assert!(asset_id == object::id(&asset), EReceiptAssetMismatch);
    let tenant_cap_id = match (read_state(escrow)) {
        EscrowState::HandoverOpen { .. }
        | EscrowState::HandoverConfirmed { .. } => do_fill_asset(escrow, asset),
        // Unreachable by PTB clock-fixity (§6.1).
        EscrowState::Idle { .. }
        | EscrowState::AtDutchAuction { .. }
        | EscrowState::Retired { .. } => abort EInvariantViolation,
    };
    event::emit(AssetReturned { escrow_id, tenant_cap_id });
}

/// spec: §6.3
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    apply_pending_transitions(escrow, clock, ctx);
    assert!(tenant_cap::escrow_id(&cap) == object::id(escrow), EWrongEscrowTenantCap);
    let cap_id = object::id(&cap);
    match (read_state(escrow)) {
        EscrowState::HandoverOpen { current, .. } => {
            assert!(current.cap_id != cap_id, ETenantCapNotStale);
        },
        EscrowState::HandoverConfirmed { current, pending, .. } => {
            assert!(current.cap_id != cap_id, ETenantCapNotStale);
            assert!(pending.cap_id != cap_id, ETenantCapNotStale);
        },
        EscrowState::Idle { .. }
        | EscrowState::AtDutchAuction { .. }
        | EscrowState::Retired { .. } => {},
    };
    tenant_cap::burn(cap, ctx);
}

/// spec: §5.2
public fun apply_pending_transitions<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
): EscrowStateTag {
    let now = clock::timestamp_ms(clock);
    // Each iteration matches on the current state. Chaining is structural:
    // the next iteration sees whatever state the previous `do_*` produced.
    // Termination is guaranteed by the strictly progressive state lattice;
    // `MAX_APT_ITERATIONS` is a runtime canary against `do_*` bugs that
    // could break that guarantee.
    let mut keep_going = true;
    let mut iterations: u64 = 0;
    while (keep_going) {
        assert!(iterations < MAX_APT_ITERATIONS, EInvariantViolation);
        iterations = iterations + 1;
        keep_going = match (read_state(escrow)) {
            EscrowState::HandoverConfirmed { handover_countdown_expiry, .. } => {
                let e = *handover_countdown_expiry;
                if (now >= e) { do_handover(escrow, e, ctx); true } else false
            },
            EscrowState::HandoverOpen { phase_start_ms, .. } => {
                let e = *phase_start_ms + config::tenure_ceiling(&escrow.config);
                if (now >= e) { do_tenure_expiry(escrow, e, ctx); true } else false
            },
            EscrowState::AtDutchAuction { phase_start_ms, .. } => {
                let e = *phase_start_ms + config::descent_ceiling(&escrow.config);
                if (now >= e) { do_auction_expiry(escrow, e); true } else false
            },
            EscrowState::Idle { .. } | EscrowState::Retired { .. } => false,
        };
    };
    state_tag(read_state(escrow))
}

// === View Functions ===

/// spec: §8.1
public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow:       &RentalEscrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    let (phase_start_ms, principal, effective_ts) = match (read_state(escrow)) {
        EscrowState::HandoverOpen { phase_start_ms, current, .. } =>
            (*phase_start_ms, balance::value(&current.stake), timestamp_ms),
        EscrowState::HandoverConfirmed {
            phase_start_ms, current, handover_countdown_expiry, ..
        } => {
            let eff = u64::min(timestamp_ms, *handover_countdown_expiry);
            (*phase_start_ms, balance::value(&current.stake), eff)
        },
        _ => abort ENotRented,
    };
    if (effective_ts < phase_start_ms) return 0;
    let elapsed = effective_ts - phase_start_ms;
    let g = curve_shape::evaluate_curve(
        config::credit_curve(&escrow.config),
        elapsed,
        config::tenure_ceiling(&escrow.config),
    );
    math::mul_div(principal, g, curve_shape::scale())
}

/// spec: §8.4
public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow:       &RentalEscrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    match (read_state(escrow)) {
        EscrowState::Idle { .. } => config::min_rent_price(&escrow.config),
        EscrowState::HandoverOpen { current, .. } =>
            compute_next_rent_price(&escrow.config, balance::value(&current.stake)),
        EscrowState::HandoverConfirmed { pending, .. } =>
            compute_next_rent_price(&escrow.config, balance::value(&pending.stake)),
        EscrowState::AtDutchAuction { .. } =>
            compute_price_descent(escrow, timestamp_ms),
        EscrowState::Retired { .. } => abort ERetiredNoBid,
    }
}

/// spec: §8.7 — discriminator projection.
public fun state_tag<Asset: key + store, CoinType>(
    s: &EscrowState<Asset, CoinType>,
): EscrowStateTag {
    match (s) {
        EscrowState::Idle              { .. } => EscrowStateTag::Idle,
        EscrowState::AtDutchAuction    { .. } => EscrowStateTag::AtDutchAuction,
        EscrowState::HandoverOpen      { .. } => EscrowStateTag::HandoverOpen,
        EscrowState::HandoverConfirmed { .. } => EscrowStateTag::HandoverConfirmed,
        EscrowState::Retired           { .. } => EscrowStateTag::Retired,
    }
}

// === Admin Functions ===

// === Private Functions ===

/// spec: §8.2 — Dutch descent. Caller has dispatched on AtDutchAuction.
fun compute_price_descent<Asset: key + store, CoinType>(
    escrow:       &RentalEscrow<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    let (phase_start_ms, last_acquisition_price) = match (read_state(escrow)) {
        EscrowState::AtDutchAuction { phase_start_ms, last_acquisition_price, .. } =>
            (*phase_start_ms, *last_acquisition_price),
        _ => abort EInvariantViolation,
    };
    if (timestamp_ms < phase_start_ms) return last_acquisition_price;
    let elapsed_ms = timestamp_ms - phase_start_ms;
    let h = curve_shape::evaluate_curve(
        config::descent_curve(&escrow.config),
        elapsed_ms,
        config::descent_ceiling(&escrow.config),
    );
    let spread   = last_acquisition_price - config::min_rent_price(&escrow.config);
    let consumed = math::mul_div(spread, h, curve_shape::scale());
    last_acquisition_price - consumed
}

/// spec: §8.3 — takeover/supersede floor.
fun compute_next_rent_price(cfg: &IntegrationConfig, price: u64): u64 {
    price_function::evaluate_price_fn(config::price_function(cfg), price)
}

/// spec: §2.6 — sole producer of `StateReceipt`. Asserts the state-cell
/// invariant explicitly so a violation aborts with `EInvariantViolation`
/// rather than the generic `option::EOPTION_NOT_SET`.
fun take_state<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
): (EscrowState<Asset, CoinType>, StateReceipt) {
    assert!(option::is_some(&escrow.state), EInvariantViolation);
    (option::extract(&mut escrow.state), StateReceipt {})
}

/// spec: §2.6 — sole consumer of `StateReceipt`. Asserts the state cell is
/// `None` (i.e. between `take_state` and `put_state`) so a double-fill
/// aborts with `EInvariantViolation` rather than `option::EOPTION_IS_SET`.
fun put_state<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    new:     EscrowState<Asset, CoinType>,
    receipt: StateReceipt,
) {
    let StateReceipt {} = receipt;
    assert!(option::is_none(&escrow.state), EInvariantViolation);
    option::fill(&mut escrow.state, new);
}

/// spec: §2.6 — sole read accessor. Single site of `option::borrow` on
/// `escrow.state`. Must never be called between `take_state` and `put_state`;
/// the assert turns a P_READ violation into an `EInvariantViolation` abort
/// rather than `option::EOPTION_NOT_SET`. See Design Conventions section.
fun read_state<Asset: key + store, CoinType>(
    escrow: &RentalEscrow<Asset, CoinType>,
): &EscrowState<Asset, CoinType> {
    assert!(option::is_some(&escrow.state), EInvariantViolation);
    option::borrow(&escrow.state)
}

/// spec: §7.1 — pending handover. Pre: state is HandoverConfirmed and
/// `boundary_ms == handover_countdown_expiry`.
///
/// Orchestrator: composes two state-mutating sub-steps, each owning its
/// own take/put window.
///   1. `do_distribute_balance` — split outgoing stake 3-way, leave state
///      with `current.stake = balance::zero()`.
///   2. `do_rotate_for_handover` — destroy zero-balance current, promote
///      pending → current, transition to HandoverOpen.
fun do_handover<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id = object::id(escrow);

    let (displaced_tenant, owner_share, protocol_fee, remain_credit) =
        do_distribute_balance(escrow, boundary_ms, ctx);
    let (new_tenant_cap_id, new_rent_price) =
        do_rotate_for_handover(escrow, boundary_ms);

    event::emit(HandoverCompleted {
        escrow_id,
        displaced_tenant,
        new_tenant_cap_id,
        used_credit: owner_share + protocol_fee,
        owner_share,
        protocol_fee,
        remain_credit,
        new_rent_price,
        timestamp_ms: boundary_ms,
    });
}

/// spec: §7.2 — tenure expiry. Pre: state is HandoverOpen.
///
/// Orchestrator: composes two state-mutating sub-steps.
///   1. `do_distribute_balance` — split stake; at elapsed=tenure_ceiling
///      the curve returns SCALE so used_credit = principal (remain = 0).
///      State stays HandoverOpen with `current.stake = balance::zero()`.
///   2. `do_terminate_tenure` — destroy zero current, unwrap asset,
///      branch on `retiring` to AtDutchAuction or Retired.
fun do_tenure_expiry<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id = object::id(escrow);

    let (tenant, owner_share, protocol_fee, _remain) =
        do_distribute_balance(escrow, boundary_ms, ctx);
    let last_acquisition_price = owner_share + protocol_fee;
    let next_tag =
        do_terminate_tenure(escrow, boundary_ms, last_acquisition_price);

    event::emit(TenureExpired {
        escrow_id, tenant, owner_share, protocol_fee,
        last_acquisition_price,
        next_state: next_tag,
        timestamp_ms: boundary_ms,
    });

    let was_retired = match (next_tag) {
        EscrowStateTag::Retired => true,
        _ => false,
    };
    if (was_retired) {
        event::emit(AssetRetired { escrow_id, from_state: EscrowStateTag::HandoverOpen });
    };
}

/// spec: §7.3 — auction expiry. Pre: state is AtDutchAuction.
fun do_auction_expiry<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
) {
    let escrow_id = object::id(escrow);
    let (old, receipt) = take_state(escrow);
    let asset = match (old) {
        EscrowState::AtDutchAuction { asset, phase_start_ms: _, last_acquisition_price: _ } => asset,
        EscrowState::Idle              { asset: _a }                                            => abort EInvariantViolation,
        EscrowState::HandoverOpen      { asset: _a, current: _c, .. }                           => abort EInvariantViolation,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                                            => abort EInvariantViolation,
    };
    put_state(escrow, EscrowState::Idle { asset }, receipt);
    event::emit(AuctionExpired { escrow_id, timestamp_ms: boundary_ms });
}

/// spec: §7.4 — pure 90/10 split. Floors fee to zero on `n < 10`.
fun split_fee(amount: u64): (u64, u64) {
    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)
}

/// spec: §7.5 — Idle | AtDutchAuction → HandoverOpen with a fresh tenant.
/// Performs take_state / put_state internally; emits RentStarted with the
/// originating variant in `from_state`. Receives `now` from the caller
/// (rent) since the PTB clock is fixed — anchors phase_start_ms = now.
fun do_install_new_tenant<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): TenantCap {
    let escrow_id  = object::id(escrow);
    let price_paid = coin::value(&payment);
    let (old, receipt) = take_state(escrow);
    let (asset, from_state) = match (old) {
        EscrowState::Idle { asset } =>
            (asset, EscrowStateTag::Idle),
        EscrowState::AtDutchAuction { asset, phase_start_ms: _, last_acquisition_price: _ } =>
            (asset, EscrowStateTag::AtDutchAuction),
        EscrowState::HandoverOpen      { asset: _a, current: _c, .. }                           => abort EInvariantViolation,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                                            => abort EInvariantViolation,
    };
    let stake       = coin::into_balance(payment);
    let tenant_addr = ctx.sender();
    let (new_cap, new_cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let current = Tenant { cap_id: new_cap_id, address: tenant_addr, stake };
    put_state(escrow, EscrowState::HandoverOpen {
        asset:           option::some(asset),
        phase_start_ms:  now,
        current,
        retiring:        false,
    }, receipt);
    event::emit(RentStarted {
        escrow_id,
        tenant_cap_id: new_cap_id,
        price_paid,
        floor_price: floor,
        from_state,
    });
    new_cap
}

/// spec: §5.1 — HandoverOpen → HandoverConfirmed (initial pending bid).
/// Performs take_state / put_state internally; emits BidPlaced. Receives
/// `now` from the caller (rent) — anchors handover_countdown_expiry.
fun do_place_bid<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): TenantCap {
    let escrow_id      = object::id(escrow);
    let pending_tenant = ctx.sender();
    let (old, receipt) = take_state(escrow);
    let (asset, phase_start_ms, current, retiring) = match (old) {
        EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
            assert!(!retiring, ERetireFlagBlocksBid);
            (asset, phase_start_ms, current, retiring)
        },
        EscrowState::Idle              { asset: _a }                                            => abort EInvariantViolation,
        EscrowState::AtDutchAuction    { asset: _a, .. }                                        => abort EInvariantViolation,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                                            => abort EInvariantViolation,
    };
    let tenure_e                  = phase_start_ms + config::tenure_ceiling(&escrow.config);
    let remaining                 = tenure_e - now;
    let countdown                 = u64::min(config::handover_floor(&escrow.config), remaining);
    let handover_countdown_expiry = now + countdown;
    let (cap, pending_cap_id, bid_amount, pending) =
        register_pending_bid(escrow_id, payment, pending_tenant, ctx);
    put_state(escrow, EscrowState::HandoverConfirmed {
        asset, phase_start_ms, current, pending,
        retiring,
        handover_countdown_expiry,
    }, receipt);
    event::emit(BidPlaced {
        escrow_id,
        tenant_cap_id: pending_cap_id,
        pending_tenant,
        bid_amount,
        floor_price: floor,
        handover_countdown_expiry,
    });
    cap
}

/// spec: §5.1 — HandoverConfirmed → HandoverConfirmed (replace pending bid).
/// Refunds the displaced bidder, registers the new pending tenant.
/// Performs take_state / put_state internally; emits BidSuperseded.
fun do_supersede_bid<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    ctx:     &mut TxContext,
): TenantCap {
    let escrow_id  = object::id(escrow);
    let new_bidder = ctx.sender();
    let (old, receipt) = take_state(escrow);
    let (asset, phase_start_ms, current, displaced, retiring, handover_countdown_expiry) = match (old) {
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms, current, pending: displaced,
            retiring, handover_countdown_expiry,
        } => (asset, phase_start_ms, current, displaced, retiring, handover_countdown_expiry),
        EscrowState::Idle           { asset: _a }                          => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. }                      => abort EInvariantViolation,
        EscrowState::HandoverOpen   { asset: _a, current: _c, .. }         => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }                          => abort EInvariantViolation,
    };
    let Tenant {
        cap_id: displaced_cap_id,
        address: displaced_bidder,
        stake: refund_balance,
    } = displaced;
    let refunded_amount = balance::value(&refund_balance);
    transfer::public_transfer(coin::from_balance(refund_balance, ctx), displaced_bidder);
    let (cap, new_pending_cap_id, new_bid_amount, new_pending) =
        register_pending_bid(escrow_id, payment, new_bidder, ctx);
    put_state(escrow, EscrowState::HandoverConfirmed {
        asset, phase_start_ms, current,
        pending: new_pending,
        retiring,
        handover_countdown_expiry,
    }, receipt);
    event::emit(BidSuperseded {
        escrow_id,
        displaced_tenant_cap_id: displaced_cap_id,
        new_tenant_cap_id: new_pending_cap_id,
        displaced_bidder,
        refunded_amount,
        new_bidder,
        new_bid_amount,
        floor_price: floor,
    });
    cap
}

/// spec: §4.2 — Idle | AtDutchAuction → Retired (immediate retirement).
/// Performs take_state / put_state internally; emits both RetireFlagSet
/// and AssetRetired (terminal transition, no deferral). Returns the new
/// state tag (always Retired).
fun do_retire_immediately<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
    ctx:    &TxContext,
): EscrowStateTag {
    let escrow_id = object::id(escrow);
    let (old, receipt) = take_state(escrow);
    let (asset, prior_tag) = match (old) {
        EscrowState::Idle { asset } =>
            (asset, EscrowStateTag::Idle),
        EscrowState::AtDutchAuction { asset, phase_start_ms: _, last_acquisition_price: _ } =>
            (asset, EscrowStateTag::AtDutchAuction),
        EscrowState::HandoverOpen      { asset: _a, current: _c, .. }                           => abort EInvariantViolation,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                                            => abort EInvariantViolation,
    };
    put_state(escrow, EscrowState::Retired { asset }, receipt);
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), state_at_set: prior_tag });
    event::emit(AssetRetired { escrow_id, from_state: prior_tag });
    EscrowStateTag::Retired
}

/// spec: §4.2 — HandoverOpen | HandoverConfirmed → same variant with
/// `retiring = true` (deferred retirement). Performs take_state / put_state
/// internally; emits RetireFlagSet only — AssetRetired is emitted later
/// by `do_tenure_expiry` when the flag is honored. Returns the (unchanged)
/// state tag.
fun do_set_retiring_flag<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
    ctx:    &TxContext,
): EscrowStateTag {
    let escrow_id = object::id(escrow);
    let (old, receipt) = take_state(escrow);
    let (new_state, prior_tag) = match (old) {
        EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
            assert!(!retiring, EAlreadyRetired);
            let new = EscrowState::HandoverOpen {
                asset, phase_start_ms, current, retiring: true,
            };
            (new, EscrowStateTag::HandoverOpen)
        },
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms, current, pending, retiring, handover_countdown_expiry,
        } => {
            assert!(!retiring, EAlreadyRetired);
            let new = EscrowState::HandoverConfirmed {
                asset, phase_start_ms, current, pending,
                retiring: true,
                handover_countdown_expiry,
            };
            (new, EscrowStateTag::HandoverConfirmed)
        },
        EscrowState::Idle           { asset: _a }                          => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. }                      => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }                          => abort EInvariantViolation,
    };
    put_state(escrow, new_state, receipt);
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), state_at_set: prior_tag });
    prior_tag
}

/// spec: §6.1 — extract the asset from the active rented variant.
/// Pre: state is HandoverOpen or HandoverConfirmed (filtered by the
/// public dispatch in `borrow_asset`). Validates the caller's TenantCap
/// against `current.cap_id` (and rejects the `pending` cap on Confirmed).
/// Aborts EInvariantViolation on terminal variants — unreachable because
/// `borrow_asset` aborts EStaleTenantCap before calling.
/// EAssetAlreadyBorrowed only fires from same-tenant double-borrow in one PTB.
fun do_extract_asset<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
    cap_id: ID,
): Asset {
    let (old, receipt) = take_state(escrow);
    let (asset, new_state) = match (old) {
        EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
            assert!(cap_id == current.cap_id, EStaleTenantCap);
            let mut asset_opt = asset;
            assert!(option::is_some(&asset_opt), EAssetAlreadyBorrowed);
            let extracted = option::extract(&mut asset_opt);
            let new = EscrowState::HandoverOpen {
                asset: asset_opt, phase_start_ms, current, retiring,
            };
            (extracted, new)
        },
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms, current, pending, retiring, handover_countdown_expiry,
        } => {
            assert!(cap_id != pending.cap_id, EPendingTenantCap);
            assert!(cap_id == current.cap_id, EStaleTenantCap);
            let mut asset_opt = asset;
            assert!(option::is_some(&asset_opt), EAssetAlreadyBorrowed);
            let extracted = option::extract(&mut asset_opt);
            let new = EscrowState::HandoverConfirmed {
                asset: asset_opt, phase_start_ms, current, pending, retiring,
                handover_countdown_expiry,
            };
            (extracted, new)
        },
        EscrowState::Idle           { asset: _a }     => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. } => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }     => abort EInvariantViolation,
    };
    put_state(escrow, new_state, receipt);
    asset
}

/// spec: §6.2 — fill the asset back into the active rented variant.
/// Returns the current tenant's cap_id for the AssetReturned event.
/// Aborts EInvariantViolation on terminal variants — unreachable by PTB
/// clock-fixity (§6.1): AssetReceipt is only produced from active states,
/// and state cannot change between borrow and return inside one PTB.
fun do_fill_asset<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
    asset:  Asset,
): ID {
    let (old, receipt) = take_state(escrow);
    let (new_state, tenant_cap_id) = match (old) {
        EscrowState::HandoverOpen { asset: asset_slot, phase_start_ms, current, retiring } => {
            let cap_id = current.cap_id;
            let mut slot = asset_slot;
            assert!(option::is_none(&slot), EInvariantViolation);
            option::fill(&mut slot, asset);
            let new = EscrowState::HandoverOpen {
                asset: slot, phase_start_ms, current, retiring,
            };
            (new, cap_id)
        },
        EscrowState::HandoverConfirmed {
            asset: asset_slot, phase_start_ms, current, pending, retiring, handover_countdown_expiry,
        } => {
            let cap_id = current.cap_id;
            let mut slot = asset_slot;
            assert!(option::is_none(&slot), EInvariantViolation);
            option::fill(&mut slot, asset);
            let new = EscrowState::HandoverConfirmed {
                asset: slot, phase_start_ms, current, pending, retiring,
                handover_countdown_expiry,
            };
            (new, cap_id)
        },
        EscrowState::Idle           { asset: _a }     => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. } => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }     => abort EInvariantViolation,
    };
    put_state(escrow, new_state, receipt);
    tenant_cap_id
}

/// Sub-helper: pays the outgoing tenant their `remain_credit` (=
/// principal − used_credit) and returns the leftover Balance (size =
/// used_credit) for the caller to continue the pipeline. Also returns
/// a zero-stake Tenant for state reconstruction.
fun settle_tenant<CoinType>(
    tenant:      Tenant<CoinType>,
    used_credit: u64,
    ctx:         &mut TxContext,
): (Tenant<CoinType>, address, Balance<CoinType>, u64) {
    // Returns: (zero_tenant, payer, leftover, remain_credit)
    let Tenant { cap_id, address: payer, stake } = tenant;
    let principal     = balance::value(&stake);
    let remain_credit = principal - used_credit;
    let leftover      = pay_tenant_remain(stake, remain_credit, payer, ctx);
    let zero_tenant   = Tenant { cap_id, address: payer, stake: balance::zero() };
    (zero_tenant, payer, leftover, remain_credit)
}

/// First step of a transition: distributes the outgoing tenant's balance
/// 3-way and leaves the state cell on the SAME variant with
/// `current.stake = balance::zero()`. The transient zero-balance current
/// is consumed by the follow-up step (`do_rotate_for_handover` or
/// `do_terminate_tenure`).
///
/// `compute_used_credit` is called BEFORE `take_state` because it reads
/// `escrow.state`; the resulting u64 is then threaded through the
/// settlement after take_state extracts the state cell.
fun do_distribute_balance<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): (address, u64, u64, u64) {  // payer, owner_share, protocol_fee, remain_credit
    let used_credit                 = compute_used_credit(escrow, boundary_ms);
    let (owner_share, protocol_fee) = split_fee(used_credit);
    let escrow_id                   = object::id(escrow);
    let fee_inbox_id                = escrow.fee_inbox_id;

    let (old, receipt) = take_state(escrow);
    let (next, payer, remain_credit) = match (old) {
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms, current, pending,
            retiring, handover_countdown_expiry,
        } => {
            // Pipeline: tenant remain → protocol fee → owner earnings.
            let (zero_current, payer, leftover, remain_credit) = settle_tenant(current, used_credit, ctx);
            let leftover                                       = pay_protocol_fee(leftover, protocol_fee, escrow_id, payer, fee_inbox_id, ctx);
            balance::join(&mut escrow.owner_earnings, leftover);

            let next = EscrowState::HandoverConfirmed {
                asset, phase_start_ms, current: zero_current, pending,
                retiring, handover_countdown_expiry,
            };
            (next, payer, remain_credit)
        },
        EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
            // Pipeline: tenant remain → protocol fee → owner earnings.
            let (zero_current, payer, leftover, remain_credit) = settle_tenant(current, used_credit, ctx);
            // Invariant: at tenure expiry, curve at elapsed=tenure_ceiling
            // returns SCALE so used_credit == principal and remain_credit == 0.
            // The tenant payment above is a no-op; assert makes the property
            // explicit.
            assert!(remain_credit == 0, EInvariantViolation);
            let leftover                                       = pay_protocol_fee(leftover, protocol_fee, escrow_id, payer, fee_inbox_id, ctx);
            balance::join(&mut escrow.owner_earnings, leftover);

            let next = EscrowState::HandoverOpen {
                asset, phase_start_ms, current: zero_current, retiring,
            };
            (next, payer, remain_credit)
        },
        EscrowState::Idle           { asset: _a }     => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. } => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }     => abort EInvariantViolation,
    };
    put_state(escrow, next, receipt);
    (payer, owner_share, protocol_fee, remain_credit)
}

/// Second step of handover: HandoverConfirmed (post-distribute) →
/// HandoverOpen with rotated tenant. Destroys the zero-balance outgoing
/// current, promotes pending to current.
fun do_rotate_for_handover<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
): (ID, u64) {  // (new_tenant_cap_id, new_rent_price)
    let (old, receipt) = take_state(escrow);
    let (next, new_cap_id, new_rent_price) = match (old) {
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms: _, current, pending,
            retiring, handover_countdown_expiry: _,
        } => {
            let Tenant { cap_id: _, address: _, stake: zero_stake } = current;
            balance::destroy_zero(zero_stake);

            let Tenant { cap_id: new_cap_id, address: new_address, stake: new_stake } = pending;
            let new_rent_price = balance::value(&new_stake);
            let new_current = Tenant { cap_id: new_cap_id, address: new_address, stake: new_stake };

            let next = EscrowState::HandoverOpen {
                asset, phase_start_ms: boundary_ms, current: new_current, retiring,
            };
            (next, new_cap_id, new_rent_price)
        },
        EscrowState::Idle           { asset: _a }                            => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. }                        => abort EInvariantViolation,
        EscrowState::HandoverOpen   { asset: _a, current: _c, .. }           => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }                            => abort EInvariantViolation,
    };
    put_state(escrow, next, receipt);
    (new_cap_id, new_rent_price)
}

/// Second step of tenure expiry: HandoverOpen (post-distribute) →
/// AtDutchAuction or Retired. Destroys the zero-balance outgoing current,
/// unwraps the asset, branches on `retiring`.
fun do_terminate_tenure<Asset: key + store, CoinType>(
    escrow:                 &mut RentalEscrow<Asset, CoinType>,
    boundary_ms:            u64,
    last_acquisition_price: u64,
): EscrowStateTag {
    let (old, receipt) = take_state(escrow);
    let (next, tag) = match (old) {
        EscrowState::HandoverOpen { asset: asset_opt, phase_start_ms: _, current, retiring } => {
            let Tenant { cap_id: _, address: _, stake: zero_stake } = current;
            balance::destroy_zero(zero_stake);

            // Unwrap Option<Asset> — guaranteed Some by P11 (no borrow can
            // be open at tenure expiry; PTB clock-fixity §6.1).
            assert!(option::is_some(&asset_opt), EInvariantViolation);
            let asset = option::destroy_some(asset_opt);

            let next: EscrowState<Asset, CoinType> = if (retiring) {
                EscrowState::Retired { asset }
            } else {
                EscrowState::AtDutchAuction {
                    asset, phase_start_ms: boundary_ms, last_acquisition_price,
                }
            };
            let tag = state_tag(&next);
            (next, tag)
        },
        EscrowState::Idle              { asset: _a }                                        => abort EInvariantViolation,
        EscrowState::AtDutchAuction    { asset: _a, .. }                                    => abort EInvariantViolation,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }          => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                                        => abort EInvariantViolation,
    };
    put_state(escrow, next, receipt);
    tag
}

/// spec: §7.1 push-before-rotate (P3) — splits `remain_amount` from
/// `balance` and refunds it to the tenant; returns the leftover.
fun pay_tenant_remain<CoinType>(
    mut balance:   Balance<CoinType>,
    remain_amount: u64,
    tenant:        address,
    ctx:           &mut TxContext,
): Balance<CoinType> {
    if (remain_amount > 0) {
        let part = balance::split(&mut balance, remain_amount);
        transfer::public_transfer(coin::from_balance(part, ctx), tenant);
    };
    balance
}

/// spec: §7.6 — splits `fee_amount` from `balance` and posts it to the
/// protocol fee inbox; returns the leftover.
fun pay_protocol_fee<CoinType>(
    mut balance:  Balance<CoinType>,
    fee_amount:   u64,
    escrow_id:    ID,
    payer:        address,
    fee_inbox_id: ID,
    ctx:          &mut TxContext,
): Balance<CoinType> {
    if (fee_amount > 0) {
        let part = balance::split(&mut balance, fee_amount);
        fee_message::post<CoinType>(part, escrow_id, payer, fee_inbox_id, ctx);
    };
    balance
}

/// spec: §7.7 — pending bid construction tail. Returns the cap, its ID,
/// the bid amount, and a fully-built `Tenant<C>` for the caller to embed
/// in `HandoverConfirmed.pending`.
fun register_pending_bid<CoinType>(
    escrow_id: ID,
    payment:   Coin<CoinType>,
    bidder:    address,
    ctx:       &mut TxContext,
): (TenantCap, ID, u64, Tenant<CoinType>) {
    let bid_amount = coin::value(&payment);
    let stake      = coin::into_balance(payment);
    let (cap, tenant_cap_id) = tenant_cap::new(escrow_id, bidder, ctx);
    let pending = Tenant { cap_id: tenant_cap_id, address: bidder, stake };
    (cap, tenant_cap_id, bid_amount, pending)
}

// === Test Functions ===

// === Design Conventions ===
//
// CONVENTION P_READ: `read_state` must never be called inside a take_state /
// put_state window (i.e. while a `StateReceipt` is live in the same frame).
//
// Enforcement summary
// ───────────────────
// │ Guarantee                                         │ Level         │
// │ put_state always follows take_state in same PTB   │ compile-time  │
// │   (StateReceipt has no `drop` — hot potato)       │               │
// │ read_state not called while state is None         │ convention    │
// │   (Move type system cannot track Option contents) │               │
// │ No external code touches escrow.state directly    │ compile-time  │
// │   (field is private; take/put/read are private)   │               │
//
// Why violating P_READ is a runtime abort, not silent corruption
// ──────────────────────────────────────────────────────────────
// `read_state` asserts `option::is_some(&escrow.state)` first, so a P_READ
// violation aborts with `EInvariantViolation` (0xDEADC0DE) rather than the
// generic `option::EOPTION_NOT_SET` (262145). Same for `take_state` /
// `put_state` — every state-cell access is guarded by an explicit assert
// against the same invariant code, making protocol bugs distinguishable
// from user errors in logs and indexers.
// The transaction rolls back entirely — no half-written state persists.
// The risk is liveness (unexpected abort), not correctness (state corruption).
//
// Required expected_failure test
// ────────────────────────────────
// To document and pin the runtime behaviour, the test suite must include:
//
//   #[test, expected_failure(abort_code = usufruct::rental_escrow::EInvariantViolation)]
//   fun test_read_state_aborts_inside_take_put_window() {
//       // ... set up a minimal RentalEscrow in a test scenario ...
//       let (state, receipt) = take_state(&mut escrow);
//       // P_READ violated — read_state sees None here:
//       let _ = read_state(&escrow);      // must abort EInvariantViolation
//       // put_state unreachable, but receipt would be consumed by abort.
//       put_state(&mut escrow, state, receipt);
//   }
//
// How to maintain the convention in future changes
// ─────────────────────────────────────────────────
// 1. read_state is private — only module-internal code can introduce a
//    violation; no external caller can trigger it.
// 2. Any new internal function that calls read_state must be audited to
//    confirm it is never reachable from a call stack that holds a live
//    StateReceipt.
// 3. Functions that call take_state must call put_state before any branch
//    that could reach read_state.  The compiler enforces that put_state is
//    called before the end of the PTB; it does not enforce call ordering
//    within the body — that ordering is the author's responsibility.
//
// CONVENTION P_DO: a private function carries the `do_*` prefix iff its body
// owns a take_state / put_state window (i.e. produces and consumes a single
// StateReceipt). The relation is bidirectional and exact: every do_* function
// calls both take_state and put_state; no other function in the module calls
// both.
//
// Two flavors of do_*:
//   (a) STATE-WINDOW OWNERS — body contains a take_state / put_state pair.
//       Single-step transitions: do_install_new_tenant, do_place_bid,
//       do_supersede_bid, do_retire_immediately, do_set_retiring_flag,
//       do_extract_asset, do_fill_asset, do_auction_expiry, and the
//       sub-step helpers do_distribute_balance, do_rotate_for_handover,
//       do_terminate_tenure.
//   (b) ORCHESTRATORS — body contains no take_state directly; instead
//       calls two or more do_* state-window owners back-to-back. The
//       transitions do_handover and do_tenure_expiry are orchestrators —
//       each splits into a balance-distribution step and a variant-change
//       step, each step owning its own take/put.
//
// Enforcement summary
// ───────────────────
// │ Guarantee                                                  │ Level         │
// │ Every do_* function either owns a take/put window OR       │ convention    │
// │   composes do_* sub-steps                                  │               │
// │ No non-do_* function owns a take/put window                │ convention    │
// │ Every take_state pairs with a put_state in PTB             │ compile-time  │
// │   (StateReceipt hot potato — see P_READ above)             │               │
//
// Why P_DO matters
// ────────────────
// The state-mutating helpers form a category with shared structural shape:
// take_state → match → mutation → put_state. Marking them with a dedicated
// prefix makes the category scannable and the contract auditable:
//
//   grep '^fun do_'                             # all state mutators (both flavors)
//   grep -B5 'take_state(escrow)' | grep '^fun' # state-window owners only
//
// Window owners ⊆ do_* always. Orchestrators are do_* but not window
// owners; they call window-owner do_* helpers instead. Non-do_* functions
// never own a window. The convention encodes a structural property — every
// state mutation is funneled through a do_* — making the call graph
// self-documenting.
//
// Why orchestrators exist
// ────────────────────────
// A transition may conceptually mutate state more than once (e.g., handover:
// redistribute balance, then rotate tenant). Decomposing into two do_*
// sub-steps, each with its own take/put, separates concerns at the cost of
// one extra take/put cycle per transition. An intermediate state value
// (e.g., `current.stake = balance::zero()`) lives between the two steps —
// transient and only observable inside the orchestrator body, never at a tx
// boundary (P13).
//
// How to maintain the convention in future changes
// ─────────────────────────────────────────────────
// 1. A new helper that calls take_state and put_state must be named do_*.
// 2. A new public function that needs to mutate state must delegate to a
//    do_* helper rather than open its own take/put window.
// 3. An orchestrator do_* that composes sub-step do_* helpers stays in the
//    do_* family even though its body has no direct take_state call.
// 4. Sub-step do_* helpers may call each other only via the orchestrator;
//    each link's receipt is consumed locally before the next sub-step takes
//    state again.
