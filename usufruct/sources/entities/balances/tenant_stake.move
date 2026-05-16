// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant_stake;

// === Imports ===

use sui::balance::{Self, Balance};
use usufruct::monetary::{Self, Stake};

// === Errors ===

// === Constants ===

// === Structs ===

public struct TenantStake<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_value<C>(s: &TenantStake<C>): Stake {
    monetary::stake(balance::value(&s.balance))
}

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(b: Balance<C>): TenantStake<C> {
    TenantStake { balance: b }
}

public(package) fun split<C>(s: &mut TenantStake<C>, amount: Stake): Balance<C> {
    balance::split(&mut s.balance, monetary::stake_mist(amount))
}

public(package) fun destroy_zero<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_zero(balance);
}

public(package) fun liquidate<C>(s: TenantStake<C>, to: address, ctx: &mut TxContext) {
    let TenantStake { balance } = s;
    transfer::public_transfer(balance.into_coin(ctx), to);
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_for_testing(balance);
}
