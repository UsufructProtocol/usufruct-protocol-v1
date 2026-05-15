// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::refund_state;

// === Imports ===

use usufruct::{
    fee_message::{Self, FeeShare},
    monetary,
    owner::{Self, Owner, OwnerEarnings},
    protocol_fee_ref::FeeInboxIdentity,
    tenant::{Self, Tenant, TenantIdentity, TenantStake},
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

public enum RefundState<phantom CoinType> {
    Nothing {
        fee_share:      FeeShare<CoinType>,
        owner_earnings: OwnerEarnings<CoinType>,
    },
    Parcial {
        identity:       TenantIdentity,
        stake:          TenantStake<CoinType>,
        fee_share:      FeeShare<CoinType>,
        owner_earnings: OwnerEarnings<CoinType>,
    },
    Total {
        identity: TenantIdentity,
        stake:    TenantStake<CoinType>,
    },
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_is_nothing<C>(rs: &RefundState<C>): bool {
    match (rs) { RefundState::Nothing { .. } => true, _ => false }
}
public(package) fun proj_is_parcial<C>(rs: &RefundState<C>): bool {
    match (rs) { RefundState::Parcial { .. } => true, _ => false }
}
public(package) fun proj_is_total<C>(rs: &RefundState<C>): bool {
    match (rs) { RefundState::Total { .. } => true, _ => false }
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun nothing<C>(
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    RefundState::Nothing { fee_share, owner_earnings }
}

public(package) fun parcial<C>(
    identity:       TenantIdentity,
    stake:          TenantStake<C>,
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    RefundState::Parcial { identity, stake, fee_share, owner_earnings }
}

public(package) fun total<C>(
    identity: TenantIdentity,
    stake:    TenantStake<C>,
): RefundState<C> {
    RefundState::Total { identity, stake }
}

public(package) fun from_superseded<C>(pending: Tenant<C>): RefundState<C> {
    let (identity, stake) = tenant::unbundle(pending);
    total(identity, stake)
}

public(package) fun from_departing<C>(
    departing:      Tenant<C>,
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    if (monetary::stake_mist(tenant::proj_stake_value(&departing)) > 0) {
        let (identity, stake) = tenant::unbundle(departing);
        parcial(identity, stake, fee_share, owner_earnings)
    } else {
        let (_, stake) = tenant::unbundle(departing);
        tenant::destroy_empty_stake(stake);
        nothing(fee_share, owner_earnings)
    }
}

public(package) fun distribute<C>(
    rs:                 RefundState<C>,
    owner:              &mut Owner<C>,
    fee_inbox_identity: FeeInboxIdentity,
    ctx:                &mut TxContext,
) {
    match (rs) {
        RefundState::Nothing { fee_share, owner_earnings } => {
            owner::deposit(owner, owner_earnings);
            fee_message::post(fee_share, fee_inbox_identity, ctx);
        },
        RefundState::Parcial { identity, stake, fee_share, owner_earnings } => {
            owner::deposit(owner, owner_earnings);
            fee_message::post(fee_share, fee_inbox_identity, ctx);
            tenant::liquidate(stake, tenant::proj_address(&identity), ctx);
        },
        RefundState::Total { identity, stake } => {
            tenant::liquidate(stake, tenant::proj_address(&identity), ctx);
        },
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(rs: RefundState<C>) {
    match (rs) {
        RefundState::Nothing { fee_share, owner_earnings } => {
            fee_message::destroy_share_for_testing(fee_share);
            owner::destroy_earnings_for_testing(owner_earnings);
        },
        RefundState::Parcial { stake, fee_share, owner_earnings, .. } => {
            tenant::destroy_stake_for_testing(stake);
            fee_message::destroy_share_for_testing(fee_share);
            owner::destroy_earnings_for_testing(owner_earnings);
        },
        RefundState::Total { stake, .. } => {
            tenant::destroy_stake_for_testing(stake);
        },
    }
}

