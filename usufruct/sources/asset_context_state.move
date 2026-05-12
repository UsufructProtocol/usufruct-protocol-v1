// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Context-State pattern: AssetContext (context carrier) + AssetState co-resident.
///
/// AssetState is a binary split: Renting (active tenancy) vs Waiting (no tenant).
///   · Renting embeds TenancyContext + TenancyState (Occupied / Demand sub-machine).
///   · Waiting embeds WaitingContext + WaitingState (Idle / AtDutch / Retired sub-machine).
///
/// All nested enum types must co-reside: Move 2024 restricts pattern access to the
/// defining module.
module usufruct::asset_context_state;

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
    owner_cap::OwnerCapIdentity,
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

/// Role a `TenantCap` plays relative to the current lifecycle state.
/// Co-resident with asset_context_state so match arms can branch on variants
/// directly — Move restricts pattern access to the defining module.
///
///   · `Current` — cap belongs to the active tenant. May borrow.
///   · `Pending` — cap belongs to the pending bidder (HandoverConfirmed). May not borrow.
///   · `Stale`   — cap is superseded, former tenant, or no active rental.
public enum CapAuthorizationState has drop {
    Current,
    Pending,
    Stale,
}

public(package) fun proj_is_current(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Current => true, _ => false }
}
public(package) fun proj_is_pending(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Pending => true, _ => false }
}
public(package) fun proj_is_stale(a: &CapAuthorizationState): bool {
    match (a) { CapAuthorizationState::Stale => true, _ => false }
}

/// Result of splitting a credit amount into owner earnings and protocol fee.
/// Named fields prevent positional swap between the two semantically distinct
/// monetary roles.
public struct FeeAllocation has drop {
    owner_share:  Stake,
    protocol_fee: Stake,
}

/// Binary lifecycle split: active tenancy vs. no tenant.
///
///   · Renting — active tenancy (Occupied or Demand sub-state via TenancyContext).
///   · Waiting — no tenant: Idle, AtDutch, or Retired (sub-state via WaitingContext).
public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Renting { tenancy: TenancyContext<Asset, CoinType> },
    Waiting { waiting: WaitingContext<Asset> },
}

/// Sub-machine state for waiting (no-tenant) lifecycle phases.
public enum WaitingState has store, drop {
    Idle    { resolved_floor: Price, resolved_ceiling: Duration, resolved_handover: Duration },
    AtDutch { last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price, resolved_ceiling: Duration, resolved_handover: Duration, resolved_descent: Duration },
    Retired,
}

/// Context-State carrier for the no-tenant phases embedded in AssetState::Waiting.
///
///   · asset — present in all three waiting states; extracted here so match arms
///     never repeat it.
///   · state — Idle, AtDutch (auction in progress), or Retired (awaiting claim).
public struct WaitingContext<Asset: key + store> has store {
    asset: asset::AssetCustodyLocked<Asset>,
    state: WaitingState,
}

/// Sub-machine state for the active tenancy. Shared fields live in TenancyContext.
public enum TenancyState<phantom Asset: key + store, phantom CoinType> has store {
    Occupied { tenant: Tenant<CoinType>, retire: RetireCondition },
    Demand   { current: Tenant<CoinType>, pending: Tenant<CoinType>, handover_expiry: Timestamp, bidding_cycles: Cycles, retire: RetireCondition },
}

/// Resolved tenancy parameters: the policy values drawn at install time
/// plus phase_start and committed_cycles. Mutated only at handover, where
/// ceiling/handover get rescaled by the new bidder's cycles and committed_cycles
/// becomes the new bidder's commitment.
///
/// `copy` enables ergonomic in-place field updates during handover.
public struct TenancyEnvelope has copy, drop, store {
    phase_start:       Timestamp,
    resolved_floor:    Price,
    resolved_ceiling:  Duration,
    resolved_handover: Duration,
    committed_cycles:  Cycles,  // per-cycle rate = stake / committed_cycles
}

/// Context-State carrier for the active tenancy sub-machine embedded in
/// AssetState::Renting.
///
///   · asset    — present in all tenancy states; extracted here so match arms
///                never repeat it.
///   · envelope — resolved policy + commitment params (see TenancyEnvelope).
///   · state    — Occupied (single tenant) or Demand (tenant + pending bidder).
///                Each variant embeds a RetireCondition; no separate bool.
public struct TenancyContext<Asset: key + store, phantom CoinType> has store {
    asset:    asset::AssetCustodyOpen<Asset>,
    envelope: TenancyEnvelope,
    state:    TenancyState<Asset, CoinType>,
}

/// Typed return of `do_tenure_expiry`. Hot-potato — must be destructured at
/// the call site. Named fields prevent positional swap between same-typed
/// Price/Duration values. The asset is already in `Locked` custody —
/// tenure has ended, so the borrow protocol is no longer applicable.
public struct TenureExpiryResult<Asset: key + store> {
    asset:             asset::AssetCustodyLocked<Asset>,
    last_acq_price:    Price,
    resolved_floor:    Price,
    resolved_ceiling:  Duration,
    resolved_handover: Duration,
}

/// Result of do_apt_transition. Co-resident with fire — matched directly
/// via nested struct pattern, no accessor functions needed.
public enum RentingFireResultState<Asset: key + store, phantom CoinType> {
    /// Demand → Occupied handover completed; tenancy stays active.
    Handover {
        tenancy: TenancyContext<Asset, CoinType>,
    },
    /// Occupied tenure expired; caller decides AtDutch vs Retired.
    /// The asset is already in `Locked` custody — no `unlock` step at the call site.
    TenureExpired {
        asset:             asset::AssetCustodyLocked<Asset>,
        last_acq_price:    Price,
        resolved_floor:    Price,
        resolved_ceiling:  Duration,
        resolved_handover: Duration,
        retire:            RetireCondition,
    },
}

/// Context envelope: everything the lifecycle FSM carries that is not the
/// state itself nor the earnings ledger.
///
///   · Bedrock (never mutated): fee_inbox_id, integrated_at, escrow_id.
///   · Policy (rarely mutated): config + pending_config (via update_config),
///     commitment_policy + commitment_anchor (via extend_commitment).
///
/// `copy` enables ergonomic field-assignment in the few sites that mutate it
/// without forcing a full destructure/rebuild.
public struct ContextEnvelope has copy, drop, store {
    config:            IntegrationConfig,
    pending_config:    Option<IntegrationConfig>,
    fee_inbox_id:      FeeInboxIdentity,
    integrated_at:     Timestamp,
    commitment_policy: CommitmentPolicyState,
    commitment_anchor: Timestamp,
    escrow_id:         EscrowIdentity,
}

/// Central engine: lifecycle state + owner ledger + context envelope.
/// Stored in Escrow as Option<AssetContext> to enable by-value extraction.
public struct AssetContext<Asset: key + store, phantom CoinType> has store {
    asset_state: AssetState<Asset, CoinType>,
    owner:       Owner<CoinType>,
    envelope:    ContextEnvelope,
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

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###
// (AssetContext has store only — not directly observable by SDK; wrappers in runtime_projection.move)

// === Public Functions ===

// ─── Constructor ──────────────────────────────────────────────────────────────

/// Construct a fresh engine. Called once at integrate time.
public(package) fun new<Asset: key + store, CoinType>(
    asset:             Asset,
    owner_cap_id:      OwnerCapIdentity,
    config:            IntegrationConfig,
    commitment_policy: CommitmentPolicyState,
    fee_inbox_id:      FeeInboxIdentity,
    integrated_at_ms:  u64,
    escrow_id:         EscrowIdentity,
    generator:         &mut RandomGenerator,
): AssetContext<Asset, CoinType> {
    let resolved_floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(&config), generator);
    let resolved_ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(&config), generator);
    let resolved_handover = handover_policy_state::resolve(config::proj_handover(&config), resolved_ceiling, generator);
    let integrated_at     = phases::timestamp(integrated_at_ms);
    AssetContext {
        asset_state: AssetState::Waiting { waiting: WaitingContext { asset: asset::lock(asset), state: WaitingState::Idle { resolved_floor, resolved_ceiling, resolved_handover } } },
        owner:       owner::new<CoinType>(owner_cap_id),
        envelope:    ContextEnvelope {
            config,
            pending_config:    option::none(),
            fee_inbox_id,
            integrated_at,
            commitment_policy,
            commitment_anchor: integrated_at,
            escrow_id,
        },
    }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun proj_is_active<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::Retired => false, _ => true },
        AssetState::Renting { .. } => true,
    }
}

public(package) fun proj_is_inactive<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool { !proj_is_active(e) }

// ─── Context accessors ────────────────────────────────────────────────────────

public(package) fun proj_config<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): &IntegrationConfig { &e.envelope.config }

public(package) fun proj_fee_inbox_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID { protocol_fee_ref::inbox_id(e.envelope.fee_inbox_id) }

public(package) fun proj_integrated_at<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Timestamp { e.envelope.integrated_at }

public(package) fun proj_escrow_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID { escrow_identity::escrow_id(e.envelope.escrow_id) }

public(package) fun proj_pending_config<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<IntegrationConfig> { e.envelope.pending_config }

public(package) fun proj_commitment_policy<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): CommitmentPolicyState { e.envelope.commitment_policy }

public(package) fun proj_commitment_anchor<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Timestamp { e.envelope.commitment_anchor }

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun proj_asset_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID {
    match (&e.asset_state) {
        AssetState::Waiting { waiting }  => asset::proj_locked_id(&waiting.asset),
        AssetState::Renting { tenancy }  => asset_id_for_tenancy(tenancy),
    }
}

public(package) fun proj_owner_balance<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Stake {
    owner::proj_value(&e.owner)
}

public(package) fun proj_owner_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): ID {
    owner_cap::cap_id(owner::proj_cap_id(owner::proj_identity(&e.owner)))
}

// ─── State predicate views (SDK surface via escrow.move) ──────────────────────

public(package) fun proj_is_idle<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::Idle { .. } => true, _ => false },
        _ => false,
    }
}

public(package) fun proj_is_at_dutch<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) { WaitingState::AtDutch { .. } => true, _ => false },
        _ => false,
    }
}

/// True iff there is an active tenancy (Occupied or Demand).
public(package) fun proj_is_rented<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Renting { .. } => true, _ => false }
}

/// True iff renting and tenancy is Occupied (no pending bid yet).
public(package) fun proj_is_handover_open<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => is_occupied(tenancy),
        _ => false,
    }
}

/// True iff renting and tenancy is Demand (pending bidder present).
public(package) fun proj_is_handover_confirmed<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => is_demand(tenancy),
        _ => false,
    }
}

public(package) fun proj_is_retiring<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) { AssetState::Renting { tenancy } => is_retiring(tenancy), _ => false }
}

// ─── Tenant data views (Option variants — only present in Renting) ────────────

public(package) fun proj_current_addr<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<address> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(current_addr(tenancy)),
        _ => option::none(),
    }
}

public(package) fun proj_current_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<ID> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenant_cap::cap_id(current_cap_id(tenancy))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_addr<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<address> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => pending_addr_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_pending_cap_id<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<ID> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => {
            let opt = pending_cap_id_for_tenancy(tenancy);
            if (opt.is_some()) option::some(tenant_cap::cap_id(*opt.borrow()))
            else option::none()
        },
        _ => option::none(),
    }
}

public(package) fun proj_current_stake<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Stake> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(current_stake(tenancy)),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake_value<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Stake {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => current_stake(tenancy),
        _ => abort ENotRented,
    }
}

public(package) fun proj_pending_stake<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Stake> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => pending_stake_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_phase_start<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(phase_start(tenancy)),
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { phase_start, .. } => option::some(*phase_start),
            _ => option::none(),
        },
    }
}

public(package) fun proj_handover_expiry<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => handover_expiry_for_tenancy(tenancy),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_ceiling<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Duration> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy.envelope.resolved_ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_handover<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Duration> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy.envelope.resolved_handover),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_floor<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Price> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(tenancy.envelope.resolved_floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_floor<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Price> {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::Idle    { resolved_floor, .. } => option::some(*resolved_floor),
            WaitingState::AtDutch { resolved_floor, .. } => option::some(*resolved_floor),
            _ => option::none(),
        },
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_ceiling<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Duration> {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::Idle    { resolved_ceiling, .. } => option::some(*resolved_ceiling),
            WaitingState::AtDutch { resolved_ceiling, .. } => option::some(*resolved_ceiling),
            _ => option::none(),
        },
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_handover<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Duration> {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::Idle    { resolved_handover, .. } => option::some(*resolved_handover),
            WaitingState::AtDutch { resolved_handover, .. } => option::some(*resolved_handover),
            _ => option::none(),
        },
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_descent<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Duration> {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { resolved_descent, .. } => option::some(*resolved_descent),
            _ => option::none(),
        },
        _ => option::none(),
    }
}

public(package) fun proj_last_acq_price<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Price> {
    match (&e.asset_state) {
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { last_acq_price, .. } => option::some(*last_acq_price),
            _ => option::none(),
        },
        _ => option::none(),
    }
}

public(package) fun proj_credit_stake<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Stake> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(credit_state::proj_stake(&credit_context_for_tenancy(tenancy))),
        _ => option::none(),
    }
}

public(package) fun proj_credit_phase_start<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => option::some(credit_state::proj_phase_start(&credit_context_for_tenancy(tenancy))),
        _ => option::none(),
    }
}

public(package) fun proj_credit_is_accruing<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => credit_state::proj_is_accruing(&credit_context_for_tenancy(tenancy)),
        _ => false,
    }
}

public(package) fun proj_credit_is_capped<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): bool {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => credit_state::proj_is_capped(&credit_context_for_tenancy(tenancy)),
        _ => false,
    }
}

public(package) fun proj_credit_expiry<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => credit_state::proj_expiry(&credit_context_for_tenancy(tenancy)),
        _ => option::none(),
    }
}

// ─── Pricing views ────────────────────────────────────────────────────────────

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    e:   &AssetContext<Asset, CoinType>,
    now: Timestamp,
): Price {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            floor_price_at_for_tenancy(tenancy, &e.envelope.config, now),
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::Idle { resolved_floor, .. } => *resolved_floor,
            WaitingState::AtDutch { last_acq_price, phase_start, resolved_floor, resolved_descent, .. } => {
                let ps = price_state::descending(*last_acq_price, *phase_start, *resolved_floor, *resolved_descent);
                price_state::floor_price(&ps, &e.envelope.config, now)
            },
            WaitingState::Retired => abort ERetiredNoBid,
        },
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    e:   &AssetContext<Asset, CoinType>,
    now: Timestamp,
): Stake {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            used_credit_at_for_tenancy(tenancy, &e.envelope.config, now),
        _ => abort ENotRented,
    }
}

/// Typed settlement for a handover boundary: (remaining_credit, owner_share, protocol_fee).
/// Extraction to u64 happens in escrow at the PTB boundary.
public(package) fun proj_handover_settlement<Asset: key + store, CoinType>(
    e:   &AssetContext<Asset, CoinType>,
    now: Timestamp,
): (Stake, Stake, Stake) {
    let stake = proj_current_stake_value(e);
    let used  = used_credit_at(e, now);
    let alloc = split_fee(used);
    (
        monetary::stake(monetary::stake_mist(stake) - monetary::stake_mist(used)),
        alloc.owner_share,
        alloc.protocol_fee,
    )
}

/// Typed settlement for a tenure expiry: (owner_share, protocol_fee).
/// Extraction to u64 happens in escrow at the PTB boundary.
public(package) fun proj_tenure_settlement<Asset: key + store, CoinType>(
    e: &AssetContext<Asset, CoinType>,
): (Stake, Stake) {
    assert!(proj_is_rented(e), ENotRented);
    let alloc = split_fee(proj_current_stake_value(e));
    (alloc.owner_share, alloc.protocol_fee)
}



// ─── Cap-authorization view ───────────────────────────────────────────────────

public(package) fun cap_authorization_state<Asset: key + store, CoinType>(
    e:      &AssetContext<Asset, CoinType>,
    cap_id: TenantCapIdentity,
): CapAuthorizationState {
    match (&e.asset_state) {
        AssetState::Renting { tenancy } => cap_auth_for_tenancy(tenancy, cap_id),
        _ => CapAuthorizationState::Stale,
    }
}

// ─── APT and pending detection ────────────────────────────────────────────────

public(package) fun next_pending<Asset: key + store, CoinType>(
    e:     &AssetContext<Asset, CoinType>,
    clock: &Clock,
): Option<PendingTransitionState> {
    let now = phases::now(clock);
    match (&e.asset_state) {
        AssetState::Renting { tenancy } =>
            next_pending_from_tenancy(tenancy, now),
        AssetState::Waiting { waiting } => match (&waiting.state) {
            WaitingState::AtDutch { phase_start, resolved_descent, .. } => {
                let start = *phase_start;
                if (descent_policy_state::has_expired(*resolved_descent, start, now).is_crossed()) {
                    return option::some(
                        pending_transition_state::auction(descent_policy_state::expiry_at(*resolved_descent, start))
                    )
                };
                option::none()
            },
            WaitingState::Idle { .. } | WaitingState::Retired => option::none(),
        },
    }
}

public(package) fun apply_pending_transition_states<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    random:  &Random,
    clock:   &Clock,
    ctx:     &mut TxContext,
): AssetContext<Asset, CoinType> {
    let mut current = context;
    let mut pending = next_pending(&current, clock);
    while (option::is_some(&pending)) {
        current = fire(current, option::destroy_some(pending), random, ctx);
        pending = next_pending(&current, clock);
    };
    current
}

// ─── Action executors ─────────────────────────────────────────────────────────

public(package) fun execute_rent<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    payment: Coin<CoinType>,
    cycles:  Cycles,
    random:  &Random,
    clock:   &Clock,
    ctx:     &mut TxContext,
): (AssetContext<Asset, CoinType>, TenantCap) {
    tenure_cycles_policy_state::validate(config::proj_tenure_cycles(&context.envelope.config), cycles);
    let context = apply_pending_transition_states(context, random, clock, ctx);
    let now    = phases::now(clock);
    let floor  = floor_price_at(&context, now);
    assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: _a, state: WaitingState::Retired } }, owner: _o, .. } =>
            abort ERetiredNoBid,
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Idle { resolved_floor, resolved_ceiling, resolved_handover } } }, owner, envelope }
        | AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { resolved_floor, resolved_ceiling, resolved_handover, .. } } }, owner, envelope } => {
            let (new_state, cap) = do_install(asset, resolved_floor, resolved_ceiling, resolved_handover, cycles, envelope.escrow_id, payment, floor, now, ctx);
            (AssetContext { asset_state: new_state, owner, envelope }, cap)
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, envelope } => {
            let (new_tenancy, cap) = accept_rent_payment(
                tenancy, &mut owner, envelope.escrow_id, envelope.fee_inbox_id, payment, floor, cycles, now, ctx,
            );
            (AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }, cap)
        },
    }
}

public(package) fun execute_retire<Asset: key + store, CoinType>(
    context:   AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): AssetContext<Asset, CoinType> {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == context.envelope.escrow_id, EWrongEscrowOwnerCap);
    let context = apply_pending_transition_states(context, random, clock, ctx);
    let now     = phases::now(clock);
    assert!(
        commitment_policy_state::is_unlocked(
            commitment_policy_state::resolve(&context.envelope.commitment_policy),
            context.envelope.commitment_anchor,
            now,
        ).is_crossed(),
        ECommitmentFloorNotElapsed,
    );
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: _a, state: WaitingState::Retired } }, owner: _o, .. } =>
            abort EAlreadyRetired,
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: _ } }, owner, mut envelope } => {
            envelope.pending_config = option::none();
            AssetContext { asset_state: do_retire_immediately(asset, envelope.escrow_id, now, ctx), owner, envelope }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, mut envelope } => {
            envelope.pending_config = option::none();
            let new_tenancy = set_retiring_flag(tenancy, envelope.escrow_id, now, ctx);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }
        },
    }
}

public(package) fun execute_update_config<Asset: key + store, CoinType>(
    context:   AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    new_cfg:   IntegrationConfig,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): AssetContext<Asset, CoinType> {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == context.envelope.escrow_id, EWrongEscrowOwnerCap);
    let context = apply_pending_transition_states(context, random, clock, ctx);
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: _a, state: WaitingState::Retired } }, owner: _o, .. } =>
            abort EAlreadyRetired,
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Idle { .. } } }, owner, mut envelope } => {
            let mut generator = sui::random::new_generator(random, ctx);
            let new_floor     = floor_price_policy_state::resolve(config::proj_min_rent_price(&new_cfg), &mut generator);
            let new_ceiling   = tenure_policy_state::resolve(config::proj_tenure_ceiling(&new_cfg), &mut generator);
            let new_handover  = handover_policy_state::resolve(config::proj_handover(&new_cfg), new_ceiling, &mut generator);
            event::emit(ConfigUpdated { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), new_config: new_cfg });
            envelope.config = new_cfg;
            envelope.pending_config = option::none();
            AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Idle { resolved_floor: new_floor, resolved_ceiling: new_ceiling, resolved_handover: new_handover } } }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } } }, owner, mut envelope } => {
            event::emit(ConfigUpdateScheduled { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), new_config: new_cfg });
            envelope.pending_config = option::some(new_cfg);
            AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } } }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, mut envelope } => {
            assert!(!is_retiring(&tenancy), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), new_config: new_cfg });
            envelope.pending_config = option::some(new_cfg);
            AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope }
        },
    }
}

public(package) fun execute_borrow<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    tenant_cap: &TenantCap,
    random:     &Random,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (AssetContext<Asset, CoinType>, Asset, AssetReceipt) {
    let context = apply_pending_transition_states(context, random, clock, ctx);
    assert!(tenant_cap::proj_escrow_identity(tenant_cap) == context.envelope.escrow_id, EWrongEscrowTenantCap);
    let cap_identity = tenant_cap::identity(tenant_cap);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope } => {
            let (new_tenancy, u, receipt) = take_asset(tenancy, envelope.escrow_id, cap_identity);
            (AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }, u, receipt)
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort EStaleTenantCap,
    }
}

public(package) fun execute_return<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope } => {
            let new_tenancy = put_asset(tenancy, envelope.escrow_id, asset_in, receipt_in);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort EReceiptEscrowMismatch,
    }
}

public(package) fun execute_burn_tenant_cap<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    cap:     TenantCap,
    random:  &Random,
    clock:   &Clock,
    ctx:     &mut TxContext,
): AssetContext<Asset, CoinType> {
    let context = apply_pending_transition_states(context, random, clock, ctx);
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, envelope } => {
            let is_retired = match (&waiting.state) { WaitingState::Retired => true, _ => false };
            if (!is_retired) { assert!(tenant_cap::proj_escrow_identity(&cap) == envelope.escrow_id, EWrongEscrowTenantCap) };
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Waiting { waiting }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope } => {
            assert!(tenant_cap::proj_escrow_identity(&cap) == envelope.escrow_id, EWrongEscrowTenantCap);
            match (cap_auth_for_tenancy(&tenancy, tenant_cap::identity(&cap))) {
                CapAuthorizationState::Stale => {},
                _ => abort ETenantCapNotStale,
            };
            tenant_cap::burn(cap, ctx);
            AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope }
        },
    }
}

public(package) fun execute_withdraw_earnings<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (AssetContext<Asset, CoinType>, Coin<CoinType>) {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == context.envelope.escrow_id, EWrongEscrowOwnerCap);
    let context       = apply_pending_transition_states(context, random, clock, ctx);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();
    let AssetContext { asset_state, mut owner, envelope } = context;
    let (coin, amount) = do_withdraw(&mut owner, owner_cap, ctx);
    event::emit(EarningsWithdrawn { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), owner_cap_id, owner: owner_addr, amount: monetary::stake_mist(amount), timestamp_ms });
    (AssetContext { asset_state, owner, envelope }, coin)
}

/// Extend the owner's permanence commitment. The new expiry must be ≥ the
/// current expiry — the commitment can only grow, never shrink.
public(package) fun execute_extend_commitment<Asset: key + store, CoinType>(
    context:    AssetContext<Asset, CoinType>,
    owner_cap:  &OwnerCap,
    new_policy: CommitmentPolicyState,
    clock:      &Clock,
): AssetContext<Asset, CoinType> {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == context.envelope.escrow_id, EWrongEscrowOwnerCap);
    let now         = phases::now(clock);
    let old_expiry  = commitment_policy_state::unlock_at(
        commitment_policy_state::resolve(&context.envelope.commitment_policy),
        context.envelope.commitment_anchor,
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
        escrow_id:     escrow_identity::escrow_id(context.envelope.escrow_id),
        new_policy,
        new_expiry_ms: phases::timestamp_ms(new_expiry),
        timestamp_ms:  phases::timestamp_ms(now),
    });
    let AssetContext { asset_state, owner, mut envelope } = context;
    envelope.commitment_policy = new_policy;
    envelope.commitment_anchor = now;
    AssetContext { asset_state, owner, envelope }
}

/// Terminal action: settle pending transitions, assert retired, unwrap asset and earnings.
public(package) fun execute_claim<Asset: key + store, CoinType>(
    context:   AssetContext<Asset, CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    assert!(owner_cap::proj_escrow_identity(owner_cap) == context.envelope.escrow_id, EWrongEscrowOwnerCap);
    let context = apply_pending_transition_states(context, random, clock, ctx);
    assert!(proj_is_inactive(&context), ENotRetired);
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }, mut owner, .. } => {
            let coin = owner::withdraw(&mut owner, owner_cap, ctx);
            owner::destroy_empty(owner);
            (asset::unlock(asset), coin)
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRetired,
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRetired,
    }
}

// ─── Tenancy-state content (merged) ─────────────────────────────────────────

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

// ─── Constructor ──────────────────────────────────────────────────────────────

public(package) fun new_tenancy_envelope(
    phase_start:       Timestamp,
    resolved_floor:    Price,
    resolved_ceiling:  Duration,
    resolved_handover: Duration,
    committed_cycles:  Cycles,
): TenancyEnvelope {
    TenancyEnvelope { phase_start, resolved_floor, resolved_ceiling, resolved_handover, committed_cycles }
}

public(package) fun new_occupied<Asset: key + store, CoinType>(
    asset:    asset::AssetCustodyOpen<Asset>,
    tenant:   Tenant<CoinType>,
    envelope: TenancyEnvelope,
): TenancyContext<Asset, CoinType> {
    TenancyContext { asset, envelope, state: TenancyState::Occupied { tenant, retire: retire_condition::new() } }
}

// ─── Variant predicates ───────────────────────────────────────────────────────

public(package) fun is_occupied<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): bool {
    match (&t.state) { TenancyState::Occupied { .. } => true, _ => false }
}

public(package) fun is_demand<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): bool {
    match (&t.state) { TenancyState::Demand { .. } => true, _ => false }
}

public(package) fun is_retiring<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): bool {
    match (&t.state) {
        TenancyState::Occupied { retire, .. } | TenancyState::Demand { retire, .. } =>
            retire_condition::proj_is_retiring(retire),
    }
}

// ─── Identity views ───────────────────────────────────────────────────────────

public(package) fun asset_id_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): ID {
    asset::proj_asset_id(&t.asset)
}

public(package) fun current_addr<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): address {
    match (&t.state) {
        TenancyState::Occupied { tenant, .. } =>
            tenant::proj_address(tenant::proj_identity(tenant)),
        TenancyState::Demand { current, .. } =>
            tenant::proj_address(tenant::proj_identity(current)),
    }
}

public(package) fun current_cap_id<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): TenantCapIdentity {
    match (&t.state) {
        TenancyState::Occupied { tenant, .. } =>
            tenant::proj_cap_id(tenant::proj_identity(tenant)),
        TenancyState::Demand { current, .. } =>
            tenant::proj_cap_id(tenant::proj_identity(current)),
    }
}

public(package) fun pending_addr_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<address> {
    match (&t.state) {
        TenancyState::Demand { pending, .. } =>
            option::some(tenant::proj_address(tenant::proj_identity(pending))),
        TenancyState::Occupied { .. } => option::none(),
    }
}

public(package) fun pending_cap_id_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<TenantCapIdentity> {
    match (&t.state) {
        TenancyState::Demand { pending, .. } =>
            option::some(tenant::proj_cap_id(tenant::proj_identity(pending))),
        TenancyState::Occupied { .. } => option::none(),
    }
}

public(package) fun current_stake<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Stake {
    match (&t.state) {
        TenancyState::Occupied { tenant, .. } => tenant::proj_stake_value(tenant),
        TenancyState::Demand { current, .. }  => tenant::proj_stake_value(current),
    }
}

public(package) fun pending_stake_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<Stake> {
    match (&t.state) {
        TenancyState::Demand { pending, .. } => option::some(tenant::proj_stake_value(pending)),
        TenancyState::Occupied { .. }        => option::none(),
    }
}

public(package) fun phase_start<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Timestamp {
    t.envelope.phase_start
}

public(package) fun handover_expiry_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): Option<Timestamp> {
    match (&t.state) {
        TenancyState::Demand { handover_expiry, .. } => option::some(*handover_expiry),
        TenancyState::Occupied { .. }                => option::none(),
    }
}

// ─── Pricing / credit views ───────────────────────────────────────────────────

public(package) fun floor_price_at_for_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    config: &IntegrationConfig,
    now:    Timestamp,
): Price {
    // Floor is per-cycle: price_function(stake / committed_cycles).
    // Competitors pay floor × their_cycles, so the market competes on rate,
    // not total commitment.
    let (stake, n) = match (&t.state) {
        TenancyState::Occupied { tenant, .. } =>
            (tenant::proj_stake_value(tenant), t.envelope.committed_cycles),
        TenancyState::Demand { pending, bidding_cycles, .. } =>
            (tenant::proj_stake_value(pending), *bidding_cycles),
    };
    let ps = price_state::ascending(cycles::per_cycle_stake(stake, n));
    price_state::floor_price(&ps, config, now)
}

fun credit_context_for_tenancy<Asset: key + store, CoinType>(
    t: &TenancyContext<Asset, CoinType>,
): credit_state::CreditContext {
    match (&t.state) {
        TenancyState::Occupied { tenant, .. } =>
            credit_state::accruing(tenant::proj_stake_value(tenant), t.envelope.phase_start),
        TenancyState::Demand { current, handover_expiry, .. } =>
            credit_state::capped(tenant::proj_stake_value(current), t.envelope.phase_start, *handover_expiry),
    }
}

public(package) fun used_credit_at_for_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    config: &IntegrationConfig,
    now:    Timestamp,
): Stake {
    let cs = match (&t.state) {
        TenancyState::Occupied { tenant, .. } =>
            credit_state::accruing(tenant::proj_stake_value(tenant), t.envelope.phase_start),
        TenancyState::Demand { current, handover_expiry, .. } =>
            credit_state::capped(
                tenant::proj_stake_value(current),
                t.envelope.phase_start,
                *handover_expiry,
            ),
    };
    credit_state::used_credit(&cs, config, t.envelope.resolved_ceiling, now)
}

// ─── Cap authorization view ───────────────────────────────────────────────────

public(package) fun cap_auth_for_tenancy<Asset: key + store, CoinType>(
    t:      &TenancyContext<Asset, CoinType>,
    cap_id: TenantCapIdentity,
): CapAuthorizationState {
    match (&t.state) {
        TenancyState::Occupied { tenant, .. } => {
            if (cap_id == tenant::proj_cap_id(tenant::proj_identity(tenant))) CapAuthorizationState::Current
            else CapAuthorizationState::Stale
        },
        TenancyState::Demand { current, pending, .. } => {
            if      (cap_id == tenant::proj_cap_id(tenant::proj_identity(current))) CapAuthorizationState::Current
            else if (cap_id == tenant::proj_cap_id(tenant::proj_identity(pending))) CapAuthorizationState::Pending
            else CapAuthorizationState::Stale
        },
    }
}

// ─── APT pending detection ────────────────────────────────────────────────────

public(package) fun next_pending_from_tenancy<Asset: key + store, CoinType>(
    t:   &TenancyContext<Asset, CoinType>,
    now: Timestamp,
): Option<PendingTransitionState> {
    match (&t.state) {
        TenancyState::Demand { handover_expiry, .. } => {
            if (phases::check_boundary(*handover_expiry, phases::zero(), now).is_crossed()) {
                return option::some(pending_transition_state::handover(*handover_expiry))
            };
            option::none()
        },
        TenancyState::Occupied { .. } => {
            let start   = t.envelope.phase_start;
            let ceiling = t.envelope.resolved_ceiling;
            if (phases::check_boundary(start, ceiling, now).is_crossed()) {
                return option::some(
                    pending_transition_state::tenure(phases::boundary_at(start, ceiling))
                )
            };
            option::none()
        },
    }
}

// ─── Tenancy-internal transitions ─────────────────────────────────────────────

/// Dispatch a rent payment: Occupied → Demand (place_bid) or Demand → Demand
/// (supersede_bid). Owner receives the displaced bidder's refund only in the
/// supersede path; passes through unchanged for a fresh bid.
public(package) fun accept_rent_payment<Asset: key + store, CoinType>(
    tenancy:      TenancyContext<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    escrow_id:    EscrowIdentity,
    fee_inbox_id: FeeInboxIdentity,
    payment:      Coin<CoinType>,
    floor:        Price,
    cycles:       Cycles,
    now:          Timestamp,
    ctx:          &mut TxContext,
): (TenancyContext<Asset, CoinType>, TenantCap) {
    let TenancyContext { asset, envelope, state } = tenancy;
    match (state) {
        TenancyState::Occupied { tenant, retire } => {
            if (retire_condition::proj_is_retiring(&retire)) abort ERetireFlagBlocksBid;
            do_place_bid(asset, tenant, envelope, cycles, escrow_id, payment, floor, now, ctx)
        },
        TenancyState::Demand { current, pending, handover_expiry, bidding_cycles: _, retire } =>
            do_supersede_bid(
                asset, current, pending, handover_expiry, envelope, cycles,
                retire,
                owner, escrow_id, fee_inbox_id, payment, floor, now, ctx,
            ),
    }
}

/// Dispatch the pending APT transition. Match lives here so engine_state::fire
/// receives a typed result and never inspects TenancyState variant internals.
/// Owner is mutated in-place; caller (Engine) owns it and passes &mut.
public(package) fun do_apt_transition<Asset: key + store, CoinType>(
    tenancy:      TenancyContext<Asset, CoinType>,
    owner:        &mut Owner<CoinType>,
    config:       &IntegrationConfig,
    escrow_id:    EscrowIdentity,
    fee_inbox_id: FeeInboxIdentity,
    boundary:     Timestamp,
    ctx:          &mut TxContext,
): RentingFireResultState<Asset, CoinType> {
    let TenancyContext { asset, envelope, state } = tenancy;
    match (state) {
        TenancyState::Demand { current, pending, handover_expiry: _, bidding_cycles, retire } => {
            let new_tenancy = do_handover(
                asset, current, pending, envelope, bidding_cycles,
                retire,
                owner, config, escrow_id, fee_inbox_id, boundary, ctx,
            );
            RentingFireResultState::Handover { tenancy: new_tenancy }
        },
        TenancyState::Occupied { tenant, retire } => {
            let TenureExpiryResult { asset: locked, last_acq_price, resolved_floor, resolved_ceiling, resolved_handover } = do_tenure_expiry(
                asset, tenant, envelope,
                owner, escrow_id, fee_inbox_id, boundary, ctx,
            );
            RentingFireResultState::TenureExpired { asset: locked, last_acq_price, resolved_floor, resolved_ceiling, resolved_handover, retire }
        },
    }
}

/// Demand → Occupied: fire the handover transition at `boundary_ms`.
/// Distributes used credit to owner; retiring flag propagates to new Occupied.
fun do_handover<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyOpen<Asset>,
    current:         Tenant<CoinType>,
    pending:         Tenant<CoinType>,
    mut envelope:    TenancyEnvelope,
    bidding_cycles:  Cycles,
    retire:          RetireCondition,
    owner:           &mut Owner<CoinType>,
    config:          &IntegrationConfig,
    escrow_id:       EscrowIdentity,
    fee_inbox_id:    FeeInboxIdentity,
    boundary:        Timestamp,
    ctx:             &mut TxContext,
): TenancyContext<Asset, CoinType> {
    let principal   = tenant::proj_stake_value(&current);
    let used_credit = {
        let cs = credit_state::capped(principal, envelope.phase_start, boundary);
        credit_state::used_credit(&cs, config, envelope.resolved_ceiling, boundary)
    };
    let alloc         = split_fee(used_credit);
    let remain_credit = monetary::stake_sub(principal, used_credit);

    let displaced_cap_id = tenant::proj_cap_id(tenant::proj_identity(&current));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&current));

    let mut departing  = current;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_id);
    let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, owner, fee_inbox_id, ctx);

    let new_cap_id     = tenant::proj_cap_id(tenant::proj_identity(&pending));
    let new_addr       = tenant::proj_address(tenant::proj_identity(&pending));
    let new_stake      = tenant::proj_stake_value(&pending);
    let new_rent_price = monetary::price_mist({
        let ps = price_state::ascending(new_stake);
        price_state::floor_price(&ps, config, boundary)
    });
    let boundary_ms = phases::timestamp_ms(boundary);

    event::emit(HandoverCompleted {
        escrow_id: escrow_identity::escrow_id(escrow_id),
        displaced_tenant_cap_id:  tenant_cap::cap_id(displaced_cap_id),
        displaced_tenant:         displaced_addr,
        displaced_phase_start_ms: phases::timestamp_ms(envelope.phase_start),
        new_tenant_cap_id:        tenant_cap::cap_id(new_cap_id),
        new_tenant_addr:          new_addr,
        new_tenant_stake:         monetary::stake_mist(new_stake),
        used_credit:              monetary::stake_mist(used_credit),
        owner_share:              monetary::stake_mist(alloc.owner_share),
        protocol_fee:             monetary::stake_mist(alloc.protocol_fee),
        remain_credit:            monetary::stake_mist(remain_credit),
        new_rent_price,
        timestamp_ms:             boundary_ms,
    });

    let old_cycles = envelope.committed_cycles;
    envelope.resolved_ceiling  = cycles::rescale_duration(envelope.resolved_ceiling,  old_cycles, bidding_cycles);
    envelope.resolved_handover = cycles::rescale_duration(envelope.resolved_handover, old_cycles, bidding_cycles);
    envelope.committed_cycles  = bidding_cycles;
    envelope.phase_start       = boundary;
    let state = TenancyState::Occupied { tenant: pending, retire };
    TenancyContext { asset, envelope, state }
}

/// Consume an Occupied tenancy at tenure expiry. Distributes full stake to
/// owner/protocol. Returns a `TenureExpiryResult` carrying the wrapped asset
/// and the per-cycle-normalized policy values for the next phase.
/// The retire condition flows through the enum variant at the call site, not here.
fun do_tenure_expiry<Asset: key + store, CoinType>(
    asset:        asset::AssetCustodyOpen<Asset>,
    tenant:       Tenant<CoinType>,
    envelope:     TenancyEnvelope,
    owner:        &mut Owner<CoinType>,
    escrow_id:    EscrowIdentity,
    fee_inbox_id: FeeInboxIdentity,
    boundary:     Timestamp,
    ctx:          &mut TxContext,
): TenureExpiryResult<Asset> {
    let principal      = tenant::proj_stake_value(&tenant);
    let tenant_cap_id  = tenant::proj_cap_id(tenant::proj_identity(&tenant));
    let tenant_addr    = tenant::proj_address(tenant::proj_identity(&tenant));
    let alloc = split_fee(principal);

    let mut departing  = tenant;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_id);
    let (_, stake)     = tenant::unbundle(departing);
    tenant::destroy_empty_stake(stake);
    refund_state::distribute(refund_state::nothing(fee_share, owner_earnings), owner, fee_inbox_id, ctx);

    event::emit(TenureExpired {
        escrow_id: escrow_identity::escrow_id(escrow_id),
        tenant_cap_id: tenant_cap::cap_id(tenant_cap_id),
        tenant:                 tenant_addr,
        phase_start_ms:         phases::timestamp_ms(envelope.phase_start),
        owner_share:            monetary::stake_mist(alloc.owner_share),
        protocol_fee:           monetary::stake_mist(alloc.protocol_fee),
        last_acquisition_price: monetary::stake_mist(principal),
        timestamp_ms:           phases::timestamp_ms(boundary),
    });

    // Normalize extended ceiling/handover back to per-cycle base.
    // The AtDutch/Idle that follows belongs to the next tenant's cycle, not this one's.
    let base_ceiling  = cycles::rescale_duration(envelope.resolved_ceiling,  envelope.committed_cycles, cycles::cycles(1));
    let base_handover = cycles::rescale_duration(envelope.resolved_handover, envelope.committed_cycles, cycles::cycles(1));
    // Tenure has ended: switch custody type. close_tenancy asserts the asset
    // is actually present (not on loan) — the borrow protocol is over.
    TenureExpiryResult {
        asset:             asset::close_tenancy(asset),
        last_acq_price:    monetary::as_reference_price(principal),
        resolved_floor:    envelope.resolved_floor,
        resolved_ceiling:  base_ceiling,
        resolved_handover: base_handover,
    }
}

/// Set the retiring flag on the current tenancy (Occupied or Demand).
/// Emits RetireFlagSet. Aborts if already retiring (via retire_condition::set).
public(package) fun set_retiring_flag<Asset: key + store, CoinType>(
    tenancy:   TenancyContext<Asset, CoinType>,
    escrow_id: EscrowIdentity,
    now:       Timestamp,
    ctx:       &TxContext,
): TenancyContext<Asset, CoinType> {
    event::emit(RetireFlagSet { escrow_id: escrow_identity::escrow_id(escrow_id), owner: ctx.sender(), timestamp_ms: phases::timestamp_ms(now) });
    let TenancyContext { asset, envelope, state } = tenancy;
    let state = match (state) {
        TenancyState::Occupied { tenant, retire } =>
            TenancyState::Occupied { tenant, retire: retire_condition::set(retire) },
        TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire } =>
            TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire: retire_condition::set(retire) },
    };
    TenancyContext { asset, envelope, state }
}

/// Borrow the underlying asset. Aborts if `cap_id` is stale or pending.
public(package) fun take_asset<Asset: key + store, CoinType>(
    tenancy:   TenancyContext<Asset, CoinType>,
    escrow_id: EscrowIdentity,
    cap_id:    TenantCapIdentity,
): (TenancyContext<Asset, CoinType>, Asset, AssetReceipt) {
    let auth = cap_auth_for_tenancy(&tenancy, cap_id);
    let TenancyContext { mut asset, envelope, state } = tenancy;
    let (tenant_addr, state) = match (state) {
        TenancyState::Occupied { tenant, retire } => {
            match (auth) {
                CapAuthorizationState::Current => (tenant::proj_address(tenant::proj_identity(&tenant)), TenancyState::Occupied { tenant, retire }),
                CapAuthorizationState::Pending => abort EPendingTenantCap,
                CapAuthorizationState::Stale   => abort EStaleTenantCap,
            }
        },
        TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire } => {
            match (auth) {
                CapAuthorizationState::Current => {
                    let addr = tenant::proj_address(tenant::proj_identity(&current));
                    (addr, TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire })
                },
                CapAuthorizationState::Pending => abort EPendingTenantCap,
                CapAuthorizationState::Stale   => abort EStaleTenantCap,
            }
        },
    };
    let (u, receipt) = asset::take(&mut asset);
    event::emit(AssetBorrowed { escrow_id: escrow_identity::escrow_id(escrow_id), tenant_cap_id: tenant_cap::cap_id(cap_id), tenant: tenant_addr });
    (TenancyContext { asset, envelope, state }, u, receipt)
}

/// Return the borrowed asset.
public(package) fun put_asset<Asset: key + store, CoinType>(
    tenancy:    TenancyContext<Asset, CoinType>,
    escrow_id:  EscrowIdentity,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): TenancyContext<Asset, CoinType> {
    let TenancyContext { mut asset, envelope, state } = tenancy;
    let (tenant_cap_id, tenant_addr) = match (&state) {
        TenancyState::Occupied { tenant, .. } => (
            tenant::proj_cap_id(tenant::proj_identity(tenant)),
            tenant::proj_address(tenant::proj_identity(tenant)),
        ),
        TenancyState::Demand { current, .. } => (
            tenant::proj_cap_id(tenant::proj_identity(current)),
            tenant::proj_address(tenant::proj_identity(current)),
        ),
    };
    asset::put(&mut asset, asset_in, receipt_in);
    event::emit(AssetReturned { escrow_id: escrow_identity::escrow_id(escrow_id), tenant_cap_id: tenant_cap::cap_id(tenant_cap_id), tenant: tenant_addr });
    TenancyContext { asset, envelope, state }
}

// === Private Functions ===

/// Occupied → Demand.
fun do_place_bid<Asset: key + store, CoinType>(
    asset:     asset::AssetCustodyOpen<Asset>,
    tenant:    Tenant<CoinType>,
    envelope:  TenancyEnvelope,
    cycles:    Cycles,
    escrow_id: EscrowIdentity,
    payment:   Coin<CoinType>,
    floor:     Price,
    now:       Timestamp,
    ctx:       &mut TxContext,
): (TenancyContext<Asset, CoinType>, TenantCap) {
    let current_cap_id = tenant::proj_cap_id(tenant::proj_identity(&tenant));
    let current_addr   = tenant::proj_address(tenant::proj_identity(&tenant));
    let current_stake  = tenant::proj_stake_value(&tenant);
    let expiry         = handover_policy_state::expiry_at(envelope.resolved_handover, envelope.resolved_ceiling, now, envelope.phase_start);
    let pending_addr = ctx.sender();
    let bid_amount   = coin::value(&payment);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_id);
    let cap          = tenant_cap::new(escrow_id, pending_addr, ctx);
    let cap_identity = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, pending_addr, coin::into_balance(payment));
    event::emit(BidPlaced {
        escrow_id: raw_escrow_id,
        current_tenant_cap_id:     tenant_cap::cap_id(current_cap_id),
        current_tenant_addr:       current_addr,
        current_tenant_stake:      monetary::stake_mist(current_stake),
        current_phase_start_ms:    phases::timestamp_ms(envelope.phase_start),
        tenant_cap_id:             tenant_cap::cap_id(cap_identity),
        pending_tenant:            pending_addr,
        bid_amount,
        floor_price:               monetary::price_mist(floor),
        handover_countdown_expiry: phases::timestamp_ms(expiry),
        timestamp_ms:              phases::timestamp_ms(now),
    });
    (
        TenancyContext {
            asset,
            envelope,
            state: TenancyState::Demand { current: tenant, pending: t, handover_expiry: expiry, bidding_cycles: cycles, retire: retire_condition::new() },
        },
        cap,
    )
}

/// Demand → Demand: displace the existing pending bidder.
fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyOpen<Asset>,
    current:         Tenant<CoinType>,
    pending:         Tenant<CoinType>,
    handover_expiry: Timestamp,
    envelope:        TenancyEnvelope,
    cycles:          Cycles,
    retire:          RetireCondition,
    owner:           &mut Owner<CoinType>,
    escrow_id:       EscrowIdentity,
    fee_inbox_id:    FeeInboxIdentity,
    payment:         Coin<CoinType>,
    floor:           Price,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (TenancyContext<Asset, CoinType>, TenantCap) {
    let protected_cap_id = tenant::proj_cap_id(tenant::proj_identity(&current));
    let protected_addr   = tenant::proj_address(tenant::proj_identity(&current));
    let protected_stake  = tenant::proj_stake_value(&current);
    let displaced_cap_id = tenant::proj_cap_id(tenant::proj_identity(&pending));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&pending));
    let refunded_amount  = tenant::proj_stake_value(&pending);

    let raw_escrow_id = escrow_identity::escrow_id(escrow_id);
    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);
    let cap          = tenant_cap::new(escrow_id, new_bidder, ctx);
    let cap_identity = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, new_bidder, coin::into_balance(payment));

    let refund = refund_state::from_superseded(pending);
    refund_state::distribute(refund, owner, fee_inbox_id, ctx);

    event::emit(BidSuperseded {
        escrow_id: raw_escrow_id,
        protected_tenant_cap_id:   tenant_cap::cap_id(protected_cap_id),
        protected_tenant_addr:     protected_addr,
        protected_tenant_stake:    monetary::stake_mist(protected_stake),
        protected_phase_start_ms:  phases::timestamp_ms(envelope.phase_start),
        displaced_tenant_cap_id:   tenant_cap::cap_id(displaced_cap_id),
        new_tenant_cap_id:         tenant_cap::cap_id(cap_identity),
        displaced_bidder:          displaced_addr,
        refunded_amount:           monetary::stake_mist(refunded_amount),
        new_bidder,
        new_bid_amount,
        floor_price:               monetary::price_mist(floor),
        handover_countdown_expiry: phases::timestamp_ms(handover_expiry),
        timestamp_ms:              phases::timestamp_ms(now),
    });
    let state = TenancyState::Demand { current, pending: t, handover_expiry, bidding_cycles: cycles, retire };
    (TenancyContext { asset, envelope, state }, cap)
}

// === Test Functions ===

public(package) fun emit_retire_flag_set(escrow_id: ID, owner: address, timestamp_ms: u64) {
    event::emit(RetireFlagSet { escrow_id, owner, timestamp_ms });
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    let alloc = split_fee(monetary::stake(amount));
    (monetary::stake_mist(alloc.owner_share), monetary::stake_mist(alloc.protocol_fee))
}

#[test_only]
public(package) fun set_retiring_flag_for_testing<Asset: key + store, CoinType>(
    tenancy: TenancyContext<Asset, CoinType>,
): TenancyContext<Asset, CoinType> {
    let TenancyContext { asset, envelope, state } = tenancy;
    let state = match (state) {
        TenancyState::Occupied { tenant, retire } =>
            TenancyState::Occupied { tenant, retire: retire_condition::set_for_testing(retire) },
        TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire } =>
            TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire: retire_condition::set_for_testing(retire) },
    };
    TenancyContext { asset, envelope, state }
}

/// Drive Occupied → Demand for testing (without full bid mechanics).
#[test_only]
fun tenancy_drive_to_demand_for_testing<Asset: key + store, CoinType>(
    asset:                     asset::AssetCustodyOpen<Asset>,
    tenant:                    Tenant<CoinType>,
    phase_start:               Timestamp,
    resolved_floor:            Price,
    resolved_ceiling:          Duration,
    resolved_handover:         Duration,
    tenant_in:                 Tenant<CoinType>,
    handover_countdown_expiry: Timestamp,
): TenancyContext<Asset, CoinType> {
    TenancyContext {
        asset,
        envelope: new_tenancy_envelope(phase_start, resolved_floor, resolved_ceiling, resolved_handover, cycles::cycles(1)),
        state: TenancyState::Demand { current: tenant, pending: tenant_in, handover_expiry: handover_countdown_expiry, bidding_cycles: cycles::cycles(1), retire: retire_condition::new() },
    }
}

/// Consume an Occupied tenancy for test state driving. Discards tenant funds.
#[test_only]
fun unbundle_occupied_for_testing<Asset: key + store, CoinType>(
    asset:        asset::AssetCustodyOpen<Asset>,
    mut tenant:   Tenant<CoinType>,
    owner_amount: u64,
    fee_amount:   u64,
    escrow_id:    EscrowIdentity,
): asset::AssetCustodyOpen<Asset> {
    let owner_earnings = tenant::take_owner_earnings(&mut tenant, monetary::stake(owner_amount));
    let fee_share      = tenant::take_fee_share(&mut tenant, monetary::stake(fee_amount), escrow_id);
    let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
    refund_state::destroy_for_testing(refund);
    asset
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

// === Private Functions ===

fun fire<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    t:       PendingTransitionState,
    random:  &Random,
    ctx:     &mut TxContext,
): AssetContext<Asset, CoinType> {
    let boundary = pending_transition_state::proj_boundary(&t);
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, mut owner, mut envelope } => {
            match (do_apt_transition(tenancy, &mut owner, &envelope.config, envelope.escrow_id, envelope.fee_inbox_id, boundary, ctx)) {
                RentingFireResultState::Handover { tenancy: new_tenancy } =>
                    AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope },
                RentingFireResultState::TenureExpired { asset, last_acq_price, resolved_floor, resolved_ceiling, resolved_handover, retire } => {
                    let boundary_ms = phases::timestamp_ms(boundary);
                    // P5/P10 boundary crossing: RetireCondition's variants live in
                    // retire_condition.move, so we project here to branch the asset state.
                    if (retire_condition::proj_is_retiring(&retire)) {
                        event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), timestamp_ms: boundary_ms });
                        envelope.pending_config = option::none();
                        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }, owner, envelope }
                    } else {
                        let mut generator    = sui::random::new_generator(random, ctx);
                        let resolved_descent = descent_policy_state::resolve(config::proj_descent(&envelope.config), &mut generator);
                        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start: boundary, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } } }, owner, envelope }
                    }
                },
            }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start, resolved_floor: _, resolved_ceiling: _, resolved_handover: _, resolved_descent: _ } } }, owner, mut envelope } => {
            if (option::is_some(&envelope.pending_config)) {
                let new_cfg = option::destroy_some(envelope.pending_config);
                event::emit(ConfigUpdated { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), new_config: new_cfg });
                envelope.config = new_cfg;
                envelope.pending_config = option::none();
            };
            let mut generator = sui::random::new_generator(random, ctx);
            let new_state = do_auction_expiry(asset, last_acq_price, phase_start, &envelope.config, envelope.escrow_id, boundary, &mut generator);
            AssetContext { asset_state: new_state, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
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
    locked:            asset::AssetCustodyLocked<Asset>,
    resolved_floor:    Price,
    resolved_ceiling:  Duration,
    resolved_handover: Duration,
    cycles:            Cycles,
    escrow_id:         EscrowIdentity,
    payment:           Coin<CoinType>,
    floor:             Price,
    now:               Timestamp,
    ctx:               &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let price_paid    = coin::value(&payment);
    let tenant_addr   = ctx.sender();
    let now_ms        = phases::timestamp_ms(now);
    let raw_escrow_id  = escrow_identity::escrow_id(escrow_id);
    let cap            = tenant_cap::new(escrow_id, tenant_addr, ctx);
    let cap_identity   = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, tenant_addr, coin::into_balance(payment));
    let wrapped = asset::open_tenancy(locked, escrow_id);
    let extended_ceiling  = cycles::total_duration(resolved_ceiling,  cycles);
    let extended_handover = cycles::total_duration(resolved_handover, cycles);
    event::emit(RentStarted {
        escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr,
        phase_start_ms: now_ms, price_paid, floor_price: monetary::price_mist(floor),
    });
    let envelope = new_tenancy_envelope(now, resolved_floor, extended_ceiling, extended_handover, cycles);
    (AssetState::Renting { tenancy: new_occupied(wrapped, t, envelope) }, cap)
}

fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:          asset::AssetCustodyLocked<Asset>,
    last_acq_price: Price,
    phase_start:    Timestamp,
    config:         &IntegrationConfig,
    escrow_id:      EscrowIdentity,
    boundary:       Timestamp,
    generator:      &mut RandomGenerator,
): AssetState<Asset, CoinType> {
    event::emit(AuctionExpired { escrow_id: escrow_identity::escrow_id(escrow_id), phase_start_ms: phases::timestamp_ms(phase_start), last_acq_price: monetary::price_mist(last_acq_price), timestamp_ms: phases::timestamp_ms(boundary) });
    let resolved_floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(config), generator);
    let resolved_ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(config), generator);
    let resolved_handover = handover_policy_state::resolve(config::proj_handover(config), resolved_ceiling, generator);
    AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Idle { resolved_floor, resolved_ceiling, resolved_handover } } }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:     asset::AssetCustodyLocked<Asset>,
    escrow_id: EscrowIdentity,
    now:       Timestamp,
    ctx:       &TxContext,
): AssetState<Asset, CoinType> {
    let timestamp_ms  = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_id);
    emit_retire_flag_set(raw_escrow_id, ctx.sender(), timestamp_ms);
    event::emit(AssetRetired { escrow_id: raw_escrow_id, timestamp_ms });
    AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }
}

// === Test Functions ===


#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, envelope: tenancy_env, state: TenancyState::Demand { current, pending, handover_expiry: _, bidding_cycles, retire } } }, mut owner, envelope } => {
            let new_tenancy = do_handover(
                asset, current, pending, tenancy_env, bidding_cycles,
                retire,
                &mut owner, &envelope.config, envelope.escrow_id, envelope.fee_inbox_id, boundary, ctx,
            );
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, envelope: _env, state: TenancyState::Occupied { tenant: _tn, retire: _r } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_tenure_expiry_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, envelope: tenancy_env, state: TenancyState::Occupied { tenant, retire } } }, mut owner, mut envelope } => {
            let TenureExpiryResult { asset: locked, last_acq_price, resolved_floor, resolved_ceiling, resolved_handover } = do_tenure_expiry(
                asset, tenant, tenancy_env,
                &mut owner, envelope.escrow_id, envelope.fee_inbox_id, boundary, ctx,
            );
            let boundary_ms = phases::timestamp_ms(boundary);
            if (retire_condition::proj_is_retiring(&retire)) {
                event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(envelope.escrow_id), timestamp_ms: boundary_ms });
                envelope.pending_config = option::none();
                AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: locked, state: WaitingState::Retired } }, owner, envelope }
            } else {
                AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: locked, state: WaitingState::AtDutch { last_acq_price, phase_start: boundary, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent: descent_policy_state::resolve(config::proj_descent(&envelope.config), &mut sui::random::new_generator_from_seed_for_testing(vector[0u8])) } } }, owner, envelope }
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, envelope: _env, state: TenancyState::Demand { current: _c, pending: _p2, handover_expiry: _e, bidding_cycles: _, retire: _r } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    context:   AssetContext<Asset, CoinType>,
    boundary:  Timestamp,
    generator: &mut RandomGenerator,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, envelope } => {
            let WaitingContext { asset, state } = waiting;
            match (state) {
                WaitingState::AtDutch { last_acq_price, phase_start, resolved_floor: _, resolved_ceiling: _, resolved_handover: _, resolved_descent: _ } =>
                    AssetContext { asset_state: do_auction_expiry(asset, last_acq_price, phase_start, &envelope.config, envelope.escrow_id, boundary, generator), owner, envelope },
                _ => abort ENotRented,
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    context:     AssetContext<Asset, CoinType>,
    tenant_in:   tenant::Tenant<CoinType>,
    phase_start: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, envelope } => {
            let WaitingContext { asset, state } = waiting;
            match (state) {
                WaitingState::Idle { resolved_floor, resolved_ceiling, resolved_handover } => {
                    let tenancy_env = new_tenancy_envelope(phase_start, resolved_floor, resolved_ceiling, resolved_handover, cycles::cycles(1));
                    let tenancy = new_occupied(asset::open_tenancy(asset, envelope.escrow_id), tenant_in, tenancy_env);
                    AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope }
                },
                _ => abort ENotRented,
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    tenant_in:                 usufruct::tenant::Tenant<CoinType>,
    handover_countdown_expiry: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, envelope: tenancy_env, state: TenancyState::Occupied { tenant, retire } } }, owner, envelope } => {
            let new_tenancy = tenancy_drive_to_demand_for_testing(
                asset, tenant, tenancy_env.phase_start, tenancy_env.resolved_floor, tenancy_env.resolved_ceiling, tenancy_env.resolved_handover, tenant_in, handover_countdown_expiry,
            );
            // Preserve retire condition carried over from Occupied into the resulting Demand.
            let TenancyContext { asset: a2, envelope: env2, state } = new_tenancy;
            let state = match (state) {
                TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire: _ } =>
                    TenancyState::Demand { current, pending, handover_expiry, bidding_cycles, retire },
                s => s,
            };
            let new_tenancy = TenancyContext { asset: a2, envelope: env2, state };
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, envelope: _env, state: TenancyState::Demand { current: _c, pending: _p2, handover_expiry: _e, bidding_cycles: _, retire: _r } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_at_dutch_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
    owner_amount:    u64,
    fee_amount:      u64,
    last_acq_price:  u64,
    new_phase_start: Timestamp,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset, envelope: tenancy_env, state: TenancyState::Occupied { tenant, retire: _ } } }, owner, envelope } => {
            let wrapped = unbundle_occupied_for_testing(
                asset, tenant, owner_amount, fee_amount, envelope.escrow_id,
            );
            AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset: asset::close_tenancy(wrapped), state: WaitingState::AtDutch { last_acq_price: monetary::price(last_acq_price), phase_start: new_phase_start, resolved_floor: tenancy_env.resolved_floor, resolved_ceiling: tenancy_env.resolved_ceiling, resolved_handover: tenancy_env.resolved_handover, resolved_descent: descent_policy_state::resolve(config::proj_descent(&envelope.config), &mut sui::random::new_generator_from_seed_for_testing(vector[0u8])) } } }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: TenancyContext { asset: _a, envelope: _env, state: TenancyState::Demand { current: _c, pending: _p2, handover_expiry: _e, bidding_cycles: _, retire: _r } } }, owner: _o, .. } => abort ENotRented,
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Waiting { waiting }, owner, envelope } => {
            let WaitingContext { asset, state } = waiting;
            match (state) {
                WaitingState::Idle { .. } =>
                    AssetContext { asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::Retired } }, owner, envelope },
                _ => abort ENotRented,
            }
        },
        AssetContext { asset_state: AssetState::Renting { tenancy: _t }, owner: _o, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    context: AssetContext<Asset, CoinType>,
): AssetContext<Asset, CoinType> {
    match (context) {
        AssetContext { asset_state: AssetState::Renting { tenancy }, owner, envelope } => {
            let new_tenancy = set_retiring_flag_for_testing(tenancy);
            AssetContext { asset_state: AssetState::Renting { tenancy: new_tenancy }, owner, envelope }
        },
        AssetContext { asset_state: AssetState::Waiting { waiting: _w }, owner: _o, .. } => abort ENotRented,
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
