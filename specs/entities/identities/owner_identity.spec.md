# owner_identity

## § OVERVIEW

Encapsulates the identity of the asset owner as seen by the protocol: not an address, but a reference to the owner's capability object. Storing `OwnerCapIdentity` rather than an address means that ownership can transfer by transferring the `OwnerCap` object; the protocol requires no update. Held inside `OwnerSeat`.

## § TYPES

```
OwnerIdentity { cap_identity: OwnerCapIdentity }   has copy, drop, store
```

## § API

**Constructors** (package)
- `owner_identity::new(cap_identity: OwnerCapIdentity): OwnerIdentity`

**Accessors** (package)
- `owner_identity::proj_cap_identity(&OwnerIdentity): OwnerCapIdentity`

## § INVARIANTS

- Identity is set once at escrow integration and never updated; ownership transfers via `OwnerCap` object transfer, not via field mutation.

## § EVENTS

None.
