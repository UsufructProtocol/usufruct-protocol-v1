# fee_inbox (api)

## § OVERVIEW

The public facade for the protocol fee layer: collect accumulated `FeeMessage`s and read the fee inbox id. Delegates to `fee_message` / `protocol_fee_inbox`. Like earnings collection, it touches only owned objects — no shared escrow — so it runs at owned-object speed and composes across many escrows that route to the same inbox.

## § API

**Public**
- `fee_inbox::collect_fee_messages<C>(inbox: &mut ProtocolFeeInbox, tickets: vector<Receiving<FeeMessage<C>>>, ctx): Coin<C>` — drains the addressed `FeeMessage`s into a single `Coin`; emits `FeeMessageCollected` per message (in `fee_message`).
- `fee_inbox::inbox_id(fee_ref: &ProtocolFeeRef): ID` — the fee inbox id an escrow routes to, read from the frozen `ProtocolFeeRef`.

## § INVARIANTS

- Collection is permissionless on the inbox object; access control is the operator's responsibility at the PTB level.

## § EVENTS

None directly. *(See `fee_message`: `FeeMessageCollected`.)*
