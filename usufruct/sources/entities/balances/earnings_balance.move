// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::earnings_balance;

// === Imports ===

use sui::balance::{Self, Balance};
use usufruct::monetary::{Self, Stake};

// === Errors ===

// === Constants ===

// === Structs ===

public struct EarningsBalance<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_value<C>(e: &EarningsBalance<C>): Stake {
    monetary::stake(balance::value(&e.balance))
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(b: Balance<C>): EarningsBalance<C> {
    EarningsBalance { balance: b }
}

public(package) fun zero<C>(): EarningsBalance<C> {
    EarningsBalance { balance: balance::zero<C>() }
}

public(package) fun join<C>(target: &mut EarningsBalance<C>, source: EarningsBalance<C>) {
    let EarningsBalance { balance } = source;
    balance::join(&mut target.balance, balance);
}

public(package) fun drain_all<C>(e: &mut EarningsBalance<C>): Balance<C> {
    balance::withdraw_all(&mut e.balance)
}

public(package) fun into_balance<C>(e: EarningsBalance<C>): Balance<C> {
    let EarningsBalance { balance } = e;
    balance
}

public(package) fun destroy_zero<C>(e: EarningsBalance<C>) {
    let EarningsBalance { balance } = e;
    balance::destroy_zero(balance);
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(e: EarningsBalance<C>) {
    let EarningsBalance { balance } = e;
    balance::destroy_for_testing(balance);
}
