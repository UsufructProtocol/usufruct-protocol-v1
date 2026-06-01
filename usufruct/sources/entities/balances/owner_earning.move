// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_earning;

// === Imports ===

use sui::balance::{Self, Balance};
use usufruct::monetary::{Self, Stake};

// === Errors ===

// === Constants ===

// === Structs ===

public struct OwnerEarnings<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_value<C>(e: &OwnerEarnings<C>): Stake {
    monetary::stake(balance::value(&e.balance))
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(b: Balance<C>): OwnerEarnings<C> {
    OwnerEarnings { balance: b }
}

public(package) fun zero<C>(): OwnerEarnings<C> {
    OwnerEarnings { balance: balance::zero<C>() }
}

public(package) fun join<C>(target: &mut OwnerEarnings<C>, source: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = source;
    balance::join(&mut target.balance, balance);
}

public(package) fun drain_all<C>(e: &mut OwnerEarnings<C>): Balance<C> {
    balance::withdraw_all(&mut e.balance)
}

public(package) fun into_balance<C>(e: OwnerEarnings<C>): Balance<C> {
    let OwnerEarnings { balance } = e;
    balance
}

public(package) fun destroy_zero<C>(e: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = e;
    balance::destroy_zero(balance);
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(e: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = e;
    balance::destroy_for_testing(balance);
}
