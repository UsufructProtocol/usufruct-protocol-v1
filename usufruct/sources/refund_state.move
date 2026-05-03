// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::refund_state;

// === Imports ===

use usufruct::{
    fee_message::FeeShare,
    owner::OwnerEarnings,
    tenant::{TenantIdentity, TenantStake},
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Transition residue produced by a lifecycle boundary that touches a
/// tenant's stake. Three variants encode the legal distribution shapes
/// of the departing tenant's funds:
///
///   · `Nothing`  — full stake consumed by owner+fee; tenant gets nothing
///                   back (e.g. tenure expiry; or accept_bid where
///                   used_credit == stake).
///   · `Parcial`  — stake split into owner + fee + remainder; remainder
///                   refunds to the tenant via the carried `stake`.
///   · `Total`    — full stake refunded to the tenant; no owner share,
///                   no fee (e.g. supersede_bid — displaced bid).
///
/// Hot potato: no abilities. Must be consumed in the same PTB it is
/// produced — by a `match` at the boundary, never stored. This makes
/// the legal-distribution shape unforgettable at the type level: a
/// caller cannot accidentally drop fees, lose a refund, or forget to
/// route the owner's share, because the enum cannot be discarded.
public enum RefundState<phantom CoinType> {
    Nothing {
        identity:       TenantIdentity,
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

// === Admin Functions ===

// === Package Functions ===

/// Construct `Nothing` — tenant identity preserved for events; fee and
/// owner shares routed to their consumers; no remainder.
public(package) fun nothing<C>(
    identity:       TenantIdentity,
    fee_share:      FeeShare<C>,
    owner_earnings: OwnerEarnings<C>,
): RefundState<C> {
    RefundState::Nothing { identity, fee_share, owner_earnings }
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

/// Sentinel for caller-contract violations on `consume_*` paths:
/// a refund variant other than the requested one was passed in.
/// The hot-potato structure already prevents accidental drops; this
/// constant only fires under a programming bug.
const EWrongVariant: u64 = 0xDEADC0DE;

/// Consume a `Total` refund and surface its components. Aborts via
/// `EWrongVariant` if the supplied refund is not `Total` —
/// `supersede_bid` is the only producer of this shape, and
/// `escrow_coordinator::do_supersede_bid` is the only consumer site.
/// Move 2024 restricts variant pattern matching to the defining
/// module, so callers route through this function rather than
/// matching directly.
public(package) fun consume_total<C>(rs: RefundState<C>): (TenantIdentity, TenantStake<C>) {
    match (rs) {
        RefundState::Total   { identity, stake } => (identity, stake),
        RefundState::Nothing { identity: _, fee_share: _fs, owner_earnings: _oe } =>
            abort EWrongVariant,
        RefundState::Parcial { identity: _, stake: _stk, fee_share: _fs, owner_earnings: _oe } =>
            abort EWrongVariant,
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun is_nothing<C>(rs: &RefundState<C>): bool {
    match (rs) {
        RefundState::Nothing { .. } => true,
        _                           => false,
    }
}

#[test_only]
public fun is_parcial<C>(rs: &RefundState<C>): bool {
    match (rs) {
        RefundState::Parcial { .. } => true,
        _                           => false,
    }
}

#[test_only]
public fun is_total<C>(rs: &RefundState<C>): bool {
    match (rs) {
        RefundState::Total { .. } => true,
        _                         => false,
    }
}

/// Consume a `RefundState` in tests, destroying any inner balance via
/// the test_only destructors of each component module. State-agnostic.
#[test_only]
public fun destroy_for_testing<C>(rs: RefundState<C>) {
    use usufruct::{fee_message, owner, tenant};
    match (rs) {
        RefundState::Nothing { identity: _, fee_share, owner_earnings } => {
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
