// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::fee_message;

// === Imports ===

use sui::{
    balance::Balance,
    coin::Coin,
    transfer::Receiving,
};
use usufruct::protocol_fee_inbox::ProtocolFeeInbox;

// === Errors ===

// === Constants ===

// === Structs ===

public struct FeeMessage<phantom CoinType> has key {
    id:        UID,
    escrow_id: ID,
    balance:   Balance<CoinType>,
}

// === Events ===

public struct FeeMessageSent<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
    tenant:         address,
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

public fun collect_fee_messages<C>(
    _inbox:   &mut ProtocolFeeInbox,
    _tickets: vector<Receiving<FeeMessage<C>>>,
    _ctx:     &mut TxContext,
): Coin<C> {
    abort 0
}

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun post<C>(
    _balance:      Balance<C>,
    _escrow_id:    ID,
    _tenant:       address,
    _fee_inbox_id: ID,
    _ctx:          &mut TxContext,
) {
    abort 0
}

// === Private Functions ===

fun receive_message<C>(
    _inbox:  &mut ProtocolFeeInbox,
    _ticket: Receiving<FeeMessage<C>>,
): FeeMessage<C> {
    abort 0
}

fun consume_message<C>(
    _msg:          FeeMessage<C>,
    _fee_inbox_id: ID,
    _collector:    address,
): Balance<C> {
    abort 0
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
    consume_message(msg, fee_inbox_id, collector)
}
