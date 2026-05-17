// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_state;

// === Imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
    random::{Random, RandomGenerator},
};
use usufruct::{
    asset_custody,
    asset_identity,
    escrowed_asset_identity::{Self, EscrowedAssetIdentity},
    policy_ensemble::{Self, PolicyEnsemble},
    tenures::{Self, Tenures},
    curve_shape_policy,
    auction_window_policy,
    floor_price_policy,
    price_escalation_policy,
    tenure_duration_policy,
    tenure_extend_policy,
    monetary::{Self, Price, Stake},
    owner_seat::{Self, OwnerSeat},
    owner_identity,
    owner_cap::{Self, OwnerCap},
    commitment_policy::{Self, CommitmentPolicy},
    handover_policy,
    math,
    phases::{Self, Timestamp, Duration},
    escrow_identity::{Self, EscrowIdentity},
    protocol_fee_ref::{Self, FeeInboxIdentity},
    tenant_cap::{Self, TenantCap, TenantCapIdentity},
    refund_address,
    refund_state,
    tenant_seat::{Self, TenantSeat},
    tenant_identity,
    tenant_stake,
};

// === Errors ===

const ENotRented:             u64 = 0;
const EInsufficientPayment:   u64 = 1;
const ERetireFlagBlocksBid:   u64 = 2;
const ERetiredNoBid:          u64 = 3;
const ECommitmentFloorNotElapsed: u64 = 4;
const EAlreadyRetired:        u64 = 5;
const EWrongEscrowOwnerCap:   u64 = 11;
const EWrongEscrowTenantCap:  u64 = 6;
const EPendingTenantCap:      u64 = 7;
const EStaleTenantCap:        u64 = 8;
const ETenantCapNotStale:     u64 = 9;
const EReceiptEscrowMismatch:  u64 = 10;
const ENotRetired:               u64 = 12;
const ENoEarnings:              u64 = 13;
const ERetireAlreadyScheduled:  u64 = 16;
const ECommitmentNotExtended:     u64 = 17;
const EReturnedDifferentAsset: u64 = 19;
const EAlreadyRetiring:        u64 = 20;

// === Constants ===

const PROTOCOL_FEE_BPS: u64 = 1_000;

// === Structs ===

public struct AssetReceipt<Asset: key + store, phantom CoinType> {
    identity: EscrowedAssetIdentity,
    renting:  RentingState<Asset, CoinType>,
}

public struct FeeAllocation has drop {
    owner_share:  Stake,
    protocol_fee: Stake,
}

public struct CycleParams has copy, drop, store {
    floor:    Price,
    ceiling:  Duration,
    handover: Duration,
    descent:  Duration,
}

public struct TenancySchedule has copy, drop, store {
    phase_start:      Timestamp,
    ceiling_total:    Duration,
    handover_total:   Duration,
    committed_tenures: Tenures,
}

public struct HandoverTerms has copy, drop, store {
    expiry: Timestamp,
    tenures: Tenures,
}

public struct AuctionTerms has copy, drop, store {
    last_acq_price: Price,
    phase_start:    Timestamp,
}

public struct EnsembleSlot has drop, store {
    active:  PolicyEnsemble,
    pending: Option<PolicyEnsemble>,
}

public struct CommitmentSlot has copy, drop, store {
    policy: CommitmentPolicy,
    anchor: Timestamp,
}

public struct OccupiedTerms<phantom CoinType> has store {
    schedule: TenancySchedule,
    current:  TenantSeat<CoinType>,
    retire:   RetireCondition,
}

public struct DemandTerms<phantom CoinType> has store {
    pending:  TenantSeat<CoinType>,
    handover: HandoverTerms,
}

public struct EscrowCore<phantom CoinType> has store {
    owner:              OwnerSeat<CoinType>,
    ensemble:           EnsembleSlot,
    fee_inbox_identity: FeeInboxIdentity,
    integrated_at:      Timestamp,
    commitment:         CommitmentSlot,
    escrow_identity:    EscrowIdentity,
}

// === Enums ===

public enum RetireCondition has store, drop {
    NotRetiring,
    Retiring,
}

public enum WaitingState<Asset: key + store> has store {
    Idle    { asset: asset_custody::AssetCustodyLocked<Asset>, cycle: CycleParams },
    AtDutch { asset: asset_custody::AssetCustodyLocked<Asset>, auction: AuctionTerms, cycle: CycleParams },
    Retired { asset: asset_custody::AssetCustodyLocked<Asset> },
}

public enum RentingState<Asset: key + store, phantom CoinType> has store {
    Occupied { asset: asset_custody::AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, cycle: CycleParams },
    Demand   { asset: asset_custody::AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, bid: DemandTerms<CoinType>, cycle: CycleParams },
}

public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Waiting(WaitingState<Asset>),
    Renting(RentingState<Asset, CoinType>),
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
    new_config: PolicyEnsemble,
}

public struct ConfigUpdated has copy, drop {
    escrow_id:  ID,
    new_config: PolicyEnsemble,
}

public struct CommitmentExtended has copy, drop {
    escrow_id:     ID,
    new_policy:    CommitmentPolicy,
    new_expiry_ms: u64,
    timestamp_ms:  u64,
}

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

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_config<CoinType>(
    core: &EscrowCore<CoinType>,
): &PolicyEnsemble { &core.ensemble.active }


public(package) fun proj_fee_inbox_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID { protocol_fee_ref::inbox_id(core.fee_inbox_identity) }

public(package) fun proj_integrated_at<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.integrated_at }

public(package) fun proj_pending_config<CoinType>(
    core: &EscrowCore<CoinType>,
): Option<PolicyEnsemble> { core.ensemble.pending }

public(package) fun proj_commitment_policy<CoinType>(
    core: &EscrowCore<CoinType>,
): CommitmentPolicy { core.commitment.policy }

public(package) fun proj_commitment_anchor<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.commitment.anchor }

public(package) fun proj_owner_balance<CoinType>(
    core: &EscrowCore<CoinType>,
): Stake {
    owner_seat::proj_value(&core.owner)
}

public(package) fun proj_owner_cap_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID {
    owner_cap::cap_id(owner_identity::proj_cap_identity(owner_seat::proj_identity(&core.owner)))
}

public(package) fun proj_is_active<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) {
        AssetState::Waiting(WaitingState::Retired { .. }) => false,
        _ => true,
    }
}


public(package) fun proj_is_idle<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Waiting(WaitingState::Idle { .. }) => true, _ => false }
}

public(package) fun proj_is_at_dutch<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Waiting(WaitingState::AtDutch { .. }) => true, _ => false }
}

public(package) fun proj_is_retired<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Waiting(WaitingState::Retired { .. }) => true, _ => false }
}

public(package) fun proj_is_rented<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Renting(_) => true, _ => false }
}

public(package) fun proj_is_occupied<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Renting(RentingState::Occupied { .. }) => true, _ => false }
}

public(package) fun proj_is_demand<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Renting(RentingState::Demand { .. }) => true, _ => false }
}

public(package) fun proj_is_retiring<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            retire_condition_is_retiring(&terms.retire),
        _ => false,
    }
}

public(package) fun proj_asset_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): ID {
    match (s) {
        AssetState::Waiting(WaitingState::Idle    { asset, .. } |
                            WaitingState::AtDutch { asset, .. } |
                            WaitingState::Retired { asset })     => asset_custody::proj_locked_id(asset),
        AssetState::Renting(RentingState::Occupied { asset, .. } | RentingState::Demand { asset, .. }) =>
            asset_identity::id(asset_custody::proj_asset_id(asset)),
    }
}

public(package) fun proj_current_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(tenant_addr(&terms.current)),
        _ => option::none(),
    }
}

public(package) fun proj_current_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(tenant_cap::cap_id(tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current)))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(tenant_addr(&bid.pending)),
        _ => option::none(),
    }
}

public(package) fun proj_pending_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(tenant_cap::cap_id(tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&bid.pending)))),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(tenant_seat::proj_stake_value(&terms.current)),
        _ => option::none(),
    }
}

public(package) fun proj_current_stake_value<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Stake {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            tenant_seat::proj_stake_value(&terms.current),
        _ => abort ENotRented,
    }
}

public(package) fun proj_pending_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(tenant_seat::proj_stake_value(&bid.pending)),
        _ => option::none(),
    }
}

public(package) fun proj_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(terms.schedule.phase_start),
        AssetState::Waiting(WaitingState::AtDutch { auction, .. }) =>
            option::some(auction.phase_start),
        _ => option::none(),
    }
}

public(package) fun proj_handover_expiry<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) => option::some(bid.handover.expiry),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(terms.schedule.ceiling_total),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(terms.schedule.handover_total),
        _ => option::none(),
    }
}

public(package) fun proj_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { cycle, .. } | RentingState::Demand { cycle, .. }) =>
            option::some(cycle.floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) =>
            option::some(cycle.floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) =>
            option::some(cycle.ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) =>
            option::some(cycle.handover),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_descent<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) =>
            option::some(cycle.descent),
        _ => option::none(),
    }
}

public(package) fun proj_last_acq_price<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Waiting(WaitingState::AtDutch { auction, .. }) => option::some(auction.last_acq_price),
        _ => option::none(),
    }
}

public(package) fun proj_credit_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(tenant_seat::proj_stake_value(&terms.current)),
        _ => option::none(),
    }
}

public(package) fun proj_credit_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(terms.schedule.phase_start),
        _ => option::none(),
    }
}

public(package) fun proj_credit_is_accruing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Renting(RentingState::Occupied { .. }) => true, _ => false }
}

public(package) fun proj_credit_is_capped<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Renting(RentingState::Demand { .. }) => true, _ => false }
}

public(package) fun proj_credit_expiry<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) => option::some(bid.handover.expiry),
        _ => option::none(),
    }
}

public(package) fun floor_price_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Price {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. }) => cycle.floor,
        AssetState::Waiting(WaitingState::AtDutch { auction, cycle, .. }) => {
            descending_floor_price(auction.last_acq_price, auction.phase_start, cycle.floor, cycle.descent, &core.ensemble.active, now)
        },
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort ERetiredNoBid,
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            ascending_floor_price(tenures::per_tenure_stake(tenant_seat::proj_stake_value(&terms.current), terms.schedule.committed_tenures), &core.ensemble.active)
        },
        AssetState::Renting(RentingState::Demand { bid, .. }) => {
            ascending_floor_price(tenures::per_tenure_stake(tenant_seat::proj_stake_value(&bid.pending), bid.handover.tenures), &core.ensemble.active)
        },
    }
}

public(package) fun used_credit_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Stake {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            accruing_used_credit(tenant_seat::proj_stake_value(&terms.current), terms.schedule.phase_start, &core.ensemble.active, terms.schedule.ceiling_total, now)
        },
        AssetState::Renting(RentingState::Demand { terms, bid, .. }) => {
            capped_used_credit(tenant_seat::proj_stake_value(&terms.current), terms.schedule.phase_start, bid.handover.expiry, &core.ensemble.active, terms.schedule.ceiling_total, now)
        },
        _ => abort ENotRented,
    }
}

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

public(package) fun proj_tenure_settlement<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): (Stake, Stake) {
    assert!(proj_is_rented(s), ENotRented);
    let alloc = split_fee(proj_current_stake_value(s));
    (alloc.owner_share, alloc.protocol_fee)
}

public(package) fun cap_is_current<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: TenantCapIdentity,
): bool {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            cap == tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current)),
        _ => false,
    }
}

public(package) fun cap_is_pending<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: TenantCapIdentity,
): bool {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            cap == tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&bid.pending)),
        _ => false,
    }
}

public(package) fun cap_is_stale<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: TenantCapIdentity,
): bool {
    !cap_is_current(s, cap) && !cap_is_pending(s, cap)
}

public(package) fun next_pending<Asset: key + store, CoinType>(
    s:     &AssetState<Asset, CoinType>,
    clock: &Clock,
): Option<Timestamp> {
    let now = phases::now(clock);
    match (s) {
        AssetState::Waiting(WaitingState::Idle { .. } | WaitingState::Retired { .. }) => option::none(),
        AssetState::Waiting(WaitingState::AtDutch { auction, cycle, .. }) => {
            if (proj_auction_is_firable(auction, cycle, now)) {
                option::some(auction_window_policy::expiry_at(cycle.descent, auction.phase_start))
            } else { option::none() }
        },
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            if (proj_occupied_is_firable(terms, now)) {
                option::some(phases::boundary_at(terms.schedule.phase_start, terms.schedule.ceiling_total))
            } else { option::none() }
        },
        AssetState::Renting(RentingState::Demand { bid, .. }) => {
            if (proj_demand_is_firable(bid, now)) { option::some(bid.handover.expiry) }
            else { option::none() }
        },
    }
}

public(package) fun protocol_fee_bps(): u64 { PROTOCOL_FEE_BPS }
public(package) fun bps_denominator():  u64 { math::bps_denominator() }

// === Admin Functions ===

// === Package Functions ===

public(package) fun renting_into_state<Asset: key + store, CoinType>(
    rs: RentingState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    AssetState::Renting(rs)
}

public(package) fun execute_integrate<Asset: key + store, CoinType>(
    asset:              Asset,
    ensemble:           PolicyEnsemble,
    commitment_policy:  CommitmentPolicy,
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
    policy_ensemble::emit_registration(&ensemble, escrow_identity);
    let floor    = floor_price_policy::resolve(policy_ensemble::proj_floor_price(&ensemble), generator);
    let ceiling  = tenure_duration_policy::resolve(policy_ensemble::proj_tenure_duration(&ensemble), generator);
    let handover = handover_policy::resolve(policy_ensemble::proj_handover(&ensemble), ceiling, generator);
    let descent  = auction_window_policy::resolve(policy_ensemble::proj_auction_window(&ensemble), generator);
    let core = EscrowCore {
        owner:              owner_seat::new<CoinType>(owner_cap_identity),
        ensemble:           EnsembleSlot { active: ensemble, pending: option::none() },
        fee_inbox_identity,
        integrated_at,
        commitment:         CommitmentSlot { policy: commitment_policy, anchor: integrated_at },
        escrow_identity,
    };
    let state = AssetState::Waiting(WaitingState::Idle {
        asset: asset_custody::lock(asset),
        cycle: CycleParams { floor, ceiling, handover, descent },
    });
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

public(package) fun execute_apply_pending_transition_states<Asset: key + store, CoinType>(
    s:        AssetState<Asset, CoinType>,
    mut core: EscrowCore<CoinType>,
    random:   &Random,
    clock:    &Clock,
    ctx:      &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    let now = phases::now(clock);
    let s = step_handover(s, &mut core, now, ctx);
    let s = step_tenure_expiry(s, &mut core, now, ctx);
    let s = step_auction_expiry(s, &mut core, random, now, ctx);
    (s, core)
}

public(package) fun execute_rent<Asset: key + store, CoinType>(
    s:        AssetState<Asset, CoinType>,
    mut core: EscrowCore<CoinType>,
    payment:  Coin<CoinType>,
    tenures:  Tenures,
    random:   &Random,
    clock:    &Clock,
    ctx:      &mut TxContext,
): (RentingState<Asset, CoinType>, EscrowCore<CoinType>, TenantCap) {
    let (s, mut core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    tenure_extend_policy::validate(policy_ensemble::proj_tenure_extend(&core.ensemble.active), tenures);
    let now                = phases::now(clock);
    let escrow_identity    = core.escrow_identity;
    let fee_inbox_identity = core.fee_inbox_identity;
    let (rs, cap) = match (s) {
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort ERetiredNoBid,
        AssetState::Waiting(WaitingState::Idle { asset, cycle }) => {
            let floor = cycle.floor;
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::total_price(floor, tenures)), EInsufficientPayment);
            do_install(asset, cycle, tenures, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Waiting(WaitingState::AtDutch { asset, auction, cycle }) => {
            let floor = descending_floor_price(auction.last_acq_price, auction.phase_start, cycle.floor, cycle.descent, &core.ensemble.active, now);
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::total_price(floor, tenures)), EInsufficientPayment);
            do_install(asset, cycle, tenures, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            if (retire_condition_is_retiring(&terms.retire)) abort ERetireFlagBlocksBid;
            let stake = tenant_seat::proj_stake_value(&terms.current);
            let floor = ascending_floor_price(tenures::per_tenure_stake(stake, terms.schedule.committed_tenures), &core.ensemble.active);
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::total_price(floor, tenures)), EInsufficientPayment);
            do_place_bid(asset, terms, cycle, tenures, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            let stake = tenant_seat::proj_stake_value(&bid.pending);
            let floor = ascending_floor_price(tenures::per_tenure_stake(stake, bid.handover.tenures), &core.ensemble.active);
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::total_price(floor, tenures)), EInsufficientPayment);
            do_supersede_bid(
                asset, terms, bid, cycle, tenures,
                &mut core.owner, escrow_identity, fee_inbox_identity, payment, floor, now, ctx,
            )
        },
    };
    (rs, core, cap)
}

public(package) fun execute_retire<Asset: key + store, CoinType>(
    s:        AssetState<Asset, CoinType>,
    mut core: EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_owner_cap_binds(owner_cap, &core);
    let now = phases::now(clock);
    assert_commitment_elapsed(&core, now);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    core.ensemble.pending = option::none();
    let escrow_identity = core.escrow_identity;
    let raw_escrow_id   = escrow_identity::escrow_id(escrow_identity);
    let now_ms          = phases::timestamp_ms(now);
    let new_s = match (s) {
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort EAlreadyRetired,
        AssetState::Waiting(WaitingState::Idle { asset, .. }) =>
            AssetState::Waiting(do_retire_immediately(asset, escrow_identity, now, ctx)),
        AssetState::Waiting(WaitingState::AtDutch { asset, .. }) =>
            AssetState::Waiting(do_retire_immediately(asset, escrow_identity, now, ctx)),
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms: now_ms });
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Renting(RentingState::Occupied { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition_set(retire) }, cycle })
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms: now_ms });
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Renting(RentingState::Demand { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition_set(retire) }, bid, cycle })
        },
    };
    (new_s, core)
}

public(package) fun execute_update_config<Asset: key + store, CoinType>(
    s:            AssetState<Asset, CoinType>,
    mut core:     EscrowCore<CoinType>,
    owner_cap:    &OwnerCap,
    new_ensemble: PolicyEnsemble,
    random:       &Random,
    clock:        &Clock,
    ctx:          &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_owner_cap_binds(owner_cap, &core);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    let raw_escrow_id = escrow_identity::escrow_id(core.escrow_identity);
    let new_s = match (s) {
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort EAlreadyRetired,
        AssetState::Waiting(WaitingState::Idle { asset, cycle: _ }) => {
            event::emit(ConfigUpdated { escrow_id: raw_escrow_id, new_config: new_ensemble });
            core.ensemble.active  = new_ensemble;
            core.ensemble.pending = option::none();
            let mut generator = sui::random::new_generator(random, ctx);
            let floor    = floor_price_policy::resolve(policy_ensemble::proj_floor_price(&core.ensemble.active), &mut generator);
            let ceiling  = tenure_duration_policy::resolve(policy_ensemble::proj_tenure_duration(&core.ensemble.active), &mut generator);
            let handover = handover_policy::resolve(policy_ensemble::proj_handover(&core.ensemble.active), ceiling, &mut generator);
            let descent  = auction_window_policy::resolve(policy_ensemble::proj_auction_window(&core.ensemble.active), &mut generator);
            AssetState::Waiting(WaitingState::Idle { asset, cycle: CycleParams { floor, ceiling, handover, descent } })
        },
        AssetState::Waiting(WaitingState::AtDutch { asset, auction, cycle }) => {
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_ensemble });
            core.ensemble.pending = option::some(new_ensemble);
            AssetState::Waiting(WaitingState::AtDutch { asset, auction, cycle })
        },
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            assert!(!retire_condition_is_retiring(&terms.retire), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_ensemble });
            core.ensemble.pending = option::some(new_ensemble);
            AssetState::Renting(RentingState::Occupied { asset, terms, cycle })
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            assert!(!retire_condition_is_retiring(&terms.retire), ERetireAlreadyScheduled);
            event::emit(ConfigUpdateScheduled { escrow_id: raw_escrow_id, new_config: new_ensemble });
            core.ensemble.pending = option::some(new_ensemble);
            AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle })
        },
    };
    (new_s, core)
}

public(package) fun execute_borrow<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    mut core:   EscrowCore<CoinType>,
    tenant_cap: &TenantCap,
    random:     &Random,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_tenant_cap_binds(tenant_cap, &core);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    let cap_identity  = tenant_cap::identity(tenant_cap);
    let raw_escrow_id = escrow_identity::escrow_id(core.escrow_identity);
    match (s) {
        AssetState::Renting(RentingState::Occupied { mut asset, terms, cycle }) => {
            assert_borrow_authorized(cap_identity,
                tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current)),
                option::none());
            let tenant_addr = tenant_addr(&terms.current);
            let asset_id    = asset_custody::proj_asset_id(&asset);
            let u           = asset_custody::take(&mut asset);
            let receipt     = AssetReceipt {
                identity: escrowed_asset_identity::new(asset_id, core.escrow_identity),
                renting:  RentingState::Occupied { asset, terms, cycle },
            };
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            (u, receipt, core)
        },
        AssetState::Renting(RentingState::Demand { mut asset, terms, bid, cycle }) => {
            assert_borrow_authorized(cap_identity,
                tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current)),
                option::some(tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&bid.pending))));
            let tenant_addr = tenant_addr(&terms.current);
            let asset_id    = asset_custody::proj_asset_id(&asset);
            let u           = asset_custody::take(&mut asset);
            let receipt     = AssetReceipt {
                identity: escrowed_asset_identity::new(asset_id, core.escrow_identity),
                renting:  RentingState::Demand { asset, terms, bid, cycle },
            };
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr });
            (u, receipt, core)
        },
        _s => abort EStaleTenantCap,
    }
}

public(package) fun execute_return<Asset: key + store, CoinType>(
    receipt_in: AssetReceipt<Asset, CoinType>,
    core:       &EscrowCore<CoinType>,
    asset_in:   Asset,
): RentingState<Asset, CoinType> {
    let AssetReceipt { identity, renting } = receipt_in;
    assert_return_valid(&identity, &asset_in, core.escrow_identity);
    match (renting) {
        RentingState::Occupied { mut asset, terms, cycle } => {
            let cap_id      = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current));
            let tenant_addr = tenant_addr(&terms.current);
            asset_custody::put(&mut asset, asset_in);
            event::emit(AssetReturned {
                escrow_id:     escrow_identity::escrow_id(core.escrow_identity),
                tenant_cap_id: tenant_cap::cap_id(cap_id),
                tenant:        tenant_addr,
            });
            RentingState::Occupied { asset, terms, cycle }
        },
        RentingState::Demand { mut asset, terms, bid, cycle } => {
            let cap_id      = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current));
            let tenant_addr = tenant_addr(&terms.current);
            asset_custody::put(&mut asset, asset_in);
            event::emit(AssetReturned {
                escrow_id:     escrow_identity::escrow_id(core.escrow_identity),
                tenant_cap_id: tenant_cap::cap_id(cap_id),
                tenant:        tenant_addr,
            });
            RentingState::Demand { asset, terms, bid, cycle }
        },
    }
}

public(package) fun execute_soft_burn_tenant_cap<Asset: key + store, CoinType>(
    s:        AssetState<Asset, CoinType>,
    mut core: EscrowCore<CoinType>,
    cap:      TenantCap,
    random:   &Random,
    clock:    &Clock,
    ctx:      &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_tenant_cap_binds(&cap, &core);
    let (s, core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    let cap_identity = tenant_cap::identity(&cap);
    match (&s) {
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            let current = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current));
            if (cap_identity == current) abort ETenantCapNotStale;
        },
        AssetState::Renting(RentingState::Demand { terms, bid, .. }) => {
            let current = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current));
            let pending = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&bid.pending));
            if (cap_identity == current || cap_identity == pending) abort ETenantCapNotStale;
        },
        _ => {},
    };
    tenant_cap::burn(cap, ctx);
    (s, core)
}

public(package) fun execute_withdraw_earnings<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    mut core:  EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>, Coin<CoinType>) {
    assert_owner_cap_binds(owner_cap, &core);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    let timestamp_ms = clock::timestamp_ms(clock);
    let owner_cap_id = object::id(owner_cap);
    let owner_addr   = ctx.sender();
    let (coin, amount) = do_withdraw(&mut core.owner, owner_cap, ctx);
    event::emit(EarningsWithdrawn { escrow_id: escrow_identity::escrow_id(core.escrow_identity), owner_cap_id, owner: owner_addr, amount: monetary::stake_mist(amount), timestamp_ms });
    (s, core, coin)
}

public(package) fun execute_extend_commitment<CoinType>(
    mut core:   EscrowCore<CoinType>,
    owner_cap:  &OwnerCap,
    new_policy: CommitmentPolicy,
    clock:      &Clock,
): EscrowCore<CoinType> {
    assert_owner_cap_binds(owner_cap, &core);
    let now         = phases::now(clock);
    let old_expiry  = commitment_policy::unlock_at(
        commitment_policy::resolve(&core.commitment.policy),
        core.commitment.anchor,
    );
    let new_expiry  = commitment_policy::unlock_at(
        commitment_policy::resolve(&new_policy),
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
    core
}

public(package) fun execute_claim<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    mut core:  EscrowCore<CoinType>,
    owner_cap: &OwnerCap,
    random:    &Random,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (Asset, Coin<CoinType>) {
    assert_owner_cap_binds(owner_cap, &core);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, random, clock, ctx);
    match (s) {
        AssetState::Waiting(WaitingState::Retired { asset }) => {
            let EscrowCore { mut owner, escrow_identity, .. } = core;
            let coin           = owner_seat::withdraw(&mut owner, owner_cap, ctx);
            let swept_earnings = coin::value(&coin);
            owner_seat::destroy_empty(owner);
            event::emit(AssetClaimed {
                escrow_id:    escrow_identity::escrow_id(escrow_identity),
                owner_cap_id: object::id(owner_cap),
                owner:        ctx.sender(),
                swept_earnings,
                timestamp_ms: clock::timestamp_ms(clock),
            });
            (asset_custody::unlock(asset), coin)
        },
        AssetState::Waiting(_ws)  => { let EscrowCore { owner: _o, .. } = core; abort ENotRetired },
        AssetState::Renting(_rs)  => { let EscrowCore { owner: _o, .. } = core; abort ENotRetired },
    }
}

// === Private Functions ===

fun assert_owner_cap_binds<CoinType>(cap: &OwnerCap, core: &EscrowCore<CoinType>) {
    assert!(owner_cap::proj_escrow_identity(cap) == core.escrow_identity, EWrongEscrowOwnerCap)
}

fun assert_tenant_cap_binds<CoinType>(cap: &TenantCap, core: &EscrowCore<CoinType>) {
    assert!(tenant_cap::proj_escrow_identity(cap) == core.escrow_identity, EWrongEscrowTenantCap)
}

fun tenant_addr<C>(seat: &TenantSeat<C>): address {
    refund_address::addr(tenant_identity::proj_address(tenant_seat::proj_identity(seat)))
}

fun assert_commitment_elapsed<CoinType>(core: &EscrowCore<CoinType>, now: Timestamp) {
    assert!(
        commitment_policy::is_unlocked(
            commitment_policy::resolve(&core.commitment.policy),
            core.commitment.anchor,
            now,
        ).is_crossed(),
        ECommitmentFloorNotElapsed,
    )
}

fun assert_borrow_authorized(
    cap:     TenantCapIdentity,
    current: TenantCapIdentity,
    pending: Option<TenantCapIdentity>,
) {
    if (cap == current) return;
    if (option::contains(&pending, &cap)) abort EPendingTenantCap;
    abort EStaleTenantCap;
}

fun assert_return_valid<Asset: key + store>(
    identity:  &EscrowedAssetIdentity,
    asset_in:  &Asset,
    escrow_id: EscrowIdentity,
) {
    assert!(escrowed_asset_identity::escrow_identity(identity) == escrow_id,                              EReceiptEscrowMismatch);
    assert!(asset_identity::new(object::id(asset_in)) == escrowed_asset_identity::asset_id(identity),    EReturnedDifferentAsset);
}

fun split_fee(amount: Stake): FeeAllocation {
    let mist         = monetary::stake_mist(amount);
    let protocol_fee = math::apply_bps(mist, math::bps(PROTOCOL_FEE_BPS));
    FeeAllocation {
        owner_share:  monetary::stake(mist - protocol_fee),
        protocol_fee: monetary::stake(protocol_fee),
    }
}

fun do_handover<Asset: key + store, CoinType>(
    asset:              asset_custody::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    bid:                DemandTerms<CoinType>,
    cycle:              CycleParams,
    owner:              &mut OwnerSeat<CoinType>,
    config:             &PolicyEnsemble,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): RentingState<Asset, CoinType> {
    let OccupiedTerms { schedule, current, retire } = terms;
    let DemandTerms { pending, handover: HandoverTerms { expiry: _, tenures: incoming_tenures } } = bid;

    let principal   = tenant_seat::proj_stake_value(&current);
    let used_credit = capped_used_credit(principal, schedule.phase_start, boundary, config, schedule.ceiling_total, boundary);
    let alloc         = split_fee(used_credit);
    let remain_credit = monetary::stake_sub(principal, used_credit);

    let displaced_cap_identity = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&current));
    let displaced_addr   = tenant_addr(&current);

    let mut departing  = current;
    let owner_earnings = tenant_seat::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant_seat::take_fee_share(&mut departing, alloc.protocol_fee, escrow_identity);
    let refund         = refund_state::from_departing(departing, fee_share, owner_earnings);
    refund_state::distribute(refund, owner, fee_inbox_identity, ctx);

    let new_cap_identity = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&pending));
    let new_addr         = tenant_addr(&pending);
    let new_stake        = tenant_seat::proj_stake_value(&pending);
    let new_rent_price = monetary::price_mist(ascending_floor_price(new_stake, config));
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
        ceiling_total:    tenures::rescale_duration(schedule.ceiling_total, schedule.committed_tenures, incoming_tenures),
        handover_total:   tenures::rescale_duration(schedule.handover_total, schedule.committed_tenures, incoming_tenures),
        committed_tenures: incoming_tenures,
    };
    RentingState::Occupied {
        asset,
        terms: OccupiedTerms { schedule: new_schedule, current: pending, retire },
        cycle,
    }
}

fun do_tenure_expiry<Asset: key + store, CoinType>(
    asset:              asset_custody::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    cycle:              CycleParams,
    owner:              &mut OwnerSeat<CoinType>,
    config:             &mut EnsembleSlot,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): WaitingState<Asset> {
    let OccupiedTerms { schedule, current: tenant, retire } = terms;

    let principal            = tenant_seat::proj_stake_value(&tenant);
    let tenant_cap_identity  = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&tenant));
    let tenant_addr          = tenant_addr(&tenant);
    let alloc = split_fee(principal);

    let mut departing  = tenant;
    let owner_earnings = tenant_seat::take_owner_earnings(&mut departing, alloc.owner_share);
    let fee_share      = tenant_seat::take_fee_share(&mut departing, alloc.protocol_fee, escrow_identity);
    let (_, stake)     = tenant_seat::unbundle(departing);
    tenant_stake::destroy_zero(stake);
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

    let locked = asset_custody::close_tenancy(asset);
    if (retire_condition_is_retiring(&retire)) {
        event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(escrow_identity), timestamp_ms: phases::timestamp_ms(boundary) });
        config.pending = option::none();
        WaitingState::Retired { asset: locked }
    } else {
        WaitingState::AtDutch {
            asset:   locked,
            auction: AuctionTerms { last_acq_price: monetary::as_reference_price(principal), phase_start: boundary },
            cycle,
        }
    }
}

fun do_place_bid<Asset: key + store, CoinType>(
    asset:           asset_custody::AssetCustodyOpen<Asset>,
    terms:           OccupiedTerms<CoinType>,
    cycle:           CycleParams,
    tenures:         Tenures,
    escrow_identity: EscrowIdentity,
    payment:         Coin<CoinType>,
    floor:           Price,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (RentingState<Asset, CoinType>, TenantCap) {
    let current_cap_identity = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current));
    let current_addr   = tenant_addr(&terms.current);
    let current_stake  = tenant_seat::proj_stake_value(&terms.current);
    let expiry         = handover_policy::expiry_at(terms.schedule.handover_total, terms.schedule.ceiling_total, now, terms.schedule.phase_start);
    let pending_addr   = ctx.sender();
    let bid_amount     = coin::value(&payment);
    let raw_escrow_id  = escrow_identity::escrow_id(escrow_identity);
    let cap            = tenant_cap::new(escrow_identity, pending_addr, ctx);
    let cap_identity   = tenant_cap::identity(&cap);
    let t = tenant_seat::new<CoinType>(cap_identity, pending_addr, coin::into_balance(payment));
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
        RentingState::Demand {
            asset,
            terms,
            bid: DemandTerms {
                pending:  t,
                handover: HandoverTerms { expiry, tenures },
            },
            cycle,
        },
        cap,
    )
}

fun do_supersede_bid<Asset: key + store, CoinType>(
    asset:              asset_custody::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    bid:                DemandTerms<CoinType>,
    cycle:              CycleParams,
    incoming_tenures:  Tenures,
    owner:              &mut OwnerSeat<CoinType>,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    payment:            Coin<CoinType>,
    floor:              Price,
    now:                Timestamp,
    ctx:                &mut TxContext,
): (RentingState<Asset, CoinType>, TenantCap) {
    let DemandTerms { pending, handover: HandoverTerms { expiry: handover_expiry, tenures: _ } } = bid;

    let protected_cap_identity = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&terms.current));
    let protected_addr   = tenant_addr(&terms.current);
    let protected_stake  = tenant_seat::proj_stake_value(&terms.current);
    let displaced_cap_identity = tenant_identity::proj_cap_identity(tenant_seat::proj_identity(&pending));
    let displaced_addr   = tenant_addr(&pending);
    let refunded_amount  = tenant_seat::proj_stake_value(&pending);

    let raw_escrow_id  = escrow_identity::escrow_id(escrow_identity);
    let new_bidder     = ctx.sender();
    let new_bid_amount = coin::value(&payment);
    let cap          = tenant_cap::new(escrow_identity, new_bidder, ctx);
    let cap_identity = tenant_cap::identity(&cap);
    let t = tenant_seat::new<CoinType>(cap_identity, new_bidder, coin::into_balance(payment));

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
        RentingState::Demand {
            asset,
            terms,
            bid: DemandTerms {
                pending:  t,
                handover: HandoverTerms { expiry: handover_expiry, tenures: incoming_tenures },
            },
            cycle,
        },
        cap,
    )
}

fun proj_demand_is_firable<CoinType>(bid: &DemandTerms<CoinType>, now: Timestamp): bool {
    phases::check_boundary(bid.handover.expiry, phases::zero(), now).is_crossed()
}

fun proj_occupied_is_firable<CoinType>(terms: &OccupiedTerms<CoinType>, now: Timestamp): bool {
    phases::check_boundary(terms.schedule.phase_start, terms.schedule.ceiling_total, now).is_crossed()
}

fun proj_auction_is_firable(auction: &AuctionTerms, cycle: &CycleParams, now: Timestamp): bool {
    auction_window_policy::has_expired(cycle.descent, auction.phase_start, now).is_crossed()
}

fun step_handover<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &mut EscrowCore<CoinType>,
    now:  Timestamp,
    ctx:  &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            if (proj_demand_is_firable(&bid, now)) {
                let boundary = bid.handover.expiry;
                AssetState::Renting(do_handover(
                    asset, terms, bid, cycle,
                    &mut core.owner, &core.ensemble.active,
                    core.escrow_identity, core.fee_inbox_identity,
                    boundary, ctx,
                ))
            } else {
                AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle })
            }
        },
        s => s,
    }
}

fun step_tenure_expiry<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &mut EscrowCore<CoinType>,
    now:  Timestamp,
    ctx:  &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            if (proj_occupied_is_firable(&terms, now)) {
                let boundary = phases::boundary_at(terms.schedule.phase_start, terms.schedule.ceiling_total);
                AssetState::Waiting(do_tenure_expiry(
                    asset, terms, cycle,
                    &mut core.owner, &mut core.ensemble, core.escrow_identity, core.fee_inbox_identity,
                    boundary, ctx,
                ))
            } else {
                AssetState::Renting(RentingState::Occupied { asset, terms, cycle })
            }
        },
        s => s,
    }
}

fun step_auction_expiry<Asset: key + store, CoinType>(
    s:      AssetState<Asset, CoinType>,
    core:   &mut EscrowCore<CoinType>,
    random: &Random,
    now:    Timestamp,
    ctx:    &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Waiting(WaitingState::AtDutch { asset, auction, cycle }) => {
            if (proj_auction_is_firable(&auction, &cycle, now)) {
                let boundary = auction_window_policy::expiry_at(cycle.descent, auction.phase_start);
                let mut generator = sui::random::new_generator(random, ctx);
                AssetState::Waiting(do_auction_expiry(asset, auction, &mut core.ensemble, core.escrow_identity, boundary, &mut generator))
            } else {
                AssetState::Waiting(WaitingState::AtDutch { asset, auction, cycle })
            }
        },
        s => s,
    }
}

fun do_withdraw<CoinType>(
    owner:     &mut OwnerSeat<CoinType>,
    owner_cap: &OwnerCap,
    ctx:       &mut TxContext,
): (Coin<CoinType>, Stake) {
    let amount = owner_seat::proj_value(owner);
    assert!(monetary::stake_mist(amount) > 0, ENoEarnings);
    let coin = owner_seat::withdraw(owner, owner_cap, ctx);
    (coin, amount)
}

fun do_install<Asset: key + store, CoinType>(
    locked:          asset_custody::AssetCustodyLocked<Asset>,
    cycle:           CycleParams,
    tenures:         Tenures,
    escrow_identity: EscrowIdentity,
    payment:         Coin<CoinType>,
    floor:           Price,
    now:             Timestamp,
    ctx:             &mut TxContext,
): (RentingState<Asset, CoinType>, TenantCap) {
    let price_paid    = coin::value(&payment);
    let tenant_addr   = ctx.sender();
    let now_ms        = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    let cap           = tenant_cap::new(escrow_identity, tenant_addr, ctx);
    let cap_identity  = tenant_cap::identity(&cap);
    let t = tenant_seat::new<CoinType>(cap_identity, tenant_addr, coin::into_balance(payment));
    let wrapped = asset_custody::open_tenancy(locked, escrow_identity);
    let schedule = TenancySchedule {
        phase_start:      now,
        ceiling_total:    tenures::total_duration(cycle.ceiling, tenures),
        handover_total:   tenures::total_duration(cycle.handover, tenures),
        committed_tenures: tenures,
    };
    event::emit(RentStarted {
        escrow_id: raw_escrow_id, tenant_cap_id: tenant_cap::cap_id(cap_identity), tenant: tenant_addr,
        phase_start_ms: now_ms, price_paid, floor_price: monetary::price_mist(floor),
    });
    (
        RentingState::Occupied {
            asset: wrapped,
            terms: OccupiedTerms { schedule, current: t, retire: retire_condition_new() },
            cycle,
        },
        cap,
    )
}

fun do_auction_expiry<Asset: key + store>(
    asset:           asset_custody::AssetCustodyLocked<Asset>,
    auction:         AuctionTerms,
    ensemble:        &mut EnsembleSlot,
    escrow_identity: EscrowIdentity,
    boundary:        Timestamp,
    generator:       &mut RandomGenerator,
): WaitingState<Asset> {
    event::emit(AuctionExpired { escrow_id: escrow_identity::escrow_id(escrow_identity), phase_start_ms: phases::timestamp_ms(auction.phase_start), last_acq_price: monetary::price_mist(auction.last_acq_price), timestamp_ms: phases::timestamp_ms(boundary) });
    if (ensemble.pending.is_some()) {
        let new_ensemble = ensemble.pending.extract();
        event::emit(ConfigUpdated { escrow_id: escrow_identity::escrow_id(escrow_identity), new_config: new_ensemble });
        ensemble.active = new_ensemble;
    };
    let floor    = floor_price_policy::resolve(policy_ensemble::proj_floor_price(&ensemble.active), generator);
    let ceiling  = tenure_duration_policy::resolve(policy_ensemble::proj_tenure_duration(&ensemble.active), generator);
    let handover = handover_policy::resolve(policy_ensemble::proj_handover(&ensemble.active), ceiling, generator);
    let descent  = auction_window_policy::resolve(policy_ensemble::proj_auction_window(&ensemble.active), generator);
    WaitingState::Idle { asset, cycle: CycleParams { floor, ceiling, handover, descent } }
}

fun do_retire_immediately<Asset: key + store>(
    asset:           asset_custody::AssetCustodyLocked<Asset>,
    escrow_identity: EscrowIdentity,
    now:             Timestamp,
    ctx:             &TxContext,
): WaitingState<Asset> {
    let timestamp_ms  = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    event::emit(RetireFlagSet { escrow_id: raw_escrow_id, owner: ctx.sender(), timestamp_ms });
    event::emit(AssetRetired { escrow_id: raw_escrow_id, timestamp_ms });
    WaitingState::Retired { asset }
}

fun retire_condition_new(): RetireCondition { RetireCondition::NotRetiring }

fun retire_condition_is_retiring(r: &RetireCondition): bool {
    match (r) { RetireCondition::Retiring => true, RetireCondition::NotRetiring => false }
}

fun retire_condition_set(r: RetireCondition): RetireCondition {
    match (r) {
        RetireCondition::NotRetiring => RetireCondition::Retiring,
        RetireCondition::Retiring    => abort EAlreadyRetiring,
    }
}

fun accruing_used_credit(
    stake:            Stake,
    phase_start:      Timestamp,
    ensemble:              &PolicyEnsemble,
    resolved_ceiling: Duration,
    now:              Timestamp,
): Stake {
    let elapsed = phases::elapsed_since(phase_start, now);
    let g = curve_shape_policy::evaluate_curve(
        policy_ensemble::proj_credit_shape(ensemble),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_ceiling),
    );
    monetary::stake(curve_shape_policy::apply(monetary::stake_mist(stake), g))
}

fun capped_used_credit(
    stake:            Stake,
    phase_start:      Timestamp,
    expiry:           Timestamp,
    ensemble:              &PolicyEnsemble,
    resolved_ceiling: Duration,
    now:              Timestamp,
): Stake {
    let effective = phases::earliest(now, expiry);
    let elapsed   = phases::elapsed_since(phase_start, effective);
    let g = curve_shape_policy::evaluate_curve(
        policy_ensemble::proj_credit_shape(ensemble),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_ceiling),
    );
    monetary::stake(curve_shape_policy::apply(monetary::stake_mist(stake), g))
}

fun ascending_floor_price(stake: Stake, ensemble: &PolicyEnsemble): Price {
    price_escalation_policy::evaluate_price_fn(
        policy_ensemble::proj_price_escalation(ensemble),
        monetary::as_reference_price(stake),
    )
}

fun descending_floor_price(
    last_acq_price:   Price,
    phase_start:      Timestamp,
    resolved_floor:   Price,
    resolved_descent: Duration,
    ensemble:              &PolicyEnsemble,
    now:              Timestamp,
): Price {
    let elapsed  = phases::elapsed_since(phase_start, now);
    let h        = curve_shape_policy::evaluate_curve(
        policy_ensemble::proj_auction_shape(ensemble),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_descent),
    );
    let spread   = monetary::price_mist(monetary::price_sub(last_acq_price, resolved_floor));
    let consumed = curve_shape_policy::apply(spread, h);
    monetary::price_sub(last_acq_price, monetary::price(consumed))
}

// === Test Functions ===

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    let alloc = split_fee(monetary::stake(amount));
    (monetary::stake_mist(alloc.owner_share), monetary::stake_mist(alloc.protocol_fee))
}

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

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    state:    AssetState<Asset, CoinType>,
    core:     &mut EscrowCore<CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) =>
            AssetState::Renting(do_handover(
                asset, terms, bid, cycle,
                &mut core.owner, &core.ensemble.active,
                core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            )),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
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
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) =>
            AssetState::Waiting(do_tenure_expiry(
                asset, terms, cycle,
                &mut core.owner, &mut core.ensemble, core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            )),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
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
        AssetState::Waiting(WaitingState::AtDutch { asset, auction, .. }) =>
            AssetState::Waiting(do_auction_expiry(asset, auction, &mut core.ensemble, core.escrow_identity, boundary, generator)),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    state:       AssetState<Asset, CoinType>,
    core:        &EscrowCore<CoinType>,
    tenant_in:   tenant_seat::TenantSeat<CoinType>,
    phase_start: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Waiting(WaitingState::Idle { asset, cycle }) => {
            let schedule = TenancySchedule {
                phase_start,
                ceiling_total:    cycle.ceiling,
                handover_total:   cycle.handover,
                committed_tenures: tenures::tenures(1),
            };
            AssetState::Renting(RentingState::Occupied {
                asset: asset_custody::open_tenancy(asset, core.escrow_identity),
                terms: OccupiedTerms { schedule, current: tenant_in, retire: retire_condition_new() },
                cycle,
            })
        },
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_demand_for_testing<Asset: key + store, CoinType>(
    state:                     AssetState<Asset, CoinType>,
    tenant_in:                 tenant_seat::TenantSeat<CoinType>,
    handover_countdown_expiry: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) =>
            AssetState::Renting(RentingState::Demand {
                asset,
                terms,
                bid: DemandTerms {
                    pending:  tenant_in,
                    handover: HandoverTerms { expiry: handover_countdown_expiry, tenures: tenures::tenures(1) },
                },
                cycle,
            }),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
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
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            let OccupiedTerms { schedule: _, current: mut tenant, retire: _ } = terms;
            let owner_earnings = tenant_seat::take_owner_earnings(&mut tenant, monetary::stake(owner_amount));
            let fee_share      = tenant_seat::take_fee_share(&mut tenant, monetary::stake(fee_amount), core.escrow_identity);
            let refund = refund_state::from_departing(tenant, fee_share, owner_earnings);
            refund_state::destroy_for_testing(refund);
            AssetState::Waiting(WaitingState::AtDutch {
                asset:   asset_custody::close_tenancy(asset),
                auction: AuctionTerms { last_acq_price: monetary::price(last_acq_price), phase_start: new_phase_start },
                cycle,
            })
        },
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retired_for_testing<Asset: key + store, CoinType>(
    state: AssetState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Waiting(WaitingState::Idle { asset, .. }) =>
            AssetState::Waiting(WaitingState::Retired { asset }),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_retiring_flag_for_testing<Asset: key + store, CoinType>(
    state: AssetState<Asset, CoinType>,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Renting(RentingState::Occupied { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition_set_for_testing(retire) }, cycle })
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            let OccupiedTerms { schedule, current, retire } = terms;
            AssetState::Renting(RentingState::Demand { asset, terms: OccupiedTerms { schedule, current, retire: retire_condition_set_for_testing(retire) }, bid, cycle })
        },
        AssetState::Waiting(_ws) => abort ENotRented,
    }
}

#[test_only]
public(package) fun proj_resolved_descent_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Duration {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) => cycle.descent,
        AssetState::Renting(RentingState::Occupied { cycle, .. } | RentingState::Demand { cycle, .. }) => cycle.descent,
        AssetState::Waiting(WaitingState::Retired { .. }) => abort 0,
    }
}

#[test_only]
public(package) fun proj_resolved_floor_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Price {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) => cycle.floor,
        AssetState::Renting(RentingState::Occupied { cycle, .. } | RentingState::Demand { cycle, .. }) => cycle.floor,
        AssetState::Waiting(WaitingState::Retired { .. }) => abort 0,
    }
}

#[test_only]
public(package) fun proj_resolved_ceiling_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Duration {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) => cycle.ceiling,
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) => terms.schedule.ceiling_total,
        AssetState::Waiting(WaitingState::Retired { .. }) => abort 0,
    }
}

#[test_only]
public(package) fun proj_resolved_handover_for_testing<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Duration {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::AtDutch { cycle, .. }) => cycle.handover,
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) => terms.schedule.handover_total,
        AssetState::Waiting(WaitingState::Retired { .. }) => abort 0,
    }
}

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
public(package) fun config_updated_new_config(e: &ConfigUpdated): PolicyEnsemble { e.new_config }

#[test_only]
public(package) fun destroy_receipt_for_testing<Asset: key + store, CoinType>(
    r: AssetReceipt<Asset, CoinType>,
) {
    std::unit_test::destroy(r);
}

#[test_only]
public(package) fun accruing_used_credit_for_testing(
    stake:            Stake,
    phase_start:      Timestamp,
    ensemble:              &PolicyEnsemble,
    resolved_ceiling: Duration,
    now:              Timestamp,
): Stake {
    accruing_used_credit(stake, phase_start, ensemble, resolved_ceiling, now)
}

#[test_only]
public(package) fun capped_used_credit_for_testing(
    stake:            Stake,
    phase_start:      Timestamp,
    expiry:           Timestamp,
    ensemble:              &PolicyEnsemble,
    resolved_ceiling: Duration,
    now:              Timestamp,
): Stake {
    capped_used_credit(stake, phase_start, expiry, ensemble, resolved_ceiling, now)
}

#[test_only]
public(package) fun ascending_floor_price_for_testing(stake: Stake, ensemble: &PolicyEnsemble): Price {
    ascending_floor_price(stake, ensemble)
}

#[test_only]
public(package) fun descending_floor_price_for_testing(
    last_acq_price:   Price,
    phase_start:      Timestamp,
    resolved_floor:   Price,
    resolved_descent: Duration,
    ensemble:              &PolicyEnsemble,
    now:              Timestamp,
): Price {
    descending_floor_price(last_acq_price, phase_start, resolved_floor, resolved_descent, ensemble, now)
}

#[test_only]
public(package) fun retire_condition_set_for_testing(r: RetireCondition): RetireCondition {
    let _ = r;
    RetireCondition::Retiring
}

