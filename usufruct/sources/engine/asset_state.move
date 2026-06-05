// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_state;

// === Imports ===

use std::string::{Self, String};
use std::type_name;
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
};
use usufruct::{
    asset_custody,
    asset_identity,
    escrowed_asset_identity::{Self, EscrowedAssetIdentity},
    policy_ensemble::{Self, PolicyEnsemble},
    tenures::{Self, Tenures},
    curve_shape_policy,
    auction_window_policy,
    rest_price_policy,
    price_escalation_policy,
    tenure_duration_policy,
    tenure_extend_policy,
    monetary::{Self, Price, Stake},
    governor_seat::{Self, GovernorSeat},
    governor_identity,
    governance_cap::{Self, GovernanceCap, GovernanceCapIdentity},
    earnings_inbox::{Self, EarningsInbox, EarningsInboxIdentity},
    retire_commitment_policy::{Self, RetireCommitmentPolicy},
    ensemble_commitment_policy::{Self, EnsembleCommitmentPolicy},
    handover_policy,
    math,
    phases::{Self, Timestamp, Duration},
    escrow_identity::{Self, EscrowIdentity},
    protocol_fee_ref::{Self, FeeInboxIdentity},
    usufruct_cap::{Self, UsufructCap, UsufructCapIdentity},
    refund_address::{Self, RefundAddress},
    refund_state,
    usufructuary_seat::{Self, UsufructuarySeat},
    usufructuary_identity,
    stake_balance,
};

// === Errors ===

const ENotRented:                        u64 = 0;
const EInsufficientPayment:              u64 = 1;
const ERetireFlagBlocksBid:              u64 = 2;
const ERetiredNoBid:                     u64 = 3;
const ERetireCommitmentFloorNotElapsed:  u64 = 4;
const EAlreadyRetired:                   u64 = 5;
const EWrongEscrowUsufructCap:             u64 = 6;
const EPendingUsufructCap:                 u64 = 7;
const EStaleUsufructCap:                   u64 = 8;
const EUsufructCapNotStale:                u64 = 9;
const EReceiptEscrowMismatch:            u64 = 10;
const EWrongEscrowGovernanceCap:              u64 = 11;
const ENotRetired:                       u64 = 12;
const ERetireAlreadyScheduled:           u64 = 13;
const ERetireCommitmentNotExtended:      u64 = 14;
const EReturnedDifferentAsset:           u64 = 15;
const EAlreadyRetiring:                  u64 = 16;
const EUsufructCapStale:                   u64 = 17;
const EEnsembleCommitmentFloorNotElapsed: u64 = 18;
const EEnsembleCommitmentNotExtended:     u64 = 19;

// === Constants ===

const PROTOCOL_FEE_BPS: u64 = 1_000;

// === Structs ===

public struct AssetReceipt<Asset: key + store, phantom CoinType> {
    identity: EscrowedAssetIdentity,
    renting:  RentingState<Asset, CoinType>,
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

public struct RetireCommitmentSlot has copy, drop, store {
    policy: RetireCommitmentPolicy,
    anchor: Timestamp,
}

public struct EnsembleCommitmentSlot has copy, drop, store {
    policy: EnsembleCommitmentPolicy,
    anchor: Timestamp,
}

public struct OccupiedTerms<phantom CoinType> has store {
    schedule: TenancySchedule,
    active:  UsufructuarySeat<CoinType>,
    retire:   RetireCondition,
}

public struct DemandTerms<phantom CoinType> has store {
    pending:  UsufructuarySeat<CoinType>,
    handover: HandoverTerms,
}

public struct EscrowCore<phantom CoinType> has store {
    governor_seat:              GovernorSeat,
    ensemble:           EnsembleSlot,
    fee_inbox_identity: FeeInboxIdentity,
    integrated_at:      Timestamp,
    retire_commitment:  RetireCommitmentSlot,
    ensemble_commitment: EnsembleCommitmentSlot,
    escrow_identity:    EscrowIdentity,
}

// === Enums ===

public enum RetireCondition has store, drop {
    NotRetiring,
    Retiring,
}

public enum WaitingState<Asset: key + store> has store {
    Idle    { asset: asset_custody::AssetCustodyLocked<Asset>, cycle: CycleParams },
    Descent { asset: asset_custody::AssetCustodyLocked<Asset>, auction: AuctionTerms, cycle: CycleParams },
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
    escrow_id:            ID,
    asset_type:           String,
    coin_type:            String,
    usufruct_cap_id:      ID,
    usufructuary_address: address,
    price_paid:           u64,
    floor_price:          u64,
    committed_tenures:    u64,
    timestamp_ms:         u64,
    ceiling_total_ms:     u64,
    handover_total_ms:    u64,
}

public struct AuctionExpired has copy, drop {
    escrow_id:      ID,
    asset_type:     String,
    coin_type:      String,
    phase_start_ms: u64,
    last_acq_price: u64,
    timestamp_ms:   u64,
}

public struct CycleParamsResolved has copy, drop {
    escrow_id:    ID,
    floor_mist:   u64,
    ceiling_ms:   u64,
    handover_ms:  u64,
    descent_ms:   u64,
    timestamp_ms: u64,
}

public struct AssetRetired has copy, drop {
    escrow_id:    ID,
    asset_type:   String,
    coin_type:    String,
    timestamp_ms: u64,
}

public struct RetireCommitmentExtended has copy, drop {
    escrow_id:           ID,
    asset_type:          String,
    coin_type:           String,
    commitment_policy:   String,
    commitment_floor_ms: Option<u64>,
    new_unlock_at_ms:    u64,
    timestamp_ms:        u64,
}

public struct EnsembleCommitmentExtended has copy, drop {
    escrow_id:           ID,
    asset_type:          String,
    coin_type:           String,
    commitment_policy:   String,
    commitment_floor_ms: Option<u64>,
    new_unlock_at_ms:    u64,
    timestamp_ms:        u64,
}

public struct AssetIntegrated has copy, drop {
    escrow_id:                        ID,
    asset_type:                       String,
    coin_type:                        String,
    governance_cap_id:                ID,
    governor_address:                 address,
    asset_id:                         ID,
    fee_inbox_id:                     ID,
    earnings_inbox_id:                ID,
    retire_commitment_unlock_at_ms:   u64,
    ensemble_commitment_unlock_at_ms: u64,
    timestamp_ms:                     u64,
}

public struct AssetClaimed has copy, drop {
    escrow_id:         ID,
    asset_type:        String,
    coin_type:         String,
    governance_cap_id: ID,
    governor_address:  address,
    timestamp_ms:      u64,
}

public struct BidPlaced has copy, drop {
    escrow_id:                    ID,
    asset_type:                   String,
    coin_type:                    String,
    active_usufruct_cap_id:       ID,
    active_usufructuary_address:  address,
    active_stake_balance:         u64,
    active_phase_start_ms:        u64,
    pending_usufruct_cap_id:      ID,
    pending_usufructuary_address: address,
    pending_bid_amount:           u64,
    pending_ceiling_total_ms:     u64,
    pending_handover_total_ms:    u64,
    floor_price:                  u64,
    handover_countdown_expiry:    u64,
    committed_tenures:            u64,
    timestamp_ms:                 u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:                    ID,
    asset_type:                   String,
    coin_type:                    String,
    active_usufruct_cap_id:       ID,
    active_usufructuary_address:  address,
    active_stake_balance:         u64,
    active_phase_start_ms:        u64,
    displaced_usufruct_cap_id:    ID,
    displaced_bidder_address:     address,
    refunded_amount:              u64,
    pending_usufruct_cap_id:      ID,
    pending_bidder_address:       address,
    pending_bid_amount:           u64,
    pending_ceiling_total_ms:     u64,
    pending_handover_total_ms:    u64,
    floor_price:                  u64,
    handover_countdown_expiry:    u64,
    committed_tenures:            u64,
    timestamp_ms:                 u64,
}

public struct HandoverCompleted has copy, drop {
    escrow_id:                       ID,
    asset_type:                      String,
    coin_type:                       String,
    departing_usufruct_cap_id:       ID,
    departing_usufructuary_address:  address,
    departing_phase_start_ms:        u64,
    departing_ceiling_total_ms:      u64,
    departing_handover_total_ms:     u64,
    active_usufruct_cap_id:          ID,
    active_usufructuary_address:     address,
    active_stake_balance:            u64,
    used_credit:                     u64,
    remain_credit:                   u64,
    governor_share:                  u64,
    protocol_fee:                    u64,
    departing_refund_amount:         u64,
    new_rent_price:                  u64,
    committed_tenures:               u64,
    ceiling_total_ms:                u64,
    handover_total_ms:               u64,
    timestamp_ms:                    u64,
}

public struct TenureExpired has copy, drop {
    escrow_id:              ID,
    asset_type:             String,
    coin_type:              String,
    usufruct_cap_id:        ID,
    usufructuary_address:   address,
    phase_start_ms:         u64,
    governor_share:         u64,
    protocol_fee:           u64,
    last_acquisition_price: u64,
    timestamp_ms:           u64,
}

public struct RetireFlagSet has copy, drop {
    escrow_id:         ID,
    asset_type:        String,
    coin_type:         String,
    governance_cap_id: ID,
    governor_address:  address,
    timestamp_ms:      u64,
}

public struct AssetBorrowed has copy, drop {
    escrow_id:            ID,
    asset_type:           String,
    coin_type:            String,
    usufruct_cap_id:      ID,
    usufructuary_address: address,
    timestamp_ms:         u64,
}

public struct AssetReturned has copy, drop {
    escrow_id:            ID,
    asset_type:           String,
    coin_type:            String,
    usufruct_cap_id:      ID,
    usufructuary_address: address,
}

public struct ActiveUsufructuaryRefundAddressUpdated has copy, drop {
    escrow_id:       ID,
    asset_type:      String,
    coin_type:       String,
    usufruct_cap_id: ID,
    old_address:     address,
    active_address:  address,
    timestamp_ms:    u64,
}

public struct PendingUsufructuaryRefundAddressUpdated has copy, drop {
    escrow_id:       ID,
    asset_type:      String,
    coin_type:       String,
    usufruct_cap_id: ID,
    old_address:     address,
    active_address:  address,
    timestamp_ms:    u64,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_ensemble<CoinType>(
    core: &EscrowCore<CoinType>,
): &PolicyEnsemble { &core.ensemble.active }


public(package) fun proj_fee_inbox_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID { protocol_fee_ref::proj_id(core.fee_inbox_identity) }

public(package) fun proj_integrated_at<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.integrated_at }

public(package) fun proj_pending_ensemble<CoinType>(
    core: &EscrowCore<CoinType>,
): Option<PolicyEnsemble> { core.ensemble.pending }

public(package) fun proj_pending_cycle_params<CoinType>(
    core: &EscrowCore<CoinType>,
): Option<CycleParams> {
    core.ensemble.pending.map!(|e| resolve_cycle_params(&e))
}

public(package) fun cycle_params_floor_mist(c: &CycleParams): u64    { monetary::price_mist(c.floor) }
public(package) fun cycle_params_ceiling_ms(c: &CycleParams): u64    { phases::duration_ms(c.ceiling) }
public(package) fun cycle_params_handover_ms(c: &CycleParams): u64   { phases::duration_ms(c.handover) }
public(package) fun cycle_params_descent_ms(c: &CycleParams): u64    { phases::duration_ms(c.descent) }

public(package) fun proj_retire_commitment_policy<CoinType>(
    core: &EscrowCore<CoinType>,
): RetireCommitmentPolicy { core.retire_commitment.policy }

public(package) fun proj_retire_commitment_anchor<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.retire_commitment.anchor }

public(package) fun proj_ensemble_commitment_policy<CoinType>(
    core: &EscrowCore<CoinType>,
): EnsembleCommitmentPolicy { core.ensemble_commitment.policy }

public(package) fun proj_ensemble_commitment_anchor<CoinType>(
    core: &EscrowCore<CoinType>,
): Timestamp { core.ensemble_commitment.anchor }

public(package) fun proj_earnings_inbox<CoinType>(
    core: &EscrowCore<CoinType>,
): EarningsInboxIdentity {
    governor_seat::proj_inbox(&core.governor_seat)
}

public(package) fun proj_governance_cap_id<CoinType>(
    core: &EscrowCore<CoinType>,
): ID {
    governance_cap::proj_id(governor_identity::proj_cap_identity(governor_seat::proj_identity(&core.governor_seat)))
}

public(package) fun proj_is_live<Asset: key + store, CoinType>(
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

public(package) fun proj_is_descent<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): bool {
    match (s) { AssetState::Waiting(WaitingState::Descent { .. }) => true, _ => false }
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
                            WaitingState::Descent { asset, .. } |
                            WaitingState::Retired { asset })     => asset_custody::proj_locked_id(asset),
        AssetState::Renting(RentingState::Occupied { asset, .. } | RentingState::Demand { asset, .. }) =>
            asset_identity::proj_id(asset_custody::proj_asset_id(asset)),
    }
}

public(package) fun proj_active_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(usufructuary_addr(&terms.active)),
        _ => option::none(),
    }
}

public(package) fun proj_active_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(usufruct_cap::proj_id(usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active)))),
        _ => option::none(),
    }
}

public(package) fun proj_pending_addr<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<address> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(usufructuary_addr(&bid.pending)),
        _ => option::none(),
    }
}

public(package) fun proj_pending_cap_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<ID> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(usufruct_cap::proj_id(usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&bid.pending)))),
        _ => option::none(),
    }
}

public(package) fun proj_active_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(usufructuary_seat::proj_stake_value(&terms.active)),
        _ => option::none(),
    }
}

public(package) fun proj_active_stake_value<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Stake {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            usufructuary_seat::proj_stake_value(&terms.active),
        _ => abort ENotRented,
    }
}

public(package) fun proj_pending_stake<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Stake> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(usufructuary_seat::proj_stake_value(&bid.pending)),
        _ => option::none(),
    }
}

public(package) fun proj_phase_start<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(terms.schedule.phase_start),
        AssetState::Waiting(WaitingState::Descent { auction, .. }) =>
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

public(package) fun proj_active_committed_tenures<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Tenures> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            option::some(terms.schedule.committed_tenures),
        _ => option::none(),
    }
}

public(package) fun proj_pending_committed_tenures<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Tenures> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            option::some(bid.handover.tenures),
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

public(package) fun proj_active_cycle_params<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<CycleParams> {
    match (s) {
        AssetState::Renting(RentingState::Occupied { cycle, .. } | RentingState::Demand { cycle, .. }) =>
            option::some(*cycle),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_floor<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::Descent { cycle, .. }) =>
            option::some(cycle.floor),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_ceiling<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::Descent { cycle, .. }) =>
            option::some(cycle.ceiling),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_handover<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::Descent { cycle, .. }) =>
            option::some(cycle.handover),
        _ => option::none(),
    }
}

public(package) fun proj_waiting_resolved_descent<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Duration> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. } | WaitingState::Descent { cycle, .. }) =>
            option::some(cycle.descent),
        _ => option::none(),
    }
}

public(package) fun proj_last_acq_price<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Price> {
    match (s) {
        AssetState::Waiting(WaitingState::Descent { auction, .. }) => option::some(auction.last_acq_price),
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

public(package) fun proj_credit_capped_at<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): Option<Timestamp> {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) => option::some(bid.handover.expiry),
        _ => option::none(),
    }
}

public(package) fun compute_floor_price_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Price {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { cycle, .. }) => cycle.floor,
        AssetState::Waiting(WaitingState::Descent { auction, cycle, .. }) => {
            descending_floor_price(auction.last_acq_price, auction.phase_start, cycle.floor, cycle.descent, &core.ensemble.active, now)
        },
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort ERetiredNoBid,
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            ascending_floor_price(tenures::compute_per_tenure_stake(usufructuary_seat::proj_stake_value(&terms.active), terms.schedule.committed_tenures), &core.ensemble.active)
        },
        AssetState::Renting(RentingState::Demand { bid, .. }) => {
            ascending_floor_price(tenures::compute_per_tenure_stake(usufructuary_seat::proj_stake_value(&bid.pending), bid.handover.tenures), &core.ensemble.active)
        },
    }
}

public(package) fun compute_used_credit_at<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): Stake {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            accruing_used_credit(usufructuary_seat::proj_stake_value(&terms.active), terms.schedule.phase_start, &core.ensemble.active, terms.schedule.ceiling_total, now)
        },
        AssetState::Renting(RentingState::Demand { terms, bid, .. }) => {
            capped_used_credit(usufructuary_seat::proj_stake_value(&terms.active), terms.schedule.phase_start, bid.handover.expiry, &core.ensemble.active, terms.schedule.ceiling_total, now)
        },
        _ => abort ENotRented,
    }
}

public(package) fun proj_handover_settlement<Asset: key + store, CoinType>(
    s:    &AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
): (Stake, Stake, Stake) {
    let stake = proj_active_stake_value(s);
    let used  = compute_used_credit_at(s, core, now);
    let (governor_share, protocol_fee) = split_fee_amounts(used);
    (
        monetary::stake(monetary::stake_mist(stake) - monetary::stake_mist(used)),
        governor_share,
        protocol_fee,
    )
}

public(package) fun proj_tenure_settlement<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): (Stake, Stake) {
    assert!(proj_is_rented(s), ENotRented);
    split_fee_amounts(proj_active_stake_value(s))
}

public(package) fun cap_is_active<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: UsufructCapIdentity,
): bool {
    match (s) {
        AssetState::Renting(RentingState::Occupied { terms, .. } | RentingState::Demand { terms, .. }) =>
            cap == usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active)),
        _ => false,
    }
}

public(package) fun cap_is_pending<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: UsufructCapIdentity,
): bool {
    match (s) {
        AssetState::Renting(RentingState::Demand { bid, .. }) =>
            cap == usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&bid.pending)),
        _ => false,
    }
}

public(package) fun cap_is_stale<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    cap: UsufructCapIdentity,
): bool {
    !cap_is_active(s, cap) && !cap_is_pending(s, cap)
}

public(package) fun compute_next_pending<Asset: key + store, CoinType>(
    s:   &AssetState<Asset, CoinType>,
    now: Timestamp,
): Option<Timestamp> {
    match (s) {
        AssetState::Waiting(WaitingState::Idle { .. } | WaitingState::Retired { .. }) => option::none(),
        AssetState::Waiting(WaitingState::Descent { auction, cycle, .. }) => {
            if (proj_auction_is_firable(auction, cycle, now)) {
                option::some(auction_window_policy::compute_expiry_at(cycle.descent, auction.phase_start))
            } else { option::none() }
        },
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            if (proj_occupied_is_firable(terms, now)) {
                option::some(phases::compute_boundary_at(terms.schedule.phase_start, terms.schedule.ceiling_total))
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
    asset:               Asset,
    ensemble:            PolicyEnsemble,
    retire_commitment:   RetireCommitmentPolicy,
    ensemble_commitment: EnsembleCommitmentPolicy,
    fee_inbox_identity:  FeeInboxIdentity,
    escrow_identity:     EscrowIdentity,
    integrated_at:       Timestamp,
    ctx:                 &mut TxContext,
): (EscrowCore<CoinType>, AssetState<Asset, CoinType>, GovernanceCap, EarningsInbox) {
    let governor_addr = ctx.sender();
    let governance_cap  = governance_cap::new(escrow_identity, governor_addr, ctx);
    let inbox      = earnings_inbox::new(ctx);
    let (core, state) = build_idle_core_and_state<Asset, CoinType>(
        asset, ensemble, retire_commitment, ensemble_commitment, fee_inbox_identity,
        earnings_inbox::identity(&inbox), governance_cap::identity(&governance_cap),
        escrow_identity, integrated_at, governor_addr,
    );
    (core, state, governance_cap, inbox)
}

public(package) fun execute_integrate_into_portfolio<Asset: key + store, CoinType>(
    asset:               Asset,
    ensemble:            PolicyEnsemble,
    retire_commitment:   RetireCommitmentPolicy,
    ensemble_commitment: EnsembleCommitmentPolicy,
    fee_inbox_identity:  FeeInboxIdentity,
    governance_cap:           &GovernanceCap,
    inbox:               &EarningsInbox,
    escrow_identity:     EscrowIdentity,
    integrated_at:       Timestamp,
    ctx:                 &TxContext,
): (EscrowCore<CoinType>, AssetState<Asset, CoinType>) {
    build_idle_core_and_state<Asset, CoinType>(
        asset, ensemble, retire_commitment, ensemble_commitment, fee_inbox_identity,
        earnings_inbox::identity(inbox), governance_cap::identity(governance_cap),
        escrow_identity, integrated_at, ctx.sender(),
    )
}

public(package) fun execute_apply_pending_transition_states<Asset: key + store, CoinType>(
    s:        AssetState<Asset, CoinType>,
    mut core: EscrowCore<CoinType>,
    clock:    &Clock,
    ctx:      &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    let now = phases::now(clock);
    let s = step_handover(s, &core, now, ctx);
    let s = step_tenure_expiry(s, &mut core, now, ctx);
    let s = step_auction_expiry(s, &mut core, now);
    (s, core)
}

public(package) fun execute_rent<Asset: key + store, CoinType>(
    s:       AssetState<Asset, CoinType>,
    core:    EscrowCore<CoinType>,
    payment: Coin<CoinType>,
    tenures:  Tenures,
    clock:    &Clock,
    ctx:      &mut TxContext,
): (RentingState<Asset, CoinType>, EscrowCore<CoinType>, UsufructCap) {
    let (s, core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    tenure_extend_policy::validate(policy_ensemble::proj_tenure_extend(&core.ensemble.active), tenures);
    let now                = phases::now(clock);
    let escrow_identity    = core.escrow_identity;
    let fee_inbox_identity = core.fee_inbox_identity;
    let (rs, cap) = match (s) {
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort ERetiredNoBid,
        AssetState::Waiting(WaitingState::Idle { asset, cycle }) => {
            let floor = cycle.floor;
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::compute_total_price(floor, tenures)), EInsufficientPayment);
            do_install(asset, cycle, tenures, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Waiting(WaitingState::Descent { asset, auction, cycle }) => {
            let floor = descending_floor_price(auction.last_acq_price, auction.phase_start, cycle.floor, cycle.descent, &core.ensemble.active, now);
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::compute_total_price(floor, tenures)), EInsufficientPayment);
            do_install(asset, cycle, tenures, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            if (retire_condition_is_retiring(&terms.retire)) abort ERetireFlagBlocksBid;
            let stake = usufructuary_seat::proj_stake_value(&terms.active);
            let floor = ascending_floor_price(tenures::compute_per_tenure_stake(stake, terms.schedule.committed_tenures), &core.ensemble.active);
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::compute_total_price(floor, tenures)), EInsufficientPayment);
            do_place_bid(asset, terms, cycle, tenures, escrow_identity, payment, floor, now, ctx)
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            let stake = usufructuary_seat::proj_stake_value(&bid.pending);
            let floor = ascending_floor_price(tenures::compute_per_tenure_stake(stake, bid.handover.tenures), &core.ensemble.active);
            assert!(coin::value(&payment) >= monetary::price_mist(tenures::compute_total_price(floor, tenures)), EInsufficientPayment);
            do_supersede_bid(
                asset, terms, bid, cycle, tenures,
                &core.governor_seat, escrow_identity, fee_inbox_identity, payment, floor, now, ctx,
            )
        },
    };
    (rs, core, cap)
}

public(package) fun execute_retire<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    core:      EscrowCore<CoinType>,
    governance_cap: &GovernanceCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_governance_cap_binds(governance_cap, &core);
    let now = phases::now(clock);
    assert_retire_commitment_elapsed(&core, now);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    core.ensemble.pending = option::none();
    let escrow_identity = core.escrow_identity;
    let raw_escrow_id   = escrow_identity::escrow_id(escrow_identity);
    let now_ms          = phases::timestamp_ms(now);
    let governance_cap_id    = object::id(governance_cap);
    let new_s = match (s) {
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort EAlreadyRetired,
        AssetState::Waiting(WaitingState::Idle { asset, .. }) =>
            AssetState::Waiting(do_retire_immediately<Asset, CoinType>(asset, governance_cap, escrow_identity, now, ctx)),
        AssetState::Waiting(WaitingState::Descent { asset, .. }) =>
            AssetState::Waiting(do_retire_immediately<Asset, CoinType>(asset, governance_cap, escrow_identity, now, ctx)),
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, governance_cap_id, governor_address: ctx.sender(), asset_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())), coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())), timestamp_ms: now_ms });
            let OccupiedTerms { schedule, active, retire } = terms;
            AssetState::Renting(RentingState::Occupied { asset, terms: OccupiedTerms { schedule, active, retire: retire_condition_set(retire) }, cycle })
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            event::emit(RetireFlagSet { escrow_id: raw_escrow_id, governance_cap_id, governor_address: ctx.sender(), asset_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())), coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())), timestamp_ms: now_ms });
            let OccupiedTerms { schedule, active, retire } = terms;
            AssetState::Renting(RentingState::Demand { asset, terms: OccupiedTerms { schedule, active, retire: retire_condition_set(retire) }, bid, cycle })
        },
    };
    (new_s, core)
}

public(package) fun execute_update_ensemble<Asset: key + store, CoinType>(
    s:            AssetState<Asset, CoinType>,
    core:         EscrowCore<CoinType>,
    governance_cap:    &GovernanceCap,
    new_ensemble: PolicyEnsemble,
    clock:        &Clock,
    ctx:          &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_governance_cap_binds(governance_cap, &core);
    assert_ensemble_commitment_elapsed(&core, phases::now(clock));
    let (s, mut core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    let raw_escrow_id = escrow_identity::escrow_id(core.escrow_identity);
    let new_s = match (s) {
        AssetState::Waiting(WaitingState::Retired { asset: _a }) => abort EAlreadyRetired,
        AssetState::Waiting(WaitingState::Idle { asset, cycle: _ }) => {
            policy_ensemble::emit_ensemble_updated(&new_ensemble, core.escrow_identity, phases::now(clock));
            core.ensemble.active  = new_ensemble;
            core.ensemble.pending = option::none();
            let cycle = resolve_and_emit_cycle_params(&core.ensemble.active, raw_escrow_id, phases::timestamp_ms(phases::now(clock)));
            AssetState::Waiting(WaitingState::Idle { asset, cycle })
        },
        AssetState::Waiting(WaitingState::Descent { asset, auction, cycle }) => {
            policy_ensemble::emit_ensemble_update_scheduled(&new_ensemble, core.escrow_identity, phases::now(clock));
            core.ensemble.pending = option::some(new_ensemble);
            AssetState::Waiting(WaitingState::Descent { asset, auction, cycle })
        },
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            assert!(!retire_condition_is_retiring(&terms.retire), ERetireAlreadyScheduled);
            policy_ensemble::emit_ensemble_update_scheduled(&new_ensemble, core.escrow_identity, phases::now(clock));
            core.ensemble.pending = option::some(new_ensemble);
            AssetState::Renting(RentingState::Occupied { asset, terms, cycle })
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            assert!(!retire_condition_is_retiring(&terms.retire), ERetireAlreadyScheduled);
            policy_ensemble::emit_ensemble_update_scheduled(&new_ensemble, core.escrow_identity, phases::now(clock));
            core.ensemble.pending = option::some(new_ensemble);
            AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle })
        },
    };
    (new_s, core)
}

public(package) fun execute_borrow<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    core:       EscrowCore<CoinType>,
    usufruct_cap: &UsufructCap,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_usufruct_cap_binds(usufruct_cap, &core);
    let (s, core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    let cap_identity  = usufruct_cap::identity(usufruct_cap);
    let raw_escrow_id = escrow_identity::escrow_id(core.escrow_identity);
    let now_ms        = phases::timestamp_ms(phases::now(clock));
    match (s) {
        AssetState::Renting(RentingState::Occupied { mut asset, terms, cycle }) => {
            assert_borrow_authorized(cap_identity,
                usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active)),
                option::none());
            let usufructuary_addr = usufructuary_addr(&terms.active);
            let asset_id    = asset_custody::proj_asset_id(&asset);
            let u           = asset_custody::take(&mut asset);
            let receipt     = AssetReceipt {
                identity: escrowed_asset_identity::new(asset_id, core.escrow_identity),
                renting:  RentingState::Occupied { asset, terms, cycle },
            };
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, usufruct_cap_id: usufruct_cap::proj_id(cap_identity), usufructuary_address: usufructuary_addr, asset_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())), coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())), timestamp_ms: now_ms });
            (u, receipt, core)
        },
        AssetState::Renting(RentingState::Demand { mut asset, terms, bid, cycle }) => {
            assert_borrow_authorized(cap_identity,
                usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active)),
                option::some(usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&bid.pending))));
            let usufructuary_addr = usufructuary_addr(&terms.active);
            let asset_id    = asset_custody::proj_asset_id(&asset);
            let u           = asset_custody::take(&mut asset);
            let receipt     = AssetReceipt {
                identity: escrowed_asset_identity::new(asset_id, core.escrow_identity),
                renting:  RentingState::Demand { asset, terms, bid, cycle },
            };
            event::emit(AssetBorrowed { escrow_id: raw_escrow_id, usufruct_cap_id: usufruct_cap::proj_id(cap_identity), usufructuary_address: usufructuary_addr, asset_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())), coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())), timestamp_ms: now_ms });
            (u, receipt, core)
        },
        _s => abort EStaleUsufructCap,
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
            let cap_id      = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
            let usufructuary_addr = usufructuary_addr(&terms.active);
            asset_custody::put(&mut asset, asset_in);
            event::emit(AssetReturned {
                escrow_id:      escrow_identity::escrow_id(core.escrow_identity),
                usufruct_cap_id:  usufruct_cap::proj_id(cap_id),
                usufructuary_address: usufructuary_addr,
                asset_type:     string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
                coin_type:      string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
            });
            RentingState::Occupied { asset, terms, cycle }
        },
        RentingState::Demand { mut asset, terms, bid, cycle } => {
            let cap_id      = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
            let usufructuary_addr = usufructuary_addr(&terms.active);
            asset_custody::put(&mut asset, asset_in);
            event::emit(AssetReturned {
                escrow_id:      escrow_identity::escrow_id(core.escrow_identity),
                usufruct_cap_id:  usufruct_cap::proj_id(cap_id),
                usufructuary_address: usufructuary_addr,
                asset_type:     string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
                coin_type:      string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
            });
            RentingState::Demand { asset, terms, bid, cycle }
        },
    }
}

public(package) fun execute_burn_stale_usufruct_cap<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: EscrowCore<CoinType>,
    cap:  UsufructCap,
    clock:    &Clock,
    ctx:      &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_usufruct_cap_binds(&cap, &core);
    let (s, core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    let cap_identity = usufruct_cap::identity(&cap);
    match (&s) {
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            let active = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
            if (cap_identity == active) abort EUsufructCapNotStale;
        },
        AssetState::Renting(RentingState::Demand { terms, bid, .. }) => {
            let active = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
            let pending = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&bid.pending));
            if (cap_identity == active || cap_identity == pending) abort EUsufructCapNotStale;
        },
        _ => {},
    };
    usufruct_cap::burn(cap, ctx);
    (s, core)
}

public(package) fun execute_update_usufructuary_refund_address<Asset: key + store, CoinType>(
    s:           AssetState<Asset, CoinType>,
    core:        EscrowCore<CoinType>,
    cap:         &UsufructCap,
    active_address: RefundAddress,
    clock:       &Clock,
    ctx:         &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_usufruct_cap_binds(cap, &core);
    let (mut s, core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    let cap_identity = usufruct_cap::identity(cap);
    let escrow_id    = escrow_identity::escrow_id(core.escrow_identity);
    let timestamp_ms = clock::timestamp_ms(clock);
    let active_addr_raw = refund_address::addr(active_address);
    let asset_type   = string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>()));
    let coin_type    = string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>()));
    match (&mut s) {
        AssetState::Renting(RentingState::Occupied { terms, .. }) => {
            let active_id = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
            if (cap_identity == active_id) {
                let old_address = usufructuary_addr(&terms.active);
                usufructuary_seat::set_refund_address(&mut terms.active, active_address);
                event::emit(ActiveUsufructuaryRefundAddressUpdated {
                    escrow_id,
                    usufruct_cap_id: usufruct_cap::proj_id(cap_identity),
                    old_address,
                    active_address:   active_addr_raw,
                    asset_type,
                    coin_type,
                    timestamp_ms,
                });
            } else {
                abort EUsufructCapStale
            }
        },
        AssetState::Renting(RentingState::Demand { terms, bid, .. }) => {
            let active_id  = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
            let pending_id = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&bid.pending));
            if (cap_identity == active_id) {
                let old_address = usufructuary_addr(&terms.active);
                usufructuary_seat::set_refund_address(&mut terms.active, active_address);
                event::emit(ActiveUsufructuaryRefundAddressUpdated {
                    escrow_id,
                    usufruct_cap_id: usufruct_cap::proj_id(cap_identity),
                    old_address,
                    active_address:   active_addr_raw,
                    asset_type,
                    coin_type,
                    timestamp_ms,
                });
            } else if (cap_identity == pending_id) {
                let old_address = usufructuary_addr(&bid.pending);
                usufructuary_seat::set_refund_address(&mut bid.pending, active_address);
                event::emit(PendingUsufructuaryRefundAddressUpdated {
                    escrow_id,
                    usufruct_cap_id: usufruct_cap::proj_id(cap_identity),
                    old_address,
                    active_address:   active_addr_raw,
                    asset_type,
                    coin_type,
                    timestamp_ms,
                });
            } else {
                abort EUsufructCapStale
            }
        },
        _ => abort EUsufructCapStale,
    };
    (s, core)
}

public(package) fun execute_extend_retire_commitment<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    core:       EscrowCore<CoinType>,
    governance_cap:  &GovernanceCap,
    new_policy: RetireCommitmentPolicy,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_governance_cap_binds(governance_cap, &core);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    assert_not_retired(&s);
    let now            = phases::now(clock);
    let new_duration   = retire_commitment_policy::compute_duration(&new_policy);
    assert!(phases::duration_ms(new_duration) > 0, ERetireCommitmentNotExtended);
    let old_expiry = retire_commitment_policy::compute_unlock_at(
        retire_commitment_policy::compute_duration(&core.retire_commitment.policy),
        core.retire_commitment.anchor,
    );
    let new_expiry = retire_commitment_policy::compute_unlock_at(
        new_duration,
        old_expiry,
    );
    event::emit(RetireCommitmentExtended {
        escrow_id:           escrow_identity::escrow_id(core.escrow_identity),
        commitment_policy:   retire_commitment_policy::proj_retire_commitment_policy(&new_policy),
        commitment_floor_ms: retire_commitment_policy::proj_retire_commitment_floor_ms(&new_policy),
        new_unlock_at_ms:       phases::timestamp_ms(new_expiry),
        asset_type:          string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:           string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
        timestamp_ms:        phases::timestamp_ms(now),
    });
    core.retire_commitment.policy = new_policy;
    core.retire_commitment.anchor = old_expiry;
    (s, core)
}

public(package) fun execute_extend_ensemble_commitment<Asset: key + store, CoinType>(
    s:          AssetState<Asset, CoinType>,
    core:       EscrowCore<CoinType>,
    governance_cap:  &GovernanceCap,
    new_policy: EnsembleCommitmentPolicy,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (AssetState<Asset, CoinType>, EscrowCore<CoinType>) {
    assert_governance_cap_binds(governance_cap, &core);
    let (s, mut core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    assert_not_retired(&s);
    let now            = phases::now(clock);
    let new_duration   = ensemble_commitment_policy::compute_duration(&new_policy);
    assert!(phases::duration_ms(new_duration) > 0, EEnsembleCommitmentNotExtended);
    let old_expiry = ensemble_commitment_policy::compute_unlock_at(
        ensemble_commitment_policy::compute_duration(&core.ensemble_commitment.policy),
        core.ensemble_commitment.anchor,
    );
    let new_expiry = ensemble_commitment_policy::compute_unlock_at(
        new_duration,
        old_expiry,
    );
    event::emit(EnsembleCommitmentExtended {
        escrow_id:           escrow_identity::escrow_id(core.escrow_identity),
        commitment_policy:   ensemble_commitment_policy::proj_ensemble_commitment_policy(&new_policy),
        commitment_floor_ms: ensemble_commitment_policy::proj_ensemble_commitment_floor_ms(&new_policy),
        new_unlock_at_ms:    phases::timestamp_ms(new_expiry),
        asset_type:          string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:           string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
        timestamp_ms:        phases::timestamp_ms(now),
    });
    core.ensemble_commitment.policy = new_policy;
    core.ensemble_commitment.anchor = old_expiry;
    (s, core)
}

public(package) fun execute_claim<Asset: key + store, CoinType>(
    s:         AssetState<Asset, CoinType>,
    core:      EscrowCore<CoinType>,
    governance_cap: &GovernanceCap,
    clock:     &Clock,
    ctx:       &mut TxContext,
): Asset {
    assert_governance_cap_binds(governance_cap, &core);
    let (s, core) = execute_apply_pending_transition_states(s, core, clock, ctx);
    match (s) {
        AssetState::Waiting(WaitingState::Retired { asset }) => {
            let EscrowCore { governor_seat, escrow_identity, .. } = core;
            governor_seat::destroy(governor_seat);
            event::emit(AssetClaimed {
                escrow_id:     escrow_identity::escrow_id(escrow_identity),
                governance_cap_id:  object::id(governance_cap),
                governor_address: ctx.sender(),
                asset_type:    string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
                coin_type:     string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
                timestamp_ms:  clock::timestamp_ms(clock),
            });
            asset_custody::unlock(asset)
        },
        AssetState::Waiting(_ws)  => { let EscrowCore { governor_seat: _o, .. } = core; abort ENotRetired },
        AssetState::Renting(_rs)  => { let EscrowCore { governor_seat: _o, .. } = core; abort ENotRetired },
    }
}

// === Private Functions ===

fun build_idle_core_and_state<Asset: key + store, CoinType>(
    asset:               Asset,
    ensemble:            PolicyEnsemble,
    retire_commitment:   RetireCommitmentPolicy,
    ensemble_commitment: EnsembleCommitmentPolicy,
    fee_inbox_identity:  FeeInboxIdentity,
    inbox_identity:      EarningsInboxIdentity,
    cap_identity:        GovernanceCapIdentity,
    escrow_identity:     EscrowIdentity,
    integrated_at:       Timestamp,
    governor_addr:          address,
): (EscrowCore<CoinType>, AssetState<Asset, CoinType>) {
    let asset_id      = object::id(&asset);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    policy_ensemble::emit_registration(&ensemble, escrow_identity, integrated_at);
    let cycle = resolve_and_emit_cycle_params(&ensemble, raw_escrow_id, phases::timestamp_ms(integrated_at));
    let core = EscrowCore {
        governor_seat:              governor_seat::new(cap_identity, inbox_identity),
        ensemble:           EnsembleSlot { active: ensemble, pending: option::none() },
        fee_inbox_identity,
        integrated_at,
        retire_commitment:  RetireCommitmentSlot { policy: retire_commitment, anchor: integrated_at },
        ensemble_commitment: EnsembleCommitmentSlot { policy: ensemble_commitment, anchor: integrated_at },
        escrow_identity,
    };
    let state = AssetState::Waiting(WaitingState::Idle {
        asset: asset_custody::lock(asset),
        cycle,
    });
    let retire_commitment_unlock_at_ms   = phases::timestamp_ms(retire_commitment_policy::compute_unlock_at(retire_commitment_policy::compute_duration(&retire_commitment), integrated_at));
    let ensemble_commitment_unlock_at_ms = phases::timestamp_ms(ensemble_commitment_policy::compute_unlock_at(ensemble_commitment_policy::compute_duration(&ensemble_commitment), integrated_at));
    event::emit(AssetIntegrated {
        escrow_id:                        raw_escrow_id,
        governance_cap_id:                governance_cap::proj_id(cap_identity),
        governor_address:                 governor_addr,
        asset_id,
        fee_inbox_id:                     protocol_fee_ref::proj_id(fee_inbox_identity),
        earnings_inbox_id:                earnings_inbox::proj_id(inbox_identity),
        retire_commitment_unlock_at_ms,
        ensemble_commitment_unlock_at_ms,
        asset_type:                       string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:                        string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
        timestamp_ms:                     phases::timestamp_ms(integrated_at),
    });
    (core, state)
}

fun resolve_cycle_params(ensemble: &PolicyEnsemble): CycleParams {
    let floor    = rest_price_policy::compute_price(policy_ensemble::proj_rest_price(ensemble));
    let ceiling  = tenure_duration_policy::compute_duration(policy_ensemble::proj_tenure_duration(ensemble));
    let handover = handover_policy::compute_duration(policy_ensemble::proj_handover(ensemble), ceiling);
    let descent  = auction_window_policy::compute_duration(policy_ensemble::proj_auction_window(ensemble));
    CycleParams { floor, ceiling, handover, descent }
}

fun resolve_and_emit_cycle_params(ensemble: &PolicyEnsemble, escrow_id: ID, timestamp_ms: u64): CycleParams {
    let cycle = resolve_cycle_params(ensemble);
    event::emit(CycleParamsResolved {
        escrow_id,
        floor_mist:   monetary::price_mist(cycle.floor),
        ceiling_ms:   phases::duration_ms(cycle.ceiling),
        handover_ms:  phases::duration_ms(cycle.handover),
        descent_ms:   phases::duration_ms(cycle.descent),
        timestamp_ms,
    });
    cycle
}

fun assert_governance_cap_binds<CoinType>(cap: &GovernanceCap, core: &EscrowCore<CoinType>) {
    assert!(
        governance_cap::identity(cap) == governor_identity::proj_cap_identity(governor_seat::proj_identity(&core.governor_seat)),
        EWrongEscrowGovernanceCap,
    )
}

fun assert_usufruct_cap_binds<CoinType>(cap: &UsufructCap, core: &EscrowCore<CoinType>) {
    assert!(usufruct_cap::proj_escrow_identity(cap) == core.escrow_identity, EWrongEscrowUsufructCap)
}

fun usufructuary_addr<C>(usufructuary_seat: &UsufructuarySeat<C>): address {
    refund_address::addr(usufructuary_identity::proj_address(usufructuary_seat::proj_identity(usufructuary_seat)))
}

fun assert_not_retired<Asset: key + store, CoinType>(s: &AssetState<Asset, CoinType>) {
    match (s) {
        AssetState::Waiting(WaitingState::Retired { .. })  => abort EAlreadyRetired,
        AssetState::Waiting(WaitingState::Idle { .. })     => {},
        AssetState::Waiting(WaitingState::Descent { .. })  => {},
        AssetState::Renting(RentingState::Occupied { .. }) => {},
        AssetState::Renting(RentingState::Demand { .. })   => {},
    }
}

fun assert_retire_commitment_elapsed<CoinType>(core: &EscrowCore<CoinType>, now: Timestamp) {
    assert!(
        retire_commitment_policy::compute_unlock_boundary(
            retire_commitment_policy::compute_duration(&core.retire_commitment.policy),
            core.retire_commitment.anchor,
            now,
        ).proj_is_crossed(),
        ERetireCommitmentFloorNotElapsed,
    )
}

fun assert_ensemble_commitment_elapsed<CoinType>(core: &EscrowCore<CoinType>, now: Timestamp) {
    assert!(
        ensemble_commitment_policy::compute_unlock_boundary(
            ensemble_commitment_policy::compute_duration(&core.ensemble_commitment.policy),
            core.ensemble_commitment.anchor,
            now,
        ).proj_is_crossed(),
        EEnsembleCommitmentFloorNotElapsed,
    )
}

fun assert_borrow_authorized(
    cap:     UsufructCapIdentity,
    active: UsufructCapIdentity,
    pending: Option<UsufructCapIdentity>,
) {
    if (cap == active) return;
    if (option::contains(&pending, &cap)) abort EPendingUsufructCap;
    abort EStaleUsufructCap;
}

fun assert_return_valid<Asset: key + store>(
    identity:  &EscrowedAssetIdentity,
    asset_in:  &Asset,
    escrow_id: EscrowIdentity,
) {
    assert!(escrowed_asset_identity::escrow_identity(identity) == escrow_id,                              EReceiptEscrowMismatch);
    assert!(asset_identity::new(object::id(asset_in)) == escrowed_asset_identity::asset_id(identity),    EReturnedDifferentAsset);
}

fun split_fee_amounts(amount: Stake): (Stake, Stake) {
    let mist     = monetary::stake_mist(amount);
    let fee_mist = math::compute_apply_bps(mist, math::bps(PROTOCOL_FEE_BPS));
    (monetary::stake(mist - fee_mist), monetary::stake(fee_mist))
}

fun do_handover<Asset: key + store, CoinType>(
    asset:              asset_custody::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    bid:                DemandTerms<CoinType>,
    cycle:              CycleParams,
    governor_seat:              &GovernorSeat,
    config:             &PolicyEnsemble,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): RentingState<Asset, CoinType> {
    let OccupiedTerms { schedule, active, retire } = terms;
    let DemandTerms { pending, handover: HandoverTerms { expiry: _, tenures: incoming_tenures } } = bid;

    let principal   = usufructuary_seat::proj_stake_value(&active);
    let used_credit = capped_used_credit(principal, schedule.phase_start, boundary, config, schedule.ceiling_total, boundary);
    let used_mist     = monetary::stake_mist(used_credit);
    let fee_mist      = math::compute_apply_bps(used_mist, math::bps(PROTOCOL_FEE_BPS));
    let remain_credit = monetary::compute_stake_sub(principal, used_credit);

    let departing_cap_identity = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&active));
    let departing_addr   = usufructuary_addr(&active);

    let mut departing  = active;
    let earnings = usufructuary_seat::take_earnings(&mut departing, monetary::stake(used_mist - fee_mist));
    let fee_share      = usufructuary_seat::take_fee_share(&mut departing, monetary::stake(fee_mist), escrow_identity);
    let refund = if (monetary::stake_mist(usufructuary_seat::proj_stake_value(&departing)) > 0) {
        refund_state::parcial(departing, fee_share, earnings)
    } else {
        let (_, stake) = usufructuary_seat::unbundle(departing);
        stake_balance::destroy_zero(stake);
        refund_state::nothing(fee_share, earnings)
    };
    refund_state::distribute(refund, governor_seat, fee_inbox_identity, escrow_identity, ctx);

    let active_cap_identity = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&pending));
    let active_addr         = usufructuary_addr(&pending);
    let active_stake        = usufructuary_seat::proj_stake_value(&pending);
    let new_rent_price = monetary::price_mist(ascending_floor_price(tenures::compute_per_tenure_stake(active_stake, incoming_tenures), config));
    let boundary_ms = phases::timestamp_ms(boundary);
    let new_ceiling_total  = tenures::compute_rescaled_duration(schedule.ceiling_total, schedule.committed_tenures, incoming_tenures);
    let new_handover_total = tenures::compute_rescaled_duration(schedule.handover_total, schedule.committed_tenures, incoming_tenures);

    event::emit(HandoverCompleted {
        escrow_id:                   escrow_identity::escrow_id(escrow_identity),
        departing_usufruct_cap_id:     usufruct_cap::proj_id(departing_cap_identity),
        departing_usufructuary_address:    departing_addr,
        departing_phase_start_ms:    phases::timestamp_ms(schedule.phase_start),
        departing_ceiling_total_ms:  phases::duration_ms(schedule.ceiling_total),
        departing_handover_total_ms: phases::duration_ms(schedule.handover_total),
        active_usufruct_cap_id:           usufruct_cap::proj_id(active_cap_identity),
        active_usufructuary_address:          active_addr,
        active_stake_balance:            monetary::stake_mist(active_stake),
        used_credit:                 used_mist,
        remain_credit:               monetary::stake_mist(remain_credit),
        governor_share:                 used_mist - fee_mist,
        protocol_fee:                fee_mist,
        departing_refund_amount:     monetary::stake_mist(remain_credit),
        new_rent_price,
        committed_tenures:           tenures::tenures_count(incoming_tenures),
        ceiling_total_ms:            phases::duration_ms(new_ceiling_total),
        handover_total_ms:           phases::duration_ms(new_handover_total),
        asset_type:                  string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:                   string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
        timestamp_ms:                boundary_ms,
    });

    let new_schedule = TenancySchedule {
        phase_start:      boundary,
        ceiling_total:    new_ceiling_total,
        handover_total:   new_handover_total,
        committed_tenures: incoming_tenures,
    };
    RentingState::Occupied {
        asset,
        terms: OccupiedTerms { schedule: new_schedule, active: pending, retire },
        cycle,
    }
}

fun do_tenure_expiry<Asset: key + store, CoinType>(
    asset:              asset_custody::AssetCustodyOpen<Asset>,
    terms:              OccupiedTerms<CoinType>,
    cycle:              CycleParams,
    governor_seat:              &GovernorSeat,
    config:             &mut EnsembleSlot,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    boundary:           Timestamp,
    ctx:                &mut TxContext,
): WaitingState<Asset> {
    let OccupiedTerms { schedule, active: usufructuary, retire } = terms;

    let principal            = usufructuary_seat::proj_stake_value(&usufructuary);
    let usufruct_cap_identity  = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&usufructuary));
    let usufructuary_addr          = usufructuary_addr(&usufructuary);
    let principal_mist = monetary::stake_mist(principal);
    let fee_mist       = math::compute_apply_bps(principal_mist, math::bps(PROTOCOL_FEE_BPS));

    let mut departing  = usufructuary;
    let earnings = usufructuary_seat::take_earnings(&mut departing, monetary::stake(principal_mist - fee_mist));
    let fee_share      = usufructuary_seat::take_fee_share(&mut departing, monetary::stake(fee_mist), escrow_identity);
    let (_, stake)     = usufructuary_seat::unbundle(departing);
    stake_balance::destroy_zero(stake);
    refund_state::distribute(refund_state::nothing(fee_share, earnings), governor_seat, fee_inbox_identity, escrow_identity, ctx);

    let asset_type = string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>()));
    let coin_type  = string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>()));
    event::emit(TenureExpired {
        escrow_id:              escrow_identity::escrow_id(escrow_identity),
        usufruct_cap_id:          usufruct_cap::proj_id(usufruct_cap_identity),
        usufructuary_address:         usufructuary_addr,
        phase_start_ms:         phases::timestamp_ms(schedule.phase_start),
        governor_share:            principal_mist - fee_mist,
        protocol_fee:           fee_mist,
        last_acquisition_price: monetary::stake_mist(tenures::compute_per_tenure_stake(principal, schedule.committed_tenures)),
        asset_type,
        coin_type,
        timestamp_ms:           phases::timestamp_ms(boundary),
    });

    let locked = asset_custody::close_tenancy(asset);
    if (retire_condition_is_retiring(&retire)) {
        event::emit(AssetRetired { escrow_id: escrow_identity::escrow_id(escrow_identity), asset_type, coin_type, timestamp_ms: phases::timestamp_ms(boundary) });
        config.pending = option::none();
        WaitingState::Retired { asset: locked }
    } else {
        WaitingState::Descent {
            asset:   locked,
            auction: AuctionTerms { last_acq_price: monetary::as_reference_price(tenures::compute_per_tenure_stake(principal, schedule.committed_tenures)), phase_start: boundary },
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
): (RentingState<Asset, CoinType>, UsufructCap) {
    let expiry                = handover_policy::compute_expiry_at(terms.schedule.handover_total, terms.schedule.ceiling_total, now, terms.schedule.phase_start);
    let pending_addr          = ctx.sender();
    let pending_bid_amount    = coin::value(&payment);
    let pending_ceiling_total_ms  = phases::duration_ms(tenures::compute_total_duration(cycle.ceiling, tenures));
    let pending_handover_total_ms = phases::duration_ms(tenures::compute_total_duration(cycle.handover, tenures));
    let cap          = usufruct_cap::new(escrow_identity, pending_addr, ctx);
    let cap_identity = usufruct_cap::identity(&cap);
    let t = usufructuary_seat::new<CoinType>(cap_identity, refund_address::new(pending_addr), coin::into_balance(payment));
    let active_cap_identity = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
    let active_addr  = usufructuary_addr(&terms.active);
    let active_stake = usufructuary_seat::proj_stake_value(&terms.active);
    event::emit(BidPlaced {
        escrow_id:                    escrow_identity::escrow_id(escrow_identity),
        active_usufruct_cap_id:       usufruct_cap::proj_id(active_cap_identity),
        active_usufructuary_address:  active_addr,
        active_stake_balance:         monetary::stake_mist(active_stake),
        active_phase_start_ms:        phases::timestamp_ms(terms.schedule.phase_start),
        pending_usufruct_cap_id:      usufruct_cap::proj_id(cap_identity),
        pending_usufructuary_address: pending_addr,
        pending_bid_amount,
        pending_ceiling_total_ms,
        pending_handover_total_ms,
        floor_price:                  monetary::price_mist(floor),
        handover_countdown_expiry:    phases::timestamp_ms(expiry),
        committed_tenures:            tenures::tenures_count(tenures),
        asset_type:                   string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:                    string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
        timestamp_ms:                 phases::timestamp_ms(now),
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
    governor_seat:              &GovernorSeat,
    escrow_identity:    EscrowIdentity,
    fee_inbox_identity: FeeInboxIdentity,
    payment:            Coin<CoinType>,
    floor:              Price,
    now:                Timestamp,
    ctx:                &mut TxContext,
): (RentingState<Asset, CoinType>, UsufructCap) {
    let DemandTerms { pending, handover: HandoverTerms { expiry: handover_expiry, tenures: _ } } = bid;

    let displaced_cap_identity = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&pending));
    let displaced_addr   = usufructuary_addr(&pending);
    let refunded_amount  = usufructuary_seat::proj_stake_value(&pending);

    let pending_bidder     = ctx.sender();
    let pending_bid_amount = coin::value(&payment);
    let cap            = usufruct_cap::new(escrow_identity, pending_bidder, ctx);
    let cap_identity   = usufruct_cap::identity(&cap);
    let t = usufructuary_seat::new<CoinType>(cap_identity, refund_address::new(pending_bidder), coin::into_balance(payment));
    let refund = refund_state::total(pending);
    refund_state::distribute(refund, governor_seat, fee_inbox_identity, escrow_identity, ctx);

    let active_cap_identity       = usufructuary_identity::proj_cap_identity(usufructuary_seat::proj_identity(&terms.active));
    let active_addr               = usufructuary_addr(&terms.active);
    let active_stake              = usufructuary_seat::proj_stake_value(&terms.active);
    let pending_ceiling_total_ms  = phases::duration_ms(tenures::compute_total_duration(cycle.ceiling, incoming_tenures));
    let pending_handover_total_ms = phases::duration_ms(tenures::compute_total_duration(cycle.handover, incoming_tenures));
    event::emit(BidSuperseded {
        escrow_id:                    escrow_identity::escrow_id(escrow_identity),
        active_usufruct_cap_id:       usufruct_cap::proj_id(active_cap_identity),
        active_usufructuary_address:  active_addr,
        active_stake_balance:         monetary::stake_mist(active_stake),
        active_phase_start_ms:        phases::timestamp_ms(terms.schedule.phase_start),
        displaced_usufruct_cap_id:    usufruct_cap::proj_id(displaced_cap_identity),
        displaced_bidder_address:     displaced_addr,
        refunded_amount:              monetary::stake_mist(refunded_amount),
        pending_usufruct_cap_id:      usufruct_cap::proj_id(cap_identity),
        pending_bidder_address:       pending_bidder,
        pending_bid_amount,
        pending_ceiling_total_ms,
        pending_handover_total_ms,
        floor_price:                  monetary::price_mist(floor),
        handover_countdown_expiry:    phases::timestamp_ms(handover_expiry),
        committed_tenures:            tenures::tenures_count(incoming_tenures),
        asset_type:                   string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:                    string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
        timestamp_ms:                 phases::timestamp_ms(now),
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
    phases::compute_boundary(bid.handover.expiry, phases::zero(), now).proj_is_crossed()
}

fun proj_occupied_is_firable<CoinType>(terms: &OccupiedTerms<CoinType>, now: Timestamp): bool {
    phases::compute_boundary(terms.schedule.phase_start, terms.schedule.ceiling_total, now).proj_is_crossed()
}

fun proj_auction_is_firable(auction: &AuctionTerms, cycle: &CycleParams, now: Timestamp): bool {
    auction_window_policy::compute_expiry_boundary(cycle.descent, auction.phase_start, now).proj_is_crossed()
}

fun step_handover<Asset: key + store, CoinType>(
    s:    AssetState<Asset, CoinType>,
    core: &EscrowCore<CoinType>,
    now:  Timestamp,
    ctx:  &mut TxContext,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            if (proj_demand_is_firable(&bid, now)) {
                let boundary = bid.handover.expiry;
                AssetState::Renting(do_handover(
                    asset, terms, bid, cycle,
                    &core.governor_seat, &core.ensemble.active,
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
                let boundary = phases::compute_boundary_at(terms.schedule.phase_start, terms.schedule.ceiling_total);
                AssetState::Waiting(do_tenure_expiry(
                    asset, terms, cycle,
                    &core.governor_seat, &mut core.ensemble, core.escrow_identity, core.fee_inbox_identity,
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
    s:    AssetState<Asset, CoinType>,
    core: &mut EscrowCore<CoinType>,
    now:  Timestamp,
): AssetState<Asset, CoinType> {
    match (s) {
        AssetState::Waiting(WaitingState::Descent { asset, auction, cycle }) => {
            if (proj_auction_is_firable(&auction, &cycle, now)) {
                let boundary = auction_window_policy::compute_expiry_at(cycle.descent, auction.phase_start);
                AssetState::Waiting(do_auction_expiry<Asset, CoinType>(asset, auction, cycle, &mut core.ensemble, core.escrow_identity, boundary))
            } else {
                AssetState::Waiting(WaitingState::Descent { asset, auction, cycle })
            }
        },
        s => s,
    }
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
): (RentingState<Asset, CoinType>, UsufructCap) {
    let price_paid   = coin::value(&payment);
    let usufructuary_addr  = ctx.sender();
    let cap          = usufruct_cap::new(escrow_identity, usufructuary_addr, ctx);
    let cap_identity = usufruct_cap::identity(&cap);
    let t = usufructuary_seat::new<CoinType>(cap_identity, refund_address::new(usufructuary_addr), coin::into_balance(payment));
    let wrapped = asset_custody::open_tenancy(locked, escrow_identity);
    let schedule = TenancySchedule {
        phase_start:      now,
        ceiling_total:    tenures::compute_total_duration(cycle.ceiling, tenures),
        handover_total:   tenures::compute_total_duration(cycle.handover, tenures),
        committed_tenures: tenures,
    };
    event::emit(RentStarted {
        escrow_id:         escrow_identity::escrow_id(escrow_identity),
        usufruct_cap_id:     usufruct_cap::proj_id(cap_identity),
        usufructuary_address:    usufructuary_addr,
        timestamp_ms:      phases::timestamp_ms(now),
        price_paid,
        floor_price:       monetary::price_mist(floor),
        committed_tenures: tenures::tenures_count(tenures),
        ceiling_total_ms:  phases::duration_ms(schedule.ceiling_total),
        handover_total_ms: phases::duration_ms(schedule.handover_total),
        asset_type:        string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>())),
        coin_type:         string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>())),
    });
    (
        RentingState::Occupied {
            asset: wrapped,
            terms: OccupiedTerms { schedule, active: t, retire: retire_condition_new() },
            cycle,
        },
        cap,
    )
}

fun do_auction_expiry<Asset: key + store, CoinType>(
    asset:           asset_custody::AssetCustodyLocked<Asset>,
    auction:         AuctionTerms,
    cycle:           CycleParams,
    ensemble:        &mut EnsembleSlot,
    escrow_identity: EscrowIdentity,
    boundary:        Timestamp,
): WaitingState<Asset> {
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    let asset_type    = string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>()));
    let coin_type     = string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>()));
    event::emit(AuctionExpired { escrow_id: raw_escrow_id, phase_start_ms: phases::timestamp_ms(auction.phase_start), last_acq_price: monetary::price_mist(auction.last_acq_price), asset_type, coin_type, timestamp_ms: phases::timestamp_ms(boundary) });
    let cycle = if (ensemble.pending.is_some()) {
        let new_ensemble = ensemble.pending.extract();
        policy_ensemble::emit_ensemble_updated(&new_ensemble, escrow_identity, boundary);
        ensemble.active = new_ensemble;
        resolve_and_emit_cycle_params(&ensemble.active, raw_escrow_id, phases::timestamp_ms(boundary))
    } else {
        cycle
    };
    WaitingState::Idle { asset, cycle }
}

fun do_retire_immediately<Asset: key + store, CoinType>(
    asset:           asset_custody::AssetCustodyLocked<Asset>,
    governance_cap:       &GovernanceCap,
    escrow_identity: EscrowIdentity,
    now:             Timestamp,
    ctx:             &TxContext,
): WaitingState<Asset> {
    let timestamp_ms  = phases::timestamp_ms(now);
    let raw_escrow_id = escrow_identity::escrow_id(escrow_identity);
    let governance_cap_id  = governance_cap::proj_id(governance_cap::identity(governance_cap));
    let asset_type    = string::from_ascii(type_name::into_string(type_name::with_defining_ids<Asset>()));
    let coin_type     = string::from_ascii(type_name::into_string(type_name::with_defining_ids<CoinType>()));
    event::emit(RetireFlagSet { escrow_id: raw_escrow_id, governance_cap_id, governor_address: ctx.sender(), asset_type, coin_type, timestamp_ms });
    event::emit(AssetRetired { escrow_id: raw_escrow_id, asset_type, coin_type, timestamp_ms });
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
    let elapsed = phases::compute_elapsed(phase_start, now);
    let g = curve_shape_policy::compute_curve_height(
        policy_ensemble::proj_credit_shape(ensemble),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_ceiling),
    );
    monetary::stake(curve_shape_policy::compute_scaled_value(monetary::stake_mist(stake), g))
}

fun capped_used_credit(
    stake:            Stake,
    phase_start:      Timestamp,
    expiry:           Timestamp,
    ensemble:              &PolicyEnsemble,
    resolved_ceiling: Duration,
    now:              Timestamp,
): Stake {
    let effective = phases::compute_earliest(now, expiry);
    let elapsed   = phases::compute_elapsed(phase_start, effective);
    let g = curve_shape_policy::compute_curve_height(
        policy_ensemble::proj_credit_shape(ensemble),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_ceiling),
    );
    monetary::stake(curve_shape_policy::compute_scaled_value(monetary::stake_mist(stake), g))
}

fun ascending_floor_price(stake: Stake, ensemble: &PolicyEnsemble): Price {
    price_escalation_policy::compute_next_price(
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
    let elapsed  = phases::compute_elapsed(phase_start, now);
    let h        = curve_shape_policy::compute_curve_height(
        policy_ensemble::proj_auction_shape(ensemble),
        phases::duration_ms(elapsed),
        phases::duration_ms(resolved_descent),
    );
    let spread   = monetary::price_mist(monetary::compute_price_sub(last_acq_price, resolved_floor));
    let consumed = curve_shape_policy::compute_scaled_value(spread, h);
    monetary::compute_price_sub(last_acq_price, monetary::price(consumed))
}

// === Test Functions ===

#[test_only]
public(package) fun resolve_cycle_params_for_testing(ensemble: &PolicyEnsemble): CycleParams {
    resolve_cycle_params(ensemble)
}

#[test_only]
public(package) fun split_fee_for_testing(amount: u64): (u64, u64) {
    let (governor_share, fee) = split_fee_amounts(monetary::stake(amount));
    (monetary::stake_mist(governor_share), monetary::stake_mist(fee))
}

#[test_only]
public(package) fun bid_placed_escrow_id(e: &BidPlaced): ID                          { e.escrow_id }
#[test_only]
public(package) fun bid_placed_active_usufruct_cap_id(e: &BidPlaced): ID              { e.active_usufruct_cap_id }
#[test_only]
public(package) fun bid_placed_active_usufructuary_address(e: &BidPlaced): address        { e.active_usufructuary_address }
#[test_only]
public(package) fun bid_placed_active_stake_balance(e: &BidPlaced): u64              { e.active_stake_balance }
#[test_only]
public(package) fun bid_placed_active_phase_start_ms(e: &BidPlaced): u64            { e.active_phase_start_ms }
#[test_only]
public(package) fun bid_placed_pending_usufruct_cap_id(e: &BidPlaced): ID          { e.pending_usufruct_cap_id }
#[test_only]
public(package) fun bid_placed_pending_usufructuary_address(e: &BidPlaced): address        { e.pending_usufructuary_address }
#[test_only]
public(package) fun bid_placed_pending_bid_amount(e: &BidPlaced): u64                    { e.pending_bid_amount }
#[test_only]
public(package) fun bid_placed_pending_ceiling_total_ms(e: &BidPlaced): u64             { e.pending_ceiling_total_ms }
#[test_only]
public(package) fun bid_placed_pending_handover_total_ms(e: &BidPlaced): u64            { e.pending_handover_total_ms }
#[test_only]
public(package) fun bid_placed_floor_price(e: &BidPlaced): u64                          { e.floor_price }
#[test_only]
public(package) fun bid_placed_handover_countdown_expiry(e: &BidPlaced): u64            { e.handover_countdown_expiry }
#[test_only]
public(package) fun bid_placed_timestamp_ms(e: &BidPlaced): u64                         { e.timestamp_ms }
#[test_only]
public(package) fun bid_placed_committed_tenures(e: &BidPlaced): u64                    { e.committed_tenures }
#[test_only]
public(package) fun bid_placed_asset_type(e: &BidPlaced): String                 { e.asset_type }
#[test_only]
public(package) fun bid_placed_coin_type(e: &BidPlaced): String                  { e.coin_type }

#[test_only]
public(package) fun bid_superseded_escrow_id(e: &BidSuperseded): ID                      { e.escrow_id }
#[test_only]
public(package) fun bid_superseded_active_cap_id(e: &BidSuperseded): ID               { e.active_usufruct_cap_id }
#[test_only]
public(package) fun bid_superseded_active_address(e: &BidSuperseded): address          { e.active_usufructuary_address }
#[test_only]
public(package) fun bid_superseded_active_stake(e: &BidSuperseded): u64               { e.active_stake_balance }
#[test_only]
public(package) fun bid_superseded_active_phase_start_ms(e: &BidSuperseded): u64      { e.active_phase_start_ms }
#[test_only]
public(package) fun bid_superseded_displaced_cap_id(e: &BidSuperseded): ID           { e.displaced_usufruct_cap_id }
#[test_only]
public(package) fun bid_superseded_displaced_bidder_address(e: &BidSuperseded): address { e.displaced_bidder_address }
#[test_only]
public(package) fun bid_superseded_refunded_amount(e: &BidSuperseded): u64           { e.refunded_amount }
#[test_only]
public(package) fun bid_superseded_pending_cap_id(e: &BidSuperseded): ID                 { e.pending_usufruct_cap_id }
#[test_only]
public(package) fun bid_superseded_pending_bidder_address(e: &BidSuperseded): address    { e.pending_bidder_address }
#[test_only]
public(package) fun bid_superseded_pending_bid_amount(e: &BidSuperseded): u64            { e.pending_bid_amount }
#[test_only]
public(package) fun bid_superseded_pending_ceiling_total_ms(e: &BidSuperseded): u64     { e.pending_ceiling_total_ms }
#[test_only]
public(package) fun bid_superseded_pending_handover_total_ms(e: &BidSuperseded): u64    { e.pending_handover_total_ms }
#[test_only]
public(package) fun bid_superseded_floor_price(e: &BidSuperseded): u64               { e.floor_price }
#[test_only]
public(package) fun bid_superseded_handover_countdown_expiry(e: &BidSuperseded): u64  { e.handover_countdown_expiry }
#[test_only]
public(package) fun bid_superseded_timestamp_ms(e: &BidSuperseded): u64              { e.timestamp_ms }
#[test_only]
public(package) fun bid_superseded_committed_tenures(e: &BidSuperseded): u64         { e.committed_tenures }
#[test_only]
public(package) fun bid_superseded_asset_type(e: &BidSuperseded): String             { e.asset_type }
#[test_only]
public(package) fun bid_superseded_coin_type(e: &BidSuperseded): String              { e.coin_type }

#[test_only]
public(package) fun handover_completed_escrow_id(e: &HandoverCompleted): ID                  { e.escrow_id }
#[test_only]
public(package) fun handover_completed_departing_cap_id(e: &HandoverCompleted): ID           { e.departing_usufruct_cap_id }
#[test_only]
public(package) fun handover_completed_departing_usufructuary_address(e: &HandoverCompleted): address { e.departing_usufructuary_address }
#[test_only]
public(package) fun handover_completed_departing_phase_start_ms(e: &HandoverCompleted): u64  { e.departing_phase_start_ms }
#[test_only]
public(package) fun handover_completed_departing_ceiling_total_ms(e: &HandoverCompleted): u64  { e.departing_ceiling_total_ms }
#[test_only]
public(package) fun handover_completed_departing_handover_total_ms(e: &HandoverCompleted): u64 { e.departing_handover_total_ms }
#[test_only]
public(package) fun handover_completed_active_cap_id(e: &HandoverCompleted): ID                 { e.active_usufruct_cap_id }
#[test_only]
public(package) fun handover_completed_active_usufructuary_address(e: &HandoverCompleted): address    { e.active_usufructuary_address }
#[test_only]
public(package) fun handover_completed_active_stake_balance(e: &HandoverCompleted): u64          { e.active_stake_balance }
#[test_only]
public(package) fun handover_completed_used_credit(e: &HandoverCompleted): u64               { e.used_credit }
#[test_only]
public(package) fun handover_completed_remain_credit(e: &HandoverCompleted): u64             { e.remain_credit }
#[test_only]
public(package) fun handover_completed_governor_share(e: &HandoverCompleted): u64               { e.governor_share }
#[test_only]
public(package) fun handover_completed_protocol_fee(e: &HandoverCompleted): u64              { e.protocol_fee }
#[test_only]
public(package) fun handover_completed_departing_refund_amount(e: &HandoverCompleted): u64   { e.departing_refund_amount }
#[test_only]
public(package) fun handover_completed_new_rent_price(e: &HandoverCompleted): u64            { e.new_rent_price }
#[test_only]
public(package) fun handover_completed_committed_tenures(e: &HandoverCompleted): u64         { e.committed_tenures }
#[test_only]
public(package) fun handover_completed_ceiling_total_ms(e: &HandoverCompleted): u64          { e.ceiling_total_ms }
#[test_only]
public(package) fun handover_completed_handover_total_ms(e: &HandoverCompleted): u64         { e.handover_total_ms }
#[test_only]
public(package) fun handover_completed_asset_type(e: &HandoverCompleted): String             { e.asset_type }
#[test_only]
public(package) fun handover_completed_coin_type(e: &HandoverCompleted): String              { e.coin_type }
#[test_only]
public(package) fun handover_completed_timestamp_ms(e: &HandoverCompleted): u64              { e.timestamp_ms }

#[test_only]
public(package) fun tenure_expired_escrow_id(e: &TenureExpired): ID                  { e.escrow_id }
#[test_only]
public(package) fun tenure_expired_usufruct_cap_id(e: &TenureExpired): ID              { e.usufruct_cap_id }
#[test_only]
public(package) fun tenure_expired_usufructuary_address(e: &TenureExpired): address       { e.usufructuary_address }
#[test_only]
public(package) fun tenure_expired_phase_start_ms(e: &TenureExpired): u64           { e.phase_start_ms }
#[test_only]
public(package) fun tenure_expired_governor_share(e: &TenureExpired): u64               { e.governor_share }
#[test_only]
public(package) fun tenure_expired_protocol_fee(e: &TenureExpired): u64              { e.protocol_fee }
#[test_only]
public(package) fun tenure_expired_last_acq_price(e: &TenureExpired): u64            { e.last_acquisition_price }
#[test_only]
public(package) fun tenure_expired_asset_type(e: &TenureExpired): String             { e.asset_type }
#[test_only]
public(package) fun tenure_expired_coin_type(e: &TenureExpired): String              { e.coin_type }
#[test_only]
public(package) fun tenure_expired_timestamp_ms(e: &TenureExpired): u64              { e.timestamp_ms }

#[test_only]
public(package) fun asset_borrowed_escrow_id(e: &AssetBorrowed): ID                 { e.escrow_id }
#[test_only]
public(package) fun asset_borrowed_usufruct_cap_id(e: &AssetBorrowed): ID              { e.usufruct_cap_id }
#[test_only]
public(package) fun asset_borrowed_usufructuary_address(e: &AssetBorrowed): address       { e.usufructuary_address }
#[test_only]
public(package) fun asset_borrowed_asset_type(e: &AssetBorrowed): String             { e.asset_type }
#[test_only]
public(package) fun asset_borrowed_coin_type(e: &AssetBorrowed): String              { e.coin_type }
#[test_only]
public(package) fun asset_borrowed_timestamp_ms(e: &AssetBorrowed): u64              { e.timestamp_ms }

#[test_only]
public(package) fun asset_returned_escrow_id(e: &AssetReturned): ID                 { e.escrow_id }
#[test_only]
public(package) fun asset_returned_usufruct_cap_id(e: &AssetReturned): ID              { e.usufruct_cap_id }
#[test_only]
public(package) fun asset_returned_usufructuary_address(e: &AssetReturned): address       { e.usufructuary_address }
#[test_only]
public(package) fun asset_returned_asset_type(e: &AssetReturned): String            { e.asset_type }
#[test_only]
public(package) fun asset_returned_coin_type(e: &AssetReturned): String             { e.coin_type }

#[test_only]
public(package) fun asset_claimed_escrow_id(e: &AssetClaimed): ID                   { e.escrow_id }
#[test_only]
public(package) fun asset_claimed_governance_cap_id(e: &AssetClaimed): ID                { e.governance_cap_id }
#[test_only]
public(package) fun asset_claimed_governor_address(e: &AssetClaimed): address          { e.governor_address }
#[test_only]
public(package) fun asset_claimed_asset_type(e: &AssetClaimed): String              { e.asset_type }
#[test_only]
public(package) fun asset_claimed_coin_type(e: &AssetClaimed): String               { e.coin_type }
#[test_only]
public(package) fun asset_claimed_timestamp_ms(e: &AssetClaimed): u64               { e.timestamp_ms }

#[test_only]
public(package) fun fire_do_handover_for_testing<Asset: key + store, CoinType>(
    state:    AssetState<Asset, CoinType>,
    core:     &EscrowCore<CoinType>,
    boundary: Timestamp,
    ctx:      &mut TxContext,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) =>
            AssetState::Renting(do_handover(
                asset, terms, bid, cycle,
                &core.governor_seat, &core.ensemble.active,
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
                &core.governor_seat, &mut core.ensemble, core.escrow_identity, core.fee_inbox_identity,
                boundary, ctx,
            )),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun fire_do_auction_expiry_for_testing<Asset: key + store, CoinType>(
    state:    AssetState<Asset, CoinType>,
    core:     &mut EscrowCore<CoinType>,
    boundary: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Waiting(WaitingState::Descent { asset, auction, cycle }) =>
            AssetState::Waiting(do_auction_expiry<Asset, CoinType>(asset, auction, cycle, &mut core.ensemble, core.escrow_identity, boundary)),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_rented_for_testing<Asset: key + store, CoinType>(
    state:       AssetState<Asset, CoinType>,
    core:        &EscrowCore<CoinType>,
    usufructuary_in:   usufructuary_seat::UsufructuarySeat<CoinType>,
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
                terms: OccupiedTerms { schedule, active: usufructuary_in, retire: retire_condition_new() },
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
    usufructuary_in:                 usufructuary_seat::UsufructuarySeat<CoinType>,
    handover_countdown_expiry: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) =>
            AssetState::Renting(RentingState::Demand {
                asset,
                terms,
                bid: DemandTerms {
                    pending:  usufructuary_in,
                    handover: HandoverTerms { expiry: handover_countdown_expiry, tenures: tenures::tenures(1) },
                },
                cycle,
            }),
        AssetState::Waiting(_ws) => abort ENotRented,
        AssetState::Renting(_rs) => abort ENotRented,
    }
}

#[test_only]
public(package) fun drive_to_descent_for_testing<Asset: key + store, CoinType>(
    state:           AssetState<Asset, CoinType>,
    core:            &EscrowCore<CoinType>,
    governor_amount:    u64,
    fee_amount:      u64,
    last_acq_price:  u64,
    new_phase_start: Timestamp,
): AssetState<Asset, CoinType> {
    match (state) {
        AssetState::Renting(RentingState::Occupied { asset, terms, cycle }) => {
            let OccupiedTerms { schedule: _, active: mut usufructuary, retire: _ } = terms;
            let earnings = usufructuary_seat::take_earnings(&mut usufructuary, monetary::stake(governor_amount));
            let fee_share      = usufructuary_seat::take_fee_share(&mut usufructuary, monetary::stake(fee_amount), core.escrow_identity);
            let refund = if (monetary::stake_mist(usufructuary_seat::proj_stake_value(&usufructuary)) > 0) {
                refund_state::parcial(usufructuary, fee_share, earnings)
            } else {
                let (_, stake) = usufructuary_seat::unbundle(usufructuary);
                stake_balance::destroy_zero(stake);
                refund_state::nothing(fee_share, earnings)
            };
            refund_state::destroy_for_testing(refund);
            AssetState::Waiting(WaitingState::Descent {
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
            let OccupiedTerms { schedule, active, retire } = terms;
            AssetState::Renting(RentingState::Occupied { asset, terms: OccupiedTerms { schedule, active, retire: retire_condition_set_for_testing(retire) }, cycle })
        },
        AssetState::Renting(RentingState::Demand { asset, terms, bid, cycle }) => {
            let OccupiedTerms { schedule, active, retire } = terms;
            AssetState::Renting(RentingState::Demand { asset, terms: OccupiedTerms { schedule, active, retire: retire_condition_set_for_testing(retire) }, bid, cycle })
        },
        AssetState::Waiting(_ws) => abort ENotRented,
    }
}

#[test_only]
public(package) fun rent_started_escrow_id(e: &RentStarted): ID                 { e.escrow_id }
#[test_only]
public(package) fun rent_started_usufruct_cap_id(e: &RentStarted): ID              { e.usufruct_cap_id }
#[test_only]
public(package) fun rent_started_usufructuary_address(e: &RentStarted): address       { e.usufructuary_address }
#[test_only]
public(package) fun rent_started_timestamp_ms(e: &RentStarted): u64              { e.timestamp_ms }
#[test_only]
public(package) fun rent_started_price_paid(e: &RentStarted): u64                { e.price_paid }
#[test_only]
public(package) fun rent_started_floor_price(e: &RentStarted): u64               { e.floor_price }
#[test_only]
public(package) fun rent_started_committed_tenures(e: &RentStarted): u64         { e.committed_tenures }
#[test_only]
public(package) fun rent_started_ceiling_total_ms(e: &RentStarted): u64          { e.ceiling_total_ms }
#[test_only]
public(package) fun rent_started_handover_total_ms(e: &RentStarted): u64         { e.handover_total_ms }
#[test_only]
public(package) fun rent_started_asset_type(e: &RentStarted): String             { e.asset_type }
#[test_only]
public(package) fun rent_started_coin_type(e: &RentStarted): String              { e.coin_type }

#[test_only]
public(package) fun auction_expired_escrow_id(e: &AuctionExpired): ID           { e.escrow_id }
#[test_only]
public(package) fun auction_expired_phase_start_ms(e: &AuctionExpired): u64     { e.phase_start_ms }
#[test_only]
public(package) fun auction_expired_last_acq_price(e: &AuctionExpired): u64     { e.last_acq_price }
#[test_only]
public(package) fun auction_expired_timestamp_ms(e: &AuctionExpired): u64        { e.timestamp_ms }
#[test_only]
public(package) fun auction_expired_asset_type(e: &AuctionExpired): String       { e.asset_type }
#[test_only]
public(package) fun auction_expired_coin_type(e: &AuctionExpired): String        { e.coin_type }

#[test_only]
public(package) fun cycle_params_resolved_escrow_id(e: &CycleParamsResolved): ID    { e.escrow_id }
#[test_only]
public(package) fun cycle_params_resolved_floor_mist(e: &CycleParamsResolved): u64  { e.floor_mist }
#[test_only]
public(package) fun cycle_params_resolved_ceiling_ms(e: &CycleParamsResolved): u64  { e.ceiling_ms }
#[test_only]
public(package) fun cycle_params_resolved_handover_ms(e: &CycleParamsResolved): u64 { e.handover_ms }
#[test_only]
public(package) fun cycle_params_resolved_descent_ms(e: &CycleParamsResolved): u64  { e.descent_ms }
#[test_only]
public(package) fun cycle_params_resolved_timestamp_ms(e: &CycleParamsResolved): u64 { e.timestamp_ms }

#[test_only]
public(package) fun asset_retired_escrow_id(e: &AssetRetired): ID               { e.escrow_id }
#[test_only]
public(package) fun asset_retired_asset_type(e: &AssetRetired): String          { e.asset_type }
#[test_only]
public(package) fun asset_retired_coin_type(e: &AssetRetired): String           { e.coin_type }
#[test_only]
public(package) fun asset_retired_timestamp_ms(e: &AssetRetired): u64           { e.timestamp_ms }

#[test_only]
public(package) fun retire_flag_set_escrow_id(e: &RetireFlagSet): ID            { e.escrow_id }
#[test_only]
public(package) fun retire_flag_set_governance_cap_id(e: &RetireFlagSet): ID         { e.governance_cap_id }
#[test_only]
public(package) fun retire_flag_set_governor_address(e: &RetireFlagSet): address   { e.governor_address }
#[test_only]
public(package) fun retire_flag_set_asset_type(e: &RetireFlagSet): String       { e.asset_type }
#[test_only]
public(package) fun retire_flag_set_coin_type(e: &RetireFlagSet): String        { e.coin_type }
#[test_only]
public(package) fun retire_flag_set_timestamp_ms(e: &RetireFlagSet): u64        { e.timestamp_ms }

#[test_only]
public(package) fun retire_commitment_extended_escrow_id(e: &RetireCommitmentExtended): ID       { e.escrow_id }
#[test_only]
public(package) fun retire_commitment_extended_policy(e: &RetireCommitmentExtended): String { e.commitment_policy }
#[test_only]
public(package) fun retire_commitment_extended_floor_ms(e: &RetireCommitmentExtended): Option<u64> { e.commitment_floor_ms }
#[test_only]
public(package) fun retire_commitment_extended_new_unlock_at_ms(e: &RetireCommitmentExtended): u64  { e.new_unlock_at_ms }
#[test_only]
public(package) fun retire_commitment_extended_asset_type(e: &RetireCommitmentExtended): String  { e.asset_type }
#[test_only]
public(package) fun retire_commitment_extended_coin_type(e: &RetireCommitmentExtended): String   { e.coin_type }
#[test_only]
public(package) fun retire_commitment_extended_timestamp_ms(e: &RetireCommitmentExtended): u64   { e.timestamp_ms }

#[test_only]
public(package) fun ensemble_commitment_extended_escrow_id(e: &EnsembleCommitmentExtended): ID       { e.escrow_id }
#[test_only]
public(package) fun ensemble_commitment_extended_policy(e: &EnsembleCommitmentExtended): String { e.commitment_policy }
#[test_only]
public(package) fun ensemble_commitment_extended_floor_ms(e: &EnsembleCommitmentExtended): Option<u64> { e.commitment_floor_ms }
#[test_only]
public(package) fun ensemble_commitment_extended_new_unlock_at_ms(e: &EnsembleCommitmentExtended): u64  { e.new_unlock_at_ms }
#[test_only]
public(package) fun ensemble_commitment_extended_asset_type(e: &EnsembleCommitmentExtended): String  { e.asset_type }
#[test_only]
public(package) fun ensemble_commitment_extended_coin_type(e: &EnsembleCommitmentExtended): String   { e.coin_type }
#[test_only]
public(package) fun ensemble_commitment_extended_timestamp_ms(e: &EnsembleCommitmentExtended): u64   { e.timestamp_ms }

#[test_only]
public(package) fun asset_integrated_escrow_id(e: &AssetIntegrated): ID          { e.escrow_id }
#[test_only]
public(package) fun asset_integrated_governance_cap_id(e: &AssetIntegrated): ID       { e.governance_cap_id }
#[test_only]
public(package) fun asset_integrated_governor_address(e: &AssetIntegrated): address { e.governor_address }
#[test_only]
public(package) fun asset_integrated_asset_id(e: &AssetIntegrated): ID           { e.asset_id }
#[test_only]
public(package) fun asset_integrated_fee_inbox_id(e: &AssetIntegrated): ID       { e.fee_inbox_id }
#[test_only]
public(package) fun asset_integrated_earnings_inbox_id(e: &AssetIntegrated): ID  { e.earnings_inbox_id }
#[test_only]
public(package) fun asset_integrated_retire_commitment_unlock_at_ms(e: &AssetIntegrated): u64   { e.retire_commitment_unlock_at_ms }
#[test_only]
public(package) fun asset_integrated_ensemble_commitment_unlock_at_ms(e: &AssetIntegrated): u64 { e.ensemble_commitment_unlock_at_ms }
#[test_only]
public(package) fun asset_integrated_asset_type(e: &AssetIntegrated): String     { e.asset_type }
#[test_only]
public(package) fun asset_integrated_coin_type(e: &AssetIntegrated): String      { e.coin_type }
#[test_only]
public(package) fun asset_integrated_timestamp_ms(e: &AssetIntegrated): u64      { e.timestamp_ms }

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

#[test_only]
public(package) fun active_refund_updated_escrow_id(e: &ActiveUsufructuaryRefundAddressUpdated): ID         { e.escrow_id }
#[test_only]
public(package) fun active_refund_updated_usufruct_cap_id(e: &ActiveUsufructuaryRefundAddressUpdated): ID     { e.usufruct_cap_id }
#[test_only]
public(package) fun active_refund_updated_old_address(e: &ActiveUsufructuaryRefundAddressUpdated): address  { e.old_address }
#[test_only]
public(package) fun active_refund_updated_active_address(e: &ActiveUsufructuaryRefundAddressUpdated): address  { e.active_address }
#[test_only]
public(package) fun active_refund_updated_asset_type(e: &ActiveUsufructuaryRefundAddressUpdated): String    { e.asset_type }
#[test_only]
public(package) fun active_refund_updated_coin_type(e: &ActiveUsufructuaryRefundAddressUpdated): String     { e.coin_type }
#[test_only]
public(package) fun active_refund_updated_timestamp_ms(e: &ActiveUsufructuaryRefundAddressUpdated): u64     { e.timestamp_ms }

#[test_only]
public(package) fun pending_refund_updated_escrow_id(e: &PendingUsufructuaryRefundAddressUpdated): ID        { e.escrow_id }
#[test_only]
public(package) fun pending_refund_updated_usufruct_cap_id(e: &PendingUsufructuaryRefundAddressUpdated): ID    { e.usufruct_cap_id }
#[test_only]
public(package) fun pending_refund_updated_old_address(e: &PendingUsufructuaryRefundAddressUpdated): address { e.old_address }
#[test_only]
public(package) fun pending_refund_updated_active_address(e: &PendingUsufructuaryRefundAddressUpdated): address { e.active_address }
#[test_only]
public(package) fun pending_refund_updated_asset_type(e: &PendingUsufructuaryRefundAddressUpdated): String   { e.asset_type }
#[test_only]
public(package) fun pending_refund_updated_coin_type(e: &PendingUsufructuaryRefundAddressUpdated): String    { e.coin_type }
#[test_only]
public(package) fun pending_refund_updated_timestamp_ms(e: &PendingUsufructuaryRefundAddressUpdated): u64    { e.timestamp_ms }

