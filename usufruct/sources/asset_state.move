// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Lifecycle FSM for an integrated escrow.
///
/// `AssetState` is a 5-variant enum (`Idle` / `AtDutch` / `Retired` /
/// `Occupied` / `Demand`) carrying exactly the fields each state needs —
/// "make illegal states unrepresentable" at the storage layer. `EscrowCore`
/// holds everything orthogonal to the lifecycle: owner ledger, policies,
/// identities, integration metadata. Together they form the on-disk shape
/// of a shared `Escrow`.
///
/// `RentingDispatch` and `FirableState` narrow `AssetState` to the
/// subsets where specific operations are valid (renting → borrow/return;
/// firable → APT transitions). The non-drop fields (`Tenant<C>`,
/// `AssetCustody*`) give hot-potato discipline for free — no separate
/// operation-time enum is needed.
///
/// All nested enum types must co-reside: Move 2024 restricts pattern
/// access to the defining module.
module usufruct::asset_state;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
    random::{Random, RandomGenerator},
};
use usufruct::{
    asset::{Self, AssetReceipt},
    config::{Self, IntegrationConfig},
    cycles::{Self, Cycles},
    descent_policy_state,
    floor_price_policy_state,
    tenure_policy_state,
    tenure_cycles_policy_state,
    monetary::{Self, Price, Stake},
    owner::{Self, Owner},
    owner_cap::{Self, OwnerCap},
    pending_transition_state::{Self, PendingTransitionState},
    price_state,
    commitment_policy_state::{Self, CommitmentPolicyState},
    credit_context_state::{Self as credit_state},
    handover_policy_state,
    math,
    phases::{Self, Timestamp, Duration},
    escrow_identity::{Self, EscrowIdentity},
    protocol_fee_ref::{Self, FeeInboxIdentity},
    tenant_cap::{Self, TenantCap, TenantCapIdentity},
    refund_state,
    retire_condition::{Self, RetireCondition},
    tenant::{Self, Tenant},
};

// === Errors ===

const ENotRented:             u64 = 0;
const EInsufficientPayment:   u64 = 1;
const ERetiredNoBid:          u64 = 3;
const ECommitmentFloorNotElapsed: u64 = 4;
const ECommitmentNotExtended:     u64 = 17;
const EAlreadyRetired:        u64 = 5;
const EWrongEscrowTenantCap:  u64 = 6;
const EWrongEscrowOwnerCap:   u64 = 11;
const EStaleTenantCap:        u64 = 8;
const EReceiptEscrowMismatch: u64 = 10;
const ENotRetired:              u64 = 12;
const ENoEarnings:              u64 = 13;
const ERetireAlreadyScheduled:  u64 = 16;

// === Structs ===

/// Result of splitting a credit amount into owner earnings and protocol fee.
/// Named fields prevent positional swap between the two semantically distinct
/// monetary roles.
public struct FeeAllocation has drop {
    owner_share:  Stake,
    protocol_fee: Stake,
}

/// The 4 resolved parameters drawn at Idle entry. Travel as an immutable
/// unit through the cycle until the next Idle entry re-draws them.
public struct CycleParams has copy, drop, store {
    floor:    Price,
    ceiling:  Duration,
    handover: Duration,
    descent:  Duration,
}

/// Scheduled time allocation for the active tenancy.
/// ceiling_total and handover_total are cycle.ceiling/handover × committed_cycles.
public struct TenancySchedule has copy, drop, store {
    phase_start:      Timestamp,
    ceiling_total:    Duration,
    handover_total:   Duration,
    committed_cycles: Cycles,
}

/// Handover window terms for a pending bid.
public struct HandoverTerms has copy, drop, store {
    expiry: Timestamp,
    cycles: Cycles,
}

/// Dutch-auction context: the price the last tenant paid and when the
/// auction started. Together they drive the descending price curve and
/// the expiry boundary.
public struct AuctionTerms has copy, drop, store {
    last_acq_price: Price,
    phase_start:    Timestamp,
}

/// Active integration config plus any pending replacement scheduled for
/// the next Idle entry. Pending is applied and cleared in do_auction_expiry.
public struct ConfigSlot has drop, store {
    active:  IntegrationConfig,
    pending: Option<IntegrationConfig>,
}

/// Commitment policy bound to its anchor timestamp. Both fields are
/// required to evaluate whether the commitment floor has elapsed.
public struct CommitmentSlot has copy, drop, store {
    policy: CommitmentPolicyState,
    anchor: Timestamp,
}

/// Active tenancy data: who is renting, on what schedule, and whether retire is pending.
/// Exists only when there is an active tenant (Occupied / Demand states).
public struct OccupiedTerms<phantom CoinType> has store {
    schedule: TenancySchedule,
    current:  Tenant<CoinType>,
    retire:   RetireCondition,
}

/// Pending bid data: who is bidding and when they take over.
public struct DemandTerms<phantom CoinType> has store {
    pending:  Tenant<CoinType>,
    handover: HandoverTerms,
}

// ─── Storage types ────────────────────────────────────────────────────────────
//
// The on-disk shape of an integrated escrow. `EscrowCore` holds the fields
// orthogonal to the lifecycle state (owner ledger + policies + identities);
// `AssetState` holds the lifecycle state as one of five variants. The two
// slots are independent: ortho actions read/mutate `core` without touching
// `state`, and APT/state transitions consume `state` without destructuring
// `core`.
//
// `AssetState` is the single source of truth for the lifecycle state —
// every `execute_*` consumes it by value and returns a fresh instance.
// The non-drop fields (`Tenant`, `AssetCustody*`) give hot-potato
// discipline without a separate operation-time enum.

public struct EscrowCore<phantom CoinType> has store {
    owner:              Owner<CoinType>,
    config:             ConfigSlot,
    fee_inbox_identity: FeeInboxIdentity,
    integrated_at:      Timestamp,
    commitment:         CommitmentSlot,
    escrow_identity:    EscrowIdentity,
}

public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Idle    { asset: asset::AssetCustodyLocked<Asset>, cycle: CycleParams },
    AtDutch { asset: asset::AssetCustodyLocked<Asset>, auction: AuctionTerms, cycle: CycleParams },
    Retired { asset: asset::AssetCustodyLocked<Asset> },
    Occupied { asset: asset::AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, cycle: CycleParams },
    Demand   { asset: asset::AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, bid: DemandTerms<CoinType>, cycle: CycleParams },
}


// === Events ===

public struct RentStarted has copy, drop {
    escrow_id:      ID,
    tenant_cap_id:  ID,
    tenant:         address,
    phase_start_ms: u64,
    price_paid:     u64,
    floor_price:    u64,
}

public struct AuctionExpired has copy, drop {
    escrow_id:      ID,
    phase_start_ms: u64,
    last_acq_price: u64,
    timestamp_ms:   u64,
}

public struct AssetRetired has copy, drop {
    escrow_id:    ID,
    timestamp_ms: u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:    ID,
    owner_cap_id: ID,
    owner:        address,
    amount:       u64,
    timestamp_ms: u64,
}

public struct ConfigUpdateScheduled has copy, drop {
    escrow_id:  ID,
    new_config: IntegrationConfig,
}

public struct ConfigUpdated has copy, drop {
    escrow_id:  ID,
    new_config: IntegrationConfig,
}

public struct CommitmentExtended has copy, drop {
    escrow_id:     ID,
    new_policy:    CommitmentPolicyState,
    new_expiry_ms: u64,
    timestamp_ms:  u64,
}

/// Boundary lifecycle events: `AssetIntegrated` marks Bootstrap → Idle
/// (one-shot, fired by `execute_integrate`); `AssetClaimed` marks
/// Retired → Destroyed (terminal, fired by `execute_claim`'s Retired
/// arm). They bracket the on-chain lifetime of the shared `Escrow`
/// object.
public struct AssetIntegrated<phantom Asset, phantom CoinType> has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    owner:            address,
    asset_id:         ID,
    fee_inbox_id:     ID,
    integrated_at_ms: u64,
}

public struct AssetClaimed has copy, drop {
    escrow_id:      ID,
    owner_cap_id:   ID,
    owner:          address,
    swept_earnings: u64,
    timestamp_ms:   u64,
}

// === Public Functions ===

// ─── Bootstrap → Idle ─────────────────────────────────────────────────────────

/// Bootstrap → Idle: the integration action. Mints the `OwnerCap`,
/// builds the two on-disk slots (`EscrowCore` + `AssetState::Idle`),
/// resolves the initial policy values, and emits both
/// `IntegrationConfigRegistered` and `AssetIntegrated`. The caller
/// (`escrow::integrate`) is left with the Sui-imposed boundary: create
/// the `UID`, wrap the slots in the `Escrow` struct, and share it.
public(package) fun execute_integrate<Asset: key + store, CoinType>(
    asset:              Asset,
    config:             IntegrationConfig,
    commitment_policy:  CommitmentPolicyState,
    fee_inbox_identity: FeeInboxIdentity,
    escrow_identity:    EscrowIdentity,
    integrated_at:      Timestamp,
    generator:          &mut RandomGenerator,
    ctx:                &mut TxContext,
): (EscrowCore<CoinType>, AssetState<Asset, CoinType>, OwnerCap) {
    let owner_addr         = ctx.sender();
    let owner_cap          = owner_cap::new(escrow_identity, owner_addr, ctx);
    let owner_cap_identity = owner_cap::identity(&owner_cap);
    let asset_id           = object::id(&asset);
    let raw_escrow_id      = escrow_identity::escrow_id(escrow_identity);
    config::emit_registration(&config, raw_escrow_id);
    let floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(&config), generator);
    let ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(&config), generator);
    let handover = handover_policy_state::resolve(config::proj_handover(&config), ceiling, generator);
    let descent  = descent_policy_state::resolve(config::proj_descent(&config), generator);
    let core = EscrowCore {
        owner:              owner::new<CoinType>(owner_cap_identity),
        config:             ConfigSlot { active: config, pending: option::none() },
        fee_inbox_identity,
        integrated_at,
        commitment:         CommitmentSlot { policy: commitment_policy, anchor: integrated_at },
        escrow_identity,
    };
    let state = AssetState::Idle {
        asset: asset::lock(asset),
        cycle: CycleParams { floor, ceiling, handover, descent },
    };
    event::emit(AssetIntegrated<Asset, CoinType> {
        escrow_id:        raw_escrow_id,
        owner_cap_id:     owner_cap::cap_id(owner_cap_identity),
        owner:            owner_addr,
        asset_id,
        fee_inbox_id:     protocol_fee_ref::inbox_id(fee_inbox_identity),
        integrated_at_ms: phases::timestamp_ms(integrated_at),
    });
    (core, state, owner_cap)
}

// ─── Core (owner + policy + identity) views ──────────────────────────────────

public(package) fun proj_config<CoinType>(
    core: &EscrowCore<CoinType>,
): &IntegrationConfig { &core.config.active }


public(package) fun proj_fee_inbox_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID { protocol_fee_ref::inbox_id(core.fee_inbox_identity) }

public(package) fun proj_integrated_at<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.integrated_at }

public(package) fun proj_pending_config<CoinType>(
    core: &EscrowCore<CoinType>,
): Option<IntegrationConfig> { core.config.pending }

public(package) fun proj_commitment_policy<CoinType>(
    core: &EscrowCore<CoinType>,
): CommitmentPolicyState { core.commitment.policy }

public(package) fun proj_commitment_anchor<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.commitment.anchor }

public(package) fun proj_owner_balance<CoinType>(
    core: &EscrowCore<CoinType>,
): Stake {
    owner::proj_value(&core.owner)
}

public(package) fun proj_owner_cap_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID {
    owner_cap::cap_id(owner::proj_cap_identity(owner::proj_identity(&core.owner)))
}

// ─── State variant predicates ─────────────────────────────────────────────────

public(package) fun proj_is_active<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) {
        AssetState::Retired { .. } => false,
        _ => true,
    }
}


public(package) fun proj_is_idle<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Idle { .. } => true, _ => false }
}

public(package) fun proj_is_at_dutch<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::AtDutch { .. } => true, _ => false }
}

public(package) fun proj_is_retired<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Retired { .. } => true, _ => false }
}

public(package) fun proj_is_rented<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) {
        AssetState::Occupied { .. } | AssetState::Demand { .. } => true,
        _ => false,
    }
}

public(package) fun proj_is_occupied<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Occupied { .. } => true, _ => false }
}

public(package) fun proj_is_demand<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Demand { .. } => true, _ => false }
}

public(package) fun proj_is_retiring<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            retire_condition::proj_is_retiring(&terms.retire),
        _ => false,
    }
}

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun proj_asset_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): ID {
    match (s) {
        AssetState::Idle    { asset, .. } => asset::proj_locked_id(asset),
        AssetState::AtDutch { asset, .. } => asset::proj_locked_id(asset),
        AssetState::Retired { asset }     => asset::proj_locked_id(asset),
        AssetState::Occupied { asset, .. } => asset::proj_asset_id(asset),
        AssetState::Demand   { asset, .. } => asset::proj_asset_id(asset),
    }
}

// ─── Tenant data views (Option variants — only present in Renting) ────────────

public(package) fun proj_current_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(tenant::proj_address(tenant::proj_identity(&terms.current))),
        _ => option::none(),
    }
}

public(package) fun proj_current_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(tenant_cap::cap_id(tenant::proj_cap_identity(tenant::proj_identity(&terms.current)))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Demand { bid, .. } =>
            option::some(tenant::proj_address(tenant::proj_identity(&bid.pending))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Demand { bid, .. } =>
            option::some(tenant_cap::cap_id(tenant::proj_cap_identity(tenant::proj_identity(&bid.pending)))),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(tenant::proj_stake_value(&terms.current)),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake_value<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Stake {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            tenant::proj_stake_value(&terms.current),
        _ => abort ENotRented,
    }
}

public(package) fun proj_pending_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Demand { bid, .. } =>
            option::some(tenant::proj_stake_value(&bid.pending)),
        _ => option::none(),
    }
}

public(package) fun proj_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(terms.schedule.phase_start),
        AssetState::AtDutch { auction, .. } =>
            option::some(auction.phase_start),
        _ => option::none(),
    }
}

public(package) fun proj_handover_expiry<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Demand { bid, .. } => option::some(bid.handover.expiry),
        _ => option::none(),
    }
}

/// Returns the total (scaled) ceiling duration for the active tenancy.
public(package) fun proj_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(terms.schedule.ceiling_total),
        _ => option::none(),
    }
}

/// Returns the total (scaled) handover duration for the active tenancy.
public(package) fun proj_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(terms.schedule.handover_total),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Occupied { cycle, .. } | AssetState::Demand { cycle, .. } =>
            option::some(cycle.floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Idle    { cycle, .. } => option::some(cycle.floor),
        AssetState::AtDutch { cycle, .. } => option::some(cycle.floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Idle    { cycle, .. } => option::some(cycle.ceiling),
        AssetState::AtDutch { cycle, .. } => option::some(cycle.ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Idle    { cycle, .. } => option::some(cycle.handover),
        AssetState::AtDutch { cycle, .. } => option::some(cycle.handover),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_descent<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Idle    { cycle, .. } => option::some(cycle.descent),
        AssetState::AtDutch { cycle, .. } => option::some(cycle.descent),
        _ => option::none(),
    }
}

public(package) fun proj_last_acq_price<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::AtDutch { auction, .. } => option::some(auction.last_acq_price),
        _ => option::none(),
    }
}

public(package) fun proj_credit_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(tenant::proj_stake_value(&terms.current)),
        _ => option::none(),
    }
}

public(package) fun proj_credit_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Occupied { terms, .. } | AssetState::Demand { terms, .. } =>
            option::some(terms.schedule.phase_start),
        _ => option::none(),
    }
}

public(package) fun proj_credit_is_accruing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Occupied { .. } => true, _ => false }
}

public(package) fun proj_credit_is_capped<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Demand { .. } => true, _ => false }
}

public(package) fun proj_credit_expiry<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Demand { bid, .. } => option::some(bid.handover.expiry),
        _ => option::none(),
    }
}

// ─── Pricing views (state + envelope) ─────────────────────────────────────────

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Price {
    match (s) {
        AssetState::Idle { cycle, .. } => cycle.floor,
        AssetState::AtDutch { auction, cycle, .. } => {
            let ps = price_state::descending(auction.last_acq_price, auction.phase_start, cycle.floor, cycle.descent);
            price_state::floor_price(&ps, &core.config.active, now)
        },
        AssetState::Retired { .. } => abort ERetiredNoBid,
        AssetState::Occupied { terms, .. } => {
            let ps = price_state::ascending(cycles::per_cycle_stake(tenant::proj_stake_value(&terms.current), terms.schedule.committed_cycles));
            price_state::floor_price(&ps, &core.config.active, now)
        },
        AssetState::Demand { bid, .. } => {
            let ps = price_state::ascending(cycles::per_cycle_stake(tenant::proj_stake_value(&bid.pending), bid.handover.cycles));
            price_state::floor_price(&ps, &core.config.active, now)
        },
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Stake {
    match (s) {
        AssetState::Occupied { terms, .. } => {
            let cs = credit_state::accruing(tenant::proj_stake_value(&terms.current), terms.schedule.phase_start);
            credit_state::used_credit(&cs, &core.config.active, terms.schedule.ceiling_total, now)
        },
        AssetState::Demand { terms, bid, .. } => {
            let cs = credit_state::capped(tenant::proj_stake_value(&terms.current), terms.schedule.phase_start, bid.handover.expiry);
            credit_state::used_credit(&cs, &core.config.active, terms.schedule.ceiling_total, now)
        },
        _ => abort ENotRented,
    }
}

/// Typed settlement for a handover boundary: (remaining_credit, owner_share, protocol_fee).
public(package) fun proj_handover_settlement<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): (Stake, Stake, Stake) {
    let stake = proj_current_stake_value(s);
    let used  = used_credit_at(s, core, now);
    let alloc = split_fee(used);
    (
        monetary::stake(monetary::stake_mist(stake) - monetary::stake_mist(used)),
        alloc.owner_share,
        alloc.protocol_fee,
    )
}

/// Typed settlement for a tenure expiry: (owner_share, protocol_fee).
public(package) fun proj_tenure_settlement<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): (Stake, Stake) {
    assert!(proj_is_rented(s), ENotRented);
    let alloc = split_fee(proj_current_stake_value(s));
    (alloc.owner_share, alloc.protocol_fee)
}

// ─── Cap-authorization predicates ────────────────────────────────────────────

public(package) fun cap_is_current<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: TenantCapIdentity,
): bool {
    match (s) {
        AssetState::Occupied { terms, .. } |
        AssetState::Demand   { terms, .. } =>
            cap == tenant::proj_cap_identity(tenant::proj_identity(&terms.current)),
        _ => false,
    }
}

public(package) fun cap_is_pending<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: TenantCapIdentity,
): bool {
    match (s) {
        AssetState::Demand { bid, .. } =>
            cap == tenant::proj_cap_identity(tenant::proj_identity(&bid.pending)),
        _ => false,
    }
}

public(package) fun cap_is_stale<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: TenantCapIdentity,
): bool {
    !cap_is_current(s, cap) && !cap_is_pending(s, cap)
}

// ─── APT and pending detection ────────────────────────────────────────────────

/// Read-only peek: does the on-disk state have a transition due at `now`?
/// Idle and Retired never produce a pending — they sit outside the APT
/// machinery by construction. Used for the SDK view in escrow.move which
/// only borrows the state.
public(package) fun next_pending<Asset: key + store, CoinType>(
    s:     &AssetState<Asset, CoinType>,
    clock: &Clock,
): Option<PendingTransitionState> {
    let now = phases::now(clock);
    match (s) {
        AssetState::Idle { .. }    => option::none(),
        AssetState::Retired { .. } => option::none(),
        AssetState::AtDutch { auction, cycle, .. } => {
            if (proj_auction_is_firable(auction, cycle, now)) {
                option::some(pending_transition_state::auction(
                    descent_policy_state::expiry_at(cycle.descent, auction.phase_start)
                ))
            } else { option::none() }
        },
        AssetState::Occupied { terms, .. } => {
            if (proj_occupied_is_firable(terms, now)) {
                option::some(pending_transition_state::occupied(
                    phases::boundary_at(terms.schedule.phase_start, terms.schedule.ceiling_total)
                ))
            } else { option::none() }
        },
        AssetState::Demand { bid, .. } => {
            if (proj_demand_is_firable(bid, now)) {
                option::some(pending_transition_state::demand(bid.handover.expiry))
            } else { option::none() }
        },
    }
}

/// Applies every APT transition whose boundary has been crossed,
/// following the fixed acyclic chain:
///
///   Demand → Occupied → AtDutch | Retired → Idle
///
/// Each step fires at most once; at most three transitions execute per
/// call. Termination is structural: the chain has no cycles and each
/// step recognises only its own source variant, passing all others
/// through unchanged.
public(package) fun apply_pending_transition_states<Asset: key + store, CoinType>(
    s:      AssetState<Asset, CoinType>,
    core:   &mut EscrowCore<CoinType>,
    random: &Random,
    clock:  &Clock,
    ctx:    &mut TxContext,
): AssetState<Asset, CoinType> {
    let now = phases::now(clock);
    let s = step_handover(s, core, now, ctx);
    let s = step_tenure_expiry(s, core, now, ctx);
    step_auction_expiry(s, core, random, now, ctx)
}

// ─── Action executors ─────────────────────────────────────────────────────────

/// Entry-point dispatcher for rent. Five arms, all reachable from the
/// public API:
///   · Retired → abort `ERetiredNoBid` (was structurally unreachable in
///     the legacy form because `floor_price_at` aborted first; now floor
///     is computed per-arm and the abort is the genuine consequence of
///     calling rent on a retired escrow).
///   · Idle    → install (`do_install`) → Occupied.
///   · AtDutch → install (`do_install`) → Occupied. Floor is the
///     descending Dutch price at `now`.
///   · Occupied → place bid (`do_place_bid`) → Demand. Aborts
///     `ERetireFlagBlocksBid` if the tenancy is flagged for retirement.
///   · Demand   → supersede bid (`do_supersede_bid`) → Demand. Mutates
///     `core.owner` to distribute the displaced bidder's refund.
///
/// Cycle validation against the integration config is the first check —
/// it does not depend on lifecycle state.
public(package) fun execute_rent<Asset: key + store, CoinType>(
    s:       AssetState<Asset, CoinType>,
    core:    &mut EscrowCore<CoinType>,
    payment: Coin<CoinType>,
    cycles:  Cycles,
    clock:   &Clock,
    ctx:     &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    tenure_cycles_policy_state::validate(config::proj_tenure_cycles(&core.config.active), cycles);
    let now                = phases::now(clock);
    let escrow_identity    = core.escrow_identity;
    let fee_inbox_identity = core.fee_inbox_identity;
    match (s) {
        AssetState::Retired { asset: _retired } => abort ERetiredNoBid,
        AssetState::Idle { asset, cycle } => {
            let floor = cycle.floor;
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_install(asset, cycle, cycles, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::AtDutch { asset, auction, cycle } => {
            let ps    = price_state::descending(auction.last_acq_price, auction.phase_start, cycle.floor, cycle.descent);
            let floor = price_state::floor_price(&ps, &core.config.active, now);
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_install(asset, cycle, cycles, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Occupied { asset, terms, cycle } => {
            if (retire_condition::proj_is_retiring(&terms.retire)) abort ERetireFlagBlocksBid;
            let stake = tenant::proj_stake_value(&terms.current);
            let ps    = price_state::ascending(cycles::per_cycle_stake(stake, terms.schedule.committed_cycles));
            let floor = price_state::floor_price(&ps, &core.config.active, now);
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_place_bid(asset, terms, cycle, cycles, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Demand { asset, terms, bid, cycle } => {
            let stake = tenant::proj_stake_value(&bid.pending);
            let ps    = price_state::ascending(cycles::per_cycle_stake(stake, bid.handover.cycles));
            let floor = price_state::floor_price(&ps, &core.config.active, now);
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_supersede_bid(
                asset, terms, bid, cycle, cycles,
                &mut core.owner, escrow_identity, fee_inbox_identity, payment, floor, now, ctx,
            )
        },
    }
}

/// Entry-point dispatcher for retire. Five arms, all reachable from the
/// public API:
///   · Retired  → abort `EAlreadyRetired`.
///   · Idle     → `do_retire_immediately` on the locked custody → Retired.
///   · AtDutch  → `do_retire_immediately` on the locked custody → Retired.
///                The descending-auction parameters are dropped — they
///                belong to a tenancy cycle that ends with this action.
///   · Occupied → set retiring flag → Occupied. The asset can still be
///                borrowed/returned during the grace period; the flag
///                prevents new bids and triggers Retired at the next
///                tenure expiry.
///   · Demand   → set retiring flag → Demand. Same semantics; the
///                active handover countdown is unaffected.
///
/// Owner-cap binding is checked first. The commitment policy must be
/// unlocked (`ECommitmentFloorNotElapsed`) regardless of state — it is a
/// property of the owner's permanence commitment, not the lifecycle.
///
/// `pending_config` is cleared unconditionally: any scheduled config
/// change is abandoned by the decision to retire.
public(package) fun execute_retire<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    core:      &mut EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &TxContext,
): AssetState<Asset, CoinType> {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == core.escrow_identity, EWrongEscrowOwnerCap);
    let now = phases::now(clock);
    assert!(
        commitment_policy_state::is_unlocked(
            commitment_policy_state::resolve(&core.commitment.policy),
            core.commitment.anchor,
            now,
        ).is_crossed(),
        ECommitmentFloorNotElapsed,
    );
    core.config.pending = option::none();
    let escrow_identity = core.escrow_identity;
    let raw_escrow_id   = escrow_identity::escrow_id(escrow_identity);
    let now_ms          = phases::timestamp_ms(now);
    match (s) {
        AssetState::Retired { asset: _retired } => abort EAlreadyRetired,
        AssetState::Idle { asset, cycle: _ } =>
            do_retire_immediately(asset, escrow_identity, now, ctx),
        AssetState::AtDutch { asset, .. } =>
            do_retire_immediately(asset, escrow_identity, now, ctx),
        AssetState::Occupied { asset, terms, cycle } => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms: now_ms });
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Occupied { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition::set(retire) }, cycle }
        },
        AssetState::Demand { asset, terms, bid, cycle } => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms: now_ms });
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Demand { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition::set(retire) }, bid, cycle }
        },
    }
}

/// Entry-point dispatcher for update_config. Five arms, all reachable
/// from the public API:
///   · Retired  → abort `EAlreadyRetired`.
///   · Idle     → apply the new config immediately: re-resolve floor /
///                ceiling / handover with fresh randomness and replace
///                the Idle resolutions. Emits `ConfigUpdated`.
///   · AtDutch  → schedule the new config (`pending_config`); the
///                descending auction in flight is allowed to complete
///                under the old parameters. Emits `ConfigUpdateScheduled`.
///   · Occupied → schedule the new config. Aborts
///                `ERetireAlreadyScheduled` if the retire flag is set —
///                a pending retire takes precedence over a pending
///                config change.
///   · Demand   → schedule the new config. Same retire-flag guard.
///
/// `random` is only consumed in the Idle arm (the only place that
/// re-resolves policy values immediately).
public(package) fun execute_update_config<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    core:      &mut EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    new_cfg:   IntegrationConfig,
    random:    &Random,
    ctx:       &mut TxContext,
): AssetState<Asset, CoinType> {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == core.escrow_identity, EWrongEscrowOwnerCap);
    let raw_escrow_id = escrow_identity::escrow_id(core.escrow_identity);
    match (s) {
        AssetState::Retired { asset: _retired } => abort EAlreadyRetired,
        AssetState::Idle { asset, cycle: _ } => {
            event::emit(ConfigUpdated { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.config.active = new_cfg;
            core.config.pending = option::none();
            let mut generator = sui::random::new_generator(random, ctx);
            let floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(&core.config.active), &mut generator);
            let ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(&core.config.active), &mut generator);
            let handover = handover_policy_state::resolve(config::proj_handover(&core.config.active), ceiling, &mut generator);
            let descent  = descent_policy_state::resolve(config::proj_descent(&core.config.active), &mut generator);
            AssetState::Idle { asset, cycle: CycleParams { floor, ceiling, handover, descent } }
        },
        AssetState::AtDutch { asset, auction, cycle } => {
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.config.pending = option::some(new_cfg);
            AssetState::AtDutch { asset, auction, cycle }
        },
        AssetState::Occupied { asset, terms, cycle } => {
            assert!(!retire_condition::proj_is_retiring(&terms.retire), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.config.pending = option::some(new_cfg);
            AssetState::Occupied { asset, terms, cycle }
        },
        AssetState::Demand { asset, terms, bid, cycle } => {
            assert!(!retire_condition::proj_is_retiring(&terms.retire), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.config.pending = option::some(new_cfg);
            AssetState::Demand { asset, terms, bid, cycle }
        },
    }
}

/// Asserts that `cap` is allowed to borrow: must be the current tenant's cap.
/// `pending` distinguishes a pending-bidder cap (EPendingTenantCap) from
/// any other non-matching cap (EStaleTenantCap).
fun assert_borrow_authorized(
    cap:     TenantCapIdentity,
    current: TenantCapIdentity,
    pending: Option<TenantCapIdentity>,
) {
    if (cap == current) return;
    if (option::contains(&pending, &cap)) abort EPendingTenantCap;
    abort EStaleTenantCap;
}

/// Tenant-gated asset borrow. Auth and action fused into a single match:
/// each renting arm authorizes via `assert_borrow_authorized` then takes
/// the asset. The `_s` arm covers Idle / AtDutch / Retired — states that
/// carry no open custody and therefore have no cap to match.
public(package) fun execute_borrow<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    tenant_cap: &TenantCap,
): (AssetState<Asset, CoinType>, Asset, AssetReceipt) {
    assert!(tenant_cap::proj_escrow_identity(tenant_cap) == core.escrow_identity, EWrongEscrowTenantCap);
    let cap_identity  = tenant_cap::identity(tenant_cap);
    let raw_escrow_id = escrow_identity::escrow_id(core.escrow_identity);
    match (s) {
        AssetState::Occupied { mut asset, terms, cycle } => {
            let current = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
            assert_borrow_authorized(cap_identity, current, option::none());
            let tenant_addr = tenant::proj_address(tenant::proj_identity(&terms.current));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            (AssetState::Occupied { asset, terms, cycle }, u, receipt)
        },
        AssetState::Demand { mut asset, terms, bid, cycle } => {
            let current = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
            let pending = tenant::proj_cap_identity(tenant::proj_identity(&bid.pending));
            assert_borrow_authorized(cap_identity, current, option::some(pending));
            let tenant_addr = tenant::proj_address(tenant::proj_identity(&terms.current));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            (AssetState::Demand { asset, terms, bid, cycle }, u, receipt)
        },
        _s => abort EStaleTenantCap,
    }
}

/// Tenant-gated asset return. Takes `&mut AssetState` — the variant does
/// not change (Occupied stays Occupied, Demand stays Demand); only the
/// open custody is mutated. The or-pattern collapses the two renting arms:
/// both expose the same `asset` and `terms` fields. The `AssetReceipt`
/// hot-potato is proof of borrow lineage; no explicit cap check is needed.
public(package) fun execute_return<Asset: key + store, CoinType>(
    s:          &mut AssetState<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
) {
    match (s) {
        AssetState::Occupied { asset, terms, .. } |
        AssetState::Demand   { asset, terms, .. } => {
            let cap_id      = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
            let tenant_addr = tenant::proj_address(tenant::proj_identity(&terms.current));
            asset::put(asset, asset_in, receipt_in);
            event::emit(AssetReturned {
                escrow_id:     escrow_identity::escrow_id(core.escrow_identity),
                tenant_cap_id: tenant_cap::cap_id(cap_id),
                tenant:        tenant_addr,
            });
        },
        _ => abort EReceiptEscrowMismatch,
    }
}

/// Entry-point dispatcher for burning a stale TenantCap (gas recovery).
///
/// Two invariants are enforced together — neither alone is sufficient:
///
///   1. The cap must have been issued by THIS escrow
///      (`EWrongEscrowTenantCap`). Without this guard, a Retired escrow
///      could be used as a "burn machine" for caps issued by other
///      escrows, including caps that are still `current`/`pending`
///      there — silently breaking invariant 2 on a foreign escrow.
///
///   2. The cap must not be `current` or `pending` of an active tenancy
///      (`ETenantCapNotStale`). Only stale caps may be burned, so that
///      live tenancy references are never destroyed.
///
/// In Idle/AtDutch/Retired the second guard is satisfied structurally —
/// Tenant-cap gas-recovery burn. Active caps (current or pending) abort
/// `ETenantCapNotStale`; stale caps burn unconditionally.
public(package) fun execute_burn_tenant_cap<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    cap:  TenantCap,
    ctx:  &TxContext,
): AssetState<Asset, CoinType> {
    assert!(tenant_cap::proj_escrow_identity(&cap) == core.escrow_identity, EWrongEscrowTenantCap);
    let cap_identity = tenant_cap::identity(&cap);
    match (&s) {
        AssetState::Occupied { terms, .. } => {
            let current = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
            if (cap_identity == current) abort ETenantCapNotStale;
        },
        AssetState::Demand { terms, bid, .. } => {
            let current = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
            let pending = tenant::proj_cap_identity(tenant::proj_identity(&bid.pending));
            if (cap_identity == current || cap_identity == pending) abort ETenantCapNotStale;
        },
        _ => {},
    };
    tenant_cap::burn(cap, ctx);
    s
}

/// Owner-gated earnings withdrawal. Operates on the core handoff
/// (owner + envelope) — orthogonal to the lifecycle state, so no
/// dispatch match is needed. The caller is responsible for routing
/// `core` from the dispatch boundary.
public(package) fun execute_withdraw_earnings<CoinType>(
    core:      &mut EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Coin<CoinType> {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == core.escrow_identity, EWrongEscrowOwnerCap);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();
    let (coin, amount) = do_withdraw(&mut core.owner, owner_cap, ctx);
    event::emit(EarningsWithdrawn { escrow_id: escrow_identity::escrow_id(core.escrow_identity), owner_cap_id, owner: owner_addr, amount: monetary::stake_mist(amount), timestamp_ms });
    coin
}

/// Extend the owner's permanence commitment. The new expiry must be ≥ the
/// current expiry — the commitment can only grow, never shrink.
///
/// Operates on the core handoff: commitment_policy + commitment_anchor
/// live in the envelope, orthogonal to the lifecycle state.
public(package) fun execute_extend_commitment<CoinType>(
    core:       &mut EscrowCore<CoinType>,
    owner_cap:  &OwnerCap,
    new_policy: CommitmentPolicyState,
    clock:      &Clock,
) {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == core.escrow_identity, EWrongEscrowOwnerCap);
    let now         = phases::now(clock);
    let old_expiry  = commitment_policy_state::unlock_at(
        commitment_policy_state::resolve(&core.commitment.policy),
        core.commitment.anchor,
    );
    let new_expiry  = commitment_policy_state::unlock_at(
        commitment_policy_state::resolve(&new_policy),
        now,
    );
    assert!(
        phases::timestamp_ms(new_expiry) >= phases::timestamp_ms(old_expiry),
        ECommitmentNotExtended,
    );
    event::emit(CommitmentExtended {
        escrow_id:     escrow_identity::escrow_id(core.escrow_identity),
        new_policy,
        new_expiry_ms: phases::timestamp_ms(new_expiry),
        timestamp_ms:  phases::timestamp_ms(now),
    });
    core.commitment.policy = new_policy;
    core.commitment.anchor = now;
}

/// Retired → Destroyed: the terminal claim action. The Retired arm
/// unwraps the locked asset and the swept owner earnings, emits
/// `AssetClaimed`, and returns. The other four arms abort `ENotRetired`
/// after consuming the hot-potatoes inline — the abort is reachable
/// from the public API (caller invoked claim while the escrow was in
/// the wrong lifecycle state) and is what `expected_failure` tests
/// exercise.
///
/// Lives here (not in escrow.move) because Move 2024 restricts pattern
/// access to the defining module — the wrong-state arms have to
/// destructure `AssetState` and `EscrowCore` before aborting, and that
/// destructure must happen inside this module.
public(package) fun execute_claim<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    core:      EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    match (s) {
        AssetState::Retired { asset } => {
            let EscrowCore { mut owner, escrow_identity, .. } = core;
            assert!(owner_cap::proj_escrow_identity(owner_cap) == escrow_identity, EWrongEscrowOwnerCap);
            let coin           = owner::withdraw(&mut owner, owner_cap, ctx);
            let swept_earnings = coin::value(&coin);
            owner::destroy_empty(owner);
            event::emit(AssetClaimed {
                escrow_id:    escrow_identity::escrow_id(escrow_identity),
                owner_cap_id: object::id(owner_cap),
                owner:        ctx.sender(),
                swept_earnings,
                timestamp_ms: clock::timestamp_ms(clock),
            });
            (asset::unlock(asset), coin)
        },
        AssetState::Idle { asset: _a, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
        AssetState::AtDutch { asset: _a, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
        AssetState::Occupied { asset: _a, terms: _t, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
        AssetState::Demand { asset: _a, terms: _t, bid: _b, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
    }
}

// === Errors ===

const ERetireFlagBlocksBid: u64 = 2;
const EPendingTenantCap:    u64 = 7;
const ETenantCapNotStale:   u64 = 9;

// === Constants ===

const PROTOCOL_FEE_BPS: u64 = 1_000;

// === Events ===

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    current_tenant_cap_id:     ID,
    current_tenant_addr:       address,
    current_tenant_stake:      u64,
    current_phase_start_ms:    u64,
    tenant_cap_id:             ID,
    pending_tenant:            address,
    bid_amount:                u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
    timestamp_ms:              u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:                 ID,
    protected_tenant_cap_id:   ID,
    protected_tenant_addr:     address,
    protected_tenant_stake:    u64,
    protected_phase_start_ms:  u64,
    displaced_tenant_cap_id:   ID,
    new_tenant_cap_id:         ID,
    displaced_bidder:          address,
    refunded_amount:           u64,
    new_bidder:                address,
    new_bid_amount:            u64,
    floor_price:               u64,
    handover_countdown_expiry: u64,
    timestamp_ms:              u64,
}

public struct HandoverCompleted has copy, drop {
    escrow_id:                ID,
    displaced_tenant_cap_id:  ID,
    displaced_tenant:         address,
    displaced_phase_start_ms: u64,
    new_tenant_cap_id:        ID,
    new_tenant_addr:          address,
    new_tenant_stake:         u64,
    used_credit:              u64,
    owner_share:              u64,
    protocol_fee:             u64,
    remain_credit:            u64,
    new_rent_price:           u64,
    timestamp_ms:             u64,
}

public struct TenureExpired has copy, drop {
    escrow_id:              ID,
    tenant_cap_id:          ID,
    tenant:                 address,
    phase_start_ms:         u64,
    owner_share:            u64,
    protocol_fee:           u64,
    last_acquisition_price: u64,
    timestamp_ms:           u64,
}

public struct RetireFlagSet has copy, drop {
    escrow_id:    ID,
    owner:        address,
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

// === Public Functions ===

// ─── Fee helpers ──────────────────────────────────────────────────────────────

fun split_fee(amount: Stake): FeeAllocation {
    let mist         = monetary::stake_mist(amount);
    let protocol_fee = math::apply_bps(mist, math::bps(PROTOCOL_FEE_BPS));
    FeeAllocation {
        owner_share:  monetary::stake(mist - protocol_fee),
        protocol_fee: monetary::stake(protocol_fee),
    }
}

public(package) fun protocol_fee_bps(): u64 { PROTOCOL_FEE_BPS }
public(package) fun bps_denominator():  u64 { math::bps_denominator() }

// ─── Tenancy-internal transitions ─────────────────────────────────────────────

/// Demand → Occupied: fire the handover transition at `boundary_ms`.
/// Distributes used credit to owner; retiring flag propagates to new Occupied.
fun do_handover<Asset: key + store, CoinType>(
    asset:              asset::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    bid:                DemandTerms<CoinType>,
    cycle:              CycleParams,
    owner:              &mut Owner<CoinType>,
    config:             &IntegrationConfig,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): AssetState<Asset, CoinType> {
    let OccupiedTerms { schedule, current, retire } = terms;
    let DemandTerms { pending, handover: HandoverTerms { expiry: _, cycles: incoming_cycles } } = bid;

    let principal   = tenant::proj_stake_value(&current);
    let used_credit = {
        let cs = credit_state::capped(principal, schedule.phase_start, boundary);
        credit_state::used_credit(&cs, config, schedule.ceiling_total, boundary)
    };
    let alloc         = split_fee(used_credit);
    let remain_credit = monetary::stake_sub(principal, used_credit);

    let displaced_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&current));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&current));

    let mut departing  = current;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_identity);
    let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, owner, fee_inbox_identity, ctx);

    let new_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&pending));
    let new_addr         = tenant::proj_address(tenant::proj_identity(&pending));
    let new_stake        = tenant::proj_stake_value(&pending);
    let new_rent_price = monetary::price_mist({
        let ps = price_state::ascending(new_stake);
        price_state::floor_price(&ps, config, boundary)
    });
    let boundary_ms = phases::timestamp_ms(boundary);

    event::emit(HandoverCompleted {
        escrow_id: escrow_identity::escrow_id(escrow_identity),
        displaced_tenant_cap_id:  tenant_cap::cap_id(displaced_cap_identity),
        displaced_tenant:         displaced_addr,
        displaced_phase_start_ms: phases::timestamp_ms(schedule.phase_start),
        new_tenant_cap_id:        tenant_cap::cap_id(new_cap_identity),
        new_tenant_addr:          new_addr,
        new_tenant_stake:         monetary::stake_mist(new_stake),
        used_credit:              monetary::stake_mist(used_credit),
        owner_share:              monetary::stake_mist(alloc.owner_share),
        protocol_fee:             monetary::stake_mist(alloc.protocol_fee),
        remain_credit:            monetary::stake_mist(remain_credit),
        new_rent_price,
        timestamp_ms:             boundary_ms,
    });

    let new_schedule = TenancySchedule {
        phase_start:      boundary,
        ceiling_total:    cycles::rescale_duration(schedule.ceiling_total, schedule.committed_cycles, incoming_cycles),
        handover_total:   cycles::rescale_duration(schedule.handover_total, schedule.committed_cycles, incoming_cycles),
        committed_cycles: incoming_cycles,
    };
    AssetState::Occupied {
        asset,
        terms: OccupiedTerms { schedule: new_schedule, current: pending, retire },
        cycle,
    }
}

/// Consume an Occupied tenancy at tenure expiry. Distributes full stake
/// to owner/protocol and decides the outcome from the retire condition:
///   · flag set   → `Retired` (the locked asset is all the caller needs).
///   · flag unset → `AtDutch` (cycle params carried unchanged; no rescaling
///     needed since cycle.ceiling/handover are already per-cycle base values).
fun do_tenure_expiry<Asset: key + store, CoinType>(
    asset:              asset::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    cycle:              CycleParams,
    owner:              &mut Owner<CoinType>,
    config:             &mut ConfigSlot,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): AssetState<Asset, CoinType> {
    let OccupiedTerms { schedule, current: tenant, retire } = terms;

    let principal            = tenant::proj_stake_value(&tenant);
    let tenant_cap_identity  = tenant::proj_cap_identity(tenant::proj_identity(&tenant));
    let tenant_addr          = tenant::proj_address(tenant::proj_identity(&tenant));
    let alloc = split_fee(principal);

    let mut departing  = tenant;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_identity);
    let (_, stake)     = tenant::unbundle(departing);
    tenant::destroy_empty_stake(stake);
    refund_state::distribute(refund_state::nothing(fee_share, owner_earnings), owner, fee_inbox_identity, ctx);

    event::emit(TenureExpired {
        escrow_id:              escrow_identity::escrow_id(escrow_identity),
        tenant_cap_id:          tenant_cap::cap_id(tenant_cap_identity),
        tenant:                 tenant_addr,
        phase_start_ms:         phases::timestamp_ms(schedule.phase_start),
        owner_share:            monetary::stake_mist(alloc.owner_share),
        protocol_fee:           monetary::stake_mist(alloc.protocol_fee),
        last_acquisition_price: monetary::stake_mist(principal),
        timestamp_ms:           phases::timestamp_ms(boundary),
    });

    // Tenure has ended: switch custody type. close_tenancy asserts the asset
    // is actually present (not on loan) — the borrow protocol is over.
    let locked = asset::close_tenancy(asset);
    if (retire_condition::proj_is_retiring(&retire)) {
        event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(escrow_identity), timestamp_ms: phases::timestamp_ms(boundary) });
        config.pending = option::none();
        AssetState::Retired { asset: locked }
    } else {
        // cycle.ceiling and cycle.handover are the per-cycle base values —
        // no rescaling needed. Pass cycle directly to the resulting AtDutch.
        AssetState::AtDutch {
            asset:   locked,
            auction: AuctionTerms { last_acq_price: monetary::as_reference_price(principal), phase_start: boundary },
            cycle,
        }
    }
}

// === Private Functions ===

/// Occupied → Demand.
fun do_place_bid<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyOpen<Asset>,
    terms:           OccupiedTerms<CoinType>,
    cycle:           CycleParams,
    cycles:          Cycles,
    escrow_identity: EscrowIdentity,
    payment:         Coin<CoinType>,
    floor:           Price,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let current_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
    let current_addr   = tenant::proj_address(tenant::proj_identity(&terms.current));
    let current_stake  = tenant::proj_stake_value(&terms.current);
    let expiry         = handover_policy_state::expiry_at(terms.schedule.handover_total, terms.schedule.ceiling_total, now, terms.schedule.phase_start);
    let pending_addr   = ctx.sender();
    let bid_amount     = coin::value(&payment);
    let raw_escrow_id  = escrow_identity::escrow_id(escrow_identity);
    let cap            = tenant_cap::new(escrow_identity, pending_addr, ctx);
    let cap_identity   = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, pending_addr, coin::into_balance(payment));
    event::emit(BidPlaced {
        escrow_id: raw_escrow_id,
        current_tenant_cap_id:     tenant_cap::cap_id(current_cap_identity),
        current_tenant_addr:       current_addr,
        current_tenant_stake:      monetary::stake_mist(current_stake),
        current_phase_start_ms:    phases::timestamp_ms(terms.schedule.phase_start),
        tenant_cap_id:             tenant_cap::cap_id(cap_identity),
        pending_tenant:            pending_addr,
        bid_amount,
        floor_price:               monetary::price_mist(floor),
        handover_countdown_expiry: phases::timestamp_ms(expiry),
        timestamp_ms:              phases::timestamp_ms(now),
    });
    (
        AssetState::Demand {
            asset,
            terms,
            bid: DemandTerms {
                pending:  t,
                handover: HandoverTerms { expiry, cycles },
            },
            cycle,
        },
        cap,
    )
}

/// Demand → Demand: displace the existing pending bidder.
fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:              asset::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    bid:                DemandTerms<CoinType>,
    cycle:              CycleParams,
    incoming_cycles:    Cycles,
    owner:              &mut Owner<CoinType>,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    payment:            Coin<CoinType>,
    floor:              Price,
    now:                Timestamp,
    ctx:                &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let DemandTerms { pending, handover: HandoverTerms { expiry: handover_expiry, cycles: _ } } = bid;

    let protected_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&terms.current));
    let protected_addr   = tenant::proj_address(tenant::proj_identity(&terms.current));
    let protected_stake  = tenant::proj_stake_value(&terms.current);
    let displaced_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&pending));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&pending));
    let refunded_amount  = tenant::proj_stake_value(&pending);

    let raw_escrow_id  = escrow_identity::escrow_id(escrow_identity);
    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);
    let cap          = tenant_cap::new(escrow_identity, new_bidder, ctx);
    let cap_identity = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, new_bidder, coin::into_balance(payment));

    let refund = refund_state::from_superseded(pending);
    refund_state::distribute(refund, owner, fee_inbox_identity, ctx);

    event::emit(BidSuperseded {
        escrow_id: raw_escrow_id,
        protected_tenant_cap_id:   tenant_cap::cap_id(protected_cap_identity),
        protected_tenant_addr:     protected_addr,
        protected_tenant_stake:    monetary::stake_mist(protected_stake),
        protected_phase_start_ms:  phases::timestamp_ms(terms.schedule.phase_start),
        displaced_tenant_cap_id:   tenant_cap::cap_id(displaced_cap_identity),
        new_tenant_cap_id:         tenant_cap::cap_id(cap_identity),
        displaced_bidder:          displaced_addr,
        refunded_amount:           monetary::stake_mist(refunded_amount),
        new_bidder,
        new_bid_amount,
        floor_price:               monetary::price_mist(floor),
        handover_countdown_expiry: phases::timestamp_ms(handover_expiry),
        timestamp_ms:              phases::timestamp_ms(now),
    });
    (
        AssetState::Demand {
            asset,
            terms,
            bid: DemandTerms {
                pending:  t,
                handover: HandoverTerms { expiry: handover_expiry, cycles: incoming_cycles },
            },
            cycle,
        },
        cap,
    )
}

// === Test Functions ===

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    let alloc = split_fee(monetary::stake(amount));
    (monetary::stake_mist(alloc.owner_share), monetary::stake_mist(alloc.protocol_fee))
}

// ─── Test-only event accessors ────────────────────────────────────────────────

#[test_only]
public(package) fun bid_placed_tenant_cap_id(e: &BidPlaced): ID                  { e.tenant_cap_id }
#[test_only]
public(package) fun bid_placed_bid_amount(e: &BidPlaced): u64                    { e.bid_amount }
#[test_only]
public(package) fun bid_placed_floor_price(e: &BidPlaced): u64                   { e.floor_price }
#[test_only]
public(package) fun bid_placed_handover_countdown_expiry(e: &BidPlaced): u64     { e.handover_countdown_expiry }

#[test_only]
public(package) fun bid_superseded_displaced_cap_id(e: &BidSuperseded): ID           { e.displaced_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_new_cap_id(e: &BidSuperseded): ID                 { e.new_tenant_cap_id }
#[test_only]
public(package) fun bid_superseded_displaced_bidder(e: &BidSuperseded): address      { e.displaced_bidder }
#[test_only]
public(package) fun bid_superseded_refunded_amount(e: &BidSuperseded): u64           { e.refunded_amount }
#[test_only]
public(package) fun bid_superseded_new_bidder(e: &BidSuperseded): address            { e.new_bidder }
#[test_only]
public(package) fun bid_superseded_new_bid_amount(e: &BidSuperseded): u64            { e.new_bid_amount }

#[test_only]
public(package) fun handover_completed_displaced_tenant(e: &HandoverCompleted): address      { e.displaced_tenant }
#[test_only]
public(package) fun handover_completed_new_cap_id(e: &HandoverCompleted): ID                 { e.new_tenant_cap_id }
#[test_only]
public(package) fun handover_completed_used_credit(e: &HandoverCompleted): u64               { e.used_credit }
#[test_only]
public(package) fun handover_completed_owner_share(e: &HandoverCompleted): u64               { e.owner_share }
#[test_only]
public(package) fun handover_completed_protocol_fee(e: &HandoverCompleted): u64              { e.protocol_fee }
#[test_only]
public(package) fun handover_completed_remain_credit(e: &HandoverCompleted): u64             { e.remain_credit }
#[test_only]
public(package) fun handover_completed_new_rent_price(e: &HandoverCompleted): u64            { e.new_rent_price }
#[test_only]
public(package) fun handover_completed_timestamp_ms(e: &HandoverCompleted): u64              { e.timestamp_ms }

#[test_only]
public(package) fun tenure_expired_owner_share(e: &TenureExpired): u64               { e.owner_share }
#[test_only]
public(package) fun tenure_expired_protocol_fee(e: &TenureExpired): u64              { e.protocol_fee }
#[test_only]
public(package) fun tenure_expired_last_acq_price(e: &TenureExpired): u64            { e.last_acquisition_price }


#[test_only]
public(package) fun asset_borrowed_tenant_cap_id(e: &AssetBorrowed): ID              { e.tenant_cap_id }

#[test_only]
public(package) fun asset_returned_tenant_cap_id(e: &AssetReturned): ID              { e.tenant_cap_id }

#[test_only]
public(package) fun asset_claimed_swept_earnings(e: &AssetClaimed): u64              { e.swept_earnings }

// === Private Functions ===

// ─── APT boundary predicates ─────────────────────────────────────────────────
// Single source of truth for each transition's due condition.
// Used by both next_pending (detection) and the step_* functions (firing).

fun proj_demand_is_firable<CoinType>(bid: &DemandTerms<CoinType>, now: Timestamp): bool {
    phases::check_boundary(bid.handover.expiry, phases::zero(), now).is_crossed()
}

fun proj_occupied_is_firable<CoinType>(terms: &OccupiedTerms<CoinType>, now: Timestamp): bool {
    phases::check_boundary(terms.schedule.phase_start, terms.schedule.ceiling_total, now).is_crossed()
}

fun proj_auction_is_firable(auction: &AuctionTerms, cycle: &CycleParams, now: Timestamp): bool {
    descent_policy_state::has_expired(cycle.descent, auction.phase_start, now).is_crossed()
}

/// Step 1 of 3: Demand → Occupied if the handover countdown has elapsed.
/// Every other variant passes through unchanged.
fun step_handover<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &mut EscrowCore<CoinType>,
    now:  Timestamp,
    ctx:  &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Demand { asset, terms, bid, cycle } => {
            if (proj_demand_is_firable(&bid, now)) {
                let boundary = bid.handover.expiry;
                do_handover(
                    asset, terms, bid, cycle,
                    &mut core.owner, &core.config.active,
                    core.escrow_identity, core.fee_inbox_identity,
                    boundary, ctx,
                )
            } else {
                AssetState::Demand { asset, terms, bid, cycle }
            }
        },
        s => s,
    }
}

/// Step 2 of 3: Occupied → AtDutch | Retired if the tenure ceiling has elapsed.
/// Every other variant passes through unchanged.
fun step_tenure_expiry<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &mut EscrowCore<CoinType>,
    now:  Timestamp,
    ctx:  &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Occupied { asset, terms, cycle } => {
            if (proj_occupied_is_firable(&terms, now)) {
                let boundary = phases::boundary_at(terms.schedule.phase_start, terms.schedule.ceiling_total);
                do_tenure_expiry(
                    asset, terms, cycle,
                    &mut core.owner, &mut core.config, core.escrow_identity, core.fee_inbox_identity,
                    boundary, ctx,
                )
            } else {
                AssetState::Occupied { asset, terms, cycle }
            }
        },
        s => s,
    }
}

/// Step 3 of 3: AtDutch → Idle if the descent window has elapsed.
/// Every other variant passes through unchanged.
fun step_auction_expiry<Asset: key + store, CoinType>(
    s:      AssetState<Asset, CoinType>,
    core:   &mut EscrowCore<CoinType>,
    random: &Random,
    now:    Timestamp,
    ctx:    &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::AtDutch { asset, auction, cycle } => {
            if (proj_auction_is_firable(&auction, &cycle, now)) {
                let boundary = descent_policy_state::expiry_at(cycle.descent, auction.phase_start);
                let mut generator = sui::random::new_generator(random, ctx);
                do_auction_expiry(asset, auction, &mut core.config, core.escrow_identity, boundary, &mut generator)
            } else {
                AssetState::AtDutch { asset, auction, cycle }
            }
        },
        s => s,
    }
}

fun do_withdraw<CoinType>(
    owner:     &mut Owner<CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Coin<CoinType>, Stake) {
    let amount = owner::proj_value(owner);
    assert!(monetary::stake_mist(amount) > 0, ENoEarnings);
    let coin = owner::withdraw(owner, owner_cap, ctx);
    (coin, amount)
}

fun do_install<Asset: key + store, CoinType>(
    locked:          asset::AssetCustodyLocked<Asset>,
    cycle:           CycleParams,
    cycles:          Cycles,
    escrow_identity: EscrowIdentity,
    payment:         Coin<CoinType>,
    floor:           Price,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let price_paid    = coin::value(&payment);
    let tenant_addr   = ctx.sender();
    let now_ms        = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    let cap           = tenant_cap::new(escrow_identity, tenant_addr, ctx);
    let cap_identity  = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, tenant_addr, coin::into_balance(payment));
    let wrapped = asset::open_tenancy(locked, escrow_identity);
    let schedule = TenancySchedule {
        phase_start:      now,
        ceiling_total:    cycles::total_duration(cycle.ceiling, cycles),
        handover_total:   cycles::total_duration(cycle.handover, cycles),
        committed_cycles: cycles,
    };
    event::emit(RentStarted {
        escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr,
        phase_start_ms: now_ms, price_paid, floor_price: monetary::price_mist(floor),
    });
    (
        AssetState::Occupied {
            asset: wrapped,
            terms: OccupiedTerms { schedule, current: t, retire: retire_condition::new() },
            cycle,
        },
        cap,
    )
}

/// AtDutch → Idle. The lifecycle invariant says all `resolved_*` are
/// drawn at Idle entry; this is the auction-expiry instance of that
/// rule. If `pending_config` was scheduled during the previous cycle it
/// is applied now (emit `ConfigUpdated` → assign → clear) BEFORE the
/// four resolves, so the new Idle reflects the new config.
fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyLocked<Asset>,
    auction:         AuctionTerms,
    config:          &mut ConfigSlot,
    escrow_identity: EscrowIdentity,
    boundary:        Timestamp,
    generator:       &mut RandomGenerator,
): AssetState<Asset, CoinType> {
    event::emit(AuctionExpired { escrow_id: escrow_identity::escrow_id(escrow_identity), phase_start_ms: phases::timestamp_ms(auction.phase_start), last_acq_price: monetary::price_mist(auction.last_acq_price), timestamp_ms: phases::timestamp_ms(boundary) });
    if (config.pending.is_some()) {
        let new_cfg = config.pending.extract();
        event::emit(ConfigUpdated { escrow_id: escrow_identity::escrow_id(escrow_identity), new_config: new_cfg });
        config.active = new_cfg;
    };
    let floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(&config.active), generator);
    let ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(&config.active), generator);
    let handover = handover_policy_state::resolve(config::proj_handover(&config.active), ceiling, generator);
    let descent  = descent_policy_state::resolve(config::proj_descent(&config.active), generator);
    AssetState::Idle { asset, cycle: CycleParams { floor, ceiling, handover, descent } }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyLocked<Asset>,
    escrow_identity: EscrowIdentity,
    now:             Timestamp,
    ctx:             &TxContext,
): AssetState<Asset, CoinType> {
    let timestamp_ms  = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms });
    event::emit(AssetRetired { escrow_id: raw_escrow_id, timestamp_ms });
    AssetState::Retired { asset }
}

// === Test Functions ===


#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    state:    AssetState<Asset, CoinType>,
    core:     &mut EscrowCore<CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Demand { asset, terms, bid, cycle } =>
            do_handover(
                asset, terms, bid, cycle,
                &mut core.owner, &core.config.active,
                core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            ),
        AssetState::Idle    { asset: _a, .. } => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. } => abort ENotRented,
        AssetState::Retired { asset: _a }      => abort ENotRented,
        AssetState::Occupied { asset: _a, terms: _t, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    state:    AssetState<Asset, CoinType>,
    core:     &mut EscrowCore<CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Occupied { asset, terms, cycle } =>
            do_tenure_expiry(
                asset, terms, cycle,
                &mut core.owner, &mut core.config, core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            ),
        AssetState::Idle    { asset: _a, .. } => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. } => abort ENotRented,
        AssetState::Retired { asset: _a }      => abort ENotRented,
        AssetState::Demand  { asset: _a, terms: _t, bid: _b, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    state:     AssetState<Asset, CoinType>,
    core:      &mut EscrowCore<CoinType>,
    boundary:  Timestamp,
    generator: &mut RandomGenerator,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::AtDutch { asset, auction, .. } =>
            do_auction_expiry(asset, auction, &mut core.config, core.escrow_identity, boundary, generator),
        AssetState::Idle     { asset: _a, .. } => abort ENotRented,
        AssetState::Retired  { asset: _a }      => abort ENotRented,
        AssetState::Occupied { asset: _a, terms: _t, .. } => abort ENotRented,
        AssetState::Demand   { asset: _a, terms: _t, bid: _b, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    state:       AssetState<Asset, CoinType>,
    core:        &EscrowCore<CoinType>,
    tenant_in:   tenant::Tenant<CoinType>,
    phase_start: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Idle { asset, cycle } => {
            let schedule = TenancySchedule {
                phase_start,
                ceiling_total:    cycle.ceiling,
                handover_total:   cycle.handover,
                committed_cycles: cycles::cycles(1),
            };
            // tenant_in is consumed only on the happy path; the abort arms
            // below leave it to drop with the divergent abort.
            AssetState::Occupied {
                asset: asset::open_tenancy(asset, core.escrow_identity),
                terms: OccupiedTerms { schedule, current: tenant_in, retire: retire_condition::new() },
                cycle,
            }
        },
        AssetState::AtDutch  { asset: _a, .. }                               => abort ENotRented,
        AssetState::Retired  { asset: _a }                                   => abort ENotRented,
        AssetState::Occupied { asset: _a, terms: _t, .. }                    => abort ENotRented,
        AssetState::Demand   { asset: _a, terms: _t, bid: _b, .. }           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    state:                     AssetState<Asset, CoinType>,
    tenant_in:                 tenant::Tenant<CoinType>,
    handover_countdown_expiry: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Occupied { asset, terms, cycle } =>
            AssetState::Demand {
                asset,
                terms,
                bid: DemandTerms {
                    pending:  tenant_in,
                    handover: HandoverTerms { expiry: handover_countdown_expiry, cycles: cycles::cycles(1) },
                },
                cycle,
            },
        AssetState::Idle    { asset: _a, .. }                               => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. }                               => abort ENotRented,
        AssetState::Retired { asset: _a }                                   => abort ENotRented,
        AssetState::Demand  { asset: _a, terms: _t, bid: _b, .. }           => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    state:           AssetState<Asset, CoinType>,
    core:            &EscrowCore<CoinType>,
    owner_amount:    u64,
    fee_amount:      u64,
    last_acq_price:  u64,
    new_phase_start: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Occupied { asset, terms, cycle } => {
            let OccupiedTerms { schedule: _, current: mut tenant, retire: _ } = terms;
            let owner_earnings = tenant::take_owner_earnings(&mut tenant, monetary::stake(owner_amount));
            let fee_share      = tenant::take_fee_share(&mut tenant, monetary::stake(fee_amount), core.escrow_identity);
            let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
            refund_state::destroy_for_testing(refund);
            AssetState::AtDutch {
                asset:   asset::close_tenancy(asset),
                auction: AuctionTerms { last_acq_price: monetary::price(last_acq_price), phase_start: new_phase_start },
                cycle,
            }
        },
        AssetState::Idle    { asset: _a, .. }                           => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. }                           => abort ENotRented,
        AssetState::Retired { asset: _a }                               => abort ENotRented,
        AssetState::Demand  { asset: _a, terms: _t, bid: _b, .. }       => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    state: AssetState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Idle { asset, cycle: _ } =>
            AssetState::Retired { asset },
        AssetState::AtDutch  { asset: _a, .. }                              => abort ENotRented,
        AssetState::Retired  { asset: _a }                                  => abort ENotRented,
        AssetState::Occupied { asset: _a, terms: _t, .. }                   => abort ENotRented,
        AssetState::Demand   { asset: _a, terms: _t, bid: _b, .. }          => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    state: AssetState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Occupied { asset, terms, cycle } => {
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Occupied { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition::set_for_testing(retire) }, cycle }
        },
        AssetState::Demand { asset, terms, bid, cycle } => {
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Demand { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition::set_for_testing(retire) }, bid, cycle }
        },
        AssetState::Idle    { asset: _a, .. } => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. } => abort ENotRented,
        AssetState::Retired { asset: _a }     => abort ENotRented,
    }
}

/// Test-only accessors: the four cycle-resident `resolved_*` values
/// read from any non-Retired variant. The SDK views deliberately
/// expose only the phase-appropriate readings (e.g.
/// `proj_waiting_resolved_descent` returns Some only on Idle/AtDutch —
/// the auction-descent semantic); these helpers exist so invariant
/// tests can verify the four flow unchanged through Occupied/Demand.
/// In Occupied/Demand the ceiling/handover values are read from
/// `cycle` (per-cycle base). Tests that compare across Idle ↔ Renting
/// use `cycles::cycles(1)` so the scaled total equals the base.
#[test_only]
public(package) fun proj_resolved_descent_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Duration {
    match (s) {
        AssetState::Idle     { cycle, .. } => cycle.descent,
        AssetState::AtDutch  { cycle, .. } => cycle.descent,
        AssetState::Occupied { cycle, .. } => cycle.descent,
        AssetState::Demand   { cycle, .. } => cycle.descent,
        AssetState::Retired { .. } => abort 0,
    }
}

#[test_only]
public(package) fun proj_resolved_floor_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Price {
    match (s) {
        AssetState::Idle     { cycle, .. } => cycle.floor,
        AssetState::AtDutch  { cycle, .. } => cycle.floor,
        AssetState::Occupied { cycle, .. } => cycle.floor,
        AssetState::Demand   { cycle, .. } => cycle.floor,
        AssetState::Retired { .. } => abort 0,
    }
}

#[test_only]
public(package) fun proj_resolved_ceiling_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Duration {
    match (s) {
        AssetState::Idle     { cycle, .. } => cycle.ceiling,
        AssetState::AtDutch  { cycle, .. } => cycle.ceiling,
        AssetState::Occupied { terms, .. } => terms.schedule.ceiling_total,
        AssetState::Demand   { terms, .. } => terms.schedule.ceiling_total,
        AssetState::Retired { .. } => abort 0,
    }
}

#[test_only]
public(package) fun proj_resolved_handover_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Duration {
    match (s) {
        AssetState::Idle     { cycle, .. } => cycle.handover,
        AssetState::AtDutch  { cycle, .. } => cycle.handover,
        AssetState::Occupied { terms, .. } => terms.schedule.handover_total,
        AssetState::Demand   { terms, .. } => terms.schedule.handover_total,
        AssetState::Retired { .. } => abort 0,
    }
}

// ─── Test-only event accessors ────────────────────────────────────────────────

#[test_only]
public(package) fun rent_started_tenant_cap_id(e: &RentStarted): ID              { e.tenant_cap_id }
#[test_only]
public(package) fun rent_started_price_paid(e: &RentStarted): u64                { e.price_paid }
#[test_only]
public(package) fun rent_started_floor_price(e: &RentStarted): u64               { e.floor_price }

#[test_only]
public(package) fun auction_expired_timestamp_ms(e: &AuctionExpired): u64        { e.timestamp_ms }


#[test_only]
public(package) fun earnings_withdrawn_amount(e: &EarningsWithdrawn): u64        { e.amount }

#[test_only]
public(package) fun config_updated_new_config(e: &ConfigUpdated): IntegrationConfig { e.new_config }
