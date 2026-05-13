// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant;

// === Imports ===

use sui::balance::{Self, Balance};
use usufruct::{
    escrow_identity::EscrowIdentity,
    fee_message::{Self, FeeShare},
    monetary::{Self, Stake},
    owner::{Self, OwnerEarnings},
    tenant_cap::TenantCapIdentity,
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Identity half of a `Tenant`. Two-component because the tenant's
/// authority over the slot is the cap_identity, while its destination for
/// payments (refunds, liquidate) is the address. Both irreducible.
public struct TenantIdentity has copy, drop, store {
    cap_identity: TenantCapIdentity,
    address:      address,
}

/// Material half of a `Tenant`. Wraps the tenant's collateral so raw
/// `Balance<C>` never crosses module borders — splits return typed
/// shares destined for specific consumers (FeeShare for fees,
/// OwnerEarnings later for owner). The internal raw Balance is reached
/// only inside this module.
public struct TenantStake<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

/// Entity = identity + material. Lives in `TenantState` slots; on
/// departure it is decomposed via `unbundle` (or consumed directly by
/// `liquidate`) at the lifecycle/refund boundary.
public struct Tenant<phantom CoinType> has store {
    identity: TenantIdentity,
    stake:    TenantStake<CoinType>,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_identity<C>(t: &Tenant<C>):      &TenantIdentity { &t.identity }
public(package) fun proj_stake_value<C>(t: &Tenant<C>):   Stake           { monetary::stake(balance::value(&t.stake.balance)) }
public(package) fun proj_cap_identity(id: &TenantIdentity):      TenantCapIdentity { id.cap_identity }
public(package) fun proj_address(id: &TenantIdentity):     address         { id.address }

// === Admin Functions ===

// === Package Functions ===

/// Bundle raw tenant data into a `Tenant`. Sole construction site —
/// the cap-layer (or a test) supplies the three components and the
/// nested wrappers are built internally.
public(package) fun new<C>(
    cap_identity: TenantCapIdentity,
    address:      address,
    balance:      Balance<C>,
): Tenant<C> {
    Tenant {
        identity: TenantIdentity { cap_identity, address },
        stake:    TenantStake { balance },
    }
}

/// Decompose a `Tenant` into its two halves. Identity is needed for
/// events; stake travels onward (liquidate, destroy_empty, …).
public(package) fun unbundle<C>(t: Tenant<C>): (TenantIdentity, TenantStake<C>) {
    let Tenant { identity, stake } = t;
    (identity, stake)
}

/// Drop a stake known to be empty. Aborts if non-zero — guards the
/// invariant at the consumption site rather than relying on caller
/// arithmetic.
public(package) fun destroy_empty_stake<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_zero(balance);
}

/// Drain `amount` off the tenant's stake as a `FeeShare<C>` destined
/// for `escrow_identity`. Aborts via `balance::split` if `amount > stake`.
public(package) fun take_fee_share<C>(
    t:               &mut Tenant<C>,
    amount:          Stake,
    escrow_identity: EscrowIdentity,
): FeeShare<C> {
    let part = balance::split(&mut t.stake.balance, monetary::stake_mist(amount));
    fee_message::new_share(part, escrow_identity)
}

/// Drain `amount` off the tenant's stake as an `OwnerEarnings<C>`
/// ready to be `deposit`-ed into an `Owner`. Aborts via `balance::split`
/// if `amount > stake`.
public(package) fun take_owner_earnings<C>(
    t:      &mut Tenant<C>,
    amount: Stake,
): OwnerEarnings<C> {
    let part = balance::split(&mut t.stake.balance, monetary::stake_mist(amount));
    owner::new_earnings(part)
}

/// Consume a `TenantStake<C>` and send its balance to `to` as a
/// `Coin<C>`. Symmetric counterpart to `fee_message::post` (sends to
/// inbox) and `owner_earning::deposit` (joins into earning) — each
/// material-bearing wrapper has its own terminal operation in its
/// owning module.
public(package) fun liquidate<C>(
    stake: TenantStake<C>,
    to:    address,
    ctx:   &mut TxContext,
) {
    let TenantStake { balance } = stake;
    transfer::public_transfer(balance.into_coin(ctx), to);
}

// === Private Functions ===

// === Test Functions ===

/// Borrow the inner `TenantStake`. Test-only — production code uses
/// `proj_stake_value` to skip the intermediate borrow.
#[test_only]
public fun proj_stake<C>(t: &Tenant<C>): &TenantStake<C> { &t.stake }

/// Stake value via a `&TenantStake` borrow. Test-only counterpart of
/// `proj_stake_value(&Tenant)` for the unbundled half.
#[test_only]
public fun proj_stake_value_of<C>(s: &TenantStake<C>): Stake {
    monetary::stake(balance::value(&s.balance))
}

/// Destroy a `Tenant` regardless of stake — releases the inner balance
/// via `balance::destroy_for_testing`.
#[test_only]
public fun destroy_for_testing<C>(t: Tenant<C>) {
    let Tenant { stake, .. } = t;
    let TenantStake { balance } = stake;
    balance::destroy_for_testing(balance);
}

/// Destroy a `TenantStake` regardless of value — releases the inner
/// balance via `balance::destroy_for_testing`.
#[test_only]
public fun destroy_stake_for_testing<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_for_testing(balance);
}
