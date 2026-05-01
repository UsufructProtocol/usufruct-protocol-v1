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
const EInvariantViolation:      u64 = 0xDEADC0DE; // spec: E_INVARIANT_VIOLATION

// === Constants ===
// spec: §1.2

const PROTOCOL_FEE_BPS:   u64 = 1_000;
const BPS_PER_UNIT:       u64 = 10_000;
const MAX_APT_ITERATIONS: u64 = 4;

// === Structs ===

/// spec: §2.1
public enum EscrowStateTag has copy, drop, store {
    Idle,
    AtDutchAuction,
    HandoverOpen,
    HandoverConfirmed,
    Retired,
}

/// spec: §2.2
public struct Tenant<phantom CoinType> has store {
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
}

/// spec: §2.3
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

/// spec: §2.4
public struct RentalEscrow<Asset: key + store, phantom CoinType> has key {
    id:                UID,
    config:            IntegrationConfig,
    fee_inbox_id:      ID,
    integrated_at_ms:  u64,
    owner_earnings:    Balance<CoinType>,
    state:             Option<EscrowState<Asset, CoinType>>,
}

/// spec: §2.5
public struct AssetReceipt {
    escrow_id: ID,
    asset_id:  ID,
}

/// spec: §2.6
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

/// spec: §5.1
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
        EscrowState::Retired { .. } => abort EInvariantViolation,
    }
}

/// spec: §4.2
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

/// spec: §8.7
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

/// spec: §8.2
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

/// spec: §8.3
fun compute_next_rent_price(cfg: &IntegrationConfig, price: u64): u64 {
    price_function::evaluate_price_fn(config::price_function(cfg), price)
}

/// spec: §2.6 — take/put/read are the only sites that touch escrow.state.
fun take_state<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
): (EscrowState<Asset, CoinType>, StateReceipt) {
    assert!(option::is_some(&escrow.state), EInvariantViolation);
    (option::extract(&mut escrow.state), StateReceipt {})
}

fun put_state<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    new:     EscrowState<Asset, CoinType>,
    receipt: StateReceipt,
) {
    let StateReceipt {} = receipt;
    assert!(option::is_none(&escrow.state), EInvariantViolation);
    option::fill(&mut escrow.state, new);
}

fun read_state<Asset: key + store, CoinType>(
    escrow: &RentalEscrow<Asset, CoinType>,
): &EscrowState<Asset, CoinType> {
    assert!(option::is_some(&escrow.state), EInvariantViolation);
    option::borrow(&escrow.state)
}

/// spec: §7.1
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

/// spec: §7.2
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

/// spec: §7.3
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

/// spec: §7.5
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

/// spec: §7.10
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
    let (cap, pending) = register_pending_bid(escrow_id, payment, pending_tenant, ctx);
    let pending_cap_id = object::id(&cap);
    let bid_amount     = balance::value(&pending.stake);
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

/// spec: §7.11
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
    let (cap, new_pending) = register_pending_bid(escrow_id, payment, new_bidder, ctx);
    let new_pending_cap_id = object::id(&cap);
    let new_bid_amount     = balance::value(&new_pending.stake);
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

/// spec: §7.8
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

/// spec: §7.9
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

/// spec: §7.12
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

/// spec: §7.13
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

fun settle_tenant<CoinType>(
    tenant:      Tenant<CoinType>,
    used_credit: u64,
    ctx:         &mut TxContext,
): (Tenant<CoinType>, address, Balance<CoinType>, u64) {
    let Tenant { cap_id, address: payer, stake } = tenant;
    let principal     = balance::value(&stake);
    let remain_credit = principal - used_credit;
    let leftover      = pay_tenant_remain(stake, remain_credit, payer, ctx);
    let zero_tenant   = Tenant { cap_id, address: payer, stake: balance::zero() };
    (zero_tenant, payer, leftover, remain_credit)
}

fun do_distribute_balance<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
): (address, u64, u64, u64) {
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
            let (zero_current, payer, leftover, remain_credit) = settle_tenant(current, used_credit, ctx);
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

fun do_rotate_for_handover<Asset: key + store, CoinType>(
    escrow:      &mut RentalEscrow<Asset, CoinType>,
    boundary_ms: u64,
): (ID, u64) {
    let (old, receipt) = take_state(escrow);
    let (next, new_cap_id, new_rent_price) = match (old) {
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms: _, current, pending,
            retiring, handover_countdown_expiry: _,
        } => {
            let Tenant { cap_id: _, address: _, stake: zero_stake } = current;
            assert!(balance::value(&zero_stake) == 0, EInvariantViolation);
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

fun do_terminate_tenure<Asset: key + store, CoinType>(
    escrow:                 &mut RentalEscrow<Asset, CoinType>,
    boundary_ms:            u64,
    last_acquisition_price: u64,
): EscrowStateTag {
    let (old, receipt) = take_state(escrow);
    let (next, tag) = match (old) {
        EscrowState::HandoverOpen { asset: asset_opt, phase_start_ms: _, current, retiring } => {
            let Tenant { cap_id: _, address: _, stake: zero_stake } = current;
            assert!(balance::value(&zero_stake) == 0, EInvariantViolation);
            balance::destroy_zero(zero_stake);

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

/// spec: §7.1
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

/// spec: §7.6
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

/// spec: §7.7
fun register_pending_bid<CoinType>(
    escrow_id: ID,
    payment:   Coin<CoinType>,
    bidder:    address,
    ctx:       &mut TxContext,
): (TenantCap, Tenant<CoinType>) {
    let stake = coin::into_balance(payment);
    let (cap, tenant_cap_id) = tenant_cap::new(escrow_id, bidder, ctx);
    let pending = Tenant { cap_id: tenant_cap_id, address: bidder, stake };
    (cap, pending)
}

// === Test Functions ===

