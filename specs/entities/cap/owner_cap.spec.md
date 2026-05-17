# owner_cap

## § OVERVIEW

The owner's bearer credential. Holding an `OwnerCap` is the proof of ownership of a specific escrow; every owner-gated operation validates the cap's `escrow_identity` against the escrow being acted on. Because the cap is a Sui object (`key, store`), ownership transfers simply by transferring the object — no protocol field update is needed. `OwnerCapIdentity` is the copy-safe handle used in stored identity structures.

## § TYPES

```
OwnerCap { id: UID, escrow_identity: EscrowIdentity }   has key, store
```
The bearer credential. One per escrow; transferable.

```
OwnerCapIdentity { id: ID }   has copy, drop, store
```
Copy-safe reference to an `OwnerCap`. Stored in `OwnerIdentity` and compared against the presented cap at every owner operation.

## § API

**Public**
- `owner_cap::proj_escrow_id(&OwnerCap): ID` — the escrow this cap is bound to; used by off-chain clients to route the cap.

**Constructors** (package)
- `owner_cap::new(escrow_identity: EscrowIdentity, owner: address, ctx: &mut TxContext): OwnerCap` — mints a new cap bound to `escrow_identity`; emits `OwnerCapMinted`.

**Accessors** (package)
- `owner_cap::identity(&OwnerCap): OwnerCapIdentity`
- `owner_cap::proj_escrow_identity(&OwnerCap): EscrowIdentity`
- `owner_cap::proj_id(OwnerCapIdentity): ID`

**Mutations** (package)
- `owner_cap::burn(OwnerCap, owner: address)` — destroys the cap; emits `OwnerCapBurned`. Called on `claim_asset` when the escrow is fully retired.

## § INVARIANTS

- One `OwnerCap` is minted per `integrate` call and burned on `claim_asset`; no duplication path exists.
- Binding is validated at every operation by comparing `cap.escrow_identity == escrow.escrow_identity`; a mismatch aborts.

## § EVENTS

```
OwnerCapMinted { owner_cap_id: ID, escrow_id: ID, owner: address }
```
Emitted when an `OwnerCap` is created. `owner` is the transaction sender at integration time.

```
OwnerCapBurned { owner_cap_id: ID, escrow_id: ID, owner: address }
```
Emitted when an `OwnerCap` is destroyed. `owner` is passed explicitly by the caller (the address receiving the claimed asset).
