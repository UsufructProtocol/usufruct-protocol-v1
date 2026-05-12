// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::monetary;

// === Imports ===

use std::u64;

// === Errors ===

const EPriceAddOverflow: u64 = 0;

// === Constants ===

// === Structs ===

/// A monetary value not yet paid — a reference price, floor, or configured increment.
public struct Price has copy, drop, store { mist: u64 }

/// A monetary value already paid — collateral held by a tenant.
/// Semantically distinct from Price: a Stake is a Price that has been actualized.
public struct Stake has copy, drop, store { mist: u64 }

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun price(mist: u64): Price { Price { mist } }
public(package) fun stake(mist: u64): Stake { Stake { mist } }

public(package) fun price_mist(p: Price): u64 { p.mist }
public(package) fun stake_mist(s: Stake): u64 { s.mist }

/// Tenure expiry: the Stake paid by the last tenant becomes the acquisition
/// reference price for the Dutch auction descent.
public(package) fun as_reference_price(s: Stake): Price { Price { mist: s.mist } }

public(package) fun price_add(a: Price, b: Price): Price {
    let sum: u128 = (a.mist as u128) + (b.mist as u128);
    assert!(sum <= (u64::max_value!() as u128), EPriceAddOverflow);
    Price { mist: sum as u64 }
}
public(package) fun price_sub(a: Price, b: Price): Price { Price { mist: a.mist - b.mist } }
public(package) fun stake_sub(a: Stake, b: Stake): Stake { Stake { mist: a.mist - b.mist } }

// === Private Functions ===

// === Test Functions ===
