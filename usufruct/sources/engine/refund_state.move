// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::refund_state;

// === Imports ===

use usufruct::{
    fee_message::{Self, FeeShare},
    owner_seat::{Self, OwnerSeat},
    owner_earning::OwnerEarnings,
    protocol_fee_ref::FeeInboxIdentity,
    refund_address,
    tenant_seat::{Self, TenantSeat},
    tenant_identity,
    tenant_stake,
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
        seat:           TenantSeat<CoinType>,
        fee_share:      FeeShare<CoinType>,
        owner_earnings: OwnerEarnings<CoinType>,
    },
    Total {
        seat: TenantSeat<CoinType>,
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
    seat:           TenantSeat<C>,
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    RefundState::Parcial { seat, fee_share, owner_earnings }
}

public(package) fun total<C>(seat: TenantSeat<C>): RefundState<C> {
    RefundState::Total { seat }
}

public(package) fun distribute<C>(
    rs:                 RefundState<C>,
    owner:              &mut OwnerSeat<C>,
    fee_inbox_identity: FeeInboxIdentity,
    ctx:                &mut TxContext,
) {
    match (rs) {
        RefundState::Nothing { fee_share, owner_earnings } => {
            owner_seat::deposit(owner, owner_earnings);
            fee_message::post(fee_share, fee_inbox_identity, ctx);
        },
        RefundState::Parcial { seat, fee_share, owner_earnings } => {
            let addr = refund_address::addr(tenant_identity::proj_address(tenant_seat::proj_identity(&seat)));
            let (_, stake) = tenant_seat::unbundle(seat);
            owner_seat::deposit(owner, owner_earnings);
            fee_message::post(fee_share, fee_inbox_identity, ctx);
            tenant_stake::liquidate(stake, addr, ctx);
        },
        RefundState::Total { seat } => {
            let addr = refund_address::addr(tenant_identity::proj_address(tenant_seat::proj_identity(&seat)));
            let (_, stake) = tenant_seat::unbundle(seat);
            tenant_stake::liquidate(stake, addr, ctx);
        },
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(rs: RefundState<C>) {
    use usufruct::owner_earning;
    match (rs) {
        RefundState::Nothing { fee_share, owner_earnings } => {
            fee_message::destroy_share_for_testing(fee_share);
            owner_earning::destroy_for_testing(owner_earnings);
        },
        RefundState::Parcial { seat, fee_share, owner_earnings } => {
            tenant_seat::destroy_for_testing(seat);
            fee_message::destroy_share_for_testing(fee_share);
            owner_earning::destroy_for_testing(owner_earnings);
        },
        RefundState::Total { seat } => {
            tenant_seat::destroy_for_testing(seat);
        },
    }
}

