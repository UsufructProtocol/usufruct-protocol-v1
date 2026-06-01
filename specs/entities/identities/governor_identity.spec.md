# governor_identity

## § OVERVIEW

Encapsulates the identity of the asset governor as seen by the protocol: not an address, but a reference to the governor's capability object. Storing `GovernanceCapIdentity` rather than an address means that governorship can transfer by transferring the `GovernanceCap` object; the protocol requires no update. Held inside `GovernorSeat`.

## § TYPES

```
GovernorIdentity { cap_identity: GovernanceCapIdentity }   has copy, drop, store
```

## § API

**Constructors** (package)
- `governor_identity::new(cap_identity: GovernanceCapIdentity): GovernorIdentity`

**Accessors** (package)
- `governor_identity::proj_cap_identity(&GovernorIdentity): GovernanceCapIdentity`

## § INVARIANTS

- Identity is set once at escrow integration and never updated; governorship transfers via `GovernanceCap` object transfer, not via field mutation.

## § EVENTS

None.
