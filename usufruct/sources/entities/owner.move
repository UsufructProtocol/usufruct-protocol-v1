// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner;

// === Imports ===

use sui::{balance::{Self, Balance}, coin::Coin};
use usufruct::{
    monetary::{Self, Stake},
    owner_cap::{Self, OwnerCap, OwnerCapIdentity},
};

// === Errors ===

const E_OWNER_WRONG_CAP: u64 = 1;

// === Constants ===

// === Structs ===

public struct OwnerIdentity has copy, drop, store {
    cap_identity: OwnerCapIdentity,
}

public struct OwnerEarnings<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

public struct Owner<phantom CoinType> has store {
    identity: OwnerIdentity,
    earnings: OwnerEarnings<CoinType>,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity<C>(o: &Owner<C>):              &OwnerIdentity     { &o.identity }
public(package) fun proj_value<C>(o: &Owner<C>):                 Stake              { monetary::stake(balance::value(&o.earnings.balance)) }
public(package) fun proj_cap_identity(id: &OwnerIdentity):       OwnerCapIdentity   { id.cap_identity }
public(package) fun proj_earnings_value<C>(e: &OwnerEarnings<C>): Stake             { monetary::stake(balance::value(&e.balance)) }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(cap_identity: OwnerCapIdentity): Owner<C> {
    Owner {
        identity: OwnerIdentity { cap_identity },
        earnings: OwnerEarnings { balance: balance::zero<C>() },
    }
}

public(package) fun new_earnings<C>(balance: Balance<C>): OwnerEarnings<C> {
    OwnerEarnings { balance }
}

public(package) fun deposit<C>(self: &mut Owner<C>, incoming: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = incoming;
    balance::join(&mut self.earnings.balance, balance);
}

public(package) fun withdraw<C>(
    self: &mut Owner<C>,
    cap:  &OwnerCap,
    ctx:  &mut TxContext,
): Coin<C> {
    assert!(owner_cap::identity(cap) == self.identity.cap_identity, E_OWNER_WRONG_CAP);
    let drained = balance::withdraw_all(&mut self.earnings.balance);
    drained.into_coin(ctx)
}

public(package) fun destroy_empty<C>(o: Owner<C>) {
    let Owner { earnings, .. } = o;
    let OwnerEarnings { balance } = earnings;
    balance::destroy_zero(balance);
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(o: Owner<C>) {
    let Owner { earnings, .. } = o;
    let OwnerEarnings { balance } = earnings;
    balance::destroy_for_testing(balance);
}

#[test_only]
public fun destroy_earnings_for_testing<C>(e: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = e;
    balance::destroy_for_testing(balance);
}

