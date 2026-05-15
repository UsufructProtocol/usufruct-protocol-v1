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

public struct TenantIdentity has copy, drop, store {
    cap_identity: TenantCapIdentity,
    address:      address,
}

public struct TenantStake<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

public struct Tenant<phantom CoinType> has store {
    identity: TenantIdentity,
    stake:    TenantStake<CoinType>,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity<C>(t: &Tenant<C>):      &TenantIdentity { &t.identity }
public(package) fun proj_stake_value<C>(t: &Tenant<C>):   Stake           { monetary::stake(balance::value(&t.stake.balance)) }
public(package) fun proj_cap_identity(id: &TenantIdentity):      TenantCapIdentity { id.cap_identity }
public(package) fun proj_address(id: &TenantIdentity):     address         { id.address }

// === Admin Functions ===

// === Package Functions ===

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

public(package) fun unbundle<C>(t: Tenant<C>): (TenantIdentity, TenantStake<C>) {
    let Tenant { identity, stake } = t;
    (identity, stake)
}

public(package) fun destroy_empty_stake<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_zero(balance);
}

public(package) fun take_fee_share<C>(
    t:               &mut Tenant<C>,
    amount:          Stake,
    escrow_identity: EscrowIdentity,
): FeeShare<C> {
    let part = balance::split(&mut t.stake.balance, monetary::stake_mist(amount));
    fee_message::new_share(part, escrow_identity)
}

public(package) fun take_owner_earnings<C>(
    t:      &mut Tenant<C>,
    amount: Stake,
): OwnerEarnings<C> {
    let part = balance::split(&mut t.stake.balance, monetary::stake_mist(amount));
    owner::new_earnings(part)
}

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

#[test_only]
public fun proj_stake<C>(t: &Tenant<C>): &TenantStake<C> { &t.stake }

#[test_only]
public fun proj_stake_value_of<C>(s: &TenantStake<C>): Stake {
    monetary::stake(balance::value(&s.balance))
}

#[test_only]
public fun destroy_for_testing<C>(t: Tenant<C>) {
    let Tenant { stake, .. } = t;
    let TenantStake { balance } = stake;
    balance::destroy_for_testing(balance);
}

#[test_only]
public fun destroy_stake_for_testing<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_for_testing(balance);
}

