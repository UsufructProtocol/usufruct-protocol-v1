// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::stake_balance;

// === Imports ===

use sui::balance::{Self, Balance};
use usufruct::monetary::{Self, Stake};

// === Errors ===

// === Constants ===

// === Structs ===

public struct StakeBalance<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_value<C>(s: &StakeBalance<C>): Stake {
    monetary::stake(balance::value(&s.balance))
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(b: Balance<C>): StakeBalance<C> {
    StakeBalance { balance: b }
}

public(package) fun split<C>(s: &mut StakeBalance<C>, amount: Stake): Balance<C> {
    balance::split(&mut s.balance, monetary::stake_mist(amount))
}

public(package) fun destroy_zero<C>(s: StakeBalance<C>) {
    let StakeBalance { balance } = s;
    balance::destroy_zero(balance);
}

public(package) fun liquidate<C>(s: StakeBalance<C>, to: address, ctx: &mut TxContext) {
    let StakeBalance { balance } = s;
    transfer::public_transfer(balance.into_coin(ctx), to);
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(s: StakeBalance<C>) {
    let StakeBalance { balance } = s;
    balance::destroy_for_testing(balance);
}
