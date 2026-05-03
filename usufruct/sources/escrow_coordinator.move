// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::escrow_coordinator;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset::{Self, AssetReceipt},
    asset_state,
    config::{Self, IntegrationConfig},
    credit_state,
    descent_policy,
    fee_message,
    handover_policy,
    lifecycle_state::{Self, LifecycleState},
    math,
    owner::{Self, Owner},
    owner_cap::{Self, OwnerCap},
    phases,
    price_state,
    protocol_fee_inbox::{Self, ProtocolFeeRef},
    refund_state,
    retire_policy,
    tenant,
    tenant_cap::{Self, TenantCap},
    tenant_state,
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
// Slot 10 reserved for `EAssetAlreadyBorrowed` parity with the legacy
// rental_escrow.move; the new design enforces the invariant
// structurally inside `asset::take` (option::extract aborts on None),
// so the coordinator-layer code is unreachable.
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

/// Owner-gated earnings withdrawal. APT first; cap-escrow guard;
/// asserts non-zero balance (ENoEarnings — gas-saving sanity, not
/// a correctness invariant). Drains all earnings to a Coin and
/// returns it to the caller. Owner stays alive for further deposits.
public fun withdraw_earnings<Asset: key + store, CoinType>(
    escrow:    &mut EscrowCoordinator<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Coin<CoinType> {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(escrow, clock, ctx);
    let amount = owner::value(&escrow.owner);
    assert!(amount > 0, ENoEarnings);
    let earnings = owner::withdraw(&mut escrow.owner, owner_cap, ctx);
    event::emit(EarningsWithdrawn {
        escrow_id:    object::id(escrow),
        owner_cap_id: object::id(owner_cap),
        owner:        ctx.sender(),
        amount,
    });
    earnings
}

/// Owner-gated terminal claim. The escrow is consumed by value:
/// after this call there is no on-chain `EscrowCoordinator` for the
/// asset.
///
/// Sequence: cap-escrow guard → APT → require Retired (ENotRetired)
/// → decompose escrow → claim asset, sanity-check tenant slot is
/// Absence, drain owner, burn cap, destroy empty owner, delete the
/// shared object → return (asset, earnings_coin) to caller.
public fun claim_asset<Asset: key + store, CoinType>(
    mut escrow: EscrowCoordinator<Asset, CoinType>,
    owner_cap:  OwnerCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, Coin<CoinType>) {
    assert!(owner_cap::escrow_id(&owner_cap) == object::id(&escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(&mut escrow, clock, ctx);
    assert!(is_tag_retired(&state_tag(&escrow)), ENotRetired);

    // Capture identifiers for the AssetClaimed event before
    // destructuring (the borrows would otherwise conflict with the
    // value-move inside `let EscrowCoordinator { .. } = escrow`).
    let escrow_id    = object::id(&escrow);
    let owner_cap_id = object::id(&owner_cap);
    let owner_addr   = ctx.sender();

    // Decompose the EscrowCoordinator; state and owner are
    // store-only (no drop), so they must be consumed explicitly.
    let EscrowCoordinator {
        id, config: _, fee_inbox_id: _, integrated_at_ms: _, state, mut owner,
    } = escrow;

    // The Option<LifecycleState> is always Some at tx boundary
    // (StateReceipt discipline).
    let inner_state = option::destroy_some(state);
    let (a_state, t_state) = lifecycle_state::decompose_retired(inner_state);
    let asset = asset_state::claim(a_state);
    tenant_state::consume_absence(t_state);

    // Drain owner earnings. value > 0 is fine (returns the coin) and
    // value == 0 is also fine (returns a zero coin); the caller can
    // dispose of the zero coin off-chain or via destroy_zero.
    let earnings = owner::withdraw(&mut owner, &owner_cap, ctx);
    let swept_earnings = coin::value(&earnings);
    owner::destroy_empty(owner);

    owner_cap::burn(owner_cap, owner_addr);
    object::delete(id);

    event::emit(AssetClaimed { escrow_id, owner_cap_id, swept_earnings });
    (asset, earnings)
}

/// Owner-gated retire entry. Calls APT first, then enforces the
/// retire-policy floor (if `Deferred`), then dispatches by tag:
///   Idle | AtDutchAuction → `do_retire_immediately`
///                          (state becomes Retired in this call)
///   HandoverOpen          → `do_set_retiring_flag` (flag lifted;
///   HandoverConfirmed       state stays Rented; tenure expiry will
///                          collapse to Retired in `do_tenure_expiry`)
///   Retired               → abort EAlreadyRetired
public fun retire<Asset: key + store, CoinType>(
    escrow:    &mut EscrowCoordinator<Asset, CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): EscrowStateTag {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(escrow, clock, ctx);
    assert!(
        retire_policy::is_unlocked(
            config::retire(&escrow.config),
            escrow.integrated_at_ms,
            clock::timestamp_ms(clock),
        ),
        ERetireFloorNotElapsed,
    );
    let tag = state_tag(escrow);
    if (is_tag_idle(&tag) || is_tag_at_dutch_auction(&tag)) {
        do_retire_immediately(escrow, ctx)
    } else if (is_tag_handover_open(&tag) || is_tag_handover_confirmed(&tag)) {
        do_set_retiring_flag(escrow, ctx)
    } else {
        // Retired.
        abort EAlreadyRetired
    }
}

/// Single entry point to become tenant or place a bid. Calls
/// `apply_pending_transitions` first (stub in this commit; real APT
/// in the upcoming wave), then dispatches by `state_tag`:
///   Idle | AtDutchAuction → install (start_rent)
///   HandoverOpen          → place bid
///   HandoverConfirmed     → supersede pending bid
///   Retired               → unreachable (compute_floor_price aborts
///                           with ERetiredNoBid before dispatch)
///
/// Returns the freshly minted `TenantCap`. Caller is responsible for
/// transferring it to the bidder's wallet (typical PTB usage:
/// `transfer::public_transfer(cap, ctx.sender())`).
public fun rent<Asset: key + store, CoinType>(
    escrow:  &mut EscrowCoordinator<Asset, CoinType>,
    payment: Coin<CoinType>,
    clock:   &Clock,
    ctx:     &mut TxContext,
): TenantCap {
    apply_pending_transitions(escrow, clock, ctx);
    let now   = clock::timestamp_ms(clock);
    let floor = compute_floor_price(escrow, now);
    assert!(coin::value(&payment) >= floor, EInsufficientPayment);

    let tag = state_tag(escrow);
    if (is_tag_idle(&tag) || is_tag_at_dutch_auction(&tag)) {
        do_install_new_tenant(escrow, payment, floor, now, ctx)
    } else if (is_tag_handover_open(&tag)) {
        do_place_bid(escrow, payment, floor, now, ctx)
    } else if (is_tag_handover_confirmed(&tag)) {
        do_supersede_bid(escrow, payment, floor, ctx)
    } else {
        // Retired — unreachable: compute_floor_price aborted earlier.
        abort EInvariantViolation
    }
}

/// Tenant-side asset borrow. Calls APT first (asset borrow gates on
/// the settled state). Cap-escrow guard, then state guards:
///   Idle | AtDutchAuction | Retired → EStaleTenantCap (no rental)
///   HandoverConfirmed + cap == pending → EPendingTenantCap
///                                          (pending bidder cannot
///                                           borrow during demand)
///   cap ≠ current → EStaleTenantCap (foreign / superseded cap)
/// On success: extracts asset via lifecycle_state::give, returns
/// (asset, AssetReceipt) to caller. The receipt is hot-potato — must
/// reach `return_asset` in the same PTB.
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut EscrowCoordinator<Asset, CoinType>,
    tenant_cap: &TenantCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt) {
    apply_pending_transitions(escrow, clock, ctx);
    let escrow_id = object::id(escrow);
    assert!(tenant_cap::escrow_id(tenant_cap) == escrow_id, EWrongEscrowTenantCap);
    let cap_id = object::id(tenant_cap);

    {
        let s = read_state(escrow);
        if (!lifecycle_state::is_rented(s)) {
            abort EStaleTenantCap
        };
        if (lifecycle_state::is_a_state_handover_confirmed(s)) {
            assert!(cap_id != lifecycle_state::pending_cap_id(s), EPendingTenantCap);
        };
        assert!(cap_id == lifecycle_state::current_cap_id(s), EStaleTenantCap);
    };

    let (state_inner, sr) = take_state(escrow);
    let (new_state, asset, asset_receipt) = lifecycle_state::give(state_inner);
    put_state(escrow, new_state, sr);
    event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id });
    (asset, asset_receipt)
}

/// Tenant-side asset return. No APT — a borrow window is clock-fixed
/// (the tenant cannot transition the lifecycle while holding the
/// asset). The three-assert safety on the receipt fires inside
/// `asset::put`; in addition, this entry surfaces the explicit
/// `EReceiptEscrowMismatch` / `EReceiptAssetMismatch` codes at the
/// coordinator layer per the public-API spec.
public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut EscrowCoordinator<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt,
) {
    let escrow_id = object::id(escrow);
    assert!(asset::receipt_escrow_id(&receipt_in) == escrow_id,         EReceiptEscrowMismatch);
    assert!(asset::receipt_asset_id(&receipt_in)  == object::id(&asset), EReceiptAssetMismatch);

    let tenant_cap_id = {
        let s = read_state(escrow);
        assert!(lifecycle_state::is_rented(s), EInvariantViolation);
        lifecycle_state::current_cap_id(s)
    };
    let (state_inner, sr) = take_state(escrow);
    let new_state = lifecycle_state::give_back(state_inner, asset, receipt_in);
    put_state(escrow, new_state, sr);
    event::emit(AssetReturned { escrow_id, tenant_cap_id });
}

/// Burn a stale `TenantCap` for gas recovery. APT first; cap-escrow
/// guard. Cap is "stale" iff it is not the live current or pending
/// reference: any cap from a superseded bid, a former tenant, or
/// when the lifecycle has no active tenants (Idle / AtDutch /
/// Retired) qualifies. Aborts `ETenantCapNotStale` on a live cap.
public fun burn_tenant_cap<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    cap:    TenantCap,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    apply_pending_transitions(escrow, clock, ctx);
    let escrow_id = object::id(escrow);
    assert!(tenant_cap::escrow_id(&cap) == escrow_id, EWrongEscrowTenantCap);
    let cap_id = object::id(&cap);

    {
        let s = read_state(escrow);
        if (lifecycle_state::is_rented(s)) {
            assert!(cap_id != lifecycle_state::current_cap_id(s), ETenantCapNotStale);
            if (lifecycle_state::is_t_state_demand(s)) {
                assert!(cap_id != lifecycle_state::pending_cap_id(s), ETenantCapNotStale);
            };
        };
        // NotRented — no live caps, anything stale.
    };
    tenant_cap::burn(cap, ctx);
}

/// Permissionless settler. Drives every elapsed lazy transition
/// before any other operation observes the state.
///
/// Three checks fire in order; each is gated by the variant + time
/// predicate. The order matters: handover countdown (Demand) precedes
/// tenure expiry (HandoverOpen) so a pending bid that auto-wins at
/// the tenure boundary is processed correctly. Tenure precedes auction
/// because tenure expiry transitions HandoverOpen → AtDutch (which
/// then becomes a candidate for the auction check next iteration).
///
/// The loop is bounded by `MAX_APT_ITERATIONS = 4` — the longest real
/// cascade is 3 (HandoverConfirmed → HandoverOpen → AtDutch → Idle
/// under `descent::Skipped`).
public fun apply_pending_transitions<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
): EscrowStateTag {
    let now = clock::timestamp_ms(clock);
    let mut keep_going = true;
    let mut iterations: u64 = 0;
    while (keep_going) {
        assert!(iterations < MAX_APT_ITERATIONS, EInvariantViolation);
        iterations = iterations + 1;
        keep_going = apt_step(escrow, now, ctx);
    };
    state_tag(escrow)
}

/// Inspect the current state and fire at most one elapsed transition.
/// Returns `true` if a transition fired (caller re-runs to chase
/// cascades), `false` otherwise (steady state).
fun apt_step<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    now:    u64,
    ctx:    &mut TxContext,
): bool {
    // Check 1 — Handover countdown (Rented + Demand).
    let handover_due: Option<u64> = {
        let s = read_state(escrow);
        if (lifecycle_state::is_rented(s) && lifecycle_state::is_t_state_demand(s)) {
            let expiry = lifecycle_state::handover_countdown_expiry_ms(s);
            if (phases::has_passed(expiry, 0, now)) { option::some(expiry) }
            else                                    { option::none() }
        } else { option::none() }
    };
    if (option::is_some(&handover_due)) {
        let boundary_ms = option::destroy_some(handover_due);
        do_handover(escrow, boundary_ms, ctx);
        return true
    };
    option::destroy_none(handover_due);

    // Check 2 — Tenure expiry (Rented + HandoverOpen).
    let tenure_due: Option<u64> = {
        let s = read_state(escrow);
        if (lifecycle_state::is_rented(s) && lifecycle_state::is_a_state_handover_open(s)) {
            let phase_start = lifecycle_state::phase_start_ms(s);
            let tenure      = config::tenure_ceiling(&escrow.config);
            if (phases::has_passed(phase_start, tenure, now)) {
                option::some(phases::boundary_at(phase_start, tenure))
            } else { option::none() }
        } else { option::none() }
    };
    if (option::is_some(&tenure_due)) {
        let boundary_ms = option::destroy_some(tenure_due);
        do_tenure_expiry(escrow, boundary_ms, ctx);
        return true
    };
    option::destroy_none(tenure_due);

    // Check 3 — Auction expiry (NotRented + AtDutch).
    let auction_due: Option<u64> = {
        let s = read_state(escrow);
        if (lifecycle_state::is_not_rented(s) && lifecycle_state::is_a_state_at_dutch(s)) {
            let phase_start = lifecycle_state::phase_start_ms(s);
            let policy      = config::descent(&escrow.config);
            if (descent_policy::has_expired(policy, phase_start, now)) {
                option::some(descent_policy::expiry_at(policy, phase_start))
            } else { option::none() }
        } else { option::none() }
    };
    if (option::is_some(&auction_due)) {
        let boundary_ms = option::destroy_some(auction_due);
        do_auction_expiry(escrow, boundary_ms);
        return true
    };
    option::destroy_none(auction_due);

    false
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

// ─── Pricing views ───────────────────────────────────────────────────────────

/// Used credit accrued by the current tenant since the rental's
/// `phase_start_ms`, evaluated at `timestamp_ms`. Defined only while
/// the lifecycle is `Rented` — aborts otherwise (`ENotRented`).
///
/// Derives the credit regime from the lifecycle's tenant slot:
/// HandoverConfirmed → `Capped` (effective time saturates at the
/// pre-stamped countdown expiry); HandoverOpen → `Accruing` (no cap).
/// All curve-and-arithmetic logic lives inside `credit_state::used_credit`.
public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow:       &EscrowCoordinator<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    let s = read_state(escrow);
    assert!(lifecycle_state::is_rented(s), ENotRented);
    let stake          = lifecycle_state::current_stake_value(s);
    let phase_start_ms = lifecycle_state::phase_start_ms(s);
    let cs = if (lifecycle_state::is_t_state_demand(s)) {
        credit_state::capped(stake, phase_start_ms, lifecycle_state::handover_countdown_expiry_ms(s))
    } else {
        credit_state::accruing(stake, phase_start_ms)
    };
    credit_state::used_credit(&cs, &escrow.config, timestamp_ms)
}

/// Minimum acceptable payment to win the rent for the next bidder,
/// evaluated at `timestamp_ms`. Derives the pricing regime from the
/// lifecycle's asset slot:
///   - `Idle`              → `Rest`       (min_rent_price)
///   - `HandoverOpen`      → `Ascending`  over current's stake
///   - `HandoverConfirmed` → `Ascending`  over pending's stake
///   - `AtDutchAuction`    → `Descending` from last_acq_price
///   - `Retired`           → aborts `ERetiredNoBid` (no pricing regime)
///
/// All pricing arithmetic lives inside `price_state::floor_price`.
public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow:       &EscrowCoordinator<Asset, CoinType>,
    timestamp_ms: u64,
): u64 {
    let s = read_state(escrow);
    let ps = if (lifecycle_state::is_a_state_idle(s)) {
        price_state::rest()
    } else if (lifecycle_state::is_a_state_handover_open(s)) {
        price_state::ascending(lifecycle_state::current_stake_value(s))
    } else if (lifecycle_state::is_a_state_handover_confirmed(s)) {
        price_state::ascending(lifecycle_state::pending_stake_value(s))
    } else if (lifecycle_state::is_a_state_at_dutch(s)) {
        price_state::descending(
            lifecycle_state::last_acq_price_of_at_dutch(s),
            lifecycle_state::phase_start_ms(s),
        )
    } else {
        // is_a_state_retired
        abort ERetiredNoBid
    };
    price_state::floor_price(&ps, &escrow.config, timestamp_ms)
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

// ─── do_* dispatch (rent path) ───────────────────────────────────────────────
// Each consumes the payment, mints a fresh TenantCap, threads the
// resulting `Tenant<C>` through `lifecycle_state`, and emits the
// corresponding boundary event.

/// Idle | AtDutchAuction → Rented{HandoverOpen}. Records the
/// `from_state` tag in `RentStarted` so off-chain observers can
/// distinguish a fresh rental (Idle) from an auction-rescue (AtDutch).
fun do_install_new_tenant<Asset: key + store, CoinType>(
    escrow:  &mut EscrowCoordinator<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): TenantCap {
    let escrow_id    = object::id(escrow);
    let price_paid   = coin::value(&payment);
    let from_state   = state_tag(escrow);
    let tenant_addr  = ctx.sender();

    let (cap, cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, tenant_addr, coin::into_balance(payment));

    let (s, receipt) = take_state(escrow);
    let new_s = lifecycle_state::start_rent<Asset, CoinType>(s, t, now, escrow_id);
    put_state(escrow, new_s, receipt);

    event::emit(RentStarted {
        escrow_id,
        tenant_cap_id: cap_id,
        price_paid,
        floor_price: floor,
        from_state,
    });
    cap
}

/// Rented{HandoverOpen} → Rented{HandoverConfirmed}. Computes and
/// stamps the handover-countdown expiry into TenantState::Demand
/// once at bid time; APT and `compute_used_credit` later read it
/// directly without re-deriving via `handover_policy::expiry_at`.
fun do_place_bid<Asset: key + store, CoinType>(
    escrow:  &mut EscrowCoordinator<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): TenantCap {
    let s = read_state(escrow);
    assert!(!lifecycle_state::is_retiring(s), ERetireFlagBlocksBid);
    let phase_start = lifecycle_state::phase_start_ms(s);
    let tenure      = config::tenure_ceiling(&escrow.config);
    let expiry      = handover_policy::expiry_at(
        config::handover(&escrow.config),
        now,
        phase_start,
        tenure,
    );

    let escrow_id    = object::id(escrow);
    let pending_addr = ctx.sender();
    let bid_amount   = coin::value(&payment);

    let (cap, cap_id) = tenant_cap::new(escrow_id, pending_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, pending_addr, coin::into_balance(payment));

    let (st, receipt) = take_state(escrow);
    let new_st = lifecycle_state::place_bid<Asset, CoinType>(st, t, expiry);
    put_state(escrow, new_st, receipt);

    event::emit(BidPlaced {
        escrow_id,
        tenant_cap_id: cap_id,
        pending_tenant: pending_addr,
        bid_amount,
        floor_price: floor,
        handover_countdown_expiry: expiry,
    });
    cap
}

/// Rented{HandoverConfirmed} → Rented{HandoverConfirmed} with the
/// pending slot replaced. The displaced tenant's full stake is
/// refunded to its registered address via `tenant::liquidate` (no
/// owner share, no fee — `RefundState::Total`). The
/// handover-countdown expiry is **preserved**, not reset: the current
/// tenant's protection period started when the first bid landed, and
/// supersede only swaps the bidder.
fun do_supersede_bid<Asset: key + store, CoinType>(
    escrow:  &mut EscrowCoordinator<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    ctx:     &mut TxContext,
): TenantCap {
    let s = read_state(escrow);
    let displaced_cap_id = lifecycle_state::pending_cap_id(s);
    let displaced_addr   = lifecycle_state::pending_addr(s);
    let existing_expiry  = lifecycle_state::handover_countdown_expiry_ms(s);

    let escrow_id      = object::id(escrow);
    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);

    let (cap, cap_id) = tenant_cap::new(escrow_id, new_bidder, ctx);
    let t = tenant::new<CoinType>(cap_id, new_bidder, coin::into_balance(payment));

    let (st, receipt) = take_state(escrow);
    let (new_st, refund) = lifecycle_state::supersede_bid<Asset, CoinType>(st, t, existing_expiry);
    put_state(escrow, new_st, receipt);

    // supersede_bid only ever produces Total — Nothing/Parcial appear
    // at handover/tenure boundaries (Phase 4). consume_total aborts if
    // it ever sees another variant.
    let (_identity, stake) = refund_state::consume_total(refund);
    let refunded_amount = tenant::stake_value_of(&stake);
    tenant::liquidate(stake, displaced_addr, ctx);
    event::emit(BidSuperseded {
        escrow_id,
        displaced_tenant_cap_id: displaced_cap_id,
        new_tenant_cap_id: cap_id,
        displaced_bidder: displaced_addr,
        refunded_amount,
        new_bidder,
        new_bid_amount,
        floor_price: floor,
    });
    cap
}

// ─── Boundary handlers ───────────────────────────────────────────────────────
// Fired by `apply_pending_transitions` when an elapsed boundary is
// detected. C6 wires APT; C4 ships the handlers themselves so they
// can be exercised directly via test-only fire helpers below.

/// Handover boundary (Demand → Occupied): the pending bidder takes
/// over from the current tenant. Computes used_credit at boundary_ms,
/// splits it 90/10 (owner / fee), routes the resulting RefundState
/// to its three terminal consumers (owner::deposit, fee_message::post,
/// tenant::liquidate for the remainder if Parcial). The promoted
/// tenant's cap was minted at place_bid/supersede_bid time — handover
/// does not mint a fresh cap.
fun do_handover<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id    = object::id(escrow);
    let used_credit  = compute_used_credit(escrow, boundary_ms);
    let (owner_amount, fee_amount) = split_fee(used_credit);
    let displaced_addr = lifecycle_state::current_addr(read_state(escrow));
    let principal      = lifecycle_state::current_stake_value(read_state(escrow));
    let remain_credit  = principal - used_credit;

    let (st, receipt) = take_state(escrow);
    let (new_st, refund) = lifecycle_state::accept_bid<Asset, CoinType>(
        st, owner_amount, fee_amount, boundary_ms, escrow_id,
    );
    put_state(escrow, new_st, receipt);

    if (refund_state::has_remainder(&refund)) {
        let (_id, stake, fee_share, owner_earnings) = refund_state::consume_parcial(refund);
        owner::deposit(&mut escrow.owner, owner_earnings);
        fee_message::post(fee_share, escrow.fee_inbox_id, ctx);
        tenant::liquidate(stake, displaced_addr, ctx);
    } else {
        let (_id, fee_share, owner_earnings) = refund_state::consume_nothing(refund);
        owner::deposit(&mut escrow.owner, owner_earnings);
        fee_message::post(fee_share, escrow.fee_inbox_id, ctx);
    };

    let new_tenant_cap_id = lifecycle_state::current_cap_id(read_state(escrow));
    // Post-handover state is HandoverOpen → compute_floor_price
    // returns Ascending(current_stake_value); timestamp irrelevant
    // for that regime.
    let new_rent_price = compute_floor_price(escrow, boundary_ms);

    event::emit(HandoverCompleted {
        escrow_id,
        displaced_tenant: displaced_addr,
        new_tenant_cap_id,
        used_credit,
        owner_share:    owner_amount,
        protocol_fee:   fee_amount,
        remain_credit,
        new_rent_price,
        timestamp_ms:   boundary_ms,
    });
}

/// Tenure boundary (HandoverOpen → AtDutch | Retired). The current
/// tenant departs; the full stake is consumed (owner + fee, no
/// remainder — `RefundState::Nothing`). If the retiring flag was
/// set during the rental, the resulting AtDutch is collapsed to
/// Retired in the same call and an `AssetRetired` event fires.
fun do_tenure_expiry<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id              = object::id(escrow);
    let s                      = read_state(escrow);
    let principal              = lifecycle_state::current_stake_value(s);
    let tenant_addr            = lifecycle_state::current_addr(s);
    let was_retiring           = lifecycle_state::is_retiring(s);
    let (owner_amount, fee_amount) = split_fee(principal);
    // At the tenure boundary, the credit curve has saturated — the
    // full stake is the AtDutch anchor.
    let last_acquisition_price = principal;

    let (st, receipt) = take_state(escrow);
    let (new_st, refund) = lifecycle_state::expire_tenure<Asset, CoinType>(
        st, owner_amount, fee_amount, last_acquisition_price, boundary_ms, escrow_id,
    );
    put_state(escrow, new_st, receipt);

    let (_id, fee_share, owner_earnings) = refund_state::consume_nothing(refund);
    owner::deposit(&mut escrow.owner, owner_earnings);
    fee_message::post(fee_share, escrow.fee_inbox_id, ctx);

    // If the retiring flag was set, collapse AtDutch → Retired.
    if (was_retiring) {
        let (st2, receipt2) = take_state(escrow);
        let new_st2 = lifecycle_state::retire_now(st2);
        put_state(escrow, new_st2, receipt2);
    };

    let next_state = state_tag(escrow);
    event::emit(TenureExpired {
        escrow_id,
        tenant:                 tenant_addr,
        owner_share:            owner_amount,
        protocol_fee:           fee_amount,
        last_acquisition_price,
        next_state,
        timestamp_ms:           boundary_ms,
    });
    if (was_retiring) {
        event::emit(AssetRetired { escrow_id, from_state: EscrowStateTag::HandoverOpen });
    };
}

/// Auction boundary (AtDutch → Idle). No tenant funds involved; only
/// emits `AuctionExpired` for off-chain observers.
fun do_auction_expiry<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
) {
    let escrow_id     = object::id(escrow);
    let (st, receipt) = take_state(escrow);
    let new_st        = lifecycle_state::expire_auction(st);
    put_state(escrow, new_st, receipt);
    event::emit(AuctionExpired { escrow_id, timestamp_ms: boundary_ms });
}

/// Retire from Idle | AtDutchAuction → Retired. The state transitions
/// in the same call (no flag-then-wait dance because no tenant is
/// active). Co-emits `RetireFlagSet` (for off-chain observers tracking
/// the owner's intent) and `AssetRetired` (for terminal-state markers).
fun do_retire_immediately<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    ctx:    &TxContext,
): EscrowStateTag {
    let escrow_id = object::id(escrow);
    let prior_tag = state_tag(escrow);
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::retire_now(s);
    put_state(escrow, new_s, receipt);
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), state_at_set: prior_tag });
    event::emit(AssetRetired   { escrow_id, from_state:    prior_tag });
    EscrowStateTag::Retired
}

/// Retire from HandoverOpen | HandoverConfirmed → flag lifted, state
/// stays Rented. The current tenant runs out their tenure; tenure
/// expiry detects the flag and collapses straight to Retired (see
/// `do_tenure_expiry` retiring branch). New bids are blocked while
/// the flag is set (`ERetireFlagBlocksBid` in `do_place_bid`).
fun do_set_retiring_flag<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    ctx:    &TxContext,
): EscrowStateTag {
    let escrow_id = object::id(escrow);
    let prior_tag = state_tag(escrow);
    assert!(!lifecycle_state::is_retiring(read_state(escrow)), EAlreadyRetired);
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::set_retiring(s);
    put_state(escrow, new_s, receipt);
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), state_at_set: prior_tag });
    prior_tag
}

// === Test Functions ===

#[test_only]
public(package) fun read_state_for_testing<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): &LifecycleState<Asset, CoinType> {
    read_state(escrow)
}

#[test_only]
public(package) fun owner_value_for_testing<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): u64 {
    owner::value(&escrow.owner)
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

// ─── Event field accessors (test-only) ───────────────────────────────────────
// Move struct fields are private to the defining module; tests
// observe events via these accessors. Production callers read events
// off-chain through Sui's event indexing.

#[test_only]
public(package) fun rent_started_escrow_id(e: &RentStarted): ID                  { e.escrow_id }
#[test_only]
public(package) fun rent_started_tenant_cap_id(e: &RentStarted): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun rent_started_price_paid(e: &RentStarted): u64                { e.price_paid }
#[test_only]
public(package) fun rent_started_floor_price(e: &RentStarted): u64               { e.floor_price }
#[test_only]
public(package) fun rent_started_from_state(e: &RentStarted): EscrowStateTag     { e.from_state }

#[test_only]
public(package) fun bid_placed_escrow_id(e: &BidPlaced): ID                      { e.escrow_id }
#[test_only]
public(package) fun bid_placed_tenant_cap_id(e: &BidPlaced): ID                  { e.tenant_cap_id }
#[test_only]
public(package) fun bid_placed_pending_tenant(e: &BidPlaced): address            { e.pending_tenant }
#[test_only]
public(package) fun bid_placed_bid_amount(e: &BidPlaced): u64                    { e.bid_amount }
#[test_only]
public(package) fun bid_placed_floor_price(e: &BidPlaced): u64                   { e.floor_price }
#[test_only]
public(package) fun bid_placed_handover_countdown_expiry(e: &BidPlaced): u64     { e.handover_countdown_expiry }

#[test_only]
public(package) fun bid_superseded_escrow_id(e: &BidSuperseded): ID              { e.escrow_id }
#[test_only]
public(package) fun bid_superseded_displaced_cap_id(e: &BidSuperseded): ID       { e.displaced_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_new_cap_id(e: &BidSuperseded): ID             { e.new_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_displaced_bidder(e: &BidSuperseded): address  { e.displaced_bidder }
#[test_only]
public(package) fun bid_superseded_refunded_amount(e: &BidSuperseded): u64       { e.refunded_amount }
#[test_only]
public(package) fun bid_superseded_new_bidder(e: &BidSuperseded): address        { e.new_bidder }
#[test_only]
public(package) fun bid_superseded_new_bid_amount(e: &BidSuperseded): u64        { e.new_bid_amount }

#[test_only]
public(package) fun handover_completed_escrow_id(e: &HandoverCompleted): ID                  { e.escrow_id }
#[test_only]
public(package) fun handover_completed_displaced_tenant(e: &HandoverCompleted): address       { e.displaced_tenant }
#[test_only]
public(package) fun handover_completed_new_cap_id(e: &HandoverCompleted): ID                  { e.new_tenant_cap_id }
#[test_only]
public(package) fun handover_completed_used_credit(e: &HandoverCompleted): u64                { e.used_credit }
#[test_only]
public(package) fun handover_completed_owner_share(e: &HandoverCompleted): u64                { e.owner_share }
#[test_only]
public(package) fun handover_completed_protocol_fee(e: &HandoverCompleted): u64               { e.protocol_fee }
#[test_only]
public(package) fun handover_completed_remain_credit(e: &HandoverCompleted): u64              { e.remain_credit }
#[test_only]
public(package) fun handover_completed_new_rent_price(e: &HandoverCompleted): u64             { e.new_rent_price }
#[test_only]
public(package) fun handover_completed_timestamp_ms(e: &HandoverCompleted): u64               { e.timestamp_ms }

#[test_only]
public(package) fun tenure_expired_escrow_id(e: &TenureExpired): ID                          { e.escrow_id }
#[test_only]
public(package) fun tenure_expired_tenant(e: &TenureExpired): address                         { e.tenant }
#[test_only]
public(package) fun tenure_expired_owner_share(e: &TenureExpired): u64                        { e.owner_share }
#[test_only]
public(package) fun tenure_expired_protocol_fee(e: &TenureExpired): u64                       { e.protocol_fee }
#[test_only]
public(package) fun tenure_expired_last_acq_price(e: &TenureExpired): u64                     { e.last_acquisition_price }
#[test_only]
public(package) fun tenure_expired_next_state(e: &TenureExpired): EscrowStateTag              { e.next_state }
#[test_only]
public(package) fun tenure_expired_timestamp_ms(e: &TenureExpired): u64                       { e.timestamp_ms }

#[test_only]
public(package) fun auction_expired_escrow_id(e: &AuctionExpired): ID                        { e.escrow_id }
#[test_only]
public(package) fun auction_expired_timestamp_ms(e: &AuctionExpired): u64                     { e.timestamp_ms }

#[test_only]
public(package) fun asset_retired_escrow_id(e: &AssetRetired): ID                            { e.escrow_id }
#[test_only]
public(package) fun asset_retired_from_state(e: &AssetRetired): EscrowStateTag               { e.from_state }

#[test_only]
public(package) fun retire_flag_set_escrow_id(e: &RetireFlagSet): ID                         { e.escrow_id }
#[test_only]
public(package) fun retire_flag_set_owner(e: &RetireFlagSet): address                         { e.owner }
#[test_only]
public(package) fun retire_flag_set_state_at_set(e: &RetireFlagSet): EscrowStateTag           { e.state_at_set }

#[test_only]
public(package) fun earnings_withdrawn_escrow_id(e: &EarningsWithdrawn): ID                  { e.escrow_id }
#[test_only]
public(package) fun earnings_withdrawn_owner_cap_id(e: &EarningsWithdrawn): ID                { e.owner_cap_id }
#[test_only]
public(package) fun earnings_withdrawn_owner(e: &EarningsWithdrawn): address                  { e.owner }
#[test_only]
public(package) fun earnings_withdrawn_amount(e: &EarningsWithdrawn): u64                     { e.amount }

#[test_only]
public(package) fun asset_claimed_escrow_id(e: &AssetClaimed): ID                            { e.escrow_id }
#[test_only]
public(package) fun asset_claimed_owner_cap_id(e: &AssetClaimed): ID                          { e.owner_cap_id }
#[test_only]
public(package) fun asset_claimed_swept_earnings(e: &AssetClaimed): u64                       { e.swept_earnings }

// ─── Drive helpers for test-only state composition ───────────────────────────
// Bypass `rent`/`retire` (not yet implemented) by chaining
// `lifecycle_state` transitions through the take/put discipline.
// Subsequent commits supersede these once the corresponding public API
// lands.

/// NotRented{Idle} → Rented{HandoverOpen}.
#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    escrow:         &mut EscrowCoordinator<Asset, CoinType>,
    tenant:         usufruct::tenant::Tenant<CoinType>,
    phase_start_ms: u64,
) {
    let escrow_id     = object::id(escrow);
    let (s, receipt)  = take_state(escrow);
    let new_s         = lifecycle_state::start_rent(s, tenant, phase_start_ms, escrow_id);
    put_state(escrow, new_s, receipt);
}

/// Rented{HandoverOpen} → Rented{HandoverConfirmed}. Caller must have
/// driven the escrow into Rented first.
#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    escrow:                    &mut EscrowCoordinator<Asset, CoinType>,
    tenant:                    usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: u64,
) {
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::place_bid(s, tenant, handover_countdown_expiry);
    put_state(escrow, new_s, receipt);
}

/// Rented{HandoverOpen} → NotRented{AtDutch}. Drains any RefundState
/// produced by `expire_tenure` via the entity-layer test helper.
#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    escrow:             &mut EscrowCoordinator<Asset, CoinType>,
    owner_amount:       u64,
    fee_amount:         u64,
    last_acq_price:     u64,
    new_phase_start_ms: u64,
) {
    let escrow_id        = object::id(escrow);
    let (s, receipt)     = take_state(escrow);
    let (new_s, refund)  = lifecycle_state::expire_tenure(
        s, owner_amount, fee_amount, last_acq_price, new_phase_start_ms, escrow_id,
    );
    usufruct::refund_state::destroy_for_testing(refund);
    put_state(escrow, new_s, receipt);
}

/// NotRented{Idle | AtDutch} → NotRented{Retired}.
#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
) {
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::retire_now(s);
    put_state(escrow, new_s, receipt);
}

/// Lift the `retiring` flag while staying in Rented. C5 supersedes
/// this with `do_set_retiring_flag` reachable through `retire`.
#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
) {
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::set_retiring(s);
    put_state(escrow, new_s, receipt);
}

/// Fire `do_handover` directly. C6 wires this through APT; C4 ships
/// the handler and exposes this helper so tests can verify the
/// boundary semantics in isolation.
#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    do_handover(escrow, boundary_ms, ctx)
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    do_tenure_expiry(escrow, boundary_ms, ctx)
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
) {
    do_auction_expiry(escrow, boundary_ms)
}
