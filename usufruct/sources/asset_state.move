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
/// `RentingDispatch` and `FirableDispatch` narrow `AssetState` to the
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
/// Co-resident with asset_state so match arms can branch on variants
/// directly — Move restricts pattern access to the defining module.
///
///   · `Current` — cap belongs to the active tenant. May borrow.
///   · `Pending` — cap belongs to the pending bidder (Demand). May not borrow.
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
    config:             IntegrationConfig,
    pending_config:     Option<IntegrationConfig>,
    fee_inbox_identity: FeeInboxIdentity,
    integrated_at:      Timestamp,
    commitment_policy:  CommitmentPolicyState,
    commitment_anchor:  Timestamp,
    escrow_identity:    EscrowIdentity,
}

public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Idle     { asset: asset::AssetCustodyLocked<Asset>, resolved_floor: Price, resolved_ceiling: Duration, resolved_handover: Duration },
    AtDutch  { asset: asset::AssetCustodyLocked<Asset>, last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price, resolved_ceiling: Duration, resolved_handover: Duration, resolved_descent: Duration },
    Retired  { asset: asset::AssetCustodyLocked<Asset> },
    Occupied { asset: asset::AssetCustodyOpen<Asset>, envelope: TenancyEnvelope, current: Tenant<CoinType>, retire: RetireCondition },
    Demand   { asset: asset::AssetCustodyOpen<Asset>, envelope: TenancyEnvelope, current: Tenant<CoinType>, pending: Tenant<CoinType>, handover_expiry: Timestamp, bidding_cycles: Cycles, retire: RetireCondition },
}

// ─── Sub-dispatchers for narrow contracts ─────────────────────────────────────
//
// `RentingDispatch` narrows `AssetState` to the two states where a
// tenancy is active (Occupied, Demand). Functions that only make sense on
// a Renting state take this type — the wider storage enum cannot reach
// them. `FirableDispatch` narrows to the three states that can fire an
// APT transition (AtDutch, Occupied, Demand); Idle and Retired are absent
// by construction, so `fire` cannot be called with a non-firable state.
//
// Variant shapes mirror `AssetState`'s respective variants 1:1;
// translation between storage and a sub-dispatcher is one move per arm,
// no intermediate type.

public enum RentingDispatch<Asset: key + store, phantom CoinType> {
    Occupied { asset: asset::AssetCustodyOpen<Asset>, envelope: TenancyEnvelope, current: Tenant<CoinType>, retire: RetireCondition },
    Demand   { asset: asset::AssetCustodyOpen<Asset>, envelope: TenancyEnvelope, current: Tenant<CoinType>, pending: Tenant<CoinType>, handover_expiry: Timestamp, bidding_cycles: Cycles, retire: RetireCondition },
}

public enum FirableDispatch<Asset: key + store, phantom CoinType> {
    AtDutch  { asset: asset::AssetCustodyLocked<Asset>, last_acq_price: Price, phase_start: Timestamp, resolved_floor: Price, resolved_ceiling: Duration, resolved_handover: Duration, resolved_descent: Duration },
    Occupied { asset: asset::AssetCustodyOpen<Asset>, envelope: TenancyEnvelope, current: Tenant<CoinType>, retire: RetireCondition },
    Demand   { asset: asset::AssetCustodyOpen<Asset>, envelope: TenancyEnvelope, current: Tenant<CoinType>, pending: Tenant<CoinType>, handover_expiry: Timestamp, bidding_cycles: Cycles, retire: RetireCondition },
}

/// Result of inspecting an `AssetState` for a due APT transition.
/// `Settled` carries the storage back unchanged (no transition is due);
/// `Pending` carries a `FirableDispatch` + the transition to fire. The
/// hot-potato discipline guarantees the caller must consume exactly one
/// branch — there is no path where the state silently disappears.
public enum AptStep<Asset: key + store, phantom CoinType> {
    Settled { s: AssetState<Asset, CoinType> },
    Pending {
        firable:    FirableDispatch<Asset, CoinType>,
        transition: PendingTransitionState,
    },
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

/// Construct a fresh integration. Called once by `escrow::integrate`.
/// Returns the two on-disk slots that the Escrow shared object will
/// carry: the core (owner ledger + policies + identities) and the
/// initial lifecycle state (always Idle).
public(package) fun new<Asset: key + store, CoinType>(
    asset:              Asset,
    owner_cap_identity: OwnerCapIdentity,
    config:             IntegrationConfig,
    commitment_policy:  CommitmentPolicyState,
    fee_inbox_identity: FeeInboxIdentity,
    integrated_at_ms:   u64,
    escrow_identity:    EscrowIdentity,
    generator:          &mut RandomGenerator,
): (EscrowCore<CoinType>, AssetState<Asset, CoinType>) {
    let resolved_floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(&config), generator);
    let resolved_ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(&config), generator);
    let resolved_handover = handover_policy_state::resolve(config::proj_handover(&config), resolved_ceiling, generator);
    let integrated_at     = phases::timestamp(integrated_at_ms);
    let core = EscrowCore {
        owner:              owner::new<CoinType>(owner_cap_identity),
        config,
        pending_config:     option::none(),
        fee_inbox_identity,
        integrated_at,
        commitment_policy,
        commitment_anchor:  integrated_at,
        escrow_identity,
    };
    let state = AssetState::Idle {
        asset: asset::lock(asset),
        resolved_floor,
        resolved_ceiling,
        resolved_handover,
    };
    (core, state)
}

// ─── Storage ↔ sub-dispatcher (RentingDispatch only) ─────────────────────────
//
// `widen_renting` lifts a `RentingDispatch` (Occupied | Demand) back into
// the wider `AssetState`. Total by construction — every Renting
// variant maps 1:1. Used by `execute_borrow` / `execute_return` to fold
// the result of the narrow `*_renting` helper back into storage form.

public(package) fun widen_renting<Asset: key + store, CoinType>(
    r: RentingDispatch<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (r) {
        RentingDispatch::Occupied { asset, envelope, current, retire } =>
            AssetState::Occupied { asset, envelope, current, retire },
        RentingDispatch::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } =>
            AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire },
    }
}

// ─── Core (owner + policy + identity) views ──────────────────────────────────

public(package) fun proj_config<CoinType>(
    core: &EscrowCore<CoinType>,
): &IntegrationConfig { &core.config }

public(package) fun proj_fee_inbox_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID { protocol_fee_ref::inbox_id(core.fee_inbox_identity) }

public(package) fun proj_integrated_at<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.integrated_at }

public(package) fun proj_pending_config<CoinType>(
    core: &EscrowCore<CoinType>,
): Option<IntegrationConfig> { core.pending_config }

public(package) fun proj_commitment_policy<CoinType>(
    core: &EscrowCore<CoinType>,
): CommitmentPolicyState { core.commitment_policy }

public(package) fun proj_commitment_anchor<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.commitment_anchor }

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

public(package) fun proj_is_inactive<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool { !proj_is_active(s) }

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
        AssetState::Occupied { retire, .. } | AssetState::Demand { retire, .. } =>
            retire_condition::proj_is_retiring(retire),
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
        AssetState::Occupied { current, .. } | AssetState::Demand { current, .. } =>
            option::some(tenant::proj_address(tenant::proj_identity(current))),
        _ => option::none(),
    }
}

public(package) fun proj_current_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Occupied { current, .. } | AssetState::Demand { current, .. } =>
            option::some(tenant_cap::cap_id(tenant::proj_cap_identity(tenant::proj_identity(current)))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Demand { pending, .. } =>
            option::some(tenant::proj_address(tenant::proj_identity(pending))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Demand { pending, .. } =>
            option::some(tenant_cap::cap_id(tenant::proj_cap_identity(tenant::proj_identity(pending)))),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Occupied { current, .. } | AssetState::Demand { current, .. } =>
            option::some(tenant::proj_stake_value(current)),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake_value<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Stake {
    match (s) {
        AssetState::Occupied { current, .. } | AssetState::Demand { current, .. } =>
            tenant::proj_stake_value(current),
        _ => abort ENotRented,
    }
}

public(package) fun proj_pending_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Demand { pending, .. } =>
            option::some(tenant::proj_stake_value(pending)),
        _ => option::none(),
    }
}

public(package) fun proj_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Occupied { envelope, .. } | AssetState::Demand { envelope, .. } =>
            option::some(envelope.phase_start),
        AssetState::AtDutch { phase_start, .. } =>
            option::some(*phase_start),
        _ => option::none(),
    }
}

public(package) fun proj_handover_expiry<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Demand { handover_expiry, .. } => option::some(*handover_expiry),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Occupied { envelope, .. } | AssetState::Demand { envelope, .. } =>
            option::some(envelope.resolved_ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Occupied { envelope, .. } | AssetState::Demand { envelope, .. } =>
            option::some(envelope.resolved_handover),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Occupied { envelope, .. } | AssetState::Demand { envelope, .. } =>
            option::some(envelope.resolved_floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Idle    { resolved_floor, .. } => option::some(*resolved_floor),
        AssetState::AtDutch { resolved_floor, .. } => option::some(*resolved_floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Idle    { resolved_ceiling, .. } => option::some(*resolved_ceiling),
        AssetState::AtDutch { resolved_ceiling, .. } => option::some(*resolved_ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Idle    { resolved_handover, .. } => option::some(*resolved_handover),
        AssetState::AtDutch { resolved_handover, .. } => option::some(*resolved_handover),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_descent<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::AtDutch { resolved_descent, .. } => option::some(*resolved_descent),
        _ => option::none(),
    }
}

public(package) fun proj_last_acq_price<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::AtDutch { last_acq_price, .. } => option::some(*last_acq_price),
        _ => option::none(),
    }
}

public(package) fun proj_credit_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Occupied { current, .. } | AssetState::Demand { current, .. } =>
            option::some(tenant::proj_stake_value(current)),
        _ => option::none(),
    }
}

public(package) fun proj_credit_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Occupied { envelope, .. } | AssetState::Demand { envelope, .. } =>
            option::some(envelope.phase_start),
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
        AssetState::Demand { handover_expiry, .. } => option::some(*handover_expiry),
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
        AssetState::Idle { resolved_floor, .. } => *resolved_floor,
        AssetState::AtDutch { last_acq_price, phase_start, resolved_floor, resolved_descent, .. } => {
            let ps = price_state::descending(*last_acq_price, *phase_start, *resolved_floor, *resolved_descent);
            price_state::floor_price(&ps, &core.config, now)
        },
        AssetState::Retired { .. } => abort ERetiredNoBid,
        AssetState::Occupied { envelope, current, .. } => {
            let ps = price_state::ascending(cycles::per_cycle_stake(tenant::proj_stake_value(current), envelope.committed_cycles));
            price_state::floor_price(&ps, &core.config, now)
        },
        AssetState::Demand { envelope: _, pending, bidding_cycles, .. } => {
            let ps = price_state::ascending(cycles::per_cycle_stake(tenant::proj_stake_value(pending), *bidding_cycles));
            price_state::floor_price(&ps, &core.config, now)
        },
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Stake {
    match (s) {
        AssetState::Occupied { envelope, current, .. } => {
            let cs = credit_state::accruing(tenant::proj_stake_value(current), envelope.phase_start);
            credit_state::used_credit(&cs, &core.config, envelope.resolved_ceiling, now)
        },
        AssetState::Demand { envelope, current, handover_expiry, .. } => {
            let cs = credit_state::capped(tenant::proj_stake_value(current), envelope.phase_start, *handover_expiry);
            credit_state::used_credit(&cs, &core.config, envelope.resolved_ceiling, now)
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

// ─── Cap-authorization view ───────────────────────────────────────────────────

public(package) fun cap_authorization_state<Asset: key + store, CoinType>(
    s:            &AssetState<Asset, CoinType>,
    cap_identity: TenantCapIdentity,
): CapAuthorizationState {
    match (s) {
        AssetState::Occupied { current, .. } => {
            if (cap_identity == tenant::proj_cap_identity(tenant::proj_identity(current)))
                CapAuthorizationState::Current
            else
                CapAuthorizationState::Stale
        },
        AssetState::Demand { current, pending, .. } => {
            if      (cap_identity == tenant::proj_cap_identity(tenant::proj_identity(current))) CapAuthorizationState::Current
            else if (cap_identity == tenant::proj_cap_identity(tenant::proj_identity(pending))) CapAuthorizationState::Pending
            else CapAuthorizationState::Stale
        },
        _ => CapAuthorizationState::Stale,
    }
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
        AssetState::AtDutch { phase_start, resolved_descent, .. } => {
            if (descent_policy_state::has_expired(*resolved_descent, *phase_start, now).is_crossed()) {
                option::some(pending_transition_state::auction(descent_policy_state::expiry_at(*resolved_descent, *phase_start)))
            } else {
                option::none()
            }
        },
        AssetState::Occupied { envelope, .. } => {
            let start   = envelope.phase_start;
            let ceiling = envelope.resolved_ceiling;
            if (phases::check_boundary(start, ceiling, now).is_crossed()) {
                option::some(pending_transition_state::tenure(phases::boundary_at(start, ceiling)))
            } else {
                option::none()
            }
        },
        AssetState::Demand { handover_expiry, .. } => {
            if (phases::check_boundary(*handover_expiry, phases::zero(), now).is_crossed()) {
                option::some(pending_transition_state::handover(*handover_expiry))
            } else {
                option::none()
            }
        },
    }
}

/// Inspect a state and produce an APT step: either `Settled` (no
/// transition due — caller keeps the state unchanged) or `Pending`
/// (transition due — caller proceeds to `fire`, getting a typed
/// `FirableDispatch` it cannot misuse on a non-firable state).
///
/// Idle and Retired always settle. AtDutch / Occupied / Demand settle
/// when their boundary has not been crossed yet, and otherwise transfer
/// into the Pending branch with a FirableDispatch of the same variant.
public(package) fun next_apt_step<Asset: key + store, CoinType>(
    s:     AssetState<Asset, CoinType>,
    clock: &Clock,
): AptStep<Asset, CoinType> {
    let now = phases::now(clock);
    match (s) {
        AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover } =>
            AptStep::Settled { s: AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover } },
        AssetState::Retired { asset } =>
            AptStep::Settled { s: AssetState::Retired { asset } },
        AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } => {
            if (descent_policy_state::has_expired(resolved_descent, phase_start, now).is_crossed()) {
                let transition = pending_transition_state::auction(descent_policy_state::expiry_at(resolved_descent, phase_start));
                AptStep::Pending {
                    firable: FirableDispatch::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent },
                    transition,
                }
            } else {
                AptStep::Settled { s: AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } }
            }
        },
        AssetState::Occupied { asset, envelope, current, retire } => {
            let start   = envelope.phase_start;
            let ceiling = envelope.resolved_ceiling;
            if (phases::check_boundary(start, ceiling, now).is_crossed()) {
                let transition = pending_transition_state::tenure(phases::boundary_at(start, ceiling));
                AptStep::Pending {
                    firable: FirableDispatch::Occupied { asset, envelope, current, retire },
                    transition,
                }
            } else {
                AptStep::Settled { s: AssetState::Occupied { asset, envelope, current, retire } }
            }
        },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            if (phases::check_boundary(handover_expiry, phases::zero(), now).is_crossed()) {
                let transition = pending_transition_state::handover(handover_expiry);
                AptStep::Pending {
                    firable: FirableDispatch::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire },
                    transition,
                }
            } else {
                AptStep::Settled { s: AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } }
            }
        },
    }
}

/// Drain every pending APT transition. Loops `next_apt_step` → `fire`
/// until a `Settled` step is produced. The state is consumed and
/// re-produced each iteration.
public(package) fun apply_pending_transition_states<Asset: key + store, CoinType>(
    s:      AssetState<Asset, CoinType>,
    core:   &mut EscrowCore<CoinType>,
    random: &Random,
    clock:  &Clock,
    ctx:    &mut TxContext,
): AssetState<Asset, CoinType> {
    let mut current = s;
    loop {
        match (next_apt_step(current, clock)) {
            AptStep::Settled { s: settled } => return settled,
            AptStep::Pending { firable, transition } => {
                current = fire(firable, transition, core, random, ctx);
            },
        }
    }
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
    tenure_cycles_policy_state::validate(config::proj_tenure_cycles(&core.config), cycles);
    let now                = phases::now(clock);
    let escrow_identity    = core.escrow_identity;
    let fee_inbox_identity = core.fee_inbox_identity;
    match (s) {
        AssetState::Retired { asset: _retired } => abort ERetiredNoBid,
        AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover } => {
            let floor = resolved_floor;
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_install(asset, resolved_floor, resolved_ceiling, resolved_handover, cycles, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } => {
            let ps    = price_state::descending(last_acq_price, phase_start, resolved_floor, resolved_descent);
            let floor = price_state::floor_price(&ps, &core.config, now);
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_install(asset, resolved_floor, resolved_ceiling, resolved_handover, cycles, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Occupied { asset, envelope, current, retire } => {
            if (retire_condition::proj_is_retiring(&retire)) abort ERetireFlagBlocksBid;
            let stake = tenant::proj_stake_value(&current);
            let ps    = price_state::ascending(cycles::per_cycle_stake(stake, envelope.committed_cycles));
            let floor = price_state::floor_price(&ps, &core.config, now);
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_place_bid(asset, current, envelope, cycles, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            let stake = tenant::proj_stake_value(&pending);
            let ps    = price_state::ascending(cycles::per_cycle_stake(stake, bidding_cycles));
            let floor = price_state::floor_price(&ps, &core.config, now);
            assert!(coin::value(&payment) >= monetary::price_mist(cycles::total_price(floor, cycles)), EInsufficientPayment);
            do_supersede_bid(
                asset, current, pending, handover_expiry, envelope, cycles, retire,
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
            commitment_policy_state::resolve(&core.commitment_policy),
            core.commitment_anchor,
            now,
        ).is_crossed(),
        ECommitmentFloorNotElapsed,
    );
    core.pending_config = option::none();
    let escrow_identity = core.escrow_identity;
    let raw_escrow_id   = escrow_identity::escrow_id(escrow_identity);
    let now_ms          = phases::timestamp_ms(now);
    match (s) {
        AssetState::Retired { asset: _retired } => abort EAlreadyRetired,
        AssetState::Idle { asset, resolved_floor: _, resolved_ceiling: _, resolved_handover: _ } =>
            do_retire_immediately(asset, escrow_identity, now, ctx),
        AssetState::AtDutch { asset, last_acq_price: _, phase_start: _, resolved_floor: _, resolved_ceiling: _, resolved_handover: _, resolved_descent: _ } =>
            do_retire_immediately(asset, escrow_identity, now, ctx),
        AssetState::Occupied { asset, envelope, current, retire } => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms: now_ms });
            AssetState::Occupied { asset, envelope, current, retire: retire_condition::set(retire) }
        },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms: now_ms });
            AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire: retire_condition::set(retire) }
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
        AssetState::Idle { asset, resolved_floor: _, resolved_ceiling: _, resolved_handover: _ } => {
            let mut generator = sui::random::new_generator(random, ctx);
            let new_floor     = floor_price_policy_state::resolve(config::proj_min_rent_price(&new_cfg), &mut generator);
            let new_ceiling   = tenure_policy_state::resolve(config::proj_tenure_ceiling(&new_cfg), &mut generator);
            let new_handover  = handover_policy_state::resolve(config::proj_handover(&new_cfg), new_ceiling, &mut generator);
            event::emit(ConfigUpdated { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.config = new_cfg;
            core.pending_config = option::none();
            AssetState::Idle { asset, resolved_floor: new_floor, resolved_ceiling: new_ceiling, resolved_handover: new_handover }
        },
        AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } => {
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.pending_config = option::some(new_cfg);
            AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent }
        },
        AssetState::Occupied { asset, envelope, current, retire } => {
            assert!(!retire_condition::proj_is_retiring(&retire), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.pending_config = option::some(new_cfg);
            AssetState::Occupied { asset, envelope, current, retire }
        },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            assert!(!retire_condition::proj_is_retiring(&retire), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_cfg });
            core.pending_config = option::some(new_cfg);
            AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire }
        },
    }
}

/// Tenant-gated asset borrow. Narrow contract: only callable on a Renting
/// state (Occupied or Demand). The type guarantees the lifecycle.
///
/// Cap-authorization rules are state-specific:
///   · Occupied — only the current tenant's cap may borrow.
///   · Demand   — the current tenant may borrow; the pending bidder
///                must not (EPendingTenantCap); any other cap is stale.
public(package) fun execute_borrow_renting<Asset: key + store, CoinType>(
    r:          RentingDispatch<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    tenant_cap: &TenantCap,
): (RentingDispatch<Asset, CoinType>, Asset, AssetReceipt) {
    let escrow_identity = core.escrow_identity;
    assert!(tenant_cap::proj_escrow_identity(tenant_cap) == escrow_identity, EWrongEscrowTenantCap);
    let cap_identity = tenant_cap::identity(tenant_cap);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    match (r) {
        RentingDispatch::Occupied { mut asset, envelope, current, retire } => {
            let current_cap = tenant::proj_cap_identity(tenant::proj_identity(&current));
            assert!(cap_identity == current_cap, EStaleTenantCap);
            let tenant_addr = tenant::proj_address(tenant::proj_identity(&current));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            (RentingDispatch::Occupied { asset, envelope, current, retire }, u, receipt)
        },
        RentingDispatch::Demand { mut asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            let current_cap = tenant::proj_cap_identity(tenant::proj_identity(&current));
            let pending_cap = tenant::proj_cap_identity(tenant::proj_identity(&pending));
            if      (cap_identity == current_cap) {}
            else if (cap_identity == pending_cap) abort EPendingTenantCap
            else                                  abort EStaleTenantCap;
            let tenant_addr = tenant::proj_address(tenant::proj_identity(&current));
            let (u, receipt) = asset::take(&mut asset);
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            (RentingDispatch::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire }, u, receipt)
        },
    }
}

/// Entry-point dispatcher for borrow. Same module-pattern constraint as
/// `execute_claim`: narrowing-or-abort must live here, not in escrow.move.
/// Escrow-binding is checked first to preserve legacy abort-code ordering
/// (wrong cap → EWrongEscrowTenantCap before wrong state → EStaleTenantCap).
public(package) fun execute_borrow<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    tenant_cap: &TenantCap,
): (AssetState<Asset, CoinType>, Asset, AssetReceipt) {
    assert!(tenant_cap::proj_escrow_identity(tenant_cap) == core.escrow_identity, EWrongEscrowTenantCap);
    match (s) {
        AssetState::Occupied { asset, envelope, current, retire } => {
            let (new_r, u, receipt) = execute_borrow_renting(RentingDispatch::Occupied { asset, envelope, current, retire }, core, tenant_cap);
            (widen_renting(new_r), u, receipt)
        },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            let (new_r, u, receipt) = execute_borrow_renting(RentingDispatch::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire }, core, tenant_cap);
            (widen_renting(new_r), u, receipt)
        },
        AssetState::Idle    { asset: _a, .. } => abort EStaleTenantCap,
        AssetState::AtDutch { asset: _a, .. } => abort EStaleTenantCap,
        AssetState::Retired { asset: _a }     => abort EStaleTenantCap,
    }
}

/// Tenant-gated asset return. Narrow contract: only callable on a Renting
/// state. The AssetReceipt verifies the borrow lineage; no cap check needed.
public(package) fun execute_return_renting<Asset: key + store, CoinType>(
    r:          RentingDispatch<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): RentingDispatch<Asset, CoinType> {
    let escrow_identity = core.escrow_identity;
    let raw_escrow_id   = escrow_identity::escrow_id(escrow_identity);
    match (r) {
        RentingDispatch::Occupied { mut asset, envelope, current, retire } => {
            let cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&current));
            let tenant_addr  = tenant::proj_address(tenant::proj_identity(&current));
            asset::put(&mut asset, asset_in, receipt_in);
            event::emit(AssetReturned { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            RentingDispatch::Occupied { asset, envelope, current, retire }
        },
        RentingDispatch::Demand { mut asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            let cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&current));
            let tenant_addr  = tenant::proj_address(tenant::proj_identity(&current));
            asset::put(&mut asset, asset_in, receipt_in);
            event::emit(AssetReturned { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            RentingDispatch::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire }
        },
    }
}

/// Entry-point dispatcher for return. Waiting variants abort
/// `EReceiptEscrowMismatch`: the receipt cannot match an escrow that has
/// no open custody.
public(package) fun execute_return<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    asset_in:   Asset,
    receipt_in: AssetReceipt,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Occupied { asset, envelope, current, retire } =>
            widen_renting(execute_return_renting(RentingDispatch::Occupied { asset, envelope, current, retire }, core, asset_in, receipt_in)),
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } =>
            widen_renting(execute_return_renting(RentingDispatch::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire }, core, asset_in, receipt_in)),
        AssetState::Idle    { asset: _a, .. } => abort EReceiptEscrowMismatch,
        AssetState::AtDutch { asset: _a, .. } => abort EReceiptEscrowMismatch,
        AssetState::Retired { asset: _a }     => abort EReceiptEscrowMismatch,
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
/// the type carries no `current`/`pending`, so every cap issued by this
/// escrow is stale by construction. The two Renting variants add the
/// stale check inline, with per-variant scope (Occupied checks only
/// against `current`; Demand checks against both `current` and `pending`).
///
/// Behavior change vs the legacy form: the legacy code skipped the
/// escrow-identity check when the state was Retired. That skip was the
/// bypass for invariant 1 — closed here.
public(package) fun execute_burn_tenant_cap<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    cap:  TenantCap,
    ctx:  &TxContext,
): AssetState<Asset, CoinType> {
    assert!(tenant_cap::proj_escrow_identity(&cap) == core.escrow_identity, EWrongEscrowTenantCap);
    match (s) {
        AssetState::Retired { asset } => {
            tenant_cap::burn(cap, ctx);
            AssetState::Retired { asset }
        },
        AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover } => {
            tenant_cap::burn(cap, ctx);
            AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover }
        },
        AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent } => {
            tenant_cap::burn(cap, ctx);
            AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent }
        },
        AssetState::Occupied { asset, envelope, current, retire } => {
            let cap_identity = tenant_cap::identity(&cap);
            let current_cap  = tenant::proj_cap_identity(tenant::proj_identity(&current));
            assert!(cap_identity != current_cap, ETenantCapNotStale);
            tenant_cap::burn(cap, ctx);
            AssetState::Occupied { asset, envelope, current, retire }
        },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } => {
            let cap_identity = tenant_cap::identity(&cap);
            let current_cap  = tenant::proj_cap_identity(tenant::proj_identity(&current));
            let pending_cap  = tenant::proj_cap_identity(tenant::proj_identity(&pending));
            assert!(cap_identity != current_cap, ETenantCapNotStale);
            assert!(cap_identity != pending_cap, ETenantCapNotStale);
            tenant_cap::burn(cap, ctx);
            AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire }
        },
    }
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
        commitment_policy_state::resolve(&core.commitment_policy),
        core.commitment_anchor,
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
    core.commitment_policy = new_policy;
    core.commitment_anchor = now;
}

/// Terminal action: unwrap a Retired state into the underlying asset and
/// the swept owner earnings. The type guarantees the lifecycle state — no
/// runtime assert on state needed.
///
/// The owner-cap → escrow binding check stays here: it is a precondition
/// of the action ("this cap is allowed to claim from this escrow"), not a
/// property of where the call comes from.
public(package) fun execute_claim_retired<Asset: key + store, CoinType>(
    asset:     asset::AssetCustodyLocked<Asset>,
    core:      EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    let EscrowCore { mut owner, escrow_identity, .. } = core;
    assert!(owner_cap::proj_escrow_identity(owner_cap) == escrow_identity, EWrongEscrowOwnerCap);
    let coin = owner::withdraw(&mut owner, owner_cap, ctx);
    owner::destroy_empty(owner);
    (asset::unlock(asset), coin)
}

/// Entry-point dispatcher for claim. Lives here (not in escrow.move) because
/// Move 2024 restricts pattern access to the defining module — the wrong-state
/// arms have to destructure `AssetState` and `EscrowCore` before
/// aborting, and that destructure must happen inside this module.
///
/// The happy path delegates to `execute_claim_retired`, which is the typed
/// contract: it can only be called with a Retired asset. The other four
/// arms abort `ENotRetired` after consuming the hot-potatoes inline — the
/// abort is reachable from the public API (caller invoked claim while the
/// escrow was in the wrong lifecycle state) and is what `expected_failure`
/// tests exercise.
public(package) fun execute_claim<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    core:      EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    match (s) {
        AssetState::Retired { asset } =>
            execute_claim_retired(asset, core, owner_cap, ctx),
        AssetState::Idle { asset: _a, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
        AssetState::AtDutch { asset: _a, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
        AssetState::Occupied { asset: _a, current: _c, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
        AssetState::Demand { asset: _a, current: _c, pending: _p, .. } => {
            let EscrowCore { owner: _o, .. } = core;
            abort ENotRetired
        },
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

// ─── Tenancy-internal transitions ─────────────────────────────────────────────

/// Demand → Occupied: fire the handover transition at `boundary_ms`.
/// Distributes used credit to owner; retiring flag propagates to new Occupied.
fun do_handover<Asset: key + store, CoinType>(
    asset:              asset::AssetCustodyOpen<Asset>,
    current:            Tenant<CoinType>,
    pending:            Tenant<CoinType>,
    mut envelope:       TenancyEnvelope,
    bidding_cycles:     Cycles,
    retire:             RetireCondition,
    owner:              &mut Owner<CoinType>,
    config:             &IntegrationConfig,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): AssetState<Asset, CoinType> {
    let principal   = tenant::proj_stake_value(&current);
    let used_credit = {
        let cs = credit_state::capped(principal, envelope.phase_start, boundary);
        credit_state::used_credit(&cs, config, envelope.resolved_ceiling, boundary)
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

    let new_cap_identity     = tenant::proj_cap_identity(tenant::proj_identity(&pending));
    let new_addr       = tenant::proj_address(tenant::proj_identity(&pending));
    let new_stake      = tenant::proj_stake_value(&pending);
    let new_rent_price = monetary::price_mist({
        let ps = price_state::ascending(new_stake);
        price_state::floor_price(&ps, config, boundary)
    });
    let boundary_ms = phases::timestamp_ms(boundary);

    event::emit(HandoverCompleted {
        escrow_id: escrow_identity::escrow_id(escrow_identity),
        displaced_tenant_cap_id:  tenant_cap::cap_id(displaced_cap_identity),
        displaced_tenant:         displaced_addr,
        displaced_phase_start_ms: phases::timestamp_ms(envelope.phase_start),
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

    let old_cycles = envelope.committed_cycles;
    envelope.resolved_ceiling  = cycles::rescale_duration(envelope.resolved_ceiling,  old_cycles, bidding_cycles);
    envelope.resolved_handover = cycles::rescale_duration(envelope.resolved_handover, old_cycles, bidding_cycles);
    envelope.committed_cycles  = bidding_cycles;
    envelope.phase_start       = boundary;
    AssetState::Occupied { asset, envelope, current: pending, retire }
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
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:     Timestamp,
    ctx:          &mut TxContext,
): TenureExpiryResult<Asset> {
    let principal      = tenant::proj_stake_value(&tenant);
    let tenant_cap_identity  = tenant::proj_cap_identity(tenant::proj_identity(&tenant));
    let tenant_addr    = tenant::proj_address(tenant::proj_identity(&tenant));
    let alloc = split_fee(principal);

    let mut departing  = tenant;
    let owner_earnings = tenant::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant::take_fee_share(&mut departing, alloc.protocol_fee, escrow_identity);
    let (_, stake)     = tenant::unbundle(departing);
    tenant::destroy_empty_stake(stake);
    refund_state::distribute(refund_state::nothing(fee_share, owner_earnings), owner, fee_inbox_identity, ctx);

    event::emit(TenureExpired {
        escrow_id: escrow_identity::escrow_id(escrow_identity),
        tenant_cap_id: tenant_cap::cap_id(tenant_cap_identity),
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

// === Private Functions ===

/// Occupied → Demand.
fun do_place_bid<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyOpen<Asset>,
    tenant:          Tenant<CoinType>,
    envelope:        TenancyEnvelope,
    cycles:          Cycles,
    escrow_identity: EscrowIdentity,
    payment:         Coin<CoinType>,
    floor:           Price,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let current_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&tenant));
    let current_addr   = tenant::proj_address(tenant::proj_identity(&tenant));
    let current_stake  = tenant::proj_stake_value(&tenant);
    let expiry         = handover_policy_state::expiry_at(envelope.resolved_handover, envelope.resolved_ceiling, now, envelope.phase_start);
    let pending_addr = ctx.sender();
    let bid_amount   = coin::value(&payment);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    let cap          = tenant_cap::new(escrow_identity, pending_addr, ctx);
    let cap_identity = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, pending_addr, coin::into_balance(payment));
    event::emit(BidPlaced {
        escrow_id: raw_escrow_id,
        current_tenant_cap_id:     tenant_cap::cap_id(current_cap_identity),
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
        AssetState::Demand {
            asset,
            envelope,
            current: tenant,
            pending: t,
            handover_expiry: expiry,
            bidding_cycles: cycles,
            retire: retire_condition::new(),
        },
        cap,
    )
}

/// Demand → Demand: displace the existing pending bidder.
fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:              asset::AssetCustodyOpen<Asset>,
    current:            Tenant<CoinType>,
    pending:            Tenant<CoinType>,
    handover_expiry:    Timestamp,
    envelope:           TenancyEnvelope,
    cycles:             Cycles,
    retire:             RetireCondition,
    owner:              &mut Owner<CoinType>,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    payment:            Coin<CoinType>,
    floor:              Price,
    now:                Timestamp,
    ctx:                &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let protected_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&current));
    let protected_addr   = tenant::proj_address(tenant::proj_identity(&current));
    let protected_stake  = tenant::proj_stake_value(&current);
    let displaced_cap_identity = tenant::proj_cap_identity(tenant::proj_identity(&pending));
    let displaced_addr   = tenant::proj_address(tenant::proj_identity(&pending));
    let refunded_amount  = tenant::proj_stake_value(&pending);

    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
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
        protected_phase_start_ms:  phases::timestamp_ms(envelope.phase_start),
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
            envelope,
            current,
            pending: t,
            handover_expiry,
            bidding_cycles: cycles,
            retire,
        },
        cap,
    )
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

/// Fire one APT transition. The `FirableDispatch` precondition is encoded
/// in the type: Idle and Retired cannot reach this function. The output
/// is a wider `AssetState` because the transition may leave the
/// firable subset (Occupied tenure-expiry → Retired; AtDutch
/// auction-expiry → Idle).
///
/// Each arm dispatches to the action helper directly — no intermediate
/// enum: the input variant already tells us which transition fires.
fun fire<Asset: key + store, CoinType>(
    firable:    FirableDispatch<Asset, CoinType>,
    transition: PendingTransitionState,
    core:       &mut EscrowCore<CoinType>,
    random:     &Random,
    ctx:        &mut TxContext,
): AssetState<Asset, CoinType> {
    let boundary = pending_transition_state::proj_boundary(&transition);
    match (firable) {
        FirableDispatch::Demand { asset, envelope, current, pending, handover_expiry: _, bidding_cycles, retire } =>
            do_handover(
                asset, current, pending, envelope, bidding_cycles, retire,
                &mut core.owner, &core.config,
                core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            ),
        FirableDispatch::Occupied { asset, envelope, current, retire } => {
            let TenureExpiryResult { asset: locked, last_acq_price, resolved_floor, resolved_ceiling, resolved_handover } = do_tenure_expiry(
                asset, current, envelope,
                &mut core.owner, core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            );
            let boundary_ms = phases::timestamp_ms(boundary);
            if (retire_condition::proj_is_retiring(&retire)) {
                event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(core.escrow_identity), timestamp_ms: boundary_ms });
                core.pending_config = option::none();
                AssetState::Retired { asset: locked }
            } else {
                let mut generator    = sui::random::new_generator(random, ctx);
                let resolved_descent = descent_policy_state::resolve(config::proj_descent(&core.config), &mut generator);
                AssetState::AtDutch { asset: locked, last_acq_price, phase_start: boundary, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent }
            }
        },
        FirableDispatch::AtDutch { asset, last_acq_price, phase_start, resolved_floor: _, resolved_ceiling: _, resolved_handover: _, resolved_descent: _ } => {
            if (core.pending_config.is_some()) {
                let new_cfg = core.pending_config.extract();
                event::emit(ConfigUpdated { escrow_id: escrow_identity::escrow_id(core.escrow_identity), new_config: new_cfg });
                core.config = new_cfg;
            };
            let mut generator = sui::random::new_generator(random, ctx);
            do_auction_expiry(asset, last_acq_price, phase_start, &core.config, core.escrow_identity, boundary, &mut generator)
        },
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
    escrow_identity:   EscrowIdentity,
    payment:           Coin<CoinType>,
    floor:             Price,
    now:               Timestamp,
    ctx:               &mut TxContext,
): (AssetState<Asset, CoinType>, TenantCap) {
    let price_paid    = coin::value(&payment);
    let tenant_addr   = ctx.sender();
    let now_ms        = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    let cap           = tenant_cap::new(escrow_identity, tenant_addr, ctx);
    let cap_identity  = tenant_cap::identity(&cap);
    let t = tenant::new<CoinType>(cap_identity, tenant_addr, coin::into_balance(payment));
    let wrapped = asset::open_tenancy(locked, escrow_identity);
    let extended_ceiling  = cycles::total_duration(resolved_ceiling,  cycles);
    let extended_handover = cycles::total_duration(resolved_handover, cycles);
    event::emit(RentStarted {
        escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr,
        phase_start_ms: now_ms, price_paid, floor_price: monetary::price_mist(floor),
    });
    let envelope = new_tenancy_envelope(now, resolved_floor, extended_ceiling, extended_handover, cycles);
    (AssetState::Occupied { asset: wrapped, envelope, current: t, retire: retire_condition::new() }, cap)
}

fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyLocked<Asset>,
    last_acq_price:  Price,
    phase_start:     Timestamp,
    config:          &IntegrationConfig,
    escrow_identity: EscrowIdentity,
    boundary:        Timestamp,
    generator:       &mut RandomGenerator,
): AssetState<Asset, CoinType> {
    event::emit(AuctionExpired { escrow_id: escrow_identity::escrow_id(escrow_identity), phase_start_ms: phases::timestamp_ms(phase_start), last_acq_price: monetary::price_mist(last_acq_price), timestamp_ms: phases::timestamp_ms(boundary) });
    let resolved_floor    = floor_price_policy_state::resolve(config::proj_min_rent_price(config), generator);
    let resolved_ceiling  = tenure_policy_state::resolve(config::proj_tenure_ceiling(config), generator);
    let resolved_handover = handover_policy_state::resolve(config::proj_handover(config), resolved_ceiling, generator);
    AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:           asset::AssetCustodyLocked<Asset>,
    escrow_identity: EscrowIdentity,
    now:             Timestamp,
    ctx:             &TxContext,
): AssetState<Asset, CoinType> {
    let timestamp_ms  = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    emit_retire_flag_set(raw_escrow_id, ctx.sender(), timestamp_ms);
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
        AssetState::Demand { asset, envelope, current, pending, handover_expiry: _, bidding_cycles, retire } =>
            do_handover(
                asset, current, pending, envelope, bidding_cycles, retire,
                &mut core.owner, &core.config,
                core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            ),
        AssetState::Idle    { asset: _a, .. } => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. } => abort ENotRented,
        AssetState::Retired { asset: _a }      => abort ENotRented,
        AssetState::Occupied { asset: _a, current: _c, .. } => abort ENotRented,
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
        AssetState::Occupied { asset, envelope: tenancy_env, current, retire } => {
            let TenureExpiryResult { asset: locked, last_acq_price, resolved_floor, resolved_ceiling, resolved_handover } = do_tenure_expiry(
                asset, current, tenancy_env,
                &mut core.owner, core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            );
            let boundary_ms = phases::timestamp_ms(boundary);
            if (retire_condition::proj_is_retiring(&retire)) {
                event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(core.escrow_identity), timestamp_ms: boundary_ms });
                core.pending_config = option::none();
                AssetState::Retired { asset: locked }
            } else {
                let resolved_descent = descent_policy_state::resolve(config::proj_descent(&core.config), &mut sui::random::new_generator_from_seed_for_testing(vector[0u8]));
                AssetState::AtDutch { asset: locked, last_acq_price, phase_start: boundary, resolved_floor, resolved_ceiling, resolved_handover, resolved_descent }
            }
        },
        AssetState::Idle    { asset: _a, .. } => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. } => abort ENotRented,
        AssetState::Retired { asset: _a }      => abort ENotRented,
        AssetState::Demand  { asset: _a, current: _c, pending: _p, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    state:     AssetState<Asset, CoinType>,
    core:      &EscrowCore<CoinType>,
    boundary:  Timestamp,
    generator: &mut RandomGenerator,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::AtDutch { asset, last_acq_price, phase_start, resolved_floor: _, resolved_ceiling: _, resolved_handover: _, resolved_descent: _ } =>
            do_auction_expiry(asset, last_acq_price, phase_start, &core.config, core.escrow_identity, boundary, generator),
        AssetState::Idle     { asset: _a, .. } => abort ENotRented,
        AssetState::Retired  { asset: _a }      => abort ENotRented,
        AssetState::Occupied { asset: _a, current: _c, .. } => abort ENotRented,
        AssetState::Demand   { asset: _a, current: _c, pending: _p, .. } => abort ENotRented,
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
        AssetState::Idle { asset, resolved_floor, resolved_ceiling, resolved_handover } => {
            let envelope = new_tenancy_envelope(phase_start, resolved_floor, resolved_ceiling, resolved_handover, cycles::cycles(1));
            // tenant_in is consumed only on the happy path; the abort arms
            // below leave it to drop with the divergent abort.
            AssetState::Occupied {
                asset: asset::open_tenancy(asset, core.escrow_identity),
                envelope,
                current: tenant_in,
                retire:  retire_condition::new(),
            }
        },
        AssetState::AtDutch  { asset: _a, .. }                               => abort ENotRented,
        AssetState::Retired  { asset: _a }                                   => abort ENotRented,
        AssetState::Occupied { asset: _a, current: _c, .. }                  => abort ENotRented,
        AssetState::Demand   { asset: _a, current: _c, pending: _p, .. }     => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    state:                     AssetState<Asset, CoinType>,
    tenant_in:                 tenant::Tenant<CoinType>,
    handover_countdown_expiry: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Occupied { asset, envelope, current, retire } =>
            AssetState::Demand {
                asset,
                envelope,
                current,
                pending:         tenant_in,
                handover_expiry: handover_countdown_expiry,
                bidding_cycles:  cycles::cycles(1),
                retire,
            },
        AssetState::Idle    { asset: _a, .. }                               => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. }                               => abort ENotRented,
        AssetState::Retired { asset: _a }                                   => abort ENotRented,
        AssetState::Demand  { asset: _a, current: _c, pending: _p, .. }     => abort ENotRented,
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
        AssetState::Occupied { asset, envelope: tenancy_env, current: mut tenant, retire: _ } => {
            let owner_earnings = tenant::take_owner_earnings(&mut tenant, monetary::stake(owner_amount));
            let fee_share      = tenant::take_fee_share(&mut tenant, monetary::stake(fee_amount), core.escrow_identity);
            let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
            refund_state::destroy_for_testing(refund);
            AssetState::AtDutch {
                asset:             asset::close_tenancy(asset),
                last_acq_price:    monetary::price(last_acq_price),
                phase_start:       new_phase_start,
                resolved_floor:    tenancy_env.resolved_floor,
                resolved_ceiling:  tenancy_env.resolved_ceiling,
                resolved_handover: tenancy_env.resolved_handover,
                resolved_descent:  descent_policy_state::resolve(config::proj_descent(&core.config), &mut sui::random::new_generator_from_seed_for_testing(vector[0u8])),
            }
        },
        AssetState::Idle    { asset: _a, .. }                           => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. }                           => abort ENotRented,
        AssetState::Retired { asset: _a }                               => abort ENotRented,
        AssetState::Demand  { asset: _a, current: _c, pending: _p, .. } => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    state: AssetState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Idle { asset, resolved_floor: _, resolved_ceiling: _, resolved_handover: _ } =>
            AssetState::Retired { asset },
        AssetState::AtDutch  { asset: _a, .. }                              => abort ENotRented,
        AssetState::Retired  { asset: _a }                                  => abort ENotRented,
        AssetState::Occupied { asset: _a, current: _c, .. }                 => abort ENotRented,
        AssetState::Demand   { asset: _a, current: _c, pending: _p, .. }    => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    state: AssetState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Occupied { asset, envelope, current, retire } =>
            AssetState::Occupied { asset, envelope, current, retire: retire_condition::set_for_testing(retire) },
        AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire } =>
            AssetState::Demand { asset, envelope, current, pending, handover_expiry, bidding_cycles, retire: retire_condition::set_for_testing(retire) },
        AssetState::Idle    { asset: _a, .. } => abort ENotRented,
        AssetState::AtDutch { asset: _a, .. } => abort ENotRented,
        AssetState::Retired { asset: _a }     => abort ENotRented,
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
