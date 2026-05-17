# protocol_fee_inbox

## § OVERVIEW

The protocol's fee accumulation sink. An owned object created once at package deployment and held by the protocol operator — it is not shared, which is precisely why `ProtocolFeeRef` exists as a frozen pointer that escrows can reference without touching the inbox itself. The inbox holds no balance directly; fees arrive as individual `FeeMessage` objects transferred to its UID via Sui's `Receiving<T>` mechanism, preserving atomicity: a fee is either fully posted or not posted at all. The protocol operator drains the inbox by presenting `Receiving<FeeMessage<C>>` tickets to `collect_fee_messages`, which sweeps a batch of messages and returns their combined balance as a single `Coin`.

## § TYPES

```
ProtocolFeeInbox { id: UID }   has key, store
```
Owned singleton held by the protocol operator. Receives `FeeMessage<C>` transfers addressed to its UID.

## § API

**Public**
- `fee_message::collect_fee_messages<C>(&mut ProtocolFeeInbox, tickets: vector<Receiving<FeeMessage<C>>>, ctx: &mut TxContext): Coin<C>` — accepts a batch of receiving tickets, drains each message, sums the balances, and returns a single `Coin<C>`; emits `FeeMessageCollected` for each message processed.

**Package**
- `protocol_fee_inbox::uid_mut(&mut ProtocolFeeInbox): &mut UID` — exposes the mutable UID needed to accept incoming `Receiving<FeeMessage<C>>` transfers.

**Initialization**
- `init(USUFRUCT, ctx)` — module initializer; creates the `ProtocolFeeInbox`, calls `protocol_fee_ref::create_and_freeze` with its ID, and transfers the inbox to the transaction sender.

## § INVARIANTS

- One `ProtocolFeeInbox` per package deployment; created in `init` and never duplicated.
- Fee collection is permissionless on the inbox object itself; access control is the operator's responsibility at the PTB level.

## § EVENTS

None. *(Fee collection events are emitted by `fee_message::collect_fee_messages`.)*
