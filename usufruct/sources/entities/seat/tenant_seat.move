// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_seat;

// === Imports ===

use sui::balance::Balance;
use usufruct::{
    escrow_identity::EscrowIdentity,
    fee_message::{Self, FeeShare},
    monetary::Stake,
    owner_earning::{Self, OwnerEarnings},
    tenant_cap::TenantCapIdentity,
    tenant_identity::{Self, TenantIdentity},
    tenant_stake::{Self, TenantStake},
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct TenantSeat<phantom CoinType> has store {
    identity: TenantIdentity,
    stake:    TenantStake<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity<C>(t: &TenantSeat<C>):    &TenantIdentity { &t.identity }
public(package) fun proj_stake_value<C>(t: &TenantSeat<C>): Stake           { tenant_stake::proj_value(&t.stake) }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(
    cap_identity: TenantCapIdentity,
    address:      address,
    balance:      Balance<C>,
): TenantSeat<C> {
    TenantSeat {
        identity: tenant_identity::new(cap_identity, address),
        stake:    tenant_stake::new(balance),
    }
}

public(package) fun unbundle<C>(t: TenantSeat<C>): (TenantIdentity, TenantStake<C>) {
    let TenantSeat { identity, stake } = t;
    (identity, stake)
}

public(package) fun take_fee_share<C>(
    t:               &mut TenantSeat<C>,
    amount:          Stake,
    escrow_identity: EscrowIdentity,
): FeeShare<C> {
    let part = tenant_stake::split(&mut t.stake, amount);
    fee_message::new_share(part, escrow_identity)
}

public(package) fun take_owner_earnings<C>(
    t:      &mut TenantSeat<C>,
    amount: Stake,
): OwnerEarnings<C> {
    let part = tenant_stake::split(&mut t.stake, amount);
    owner_earning::new(part)
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun proj_stake<C>(t: &TenantSeat<C>): &TenantStake<C> { &t.stake }

#[test_only]
public fun destroy_for_testing<C>(t: TenantSeat<C>) {
    let TenantSeat { stake, .. } = t;
    tenant_stake::destroy_for_testing(stake);
}
