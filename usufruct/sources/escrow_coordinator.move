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
    cap_authorization::{Self, CapAuthorization},
    config::{Self, IntegrationConfig},
    credit_state,
    descent_policy,
    handover_policy,
    lifecycle_state::{Self, LifecycleState},
    math,
    owner::{Self, Owner},
    owner_cap::{Self, OwnerCap},
    pending_transition::{Self, PendingTransition},
    phases,
    price_state,
    protocol_fee_inbox::{Self, ProtocolFeeRef},
    refund_state,
    rent_action::{Self, RentAction},
    retire_policy,
    retire_route::{Self, RetireRoute},
    tenant,
    tenant_cap::{Self, TenantCap},
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


// === Structs ===

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
    escrow_id:        ID,
    owner_cap_id:     ID,
    asset_id:         ID,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
}

public struct RentStarted has copy, drop {
    escrow_id:      ID,
    tenant_cap_id:  ID,
    tenant:         address,
    phase_start_ms: u64,
    price_paid:     u64,
    floor_price:    u64,
}

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    current_tenant_cap_id:     ID,
    current_tenant_addr:       address,
    current_phase_start_ms:    u64,
    tenant_cap_id:             ID,
    pending_tenant:            address,
    bid_amount:                u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:                 ID,
    displaced_tenant_cap_id:   ID,
    new_tenant_cap_id:         ID,
    displaced_bidder:          address,
    refunded_amount:           u64,
    new_bidder:                address,
    new_bid_amount:            u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
}

public struct HandoverCompleted has copy, drop {
    escrow_id:               ID,
    displaced_tenant_cap_id: ID,
    displaced_tenant:        address,
    new_tenant_cap_id:       ID,
    new_tenant_addr:         address,
    new_tenant_stake:        u64,
    used_credit:             u64,
    owner_share:             u64,
    protocol_fee:            u64,
    remain_credit:           u64,
    new_rent_price:          u64,
    timestamp_ms:            u64,
}

public struct TenureExpired has copy, drop {
    escrow_id:               ID,
    tenant_cap_id:           ID,
    tenant:                  address,
    phase_start_ms:          u64,
    owner_share:             u64,
    protocol_fee:            u64,
    last_acquisition_price:  u64,
    timestamp_ms:            u64,
}

public struct AuctionExpired has copy, drop {
    escrow_id:     ID,
    last_acq_price: u64,
    timestamp_ms:  u64,
}

public struct RetireFlagSet has copy, drop {
    escrow_id:    ID,
    owner:        address,
    timestamp_ms: u64,
}

public struct AssetRetired has copy, drop {
    escrow_id:    ID,
    timestamp_ms: u64,
}

public struct AssetBorrowed has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    tenant:        address,
}

public struct AssetReturned has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    tenant:        address,
}

public struct AssetClaimed has copy, drop {
    escrow_id:      ID,
    owner_cap_id:   ID,
    owner:          address,
    swept_earnings: u64,
    timestamp_ms:   u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:    ID,
    owner_cap_id: ID,
    owner:        address,
    amount:       u64,
    timestamp_ms: u64,
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
    event::emit(AssetIntegrated<Asset, CoinType> { escrow_id, owner_cap_id, asset_id, fee_inbox_id, integrated_at_ms });
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
        timestamp_ms: clock::timestamp_ms(clock),
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
    assert!(is_retired(&escrow), ENotRetired);

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
    let asset       = lifecycle_state::take_asset(inner_state);

    // Drain owner earnings. value > 0 is fine (returns the coin) and
    // value == 0 is also fine (returns a zero coin); the caller can
    // dispose of the zero coin off-chain or via destroy_zero.
    let earnings = owner::withdraw(&mut owner, &owner_cap, ctx);
    let swept_earnings = coin::value(&earnings);
    owner::destroy_empty(owner);

    owner_cap::burn(owner_cap, owner_addr);
    object::delete(id);

    event::emit(AssetClaimed {
        escrow_id,
        owner_cap_id,
        owner:        owner_addr,
        swept_earnings,
        timestamp_ms: clock::timestamp_ms(clock),
    });
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
) {
    assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), EWrongEscrowOwnerCap);
    apply_pending_transitions(escrow, clock, ctx);
    let now_ms = clock::timestamp_ms(clock);
    assert!(
        retire_policy::is_unlocked(config::retire(&escrow.config), escrow.integrated_at_ms, now_ms),
        ERetireFloorNotElapsed,
    );
    let route = lifecycle_state::retire_route(read_state(escrow));
    if      (retire_route::is_immediate(&route))      { do_retire_immediately(escrow, now_ms, ctx) }
    else if (retire_route::is_deferred(&route))       { do_set_retiring_flag(escrow, now_ms, ctx)  }
    else                                              { abort EAlreadyRetired                      }
}

/// Single entry point to become tenant or place a bid. Calls
/// `apply_pending_transitions` first, then dispatches by state:
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
    let floor = floor_price_at(escrow, now);
    assert!(coin::value(&payment) >= floor, EInsufficientPayment);

    let action = lifecycle_state::rent_action(read_state(escrow));
    if      (rent_action::is_install(&action))      { do_install_new_tenant(escrow, payment, floor, now, ctx) }
    else if (rent_action::is_place_bid(&action))    { do_place_bid(escrow, payment, floor, now, ctx)         }
    else if (rent_action::is_supersede_bid(&action)){ do_supersede_bid(escrow, payment, floor, ctx)          }
    else {
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
        let auth = lifecycle_state::cap_authorization(read_state(escrow), cap_id);
        if (cap_authorization::is_stale(&auth))   { abort EStaleTenantCap };
        if (cap_authorization::is_pending(&auth)) { abort EPendingTenantCap };
    };

    let tenant_addr = lifecycle_state::current_addr(read_state(escrow));
    let (state_inner, sr) = take_state(escrow);
    let (new_state, asset, asset_receipt) = lifecycle_state::give(state_inner);
    put_state(escrow, new_state, sr);
    event::emit(AssetBorrowed { escrow_id, tenant_cap_id: cap_id, tenant: tenant_addr });
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

    let (tenant_cap_id, tenant_addr) = {
        let s = read_state(escrow);
        assert!(lifecycle_state::is_rented(s), EInvariantViolation);
        (lifecycle_state::current_cap_id(s), lifecycle_state::current_addr(s))
    };
    let (state_inner, sr) = take_state(escrow);
    let new_state = lifecycle_state::give_back(state_inner, asset, receipt_in);
    put_state(escrow, new_state, sr);
    event::emit(AssetReturned { escrow_id, tenant_cap_id, tenant: tenant_addr });
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
        let auth = lifecycle_state::cap_authorization(read_state(escrow), cap_id);
        if (!cap_authorization::is_stale(&auth)) { abort ETenantCapNotStale };
    };
    tenant_cap::burn(cap, ctx);
}

/// Permissionless settler. Drives every elapsed lazy transition
/// before any other operation observes the state.
///
/// The protocol's cascade is structurally bounded at three transitions:
///   Handover (HC → HO) → Tenure (HO → AtDutch) → Auction (AtDutch → Idle).
/// After Idle (or Retired) no further transitions are pending. The loop
/// exits early when nothing is due; `EInvariantViolation` fires if the
/// state machine somehow requires a fourth step — that would indicate
/// an impossible cycle in the transition graph.
public fun apply_pending_transitions<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
    ctx:    &mut TxContext,
) {
    let mut i = 0u8;
    loop {
        let pending = next_pending(escrow, clock);
        if (option::is_some(&pending)) {
            assert!(i < 3, EInvariantViolation);
            fire(escrow, option::destroy_some(pending), ctx);
            i = i + 1;
        } else {
            break
        }
    }
}

/// Detect the single transition that is due at `now`, if any.
/// Priority order: Handover → Tenure → Auction. The first match wins;
/// later checks short-circuit. Pure read — no mutation, no events.
///
/// Useful as a standalone query for keepers / `devInspectTransactionBlock`:
/// callers can probe what would fire without committing the tx.
public fun next_pending<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
): Option<PendingTransition> {
    let now = clock::timestamp_ms(clock);
    let s = read_state(escrow);

    // Check 1 — Handover countdown (Rented + Demand).
    if (lifecycle_state::is_rented(s) && lifecycle_state::is_t_state_demand(s)) {
        let expiry = lifecycle_state::handover_countdown_expiry_ms(s);
        if (phases::has_passed(expiry, 0, now)) {
            return option::some(pending_transition::handover(expiry))
        };
    };

    // Check 2 — Tenure expiry (Rented + HandoverOpen).
    if (lifecycle_state::is_rented(s) && lifecycle_state::is_a_state_handover_open(s)) {
        let phase_start = lifecycle_state::phase_start_ms(s);
        let tenure      = config::tenure_ceiling(&escrow.config);
        if (phases::has_passed(phase_start, tenure, now)) {
            return option::some(pending_transition::tenure(phases::boundary_at(phase_start, tenure)))
        };
    };

    // Check 3 — Auction expiry (NotRented + AtDutch).
    if (lifecycle_state::is_not_rented(s) && lifecycle_state::is_a_state_at_dutch(s)) {
        let phase_start = lifecycle_state::phase_start_ms(s);
        let policy      = config::descent(&escrow.config);
        if (descent_policy::has_expired(policy, phase_start, now)) {
            return option::some(pending_transition::auction(descent_policy::expiry_at(policy, phase_start)))
        };
    };

    option::none()
}

/// Apply a `PendingTransition` by dispatching to the matching boundary
/// handler. The dispatch uses the public predicates from
/// `pending_transition` rather than variant pattern matching, since
/// the enum lives in another module (Move 2024 restricts external
/// matching). With three variants and copy ability, the if/else chain
/// is honest dispatch — not the if/else-hides-state smell.
fun fire<Asset: key + store, CoinType>(
    escrow: &mut EscrowCoordinator<Asset, CoinType>,
    t:      PendingTransition,
    ctx:    &mut TxContext,
) {
    let boundary_ms = pending_transition::boundary_ms(&t);
    if (pending_transition::is_handover(&t)) {
        do_handover(escrow, boundary_ms, ctx)
    } else if (pending_transition::is_tenure(&t)) {
        do_tenure_expiry(escrow, boundary_ms, ctx)
    } else {
        // is_auction (only remaining variant — three are exhaustive
        // and stable; new variants would need new lifecycle boundaries).
        do_auction_expiry(escrow, boundary_ms)
    }
}

// === View Functions ===

// ─── State predicates ────────────────────────────────────────────────────────

public fun is_idle<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): bool { lifecycle_state::is_a_state_idle(read_state(escrow)) }

public fun is_at_dutch_auction<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): bool { lifecycle_state::is_a_state_at_dutch(read_state(escrow)) }

public fun is_handover_open<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): bool { lifecycle_state::is_a_state_handover_open(read_state(escrow)) }

public fun is_handover_confirmed<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): bool { lifecycle_state::is_a_state_handover_confirmed(read_state(escrow)) }

public fun is_retired<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): bool { lifecycle_state::is_a_state_retired(read_state(escrow)) }

/// True iff the retire flag is set on the current rental. The asset will
/// transition to Retired when the active tenure expires.
/// Valid in any state; false when NotRented.
public fun is_retiring<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): bool { lifecycle_state::is_retiring(read_state(escrow)) }

// ─── Action classification ───────────────────────────────────────────────────

/// How a `retire()` call will be routed given the current state.
///   Immediate      — no active tenant; asset retires immediately.
///   Deferred       — active tenant; sets the retiring flag for tenure-expiry.
///   AlreadyRetired — call will abort; surface the error before signing.
/// SDK use: explain to the owner what retire() will do before they sign.
public fun retire_route<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): RetireRoute {
    lifecycle_state::retire_route(read_state(escrow))
}

/// Which entry operation a `rent()` call will execute given the current state.
///   Install      — no active tenant; starts a fresh rental.
///   PlaceBid     — HandoverOpen; places a competing bid.
///   SupersedeBid — HandoverConfirmed; replaces the existing pending bid.
///   Retired      — call will abort; the rent action is unavailable.
/// SDK use: label the rent button correctly and build the right UI flow.
public fun rent_action<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): RentAction {
    lifecycle_state::rent_action(read_state(escrow))
}

// ─── Identity views ──────────────────────────────────────────────────────────

/// Address of the active tenant. `Some` while the lifecycle is Rented
/// (HandoverOpen or HandoverConfirmed); `None` otherwise.
public fun current_tenant_addr<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): Option<address> {
    let s = read_state(escrow);
    if (lifecycle_state::is_rented(s)) option::some(lifecycle_state::current_addr(s))
    else option::none()
}

/// Address of the pending bidder. `Some` only in HandoverConfirmed
/// (a bid has been placed and is awaiting the countdown expiry);
/// `None` in every other state.
public fun pending_tenant_addr<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): Option<address> {
    let s = read_state(escrow);
    if (lifecycle_state::is_a_state_handover_confirmed(s)) option::some(lifecycle_state::pending_addr(s))
    else option::none()
}

// ─── Stake views ─────────────────────────────────────────────────────────────

/// Stake value held by the active tenant, in coin base units.
/// `Some` while the lifecycle is Rented (HandoverOpen or HandoverConfirmed);
/// `None` otherwise.
/// SDK use: show "current bid: X SUI" on the marketplace card.
public fun current_stake<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): Option<u64> {
    let s = read_state(escrow);
    if (lifecycle_state::is_rented(s)) option::some(lifecycle_state::current_stake_value(s))
    else option::none()
}

/// Stake value held by the pending bidder, in coin base units.
/// `Some` only in HandoverConfirmed (a bid is awaiting countdown expiry);
/// `None` in every other state.
/// SDK use: show "pending bid: X SUI" on the marketplace card.
public fun pending_stake<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): Option<u64> {
    let s = read_state(escrow);
    if (lifecycle_state::is_a_state_handover_confirmed(s)) option::some(lifecycle_state::pending_stake_value(s))
    else option::none()
}

// ─── Temporal views ───────────────────────────────────────────────────────────

/// Absolute timestamp at which the active tenant's tenure expires.
/// `Some` while the lifecycle is Rented; `None` otherwise.
/// Computed as phase_start_ms + config::tenure_ceiling.
/// SDK use: show "rental expires at X" and drive expiry countdown timers.
public fun tenure_expiry_ms<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): Option<u64> {
    let s = read_state(escrow);
    if (lifecycle_state::is_rented(s)) {
        option::some(phases::boundary_at(
            lifecycle_state::phase_start_ms(s),
            config::tenure_ceiling(&escrow.config),
        ))
    } else {
        option::none()
    }
}

/// Absolute timestamp at which the pending bid auto-wins the handover.
/// `Some` only in HandoverConfirmed; `None` in every other state.
/// SDK use: show "bid wins at X" countdown; inform keepers when to
/// call `apply_pending_transitions`.
public fun handover_countdown_expiry_ms<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): Option<u64> {
    let s = read_state(escrow);
    if (lifecycle_state::is_a_state_handover_confirmed(s)) {
        option::some(lifecycle_state::handover_countdown_expiry_ms(s))
    } else {
        option::none()
    }
}

/// Maximum duration a single rental can last, in milliseconds.
/// Defined by the escrow's IntegrationConfig and constant for the
/// escrow's lifetime.
/// SDK use: risk protocols evaluating an idle escrow need the ceiling
/// to estimate maximum exposure duration before `tenure_expiry_ms`
/// becomes available (i.e. before a tenant installs).
public fun tenure_ceiling_ms<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): u64 {
    config::tenure_ceiling(&escrow.config)
}

/// Timestamp at which this escrow was created, in milliseconds.
/// SDK use: display "created on X"; combine with `retire_unlocks_at_ms`
/// to show time elapsed since integration.
public fun integrated_at_ms<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): u64 {
    escrow.integrated_at_ms
}

/// Absolute timestamp at which `retire()` becomes available.
/// For Immediate policies this equals `integrated_at_ms`.
/// For Deferred policies it is `integrated_at_ms + floor_ms`.
/// SDK use: show "you can retire in X days" on the owner dashboard.
public fun retire_unlocks_at_ms<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): u64 {
    retire_policy::unlock_at_ms(
        config::retire(&escrow.config),
        escrow.integrated_at_ms,
    )
}

// ─── Cap views ───────────────────────────────────────────────────────────────

/// Authorization status of `cap_id` relative to the current lifecycle state.
///   Current — belongs to the active tenant; may borrow.
///   Pending — belongs to the pending bidder in HandoverConfirmed.
///   Stale   — superseded, former tenant, or no active rental.
/// SDK use: check before `borrow_asset` or `burn_tenant_cap` to surface a
/// meaningful error instead of letting the transaction abort.
public fun tenant_cap_status<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
    cap_id: ID,
): CapAuthorization {
    lifecycle_state::cap_authorization(read_state(escrow), cap_id)
}

// ─── Timing views ────────────────────────────────────────────────────────────

/// True iff at least one time-based transition is due at the current
/// clock time. Callers can probe this before committing to
/// `apply_pending_transitions` to avoid paying gas for a no-op.
public fun has_pending_transitions<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
): bool {
    option::is_some(&next_pending(escrow, clock))
}

/// Timestamp at which the next pending transition fires, if any.
/// `Some(ms)` when a transition is due; `None` when the escrow is quiescent.
/// SDK use: schedule keeper calls and drive countdown timers without
/// committing a transaction.
public fun next_transition_ms<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
): Option<u64> {
    let pending = next_pending(escrow, clock);
    if (option::is_some(&pending)) {
        option::some(pending_transition::boundary_ms(option::borrow(&pending)))
    } else {
        option::none()
    }
}

// ─── Pricing views ───────────────────────────────────────────────────────────

/// Used credit accrued by the current tenant at the current clock time.
/// Defined only while the lifecycle is `Rented` — aborts otherwise (`ENotRented`).
///
/// Derives the credit regime from the lifecycle's tenant slot:
/// HandoverConfirmed → `Capped` (effective time saturates at the
/// pre-stamped countdown expiry); HandoverOpen → `Accruing` (no cap).
/// All curve-and-arithmetic logic lives inside `credit_state::used_credit`.
public fun compute_used_credit<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    used_credit_at(escrow, clock::timestamp_ms(clock))
}

/// Minimum acceptable payment to win the rent for the next bidder,
/// evaluated at the current clock time. Derives the pricing regime from
/// the lifecycle's asset slot:
///   - `Idle`              → `Rest`       (min_rent_price)
///   - `HandoverOpen`      → `Ascending`  over current's stake
///   - `HandoverConfirmed` → `Ascending`  over pending's stake
///   - `AtDutchAuction`    → `Descending` from last_acq_price
///   - `Retired`           → aborts `ERetiredNoBid` (no pricing regime)
///
/// All pricing arithmetic lives inside `price_state::floor_price`.
public fun compute_floor_price<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
    clock:  &Clock,
): u64 {
    floor_price_at(escrow, clock::timestamp_ms(clock))
}

// ─── Earnings views ──────────────────────────────────────────────────────────

/// Accumulated owner earnings inside this escrow, in coin base units.
/// Includes all owner shares from completed boundary transitions not yet
/// drained by `withdraw_earnings`.
/// SDK use: owner dashboard — show pending balance before prompting a
/// `withdraw_earnings` transaction.
public fun owner_balance<Asset: key + store, CoinType>(
    escrow: &EscrowCoordinator<Asset, CoinType>,
): u64 {
    owner::value(&escrow.owner)
}

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

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

fun used_credit_at<Asset: key + store, CoinType>(
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

fun floor_price_at<Asset: key + store, CoinType>(
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
        abort ERetiredNoBid
    };
    price_state::floor_price(&ps, &escrow.config, timestamp_ms)
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

/// Idle | AtDutchAuction → Rented{HandoverOpen}.
fun do_install_new_tenant<Asset: key + store, CoinType>(
    escrow:  &mut EscrowCoordinator<Asset, CoinType>,
    payment: Coin<CoinType>,
    floor:   u64,
    now:     u64,
    ctx:     &mut TxContext,
): TenantCap {
    let escrow_id   = object::id(escrow);
    let price_paid  = coin::value(&payment);
    let tenant_addr = ctx.sender();

    let (cap, cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let t = tenant::new<CoinType>(cap_id, tenant_addr, coin::into_balance(payment));

    let (s, receipt) = take_state(escrow);
    let new_s = lifecycle_state::start_rent<Asset, CoinType>(s, t, now, escrow_id);
    put_state(escrow, new_s, receipt);

    event::emit(RentStarted {
        escrow_id,
        tenant_cap_id:  cap_id,
        tenant:         tenant_addr,
        phase_start_ms: now,
        price_paid,
        floor_price:    floor,
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
    let current_cap_id   = lifecycle_state::current_cap_id(s);
    let current_addr_val = lifecycle_state::current_addr(s);
    let phase_start      = lifecycle_state::phase_start_ms(s);
    let tenure           = config::tenure_ceiling(&escrow.config);
    let expiry           = handover_policy::expiry_at(
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
        current_tenant_cap_id:     current_cap_id,
        current_tenant_addr:       current_addr_val,
        current_phase_start_ms:    phase_start,
        tenant_cap_id:             cap_id,
        pending_tenant:            pending_addr,
        bid_amount,
        floor_price:               floor,
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
    let refunded_amount  = lifecycle_state::pending_stake_value(s);
    let existing_expiry  = lifecycle_state::handover_countdown_expiry_ms(s);

    let escrow_id      = object::id(escrow);
    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);

    let (cap, cap_id) = tenant_cap::new(escrow_id, new_bidder, ctx);
    let t = tenant::new<CoinType>(cap_id, new_bidder, coin::into_balance(payment));

    let (st, receipt) = take_state(escrow);
    let (new_st, refund) = lifecycle_state::supersede_bid<Asset, CoinType>(st, t, existing_expiry);
    put_state(escrow, new_st, receipt);

    refund_state::distribute(refund, &mut escrow.owner, escrow.fee_inbox_id, ctx);
    event::emit(BidSuperseded {
        escrow_id,
        displaced_tenant_cap_id:   displaced_cap_id,
        new_tenant_cap_id:         cap_id,
        displaced_bidder:          displaced_addr,
        refunded_amount,
        new_bidder,
        new_bid_amount,
        floor_price:               floor,
        handover_countdown_expiry: existing_expiry,
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
/// via `refund_state::distribute`. The promoted tenant's cap was
/// minted at place_bid/supersede_bid time — handover does not mint
/// a fresh cap.
fun do_handover<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
    ctx:         &mut TxContext,
) {
    let escrow_id    = object::id(escrow);
    let used_credit  = used_credit_at(escrow, boundary_ms);
    let (owner_amount, fee_amount) = split_fee(used_credit);
    let s_pre            = read_state(escrow);
    let displaced_cap_id = lifecycle_state::current_cap_id(s_pre);
    let displaced_addr   = lifecycle_state::current_addr(s_pre);
    let principal        = lifecycle_state::current_stake_value(s_pre);
    let remain_credit  = principal - used_credit;

    let (st, receipt) = take_state(escrow);
    let (new_st, refund) = lifecycle_state::accept_bid<Asset, CoinType>(
        st, owner_amount, fee_amount, boundary_ms, escrow_id,
    );
    put_state(escrow, new_st, receipt);

    refund_state::distribute(refund, &mut escrow.owner, escrow.fee_inbox_id, ctx);

    let s_post            = read_state(escrow);
    let new_tenant_cap_id = lifecycle_state::current_cap_id(s_post);
    let new_tenant_addr   = lifecycle_state::current_addr(s_post);
    let new_tenant_stake  = lifecycle_state::current_stake_value(s_post);
    // Post-handover state is HandoverOpen → compute_floor_price
    // returns Ascending(current_stake_value); timestamp irrelevant
    // for that regime.
    let new_rent_price = floor_price_at(escrow, boundary_ms);

    event::emit(HandoverCompleted {
        escrow_id,
        displaced_tenant_cap_id: displaced_cap_id,
        displaced_tenant:        displaced_addr,
        new_tenant_cap_id,
        new_tenant_addr,
        new_tenant_stake,
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
    let tenant_cap_id          = lifecycle_state::current_cap_id(s);
    let phase_start_ms         = lifecycle_state::phase_start_ms(s);
    let (owner_amount, fee_amount) = split_fee(principal);
    let last_acquisition_price = principal;

    let (st, receipt) = take_state(escrow);
    let (new_st, refund) = lifecycle_state::expire_tenure<Asset, CoinType>(
        st, owner_amount, fee_amount, last_acquisition_price, boundary_ms, escrow_id,
    );
    put_state(escrow, new_st, receipt);

    refund_state::distribute(refund, &mut escrow.owner, escrow.fee_inbox_id, ctx);

    event::emit(TenureExpired {
        escrow_id,
        tenant_cap_id,
        tenant:                 tenant_addr,
        phase_start_ms,
        owner_share:            owner_amount,
        protocol_fee:           fee_amount,
        last_acquisition_price,
        timestamp_ms:           boundary_ms,
    });
    if (is_retired(escrow)) {
        event::emit(AssetRetired { escrow_id, timestamp_ms: boundary_ms });
    };
}

/// Auction boundary (AtDutch → Idle). No tenant funds involved; only
/// emits `AuctionExpired` for off-chain observers.
fun do_auction_expiry<Asset: key + store, CoinType>(
    escrow:      &mut EscrowCoordinator<Asset, CoinType>,
    boundary_ms: u64,
) {
    let escrow_id      = object::id(escrow);
    let last_acq_price = lifecycle_state::last_acq_price_of_at_dutch(read_state(escrow));
    let (st, receipt)  = take_state(escrow);
    let new_st         = lifecycle_state::expire_auction(st);
    put_state(escrow, new_st, receipt);
    event::emit(AuctionExpired { escrow_id, last_acq_price, timestamp_ms: boundary_ms });
}

/// Retire from Idle | AtDutchAuction → Retired. The state transitions
/// in the same call (no flag-then-wait dance because no tenant is
/// active). Co-emits `RetireFlagSet` (for off-chain observers tracking
/// the owner's intent) and `AssetRetired` (for terminal-state markers).
fun do_retire_immediately<Asset: key + store, CoinType>(
    escrow:       &mut EscrowCoordinator<Asset, CoinType>,
    timestamp_ms: u64,
    ctx:          &TxContext,
) {
    let escrow_id    = object::id(escrow);
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::retire_now(s);
    put_state(escrow, new_s, receipt);
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
    event::emit(AssetRetired  { escrow_id, timestamp_ms });
}

/// Retire from HandoverOpen | HandoverConfirmed → flag lifted, state
/// stays Rented. The current tenant runs out their tenure; tenure
/// expiry detects the flag and collapses straight to Retired (see
/// `do_tenure_expiry` retiring branch). New bids are blocked while
/// the flag is set (`ERetireFlagBlocksBid` in `do_place_bid`).
fun do_set_retiring_flag<Asset: key + store, CoinType>(
    escrow:       &mut EscrowCoordinator<Asset, CoinType>,
    timestamp_ms: u64,
    ctx:          &TxContext,
) {
    let escrow_id    = object::id(escrow);
    assert!(!lifecycle_state::is_retiring(read_state(escrow)), EAlreadyRetired);
    let (s, receipt) = take_state(escrow);
    let new_s        = lifecycle_state::set_retiring(s);
    put_state(escrow, new_s, receipt);
    event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), timestamp_ms });
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
public(package) fun asset_integrated_escrow_id<A, C>(e: &AssetIntegrated<A, C>): ID      { e.escrow_id }
#[test_only]
public(package) fun asset_integrated_owner_cap_id<A, C>(e: &AssetIntegrated<A, C>): ID   { e.owner_cap_id }
#[test_only]
public(package) fun asset_integrated_asset_id<A, C>(e: &AssetIntegrated<A, C>): ID       { e.asset_id }
#[test_only]
public(package) fun asset_integrated_fee_inbox_id<A, C>(e: &AssetIntegrated<A, C>): ID   { e.fee_inbox_id }
#[test_only]
public(package) fun asset_integrated_at_ms<A, C>(e: &AssetIntegrated<A, C>): u64         { e.integrated_at_ms }

#[test_only]
public(package) fun rent_started_escrow_id(e: &RentStarted): ID                  { e.escrow_id }
#[test_only]
public(package) fun rent_started_tenant_cap_id(e: &RentStarted): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun rent_started_tenant(e: &RentStarted): address                { e.tenant }
#[test_only]
public(package) fun rent_started_phase_start_ms(e: &RentStarted): u64            { e.phase_start_ms }
#[test_only]
public(package) fun rent_started_price_paid(e: &RentStarted): u64                { e.price_paid }
#[test_only]
public(package) fun rent_started_floor_price(e: &RentStarted): u64               { e.floor_price }

#[test_only]
public(package) fun bid_placed_escrow_id(e: &BidPlaced): ID                      { e.escrow_id }
#[test_only]
public(package) fun bid_placed_current_tenant_cap_id(e: &BidPlaced): ID          { e.current_tenant_cap_id }
#[test_only]
public(package) fun bid_placed_current_tenant_addr(e: &BidPlaced): address       { e.current_tenant_addr }
#[test_only]
public(package) fun bid_placed_current_phase_start_ms(e: &BidPlaced): u64        { e.current_phase_start_ms }
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
public(package) fun bid_superseded_floor_price(e: &BidSuperseded): u64           { e.floor_price }
#[test_only]
public(package) fun bid_superseded_handover_countdown_expiry(e: &BidSuperseded): u64 { e.handover_countdown_expiry }

#[test_only]
public(package) fun handover_completed_escrow_id(e: &HandoverCompleted): ID                  { e.escrow_id }
#[test_only]
public(package) fun handover_completed_displaced_tenant_cap_id(e: &HandoverCompleted): ID     { e.displaced_tenant_cap_id }
#[test_only]
public(package) fun handover_completed_displaced_tenant(e: &HandoverCompleted): address       { e.displaced_tenant }
#[test_only]
public(package) fun handover_completed_new_cap_id(e: &HandoverCompleted): ID                  { e.new_tenant_cap_id }
#[test_only]
public(package) fun handover_completed_new_tenant_addr(e: &HandoverCompleted): address        { e.new_tenant_addr }
#[test_only]
public(package) fun handover_completed_new_tenant_stake(e: &HandoverCompleted): u64           { e.new_tenant_stake }
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
public(package) fun tenure_expired_tenant_cap_id(e: &TenureExpired): ID                       { e.tenant_cap_id }
#[test_only]
public(package) fun tenure_expired_tenant(e: &TenureExpired): address                         { e.tenant }
#[test_only]
public(package) fun tenure_expired_phase_start_ms(e: &TenureExpired): u64                    { e.phase_start_ms }
#[test_only]
public(package) fun tenure_expired_owner_share(e: &TenureExpired): u64                        { e.owner_share }
#[test_only]
public(package) fun tenure_expired_protocol_fee(e: &TenureExpired): u64                       { e.protocol_fee }
#[test_only]
public(package) fun tenure_expired_last_acq_price(e: &TenureExpired): u64                     { e.last_acquisition_price }
#[test_only]
public(package) fun tenure_expired_timestamp_ms(e: &TenureExpired): u64                       { e.timestamp_ms }

#[test_only]
public(package) fun auction_expired_escrow_id(e: &AuctionExpired): ID                        { e.escrow_id }
#[test_only]
public(package) fun auction_expired_last_acq_price(e: &AuctionExpired): u64                   { e.last_acq_price }
#[test_only]
public(package) fun auction_expired_timestamp_ms(e: &AuctionExpired): u64                     { e.timestamp_ms }

#[test_only]
public(package) fun asset_borrowed_escrow_id(e: &AssetBorrowed): ID                          { e.escrow_id }
#[test_only]
public(package) fun asset_borrowed_tenant_cap_id(e: &AssetBorrowed): ID                      { e.tenant_cap_id }
#[test_only]
public(package) fun asset_borrowed_tenant(e: &AssetBorrowed): address                        { e.tenant }
#[test_only]
public(package) fun asset_returned_escrow_id(e: &AssetReturned): ID                          { e.escrow_id }
#[test_only]
public(package) fun asset_returned_tenant_cap_id(e: &AssetReturned): ID                      { e.tenant_cap_id }
#[test_only]
public(package) fun asset_returned_tenant(e: &AssetReturned): address                        { e.tenant }

#[test_only]
public(package) fun asset_retired_escrow_id(e: &AssetRetired): ID                            { e.escrow_id }
#[test_only]
public(package) fun asset_retired_timestamp_ms(e: &AssetRetired): u64                        { e.timestamp_ms }

#[test_only]
public(package) fun retire_flag_set_escrow_id(e: &RetireFlagSet): ID                         { e.escrow_id }
#[test_only]
public(package) fun retire_flag_set_owner(e: &RetireFlagSet): address                        { e.owner }
#[test_only]
public(package) fun retire_flag_set_timestamp_ms(e: &RetireFlagSet): u64                     { e.timestamp_ms }

#[test_only]
public(package) fun earnings_withdrawn_escrow_id(e: &EarningsWithdrawn): ID                  { e.escrow_id }
#[test_only]
public(package) fun earnings_withdrawn_owner_cap_id(e: &EarningsWithdrawn): ID                { e.owner_cap_id }
#[test_only]
public(package) fun earnings_withdrawn_owner(e: &EarningsWithdrawn): address                  { e.owner }
#[test_only]
public(package) fun earnings_withdrawn_amount(e: &EarningsWithdrawn): u64                     { e.amount }
#[test_only]
public(package) fun earnings_withdrawn_timestamp_ms(e: &EarningsWithdrawn): u64               { e.timestamp_ms }

#[test_only]
public(package) fun asset_claimed_escrow_id(e: &AssetClaimed): ID                            { e.escrow_id }
#[test_only]
public(package) fun asset_claimed_owner_cap_id(e: &AssetClaimed): ID                          { e.owner_cap_id }
#[test_only]
public(package) fun asset_claimed_owner(e: &AssetClaimed): address                            { e.owner }
#[test_only]
public(package) fun asset_claimed_swept_earnings(e: &AssetClaimed): u64                       { e.swept_earnings }
#[test_only]
public(package) fun asset_claimed_timestamp_ms(e: &AssetClaimed): u64                         { e.timestamp_ms }

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
