# earnings_message

## § OVERVIEW

The atomic unit of governor-earnings transfer — the income-side twin of `fee_message`. When a settlement produces the governor's share, it is captured as an `EarningsBalance` (split from the departing usufructuary's stake) and posted as an `EarningsMessage` object transferred to the governor's `EarningsInbox` address via transfer-to-object. Because the inbox is an owned object, Sui's `Receiving<T>` mechanism applies: the message lands at the inbox's address and can only be claimed by presenting a `Receiving<EarningsMessage<C>>` ticket — the earnings are either fully delivered or not at all. The inbox bearer collects accumulated messages in batches, draining each and combining the balances into a single `Coin`. This two-step design (balance → message → collect) decouples earnings production from collection and keeps each settlement's contribution traceable via `escrow_identity`.

## § TYPES

```
EarningsMessage<CoinType: phantom> {
    id:              UID,
    escrow_identity: EscrowIdentity,
    balance:         Balance<CoinType>,
}   has key
```
A Sui object mailed to the `EarningsInbox`. `key` only (no `store`) — it lives at the inbox's address until `collect` drains it. One per settlement event. The `escrow_identity` makes it self-describing for the star schema.

## § API

**Posting** (package)
- `earnings_message::post<C>(earnings: EarningsBalance<C>, inbox_identity: EarningsInboxIdentity, escrow_identity: EscrowIdentity, ctx)` — wraps the earnings into an `EarningsMessage`, transfers it to the inbox address, emits `EarningsPosted`.

**Collection** (package)
- `earnings_message::collect_earnings_messages<C>(&mut EarningsInbox, tickets: vector<Receiving<EarningsMessage<C>>>, ctx): Coin<C>` — drains all messages in `tickets`, sums balances, emits `EarningsCollected` per message, returns combined `Coin<C>`. Re-exported by the public facade `api/earnings`.

**Accessors** (package)
- `earnings_message::proj_escrow_id<C>(&EarningsMessage<C>): ID` — originating escrow.

## § INVARIANTS

- An `EarningsBalance` is consumed into a message via `post` — it does not persist as accumulated governor state.
- Each `EarningsMessage` carries exactly one `escrow_identity`, enabling per-escrow earnings attribution in the event log.
- `collect_earnings_messages` processes each ticket atomically; partial collection within a batch is not possible.
- Mirrors `fee_message` shape and discipline: same `Receiving` mechanism, same owned-object fast path (no shared-escrow contention).

## § EVENTS

```
EarningsPosted<CoinType> {
    earnings_message_id: ID,
    earnings_inbox_id:   ID,
    escrow_id:           ID,
    amount:              u64,
    coin_type:           String,
}
```
Emitted when an `EarningsBalance` is posted to the inbox as an `EarningsMessage`. `coin_type` is the fully-qualified type string of `CoinType`, redundant with the generic event type but kept so the event is self-describing by field.

```
EarningsCollected<CoinType> {
    earnings_message_id: ID,
    earnings_inbox_id:   ID,
    escrow_id:           ID,
    amount:              u64,
    collector:           address,
    coin_type:           String,
}
```
Emitted once per message when `collect_earnings_messages` drains it. `collector` is the transaction sender; `coin_type` mirrors `EarningsPosted`.
