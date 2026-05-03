// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::escrow_coordinator;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    event,
};
use usufruct::{
    config::{Self, IntegrationConfig},
    lifecycle_state::{Self, LifecycleState},
    math,
    owner::{Self, Owner},
    owner_cap::{Self, OwnerCap},
    protocol_fee_inbox::{Self, ProtocolFeeRef},
};

// === Errors ===

const ENotRented:               u64 = 0;
const EInsufficientPayment:     u64 = 1;
const ERetireFlagBlocksBid:     u64 = 2;
const ERetiredNoBid:            u64 = 3;
const ERetireFloorNotElapsed:   u64 = 4;
const EAlreadyRetired:          u64 = 5;
const ENotRetired:              u64 = 6;
const EReceiptEscrowMismatch:   u64 = 7;
const EReceiptAssetMismatch:    u64 = 8;
const ENoEarnings:              u64 = 9;
const EAssetAlreadyBorrowed:    u64 = 10;
const EWrongEscrowOwnerCap:     u64 = 11;
const EWrongEscrowTenantCap:    u64 = 12;
const EPendingTenantCap:        u64 = 13;
const EStaleTenantCap:          u64 = 14;
const ETenantCapNotStale:       u64 = 15;
const EInvariantViolation:      u64 = 0xDEADC0DE;

// === Constants ===

/// Protocol fee — 10 % of `used_credit` at every boundary that touches
/// a tenant's stake (handover, tenure expiry). Lives at the
/// coordinator layer because it is a protocol-policy constant, not an
/// integration-config knob.
const PROTOCOL_FEE_BPS:   u64 = 1_000;
const BPS_PER_UNIT:       u64 = 10_000;

/// Hard cap on `apply_pending_transitions` iterations. The longest
/// real cascade is 3 (HandoverConfirmed → HandoverOpen → AtDutch →
/// Idle under `descent::Skipped`); 4 leaves margin while still
/// guaranteeing termination.
const MAX_APT_ITERATIONS: u64 = 4;

// === Structs ===

/// Public 5-variant tag mirroring `LifecycleState` cross-product
/// projection. Off-chain consumers / events surface this; protocol
/// logic uses the inner `LifecycleState` accessors directly.
public enum EscrowStateTag has copy, drop, store {
    Idle,
    AtDutchAuction,
    HandoverOpen,
    HandoverConfirmed,
    Retired,
}

/// Central shared object. One per integrated asset.
///
/// `state` is wrapped in `Option` solely to support the take/put
/// discipline during transitions — it is never `None` at a
/// transaction boundary (`StateReceipt` enforces this structurally).
///
/// `owner` lives at the coordinator layer (not inside `LifecycleState`)
/// because the owner is orthogonal to the rental lifecycle: earnings
/// accumulate across rentals via `owner::deposit`, and `owner::withdraw`
/// is gated by `OwnerCap` regardless of the lifecycle position.
public struct EscrowCoordinator<Asset: key + store, phantom CoinType> has key {
    id:               UID,
    config:           IntegrationConfig,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
    state:            Option<LifecycleState<Asset, CoinType>>,
    owner:            Owner<CoinType>,
}

/// Hot-potato guard for the take/put discipline on `state`.
/// Minted by `take_state`, consumed by `put_state` — the type system
/// enforces that no take is left unmatched and that `state` ends every
/// transaction in `Some`.
public struct StateReceipt {}

// === Events ===

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

/// Create and share an `EscrowCoordinator`. Mints the `OwnerCap` and
/// returns it to the caller — typical PTB usage transfers it to the
/// deployer's wallet in the same transaction.
///
/// Emits `IntegrationConfigRegistered` (via `config::emit_registration`)
/// followed by `AssetIntegrated`. The two events form the genesis pair
/// for off-chain observers tracking new instances.
public fun integrate<Asset: key + store, CoinType>(
    asset:   Asset,
    cfg:     IntegrationConfig,
    fee_ref: &ProtocolFeeRef,
    clock:   &Clock,
    ctx:     &mut TxContext,
): OwnerCap {
    let uid              = object::new(ctx);
    let escrow_id        = object::uid_to_inner(&uid);
    let asset_id         = object::id(&asset);
    let owner_addr       = ctx.sender();
    let owner_cap        = owner_cap::new(escrow_id, owner_addr, ctx);
    let owner_cap_id     = object::id(&owner_cap);
    let fee_inbox_id     = protocol_fee_inbox::inbox_id(fee_ref);
    let integrated_at_ms = clock::timestamp_ms(clock);

    let state_inner = lifecycle_state::new<Asset, CoinType>(asset);
    let owner       = owner::new<CoinType>(owner_cap_id);

    let escrow = EscrowCoordinator<Asset, CoinType> {
        id:               uid,
        config:           cfg,
        fee_inbox_id,
        integrated_at_ms,
        state:            option::some(state_inner),
        owner,
    };
    config::emit_registration(&escrow.config, escrow_id);
    transfer::share_object(escrow);
    event::emit(AssetIntegrated<Asset, CoinType> { escrow_id, owner_cap_id, asset_id });
    owner_cap
}

// === View Functions ===

/// Project the inner lifecycle to the public 5-variant tag. Pure read
/// — no state mutation, no APT, callable from any caller (off-chain
/// consumers, integrating PTBs, internal dispatch).
public fun state_tag<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): EscrowStateTag {
    project_tag(read_state(escrow))
}

// ─── Tag predicates ──────────────────────────────────────────────────────────
// Move 2024 restricts enum-variant construction to the defining module;
// callers compare tags via these predicates rather than constructing one
// to compare against.

public fun is_tag_idle(t: &EscrowStateTag): bool {
    match (t) { EscrowStateTag::Idle => true, _ => false }
}

public fun is_tag_at_dutch_auction(t: &EscrowStateTag): bool {
    match (t) { EscrowStateTag::AtDutchAuction => true, _ => false }
}

public fun is_tag_handover_open(t: &EscrowStateTag): bool {
    match (t) { EscrowStateTag::HandoverOpen => true, _ => false }
}

public fun is_tag_handover_confirmed(t: &EscrowStateTag): bool {
    match (t) { EscrowStateTag::HandoverConfirmed => true, _ => false }
}

public fun is_tag_retired(t: &EscrowStateTag): bool {
    match (t) { EscrowStateTag::Retired => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

/// Project a `LifecycleState` to the corresponding `EscrowStateTag`.
/// The legal cross-products are:
///   NotRented + Idle              → Idle
///   NotRented + AtDutch           → AtDutchAuction
///   NotRented + Retired           → Retired
///   Rented    + HandoverOpen      → HandoverOpen
///   Rented    + HandoverConfirmed → HandoverConfirmed
/// Any other combination is a structural invariant violation.
fun project_tag<Asset: key + store, CoinType>(
    s: &LifecycleState<Asset, CoinType>,
): EscrowStateTag {
    if (lifecycle_state::is_not_rented(s)) {
        if (lifecycle_state::is_a_state_idle(s))         { EscrowStateTag::Idle }
        else if (lifecycle_state::is_a_state_at_dutch(s)) { EscrowStateTag::AtDutchAuction }
        else if (lifecycle_state::is_a_state_retired(s))  { EscrowStateTag::Retired }
        else                                              { abort EInvariantViolation }
    } else {
        if (lifecycle_state::is_a_state_handover_open(s))           { EscrowStateTag::HandoverOpen }
        else if (lifecycle_state::is_a_state_handover_confirmed(s)) { EscrowStateTag::HandoverConfirmed }
        else                                                         { abort EInvariantViolation }
    }
}

/// take/put/read are the only sites that touch `escrow.state`. The
/// `StateReceipt` hot-potato enforces that every take is followed by
/// a put within the same PTB.
fun take_state<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
): (LifecycleState<Asset, CoinType>, StateReceipt) {
    assert!(option::is_some(&escrow.state), EInvariantViolation);
    (option::extract(&mut escrow.state), StateReceipt {})
}

fun put_state<Asset: key + store, CoinType>(
    escrow:  &mut EscrowCoordinator<Asset, CoinType>,
    new:     LifecycleState<Asset, CoinType>,
    receipt: StateReceipt,
) {
    let StateReceipt {} = receipt;
    assert!(option::is_none(&escrow.state), EInvariantViolation);
    option::fill(&mut escrow.state, new);
}

fun read_state<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): &LifecycleState<Asset, CoinType> {
    assert!(option::is_some(&escrow.state), EInvariantViolation);
    option::borrow(&escrow.state)
}

/// Pure 90/10 split of `amount` into `(owner_share, protocol_fee)`.
/// `mul_div` is overflow-safe; the fee floors to zero when
/// `amount < BPS_PER_UNIT / PROTOCOL_FEE_BPS = 10`.
fun split_fee(amount: u64): (u64, u64) {
    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)
}

// === Test Functions ===

#[test_only]
public(package) fun read_state_for_testing<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): &LifecycleState<Asset, CoinType> {
    read_state(escrow)
}

/// Exercise the take/put cycle as a no-op. Verifies the
/// `StateReceipt` hot-potato discipline structurally — the cycle
/// must compile and run without aborting from the
/// `option::is_some` / `option::is_none` invariants.
#[test_only]
public(package) fun take_put_no_op_for_testing<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
) {
    let (s, receipt) = take_state(escrow);
    put_state(escrow, s, receipt);
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    split_fee(amount)
}
