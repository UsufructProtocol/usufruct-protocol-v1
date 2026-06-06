// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

/// A minimal free-mint test coin for demonstrating usufruct priced in a non-SUI
/// coin. The `TreasuryCap` is shared at publish time, so `mint` is permissionless:
/// anyone can mint any amount, with no faucet, rate limit, or human in the loop —
/// the coin analogue of `dummy_asset::mint`. usufruct is agnostic to the rent coin;
/// this is just the zero-friction default for a non-SUI demo.
module dummy_coin::dummy_coin;

use sui::coin::{Self, TreasuryCap, Coin};

/// One-time witness — must match the module name uppercased.
public struct DUMMY_COIN has drop {}

#[allow(deprecated_usage)]
fun init(witness: DUMMY_COIN, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        witness,
        9,                                          // decimals (mirrors SUI/MIST)
        b"DUMMY",
        b"Dummy Test Coin",
        b"Free-mint test coin for usufruct demos on testnet",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    // Share the cap so mint is permissionless — this is the "faucet".
    transfer::public_share_object(treasury);
}

/// Free, permissionless mint — the demo faucet. Returns `Coin<DUMMY_COIN>` you keep
/// (e.g. split a rent stake from it, or pass the whole coin to `escrow::rent`).
public fun mint(treasury: &mut TreasuryCap<DUMMY_COIN>, amount: u64, ctx: &mut TxContext): Coin<DUMMY_COIN> {
    coin::mint(treasury, amount, ctx)
}

/// Burn test coins when you're done.
public fun burn(treasury: &mut TreasuryCap<DUMMY_COIN>, coin: Coin<DUMMY_COIN>) {
    coin::burn(treasury, coin);
}
