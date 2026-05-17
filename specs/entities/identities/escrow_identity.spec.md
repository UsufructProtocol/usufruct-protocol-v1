# escrow_identity

## § OVERVIEW

A typed wrapper around the `ID` of the `Escrow` shared object. Acts as the root foreign key in the protocol's event topology: every event emitted anywhere in the system carries an `EscrowIdentity`, allowing clients to reconstruct the full lifecycle of any escrow by filtering on a single field. Also used to bind capabilities (`OwnerCap`, `TenantCap`) to their escrow at mint time, preventing cross-escrow cap reuse.

## § TYPES

```
EscrowIdentity { id: ID }   has copy, drop, store
```
The on-chain object ID of the `Escrow` shared object.

## § API

**Constructors** (package)
- `escrow_identity::new(id: ID): EscrowIdentity`
- `escrow_identity::escrow_id(EscrowIdentity): ID`

## § INVARIANTS

- Produced once at `execute_integrate` from `object::id(&escrow)` and stored in every entity and event that flows through that escrow.
- Equality comparison is the mechanism for cap binding validation.

## § EVENTS

None.
