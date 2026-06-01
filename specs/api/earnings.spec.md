# earnings (api)

## § OVERVIEW

The public facade for collecting governor income. A single entry — `collect_earnings_messages` — that delegates to `earnings_message`. It touches only owned objects (the inbox and its received messages), no shared escrow, so collection runs at owned-object speed exactly like fee collection. The inbox is born paired with a `GovernanceCap` at `escrow::integrate`; holding the inbox (bearer) is the sole right to collect.

## § API

**Public**
- `earnings::collect_earnings_messages<C>(inbox: &mut EarningsInbox, tickets: vector<Receiving<EarningsMessage<C>>>, ctx): Coin<C>` — drains the addressed `EarningsMessage`s, returns their summed balance as a single `Coin`; emits `EarningsCollected` per message (in `earnings_message`).

## § INVARIANTS

- Permissionless on the inbox object; the right to collect is bearer.
- No shared-object contention — collection never touches the escrow, so it batches and composes across a fleet of escrows that all post to the same inbox.

## § EVENTS

None directly. *(See `earnings_message`: `EarningsCollected`.)*
