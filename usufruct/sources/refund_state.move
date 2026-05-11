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

/// Transition residue produced by a lifecycle boundary that touches a
/// tenant's stake. Three variants encode the legal distribution shapes
/// of the departing tenant's funds:
///
///   · `Nothing`  — full stake consumed by owner+fee; tenant receives
///                   nothing back. No identity: there is no recipient,
///                   so carrying one would be a lie.
///   · `Parcial`  — stake split: owner + fee + remainder refunded to
///                   the tenant. Carries `identity` — the remainder has
///                   a recipient and the type must name them.
///   · `Total`    — full stake refunded to the tenant; no owner share,
///                   no fee. Carries `identity` — same reason as Parcial.
///
/// Hot potato: no abilities. Must be consumed in the same PTB it is
/// produced — by a `match` at the boundary, never stored. This makes
/// the legal-distribution shape unforgettable at the type level: a
/// caller cannot accidentally drop fees, lose a refund, or forget to
/// route the owner's share, because the enum cannot be discarded.
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

// ### RUNTIME PROJECTION FOR SDK ###

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

/// Construct `Nothing` — fee and owner shares routed to their consumers;
/// no remainder, no recipient.
public(package) fun nothing<C>(
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    RefundState::Nothing { fee_share, owner_earnings }
}

/// Construct `Parcial` — three-way split. The carried `stake` holds
/// the remainder destined for the tenant via `tenant::liquidate`.
public(package) fun parcial<C>(
    identity:       TenantIdentity,
    stake:          TenantStake<C>,
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    RefundState::Parcial { identity, stake, fee_share, owner_earnings }
}

/// Construct `Total` — full stake returns to the tenant; no owner or
/// fee involvement (e.g. displaced bid in `supersede_bid`).
public(package) fun total<C>(
    identity: TenantIdentity,
    stake:    TenantStake<C>,
): RefundState<C> {
    RefundState::Total { identity, stake }
}

/// Construct `Total` from a superseded bidder whose full stake is
/// returned with no owner or fee involvement.
public(package) fun from_superseded<C>(pending: Tenant<C>): RefundState<C> {
    let (identity, stake) = tenant::unbundle(pending);
    total(identity, stake)
}

/// Construct `Parcial` or `Nothing` from a departing `Tenant` whose
/// owner and fee shares have already been extracted. If the remaining
/// stake is non-zero the tenant gets a partial refund (`Parcial`);
/// otherwise the stake is empty and destroyed (`Nothing`). The
/// classification belongs here — the defining module — rather than at
/// every call site that produces a boundary refund.
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

/// Route all three terminal operations for the departing tenant's
/// funds. Exhaustive match over the three variants; lives here (the
/// defining module) so it can see variant internals directly.
///
///   Nothing — no recipient; deposit owner share, post fee.
///   Parcial — split stake; deposit + post + liquidate remainder to identity.
///   Total   — full stake refunded to identity; no owner/fee.
public(package) fun distribute<C>(
    rs:    RefundState<C>,
    owner: &mut Owner<C>,
    inbox: FeeInboxIdentity,
    ctx:   &mut TxContext,
) {
    match (rs) {
        RefundState::Nothing { fee_share, owner_earnings } => {
            owner::deposit(owner, owner_earnings);
            fee_message::post(fee_share, inbox, ctx);
        },
        RefundState::Parcial { identity, stake, fee_share, owner_earnings } => {
            owner::deposit(owner, owner_earnings);
            fee_message::post(fee_share, inbox, ctx);
            tenant::liquidate(stake, tenant::proj_address(&identity), ctx);
        },
        RefundState::Total { identity, stake } => {
            tenant::liquidate(stake, tenant::proj_address(&identity), ctx);
        },
    }
}

// === Private Functions ===

// === Test Functions ===

/// Consume a `RefundState` in tests, destroying any inner balance via
/// the test_only destructors of each component module. State-agnostic.
#[test_only]
public fun destroy_for_testing<C>(rs: RefundState<C>) {
    match (rs) {
        RefundState::Nothing { fee_share, owner_earnings } => {
            fee_message::destroy_share_for_testing(fee_share);
            owner::destroy_earnings_for_testing(owner_earnings);
        },
        RefundState::Parcial { identity: _, stake, fee_share, owner_earnings } => {
            tenant::destroy_stake_for_testing(stake);
            fee_message::destroy_share_for_testing(fee_share);
            owner::destroy_earnings_for_testing(owner_earnings);
        },
        RefundState::Total { identity: _, stake } => {
            tenant::destroy_stake_for_testing(stake);
        },
    }
}
