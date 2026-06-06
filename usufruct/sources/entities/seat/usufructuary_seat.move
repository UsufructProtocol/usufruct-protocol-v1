// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::usufructuary_seat;

// === Imports ===

use sui::balance::Balance;
use usufruct::{
    escrow_identity::EscrowIdentity,
    fee_message::{Self, FeeShare},
    monetary::Stake,
    earnings_balance::{Self, EarningsBalance},
    refund_address::RefundAddress,
    usufruct_cap::UsufructCapIdentity,
    usufructuary_identity::{Self, UsufructuaryIdentity},
    stake_balance::{Self, StakeBalance},
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct UsufructuarySeat<phantom CoinType> has store {
    identity: UsufructuaryIdentity,
    stake:    StakeBalance<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity<C>(t: &UsufructuarySeat<C>):    &UsufructuaryIdentity { &t.identity }
public(package) fun proj_stake_value<C>(t: &UsufructuarySeat<C>): Stake           { stake_balance::proj_value(&t.stake) }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(
    cap_identity: UsufructCapIdentity,
    refund:       RefundAddress,
    balance:      Balance<C>,
): UsufructuarySeat<C> {
    UsufructuarySeat {
        identity: usufructuary_identity::new(cap_identity, refund),
        stake:    stake_balance::new(balance),
    }
}

public(package) fun unbundle<C>(t: UsufructuarySeat<C>): (UsufructuaryIdentity, StakeBalance<C>) {
    let UsufructuarySeat { identity, stake } = t;
    (identity, stake)
}

public(package) fun set_refund_address<C>(t: &mut UsufructuarySeat<C>, new: RefundAddress) {
    usufructuary_identity::set_address(&mut t.identity, new);
}

public(package) fun take_fee_share<C>(
    t:               &mut UsufructuarySeat<C>,
    amount:          Stake,
    escrow_identity: EscrowIdentity,
): FeeShare<C> {
    let part = stake_balance::split(&mut t.stake, amount);
    fee_message::new_share(part, escrow_identity)
}

public(package) fun take_earnings<C>(
    t:      &mut UsufructuarySeat<C>,
    amount: Stake,
): EarningsBalance<C> {
    let part = stake_balance::split(&mut t.stake, amount);
    earnings_balance::new(part)
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public(package) fun proj_stake<C>(t: &UsufructuarySeat<C>): &StakeBalance<C> { &t.stake }

#[test_only]
public fun destroy_for_testing<C>(t: UsufructuarySeat<C>) {
    let UsufructuarySeat { stake, .. } = t;
    stake_balance::destroy_for_testing(stake);
}
