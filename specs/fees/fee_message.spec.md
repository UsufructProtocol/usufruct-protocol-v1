# fee_message

## § OVERVIEW

The atomic unit of protocol fee transfer. When a rental settlement produces a protocol fee, it is first captured as a `FeeShare` — a typed balance tagged with the originating escrow. That share is then posted as a `FeeMessage` object transferred directly to the `ProtocolFeeInbox` owned object via `transfer::public_transfer`. Because `ProtocolFeeInbox` is an owned object, Sui's `Receiving<T>` mechanism applies: the fee message lands in the inbox's address and can only be claimed by presenting a `Receiving<FeeMessage<C>>` ticket in a transaction signed by the inbox governor. This guarantees the fee is either fully delivered or not delivered at all. The inbox operator collects accumulated messages in batches, draining each and combining the balances into a single `Coin`. This two-step design (share → message → collect) decouples fee production from fee collection and keeps each settlement's contribution traceable via `escrow_identity`.

## § TYPES

```
FeeShare<CoinType: phantom> {
    balance:          Balance<CoinType>,
    escrow_identity:  EscrowIdentity,
}   has store
```
An intermediate value holding the protocol's cut from a single settlement. No `copy` or `drop`; must be posted to the inbox via `fee_message::post`.

```
FeeMessage<CoinType: phantom> {
    id:               UID,
    escrow_identity:  EscrowIdentity,
    balance:          Balance<CoinType>,
}   has key
```
A Sui object transferred to the `ProtocolFeeInbox`. One per settlement event; collected in batches by the operator.

## § API

**Public**
- `fee_message::collect_fee_messages<C>(&mut ProtocolFeeInbox, tickets: vector<Receiving<FeeMessage<C>>>, ctx: &mut TxContext): Coin<C>` — drains all messages in `tickets`, sums balances, emits `FeeMessageCollected` for each, returns combined `Coin<C>`.

**Accessors** (package)
- `fee_message::proj_share_value<C>(&FeeShare<C>): Stake` — balance of the share.
- `fee_message::proj_escrow_id<C>(&FeeMessage<C>): ID` — originating escrow.

**Constructors** (package)
- `fee_message::new_share<C>(balance: Balance<C>, escrow_identity: EscrowIdentity): FeeShare<C>`

**Posting** (package)
- `fee_message::post<C>(share: FeeShare<C>, fee_inbox_identity: FeeInboxIdentity, ctx: &mut TxContext)` — wraps the share into a `FeeMessage`, transfers it to the inbox address, emits `FeeMessagePosted`.

## § INVARIANTS

- `FeeShare` has no `drop`; it must be consumed via `post` — silent discard of protocol fees is impossible.
- Each `FeeMessage` carries exactly one `escrow_identity`, enabling per-escrow fee attribution in the event log.
- `collect_fee_messages` processes messages atomically per ticket; partial collection within a batch is not possible.

## § EVENTS

```
FeeMessagePosted {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
    coin_type:      String,
}
```
Emitted when a `FeeShare` is posted to the inbox as a `FeeMessage`. `coin_type` is the fully-qualified type string of the coin. The event is non-generic (matching the `asset_state` events), so this field is the sole carrier of the coin type — self-describing without a type parameter.

```
FeeMessageCollected {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
    collector:      address,
    coin_type:      String,
}
```
Emitted once per message when `collect_fee_messages` drains it. `collector` is the transaction sender; `coin_type` mirrors `FeeMessagePosted`.
