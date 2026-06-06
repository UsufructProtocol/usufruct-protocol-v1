// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::earnings_message;

// === Imports ===

use std::string::{Self, String};
use std::type_name;
use sui::{
    balance::{Self, Balance},
    coin::Coin,
    event,
    transfer::Receiving,
};
use usufruct::{
    earnings_inbox::{Self, EarningsInbox, EarningsInboxIdentity},
    escrow_identity::{Self, EscrowIdentity},
    earnings_balance::{Self, EarningsBalance},
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct EarningsMessage<phantom CoinType> has key {
    id:      UID,
    balance: Balance<CoinType>,
}

// === Events ===

public struct EarningsMessagePosted has copy, drop {
    escrow_id:           ID,
    earnings_message_id: ID,
    earnings_inbox_id:   ID,
    amount:              u64,
    coin_type:           String,
}

public struct EarningsMessageCollected has copy, drop {
    earnings_message_id: ID,
    earnings_inbox_id:   ID,
    amount:              u64,
    collector:           address,
    coin_type:           String,
}

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun collect_earnings_messages<C>(
    inbox:   &mut EarningsInbox,
    tickets: vector<Receiving<EarningsMessage<C>>>,
    ctx:     &mut TxContext,
): Coin<C> {
    let inbox_identity = earnings_inbox::inbox_identity(object::id(inbox));
    let collector      = ctx.sender();
    let mut total      = balance::zero<C>();
    tickets.do!(|ticket| {
        let msg = receive_message(inbox, ticket);
        balance::join(&mut total, consume_message(msg, inbox_identity, collector));
    });
    total.into_coin(ctx)
}

public(package) fun post<C>(
    earnings:           EarningsBalance<C>,
    inbox_identity:     EarningsInboxIdentity,
    escrow_identity:    EscrowIdentity,
    ctx:                &mut TxContext,
) {
    let balance           = earnings_balance::into_balance(earnings);
    let amount            = balance::value(&balance);
    let earnings_inbox_id = earnings_inbox::proj_id(inbox_identity);
    let escrow_id         = escrow_identity::escrow_id(escrow_identity);
    let msg = EarningsMessage<C> {
        id: object::new(ctx),
        balance,
    };
    let earnings_message_id = object::uid_to_inner(&msg.id);
    transfer::transfer(msg, earnings_inbox_id.to_address());
    event::emit(EarningsMessagePosted { earnings_message_id, earnings_inbox_id, escrow_id, amount, coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<C>())) });
}

// === Private Functions ===

fun receive_message<C>(
    inbox:  &mut EarningsInbox,
    ticket: Receiving<EarningsMessage<C>>,
): EarningsMessage<C> {
    transfer::receive(earnings_inbox::uid_mut(inbox), ticket)
}

fun consume_message<C>(
    msg:            EarningsMessage<C>,
    inbox_identity: EarningsInboxIdentity,
    collector:      address,
): Balance<C> {
    let EarningsMessage { id, balance } = msg;
    let earnings_message_id = object::uid_to_inner(&id);
    let amount              = balance::value(&balance);
    let earnings_inbox_id   = earnings_inbox::proj_id(inbox_identity);
    id.delete();
    event::emit(EarningsMessageCollected { earnings_message_id, earnings_inbox_id, amount, collector, coin_type: string::from_ascii(type_name::into_string(type_name::with_defining_ids<C>())) });
    balance
}

// === Test Functions ===

#[test_only]
public fun receive_message_for_testing<C>(
    inbox:  &mut EarningsInbox,
    ticket: Receiving<EarningsMessage<C>>,
): EarningsMessage<C> {
    receive_message(inbox, ticket)
}

#[test_only]
public fun consume_message_for_testing<C>(
    msg:              EarningsMessage<C>,
    earnings_inbox_id: ID,
    collector:        address,
): Balance<C> {
    consume_message(msg, earnings_inbox::inbox_identity(earnings_inbox_id), collector)
}

#[test_only]
public fun posted_earnings_message_id(e: &EarningsMessagePosted): ID { e.earnings_message_id }
#[test_only]
public fun posted_earnings_inbox_id(e: &EarningsMessagePosted): ID { e.earnings_inbox_id }
#[test_only]
public fun posted_escrow_id(e: &EarningsMessagePosted): ID { e.escrow_id }
#[test_only]
public fun posted_amount(e: &EarningsMessagePosted): u64 { e.amount }
#[test_only]
public fun posted_coin_type(e: &EarningsMessagePosted): String { e.coin_type }

#[test_only]
public fun collected_earnings_message_id(e: &EarningsMessageCollected): ID { e.earnings_message_id }
#[test_only]
public fun collected_earnings_inbox_id(e: &EarningsMessageCollected): ID { e.earnings_inbox_id }
#[test_only]
public fun collected_amount(e: &EarningsMessageCollected): u64 { e.amount }
#[test_only]
public fun collected_collector(e: &EarningsMessageCollected): address { e.collector }
#[test_only]
public fun collected_coin_type(e: &EarningsMessageCollected): String { e.coin_type }
