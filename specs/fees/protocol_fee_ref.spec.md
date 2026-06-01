# protocol_fee_ref

## § OVERVIEW

A frozen, immutable pointer to the `ProtocolFeeInbox`. `ProtocolFeeInbox` is an owned object — it cannot be passed by reference in a transaction that also involves shared objects, which is the case for every `integrate` call. `ProtocolFeeRef` solves this: created once at package deployment and frozen, it becomes a publicly readable immutable object that any transaction can pass as `&ProtocolFeeRef` without governorship or mutability constraints. Passing it to `integrate` threads the inbox identity into the escrow permanently, so every subsequent fee posting knows its destination without touching the inbox directly. `FeeInboxIdentity` is the copy-safe handle extracted from the ref and stored wherever the inbox address needs to travel.

## § TYPES

```
ProtocolFeeRef { id: UID, proj_id: FeeInboxIdentity }   has key
```
Frozen singleton. Passed by immutable reference to `integrate`; never mutated after creation.

```
FeeInboxIdentity { id: ID }   has copy, drop, store
```
Copy-safe identity of the `ProtocolFeeInbox`. Stored in `EscrowCore` and carried in every `FeeShare` and `FeeMessage` to identify the destination inbox.

## § API

**Public**
- `protocol_fee_ref::proj_inbox_id(&ProtocolFeeRef): ID` — raw ID of the fee inbox; used by off-chain clients to locate the inbox object.

**Package**
- `protocol_fee_ref::proj_inbox_identity(&ProtocolFeeRef): FeeInboxIdentity`
- `protocol_fee_ref::fee_inbox_identity(id: ID): FeeInboxIdentity` — constructs a `FeeInboxIdentity` from a raw ID.
- `protocol_fee_ref::proj_id(FeeInboxIdentity): ID`
- `protocol_fee_ref::create_and_freeze(proj_id: ID, ctx: &mut TxContext)` — creates the `ProtocolFeeRef` and freezes it; called once inside `protocol_fee_inbox::init`.

## § INVARIANTS

- `ProtocolFeeRef` is frozen at creation; its `proj_id` never changes.
- One `ProtocolFeeRef` per package deployment, paired with one `ProtocolFeeInbox`.

## § EVENTS

None.
