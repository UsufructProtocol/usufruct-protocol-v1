// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_seat;

// === Imports ===

use sui::coin::Coin;
use usufruct::{
    monetary::Stake,
    owner_cap::{Self, OwnerCap, OwnerCapIdentity},
    owner_earning::{Self, OwnerEarnings},
    owner_identity::{Self, OwnerIdentity},
};

// === Errors ===

const EWrongCap: u64 = 1;

// === Constants ===

// === Structs ===

public struct OwnerSeat<phantom CoinType> has store {
    identity: OwnerIdentity,
    earnings: OwnerEarnings<CoinType>,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_identity<C>(o: &OwnerSeat<C>):  &OwnerIdentity { &o.identity }
public(package) fun proj_value<C>(o: &OwnerSeat<C>):     Stake          { owner_earning::proj_value(&o.earnings) }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new<C>(cap_identity: OwnerCapIdentity): OwnerSeat<C> {
    OwnerSeat {
        identity: owner_identity::new(cap_identity),
        earnings: owner_earning::zero<C>(),
    }
}

public(package) fun deposit<C>(self: &mut OwnerSeat<C>, incoming: OwnerEarnings<C>) {
    owner_earning::join(&mut self.earnings, incoming);
}

public(package) fun withdraw<C>(
    self: &mut OwnerSeat<C>,
    cap:  &OwnerCap,
    ctx:  &mut TxContext,
): Coin<C> {
    assert!(owner_cap::identity(cap) == owner_identity::proj_cap_identity(&self.identity), EWrongCap);
    owner_earning::drain_all(&mut self.earnings).into_coin(ctx)
}

public(package) fun destroy_empty<C>(o: OwnerSeat<C>) {
    let OwnerSeat { earnings, .. } = o;
    owner_earning::destroy_zero(earnings);
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(o: OwnerSeat<C>) {
    let OwnerSeat { earnings, .. } = o;
    owner_earning::destroy_for_testing(earnings);
}
