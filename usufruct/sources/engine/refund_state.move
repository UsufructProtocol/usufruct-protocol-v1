// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::refund_state;

// === Imports ===

use usufruct::{
    fee_message::{Self, FeeShare},
    earnings_message,
    governor_seat::{Self, GovernorSeat},
    earnings_balance::EarningsBalance,
    protocol_fee_ref::FeeInboxIdentity,
    escrow_identity::EscrowIdentity,
    refund_address,
    usufructuary_seat::{Self, UsufructuarySeat},
    usufructuary_identity,
    stake_balance,
};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

public enum RefundState<phantom CoinType> {
    Nothing {
        fee_share:      FeeShare<CoinType>,
        earnings: EarningsBalance<CoinType>,
    },
    Parcial {
        usufructuary_seat:           UsufructuarySeat<CoinType>,
        fee_share:      FeeShare<CoinType>,
        earnings: EarningsBalance<CoinType>,
    },
    Total {
        usufructuary_seat: UsufructuarySeat<CoinType>,
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
    earnings: EarningsBalance<C>,
): RefundState<C> {
    RefundState::Nothing { fee_share, earnings }
}

public(package) fun parcial<C>(
    usufructuary_seat:           UsufructuarySeat<C>,
    fee_share:      FeeShare<C>,
    earnings: EarningsBalance<C>,
): RefundState<C> {
    RefundState::Parcial { usufructuary_seat, fee_share, earnings }
}

public(package) fun total<C>(usufructuary_seat: UsufructuarySeat<C>): RefundState<C> {
    RefundState::Total { usufructuary_seat }
}

public(package) fun distribute<C>(
    rs:                 RefundState<C>,
    governor_seat:              &GovernorSeat,
    fee_inbox_identity: FeeInboxIdentity,
    escrow_identity:    EscrowIdentity,
    ctx:                &mut TxContext,
) {
    match (rs) {
        RefundState::Nothing { fee_share, earnings } => {
            earnings_message::post(earnings, governor_seat::proj_inbox(governor_seat), escrow_identity, ctx);
            fee_message::post(fee_share, fee_inbox_identity, ctx);
        },
        RefundState::Parcial { usufructuary_seat, fee_share, earnings } => {
            let addr = refund_address::addr(usufructuary_identity::proj_address(usufructuary_seat::proj_identity(&usufructuary_seat)));
            let (_, stake) = usufructuary_seat::unbundle(usufructuary_seat);
            earnings_message::post(earnings, governor_seat::proj_inbox(governor_seat), escrow_identity, ctx);
            fee_message::post(fee_share, fee_inbox_identity, ctx);
            stake_balance::liquidate(stake, addr, ctx);
        },
        RefundState::Total { usufructuary_seat } => {
            let addr = refund_address::addr(usufructuary_identity::proj_address(usufructuary_seat::proj_identity(&usufructuary_seat)));
            let (_, stake) = usufructuary_seat::unbundle(usufructuary_seat);
            stake_balance::liquidate(stake, addr, ctx);
        },
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(rs: RefundState<C>) {
    use usufruct::earnings_balance;
    match (rs) {
        RefundState::Nothing { fee_share, earnings } => {
            fee_message::destroy_share_for_testing(fee_share);
            earnings_balance::destroy_for_testing(earnings);
        },
        RefundState::Parcial { usufructuary_seat, fee_share, earnings } => {
            usufructuary_seat::destroy_for_testing(usufructuary_seat);
            fee_message::destroy_share_for_testing(fee_share);
            earnings_balance::destroy_for_testing(earnings);
        },
        RefundState::Total { usufructuary_seat } => {
            usufructuary_seat::destroy_for_testing(usufructuary_seat);
        },
    }
}

