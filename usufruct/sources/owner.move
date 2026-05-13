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

/// Withdraw was presented a cap whose object id does not match the
/// `cap_identity` recorded in `OwnerIdentity`. Indicates a mis-routed cap
/// or a coding bug at the call site.
const E_OWNER_WRONG_CAP: u64 = 1;

// === Constants ===

// === Structs ===

/// Identity half of an `Owner`. Single-component because the owner's
/// authority over the escrow is the cap_identity, and the destination of
/// withdrawals is the cap-bearer at withdraw-time (`tx_context::sender`),
/// not a pre-registered address. Asymmetric with `TenantIdentity` — and
/// the asymmetry is structural, not accidental.
public struct OwnerIdentity has copy, drop, store {
    cap_identity: OwnerCapIdentity,
}

/// Material half of an `Owner`. Wraps the accumulated earnings; the
/// same wrapper is also used as the in-transit type when shares flow
/// from a tenant's stake into the owner via `deposit` — collapse of
/// the in-storage and in-flight types, since both are just "balance
/// destined for the owner".
public struct OwnerEarnings<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

/// Entity = identity + material. Lives at the rental-escrow layer (one
/// per escrow); withdraw is gated by `OwnerCap` matching the bound
/// `cap_identity`. Has no per-owner state machine — orthogonal to the
/// rental lifecycle by design.
public struct Owner<phantom CoinType> has store {
    identity: OwnerIdentity,
    earnings: OwnerEarnings<CoinType>,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_identity<C>(o: &Owner<C>):              &OwnerIdentity     { &o.identity }
public(package) fun proj_value<C>(o: &Owner<C>):                 Stake              { monetary::stake(balance::value(&o.earnings.balance)) }
public(package) fun proj_cap_identity(id: &OwnerIdentity):       OwnerCapIdentity   { id.cap_identity }
public(package) fun proj_earnings_value<C>(e: &OwnerEarnings<C>): Stake             { monetary::stake(balance::value(&e.balance)) }

// === Admin Functions ===

// === Package Functions ===

/// Construct an `Owner` bound to `cap_identity` with zero earnings. Sole
/// construction site — the cap-layer supplies the cap_identity at escrow
/// creation time.
public(package) fun new<C>(cap_identity: OwnerCapIdentity): Owner<C> {
    Owner {
        identity: OwnerIdentity { cap_identity },
        earnings: OwnerEarnings { balance: balance::zero<C>() },
    }
}

/// Construct an `OwnerEarnings<C>` carrying `balance`. Used by upstream
/// producers (e.g. `tenant::take_owner_earnings`) that drain a portion
/// of stake destined for the owner.
public(package) fun new_earnings<C>(balance: Balance<C>): OwnerEarnings<C> {
    OwnerEarnings { balance }
}

/// Join an in-transit `OwnerEarnings<C>` into the long-lived earnings
/// of this `Owner`. Symmetric counterpart to `tenant::liquidate` (sends
/// to address) and `fee_message::post` (sends to inbox) — each
/// material-bearing wrapper has its own consumer in its owning module.
public(package) fun deposit<C>(self: &mut Owner<C>, incoming: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = incoming;
    balance::join(&mut self.earnings.balance, balance);
}

/// Drain all earnings as a `Coin<C>`, gated by the matching `OwnerCap`.
/// Aborts if the cap's object id does not match the cap_identity recorded
/// at construction. The earnings field is replaced with a fresh zero
/// balance — `Owner` lives on for further deposits.
public(package) fun withdraw<C>(
    self: &mut Owner<C>,
    cap:  &OwnerCap,
    ctx:  &mut TxContext,
): Coin<C> {
    assert!(owner_cap::identity(cap) == self.identity.cap_identity, E_OWNER_WRONG_CAP);
    let drained = balance::withdraw_all(&mut self.earnings.balance);
    drained.into_coin(ctx)
}

/// Tear down an `Owner<C>` known to hold zero earnings. Aborts via
/// `balance::destroy_zero` if the inner balance is non-zero — guards
/// the invariant at the consumption site rather than relying on caller
/// arithmetic. Symmetric with `tenant::destroy_empty_stake`. Used at
/// escrow-deletion time after `withdraw` has drained the earnings.
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
