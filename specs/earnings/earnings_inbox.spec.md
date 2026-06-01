# earnings_inbox

## § OVERVIEW

A governor's earnings sink. An owned object (`key + store`) born paired with a `GovernanceCap` at `escrow::integrate`; after birth the two are independent — the cap governs, the inbox collects, and either can be transferred separately. The inbox holds no balance directly; governor earnings arrive as individual `EarningsMessage` objects transferred to its UID via Sui's `Receiving<T>` mechanism, preserving atomicity (a settlement's earnings are either fully posted or not at all).

Because it is `store`, the inbox is **itself integrable into a usufruct escrow** — the coupon-strip primitive: the income stream can be rented or sold apart from the `GovernanceCap` that produces it. The bearer of the inbox is the sole party that can collect; holding the object is the right.

## § TYPES

```
EarningsInbox { id: UID }   has key, store
```
Owned object, born with a `GovernanceCap`. Receives `EarningsMessage<C>` transfers addressed to its UID. `store` makes it integrable as an asset in its own right.

```
EarningsInboxIdentity { id: ID }   has copy, drop, store
```
Copy/drop projection of an inbox's object id. Stored inside `GovernorSeat` as the permanent earnings destination and carried by every `EarningsMessage`. A value (never an object), so it crosses module borders without touching the object store. Mirrors `FeeInboxIdentity`.

## § API

**Constructors** (package)
- `earnings_inbox::new(ctx): EarningsInbox` — mints an inbox; called only by `escrow::integrate`, paired once with a `GovernanceCap`.

**Accessors** (package)
- `earnings_inbox::identity(&EarningsInbox): EarningsInboxIdentity` — the inbox's identity handle.
- `earnings_inbox::inbox_identity(id: ID): EarningsInboxIdentity` — build an identity from a raw id.
- `earnings_inbox::proj_id(EarningsInboxIdentity): ID` — the underlying object id.

**Receiving** (package)
- `earnings_inbox::uid_mut(&mut EarningsInbox): &mut UID` — exposes the mutable UID needed to accept incoming `Receiving<EarningsMessage<C>>` transfers.

## § INVARIANTS

- One inbox is born per `integrate`, paired with one `GovernanceCap`; thereafter the two are independent objects — sell/rent the inbox without affecting governance, and vice versa.
- The inbox holds no balance; all funds arrive and leave as `EarningsMessage` objects (see `earnings_message`).
- Collection is permissionless on the object itself; the right to collect is bearer (whoever holds the inbox).

## § EVENTS

None. *(Earnings post/collect events are emitted by `earnings_message`.)*
