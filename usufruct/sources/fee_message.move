// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::fee_message;

// === Imports ===

use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin},
    event,
    transfer::Receiving,
};
use usufruct::{
    escrow_identity::{Self, EscrowIdentity},
    monetary::{Self, Stake},
    protocol_fee_inbox::{Self, ProtocolFeeInbox},
    protocol_fee_ref::{Self, FeeInboxIdentity},
};

// === Errors ===

// === Constants ===

// === Structs ===

/// Pre-message wrapper carrying the balance + escrow_id for a fee
/// transfer. Constructed by the producer (e.g. tenant draining a fee
/// share off its stake) and consumed by `post`, which mints the
/// on-chain `FeeMessage<C>` object and ships it to the inbox. The
/// share never reaches on-chain storage — it lives only in PTB scope
/// between the split site and the post site.
public struct FeeShare<phantom CoinType> has store {
    balance: Balance<CoinType>,
    escrow:  EscrowIdentity,
}

public struct FeeMessage<phantom CoinType> has key {
    id:      UID,
    escrow:  EscrowIdentity,
    balance: Balance<CoinType>,
}

// === Events ===

public struct FeeMessageSent<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
}

public struct FeeMessageCollected<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
    collector:      address,
}

// === Method Aliases ===

// === Public Functions ===

/// Pipeline of receive + consume over all tickets for one CoinType. Returns a
/// single `Coin<C>` accumulating all drained balances.
public fun collect_fee_messages<C>(
    inbox:   &mut ProtocolFeeInbox,
    tickets: vector<Receiving<FeeMessage<C>>>,
    ctx:     &mut TxContext,
): Coin<C> {
    let inbox_identity = protocol_fee_ref::fee_inbox_identity(object::id(inbox));
    let collector      = tx_context::sender(ctx);
    let mut total      = balance::zero<C>();
    tickets.do!(|ticket| {
        let msg = receive_message(inbox, ticket);
        balance::join(&mut total, consume_message(msg, inbox_identity, collector));
    });
    coin::from_balance(total, ctx)
}

// === View Functions ===

// ### RUNTIME PROJECTION FOR SDK ###

public(package) fun proj_share_value<C>(s: &FeeShare<C>): Stake { monetary::stake(balance::value(&s.balance)) }

public(package) fun proj_escrow_id<C>(msg: &FeeMessage<C>): ID    { escrow_identity::escrow_id(msg.escrow) }

// === Admin Functions ===

// === Package Functions ===

/// Construct a `FeeShare<C>` carrying `balance` destined for the fee
/// flow of `escrow_id`. Pre-message form — no UID minted yet; the
/// on-chain `FeeMessage<C>` is built inside `post`.
public(package) fun new_share<C>(balance: Balance<C>, escrow: EscrowIdentity): FeeShare<C> {
    FeeShare { balance, escrow }
}

/// Mint a `FeeMessage<C>` from `share`, transfer it to `inbox`
/// via transfer-to-object, and emit `FeeMessageSent<C>`. Fused — no
/// caller ever holds a `FeeMessage<C>` as a local.
public(package) fun post<C>(
    share: FeeShare<C>,
    inbox: FeeInboxIdentity,
    ctx:   &mut TxContext,
) {
    let FeeShare { balance, escrow } = share;
    let amount         = balance::value(&balance);
    let fee_inbox_id   = protocol_fee_ref::inbox_id(inbox);
    let escrow_id      = escrow_identity::escrow_id(escrow);
    let msg = FeeMessage<C> {
        id: object::new(ctx),
        escrow,
        balance,
    };
    let fee_message_id = object::uid_to_inner(&msg.id);
    transfer::transfer(msg, fee_inbox_id.to_address());
    event::emit(FeeMessageSent<C> { fee_message_id, fee_inbox_id, escrow_id, amount });
}

// === Private Functions ===

fun receive_message<C>(
    inbox:  &mut ProtocolFeeInbox,
    ticket: Receiving<FeeMessage<C>>,
): FeeMessage<C> {
    transfer::receive(protocol_fee_inbox::uid_mut(inbox), ticket)
}

fun consume_message<C>(
    msg:       FeeMessage<C>,
    inbox:     FeeInboxIdentity,
    collector: address,
): Balance<C> {
    let FeeMessage { id, escrow, balance } = msg;
    let fee_message_id = object::uid_to_inner(&id);
    let amount         = balance::value(&balance);
    let fee_inbox_id   = protocol_fee_ref::inbox_id(inbox);
    let escrow_id      = escrow_identity::escrow_id(escrow);
    object::delete(id);
    event::emit(FeeMessageCollected<C> { fee_message_id, fee_inbox_id, escrow_id, amount, collector });
    balance
}

// === Test Functions ===

#[test_only]
public fun receive_message_for_testing<C>(
    inbox:  &mut ProtocolFeeInbox,
    ticket: Receiving<FeeMessage<C>>,
): FeeMessage<C> {
    receive_message(inbox, ticket)
}

#[test_only]
public fun consume_message_for_testing<C>(
    msg:          FeeMessage<C>,
    fee_inbox_id: ID,
    collector:    address,
): Balance<C> {
    consume_message(msg, protocol_fee_ref::fee_inbox_identity(fee_inbox_id), collector)
}

// FeeShare field accessors (struct fields are module-private)
#[test_only]
public fun share_escrow_id<C>(s: &FeeShare<C>): ID { escrow_identity::escrow_id(s.escrow) }
#[test_only]
public fun destroy_share_for_testing<C>(s: FeeShare<C>) {
    let FeeShare { balance, escrow: _ } = s;
    balance::destroy_for_testing(balance);
}

// FeeMessageSent field accessors (struct fields are module-private)
#[test_only]
public fun sent_fee_message_id<C>(e: &FeeMessageSent<C>): ID { e.fee_message_id }
#[test_only]
public fun sent_fee_inbox_id<C>(e: &FeeMessageSent<C>): ID { e.fee_inbox_id }
#[test_only]
public fun sent_escrow_id<C>(e: &FeeMessageSent<C>): ID { e.escrow_id }
#[test_only]
public fun sent_amount<C>(e: &FeeMessageSent<C>): u64 { e.amount }

// FeeMessageCollected field accessors
#[test_only]
public fun collected_fee_message_id<C>(e: &FeeMessageCollected<C>): ID { e.fee_message_id }
#[test_only]
public fun collected_fee_inbox_id<C>(e: &FeeMessageCollected<C>): ID { e.fee_inbox_id }
#[test_only]
public fun collected_escrow_id<C>(e: &FeeMessageCollected<C>): ID { e.escrow_id }
#[test_only]
public fun collected_amount<C>(e: &FeeMessageCollected<C>): u64 { e.amount }
#[test_only]
public fun collected_collector<C>(e: &FeeMessageCollected<C>): address { e.collector }
