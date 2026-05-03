// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner;

// === Imports ===

use sui::{balance::{Self, Balance}, coin::{Self, Coin}};
use usufruct::owner_cap::OwnerCap;

// === Errors ===

/// Withdraw was presented a cap whose object id does not match the
/// `cap_id` recorded in `OwnerIdentity`. Indicates a mis-routed cap or
/// a coding bug at the call site.
const E_OWNER_WRONG_CAP: u64 = 1;

// === Constants ===

// === Structs ===

/// Identity half of an `Owner`. Single-component because the owner's
/// authority over the escrow is the cap_id, and the destination of
/// withdrawals is the cap-bearer at withdraw-time (`tx_context::sender`),
/// not a pre-registered address. Asymmetric with `TenantIdentity` — and
/// the asymmetry is structural, not accidental.
public struct OwnerIdentity has copy, drop, store {
    cap_id: ID,
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
/// `cap_id`. Has no per-owner state machine — orthogonal to the
/// rental lifecycle by design.
public struct Owner<phantom CoinType> has store {
    identity: OwnerIdentity,
    earnings: OwnerEarnings<CoinType>,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun identity<C>(o: &Owner<C>):              &OwnerIdentity     { &o.identity }
public(package) fun earnings<C>(o: &Owner<C>):              &OwnerEarnings<C>  { &o.earnings }
public(package) fun value<C>(o: &Owner<C>):                 u64                { balance::value(&o.earnings.balance) }
public(package) fun id_cap_id(id: &OwnerIdentity):          ID                 { id.cap_id }
public(package) fun earnings_value<C>(e: &OwnerEarnings<C>): u64               { balance::value(&e.balance) }

// === Admin Functions ===

// === Package Functions ===

/// Construct an `Owner` bound to `cap_id` with zero earnings. Sole
/// construction site — the cap-layer supplies the cap_id at escrow
/// creation time.
public(package) fun new<C>(cap_id: ID): Owner<C> {
    Owner {
        identity: OwnerIdentity { cap_id },
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
/// Aborts if the cap's object id does not match the cap_id recorded at
/// construction. The earnings field is replaced with a fresh zero
/// balance — `Owner` lives on for further deposits.
public(package) fun withdraw<C>(
    self: &mut Owner<C>,
    cap:  &OwnerCap,
    ctx:  &mut TxContext,
): Coin<C> {
    assert!(object::id(cap) == self.identity.cap_id, E_OWNER_WRONG_CAP);
    let drained = balance::withdraw_all(&mut self.earnings.balance);
    coin::from_balance(drained, ctx)
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public fun destroy_for_testing<C>(o: Owner<C>) {
    let Owner { identity: _, earnings } = o;
    let OwnerEarnings { balance } = earnings;
    balance::destroy_for_testing(balance);
}

#[test_only]
public fun destroy_earnings_for_testing<C>(e: OwnerEarnings<C>) {
    let OwnerEarnings { balance } = e;
    balance::destroy_for_testing(balance);
}
