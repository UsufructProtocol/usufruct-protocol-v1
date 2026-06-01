# refund (api)

## § OVERVIEW

The public constructor for a `RefundAddress` — the typed wrapper over a raw `address` used as a usufructuary's refund destination. Exposed so PTBs can build the value passed to `escrow::update_usufructuary_refund_address`. The wrapping is what lets the protocol distinguish a refund destination from any other address at the type level.

## § API

**Public**
- `refund::refund_address(addr: address): RefundAddress` — wrap a raw address as a `RefundAddress`. See `entities/address/refund_address` for the type and how a seat consumes it.

## § INVARIANTS

- Pure constructor — no state, no events.

## § EVENTS

None.
