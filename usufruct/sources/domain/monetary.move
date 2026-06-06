// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::monetary;

// === Imports ===

use std::u64;

// === Errors ===

const EPriceAddOverflow: u64 = 0;

// === Constants ===

// === Structs ===

public struct Price has copy, drop, store { mist: u64 }

public struct Stake has copy, drop, store { mist: u64 }

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun price(mist: u64): Price { Price { mist } }
public(package) fun price_mist(p: Price): u64 { p.mist }

public(package) fun stake(mist: u64): Stake { Stake { mist } }

public(package) fun stake_mist(s: Stake): u64 { s.mist }

public(package) fun as_reference_price(s: Stake): Price { Price { mist: s.mist } }

public(package) fun compute_price_add(a: Price, b: Price): Price {
    let sum: u128 = (a.mist as u128) + (b.mist as u128);
    assert!(sum <= (u64::max_value!() as u128), EPriceAddOverflow);
    Price { mist: sum as u64 }
}
public(package) fun compute_price_sub(a: Price, b: Price): Price { Price { mist: a.mist - b.mist } }
public(package) fun compute_stake_sub(a: Stake, b: Stake): Stake { Stake { mist: a.mist - b.mist } }

// === Private Functions ===

// === Test Functions ===

