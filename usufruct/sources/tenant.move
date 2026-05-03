// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::tenant;

// === Imports ===

use sui::{balance::{Self, Balance}, coin};
use usufruct::{
    fee_message::{Self, FeeShare},
    owner::{Self, OwnerEarnings},
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Identity half of a `Tenant`. Two-component because the tenant's
/// authority over the slot is the cap_id, while its destination for
/// payments (refunds, liquidate) is the address. Both irreducible.
public struct TenantIdentity has copy, drop, store {
    cap_id:  ID,
    address: address,
}

/// Material half of a `Tenant`. Wraps the tenant's collateral so raw
/// `Balance<C>` never crosses module borders — splits return typed
/// shares destined for specific consumers (FeeShare for fees,
/// OwnerEarnings later for owner). The internal raw Balance is reached
/// only inside this module.
public struct TenantStake<phantom CoinType> has store {
    balance: Balance<CoinType>,
}

/// Entity = identity + material. Lives in `TenantState` slots; on
/// departure it is decomposed via `unbundle` (or consumed directly by
/// `liquidate`) at the lifecycle/refund boundary.
public struct Tenant<phantom CoinType> has store {
    identity: TenantIdentity,
    stake:    TenantStake<CoinType>,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun identity<C>(t: &Tenant<C>):     &TenantIdentity   { &t.identity }
public(package) fun stake<C>(t: &Tenant<C>):        &TenantStake<C>   { &t.stake }
public(package) fun stake_value<C>(t: &Tenant<C>):  u64               { balance::value(&t.stake.balance) }

public(package) fun id_cap_id(id: &TenantIdentity):  ID      { id.cap_id }
public(package) fun id_address(id: &TenantIdentity): address { id.address }

public(package) fun stake_value_of<C>(s: &TenantStake<C>): u64 { balance::value(&s.balance) }

// === Admin Functions ===

// === Package Functions ===

/// Bundle raw tenant data into a `Tenant`. Sole construction site —
/// the cap-layer (or a test) supplies the three components and the
/// nested wrappers are built internally.
public(package) fun new<C>(
    cap_id:  ID,
    address: address,
    balance: Balance<C>,
): Tenant<C> {
    Tenant {
        identity: TenantIdentity { cap_id, address },
        stake:    TenantStake { balance },
    }
}

/// Decompose a `Tenant` into its two halves. Identity is needed for
/// events; stake travels onward (liquidate, destroy_empty, …).
public(package) fun unbundle<C>(t: Tenant<C>): (TenantIdentity, TenantStake<C>) {
    let Tenant { identity, stake } = t;
    (identity, stake)
}

/// Drop a stake known to be empty. Aborts if non-zero — guards the
/// invariant at the consumption site rather than relying on caller
/// arithmetic.
public(package) fun destroy_empty_stake<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_zero(balance);
}

/// Drain `amount` off the tenant's stake as a `FeeShare<C>` destined
/// for `escrow_id`. Aborts via `balance::split` if `amount > stake`.
public(package) fun take_fee_share<C>(
    t:         &mut Tenant<C>,
    amount:    u64,
    escrow_id: ID,
): FeeShare<C> {
    let part = balance::split(&mut t.stake.balance, amount);
    fee_message::new_share(part, escrow_id)
}

/// Drain `amount` off the tenant's stake as an `OwnerEarnings<C>`
/// ready to be `deposit`-ed into an `Owner`. Aborts via `balance::split`
/// if `amount > stake`.
public(package) fun take_owner_earnings<C>(
    t:      &mut Tenant<C>,
    amount: u64,
): OwnerEarnings<C> {
    let part = balance::split(&mut t.stake.balance, amount);
    owner::new_earnings(part)
}

/// Drain `amount` off the tenant's stake as a raw `Balance<C>`.
/// Temporary primitive used by callers whose destination wrapper
/// does not yet exist (owner side) — to be replaced by
/// `take_owner_earnings` once `owner.move` lands.
public(package) fun split_stake<C>(
    t:      &mut Tenant<C>,
    amount: u64,
): Balance<C> {
    balance::split(&mut t.stake.balance, amount)
}

/// Consume a `TenantStake<C>` and send its balance to `to` as a
/// `Coin<C>`. Symmetric counterpart to `fee_message::post` (sends to
/// inbox) and `owner_earning::deposit` (joins into earning) — each
/// material-bearing wrapper has its own terminal operation in its
/// owning module.
public(package) fun liquidate<C>(
    stake: TenantStake<C>,
    to:    address,
    ctx:   &mut TxContext,
) {
    let TenantStake { balance } = stake;
    transfer::public_transfer(coin::from_balance(balance, ctx), to);
}

// === Private Functions ===

// === Test Functions ===

/// Destroy a `Tenant` regardless of stake — releases the inner balance
/// via `balance::destroy_for_testing`.
#[test_only]
public fun destroy_for_testing<C>(t: Tenant<C>) {
    let Tenant { identity: _, stake } = t;
    let TenantStake { balance } = stake;
    balance::destroy_for_testing(balance);
}

/// Destroy a `TenantStake` regardless of value — releases the inner
/// balance via `balance::destroy_for_testing`.
#[test_only]
public fun destroy_stake_for_testing<C>(s: TenantStake<C>) {
    let TenantStake { balance } = s;
    balance::destroy_for_testing(balance);
}
