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
            install_new_tenant(escrow, payment, floor, now, ctx),
        EscrowState::HandoverOpen { .. } =>
            place_bid(escrow, payment, floor, now, ctx),
        EscrowState::HandoverConfirmed { .. } =>
            supersede_bid(escrow, payment, floor, ctx),
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
        | EscrowState::AtDutchAuction { .. } => retire_immediately(escrow, ctx),
        EscrowState::HandoverOpen { .. }
        | EscrowState::HandoverConfirmed { .. } => set_retiring_flag(escrow, ctx),
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
        EscrowState::Idle           { asset: _a }     => abort EStaleTenantCap,
        EscrowState::AtDutchAuction { asset: _a, .. } => abort EStaleTenantCap,
        EscrowState::Retired        { asset: _a }     => abort EStaleTenantCap,
    };
    put_state(escrow, new_state, receipt);
    let asset_id = object::id(&asset);
    let r = AssetReceipt { escrow_id, asset_id };
    event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id });
    (asset, r)
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
    let (old, receipt) = take_state(escrow);
    let (new_state, tenant_cap_id) = match (old) {
        EscrowState::HandoverOpen { asset: asset_slot, phase_start_ms, current, retiring } => {
            let cap_id = current.cap_id;
            let mut slot = asset_slot;
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
            option::fill(&mut slot, asset);
            let new = EscrowState::HandoverConfirmed {
                asset: slot, phase_start_ms, current, pending, retiring,
                handover_countdown_expiry,
            };
            (new, cap_id)
        },
        // Unreachable by PTB clock-fixity (§6.1): AssetReceipt is only
        // produced from HandoverOpen/HandoverConfirmed, and state cannot
        // change between borrow and return inside one PTB.
        EscrowState::Idle           { asset: _a }     => abort EInvariantViolation,
        EscrowState::AtDutchAuction { asset: _a, .. } => abort EInvariantViolation,
        EscrowState::Retired        { asset: _a }     => abort EInvariantViolation,
    };
    put_state(escrow, new_state, receipt);
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
    let elapsed_ms = effective_ts - phase_start_ms;
    let g = curve_shape::evaluate_curve(
        config::credit_curve(&escrow.config),
        elapsed_ms,
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
fun do_handover<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id = object::id(escrow);
    let (old, receipt) = take_state(escrow);
    let (asset, phase_start_outgoing, current, pending, retiring) = match (old) {
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms, current, pending,
            retiring, handover_countdown_expiry: _,
        } => (asset, phase_start_ms, current, pending, retiring),
        EscrowState::Idle              { asset: _a }                       => abort EInvariantViolation,
        EscrowState::AtDutchAuction    { asset: _a, .. }                   => abort EInvariantViolation,
        EscrowState::HandoverOpen      { asset: _a, current: _c, .. }      => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                       => abort EInvariantViolation,
    };

    let Tenant { cap_id: _, address: displaced_tenant, stake: outgoing_stake } = current;
    let principal = balance::value(&outgoing_stake);

    // Curve-derived used_credit (same math as compute_used_credit, on the
    // owned outgoing stake). Clamp would be a no-op here (boundary equals
    // handover_countdown_expiry by precondition).
    let elapsed = boundary_ms - phase_start_outgoing;
    let g = curve_shape::evaluate_curve(
        config::credit_curve(&escrow.config),
        elapsed,
        config::tenure_ceiling(&escrow.config),
    );
    let used_credit   = math::mul_div(principal, g, curve_shape::scale());
    let remain_credit = principal - used_credit;

    // Push remain_credit before any rotation (push-before-rotate, P3).
    let mut outgoing_balance = outgoing_stake;
    if (remain_credit > 0) {
        let remain_part = balance::split(&mut outgoing_balance, remain_credit);
        transfer::public_transfer(coin::from_balance(remain_part, ctx), displaced_tenant);
    };

    // Settle remainder == used_credit.
    let fee_inbox_id = escrow.fee_inbox_id;
    let (owner_share, protocol_fee) = settle_stake_earnings(
        &mut escrow.owner_earnings, outgoing_balance, used_credit,
        escrow_id, fee_inbox_id, displaced_tenant, ctx,
    );

    // Rotate pending → new current.
    let Tenant { cap_id: new_cap_id, address: new_address, stake: new_stake } = pending;
    let new_rent_price = balance::value(&new_stake);
    let new_current = Tenant { cap_id: new_cap_id, address: new_address, stake: new_stake };

    put_state(escrow, EscrowState::HandoverOpen {
        asset,
        phase_start_ms: boundary_ms,
        current:        new_current,
        retiring,
    }, receipt);

    event::emit(HandoverCompleted {
        escrow_id,
        displaced_tenant,
        new_tenant_cap_id: new_cap_id,
        used_credit,
        owner_share,
        protocol_fee,
        remain_credit,
        new_rent_price,
        timestamp_ms: boundary_ms,
    });
}

/// spec: §7.2 — tenure expiry. Pre: state is HandoverOpen.
fun do_tenure_expiry<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id = object::id(escrow);
    let (old, receipt) = take_state(escrow);
    let (asset_opt, current, retiring) = match (old) {
        EscrowState::HandoverOpen { asset, phase_start_ms: _, current, retiring } =>
            (asset, current, retiring),
        EscrowState::Idle              { asset: _a }                                            => abort EInvariantViolation,
        EscrowState::AtDutchAuction    { asset: _a, .. }                                        => abort EInvariantViolation,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort EInvariantViolation,
        EscrowState::Retired           { asset: _a }                                            => abort EInvariantViolation,
    };
    // Unwrap Option<Asset> — guaranteed Some by P11 (no borrow can be open
    // when do_tenure_expiry fires; PTB clock-fixity §6.1).
    let asset = option::destroy_some(asset_opt);

    let Tenant { cap_id: _, address: tenant, stake: outgoing_stake } = current;
    let stake_total            = balance::value(&outgoing_stake);
    let last_acquisition_price = stake_total;

    let fee_inbox_id = escrow.fee_inbox_id;
    let (owner_share, protocol_fee) = settle_stake_earnings(
        &mut escrow.owner_earnings, outgoing_stake, stake_total,
        escrow_id, fee_inbox_id, tenant, ctx,
    );

    let next_state: EscrowState<Asset, CoinType> = if (retiring) {
        EscrowState::Retired { asset }
    } else {
        EscrowState::AtDutchAuction {
            asset,
            phase_start_ms: boundary_ms,
            last_acquisition_price,
        }
    };
    let next_tag = state_tag(&next_state);
    put_state(escrow, next_state, receipt);

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
fun install_new_tenant<Asset: key + store, CoinType>(
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
fun place_bid<Asset: key + store, CoinType>(
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
fun supersede_bid<Asset: key + store, CoinType>(
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
fun retire_immediately<Asset: key + store, CoinType>(
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
fun set_retiring_flag<Asset: key + store, CoinType>(
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

/// spec: §7.6 — split + (gated) fee post + drain into owner_earnings.
/// Operates on the owned destructured stake; caller passes `&mut owner_earnings`.
fun settle_stake_earnings<CoinType>(
    owner_earnings: &mut Balance<CoinType>,
    mut stake:      Balance<CoinType>,
    principal:      u64,
    escrow_id:      ID,
    fee_inbox_id:   ID,
    payer:          address,
    ctx:            &mut TxContext,
): (u64, u64) {
    let (owner_share, protocol_fee) = split_fee(principal);
    if (protocol_fee > 0) {
        let fee_balance = balance::split(&mut stake, protocol_fee);
        fee_message::post<CoinType>(fee_balance, escrow_id, payer, fee_inbox_id, ctx);
    };
    balance::join(owner_earnings, stake);
    (owner_share, protocol_fee)
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
