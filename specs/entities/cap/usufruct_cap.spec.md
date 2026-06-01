# usufruct_cap

## § OVERVIEW

The usufructuary's bearer credential. Holding a `UsufructCap` is the proof of tenancy for a specific escrow; it authorises `borrow_asset`, `return_asset`, and cap-related operations. Like `GovernanceCap`, it is a Sui object and transfers by object transfer. A usufructuary can hold at most one active cap per escrow; a superseded usufructuary's cap becomes stale and can be burned via `soft_burn_usufruct_cap` once they are no longer current or pending. `UsufructCapIdentity` is the copy-safe handle stored in `UsufructuaryIdentity`.

## § TYPES

```
UsufructCap { id: UID, escrow_identity: EscrowIdentity }   has key, store
```
The bearer credential. One active cap per escrow usufructuary slot; transferable.

```
UsufructCapIdentity { id: ID }   has copy, drop, store
```
Copy-safe reference to a `UsufructCap`. Stored in `UsufructuaryIdentity` and compared against the presented cap at every usufructuary operation.

## § API

**Constructors** (package)
- `usufruct_cap::new(escrow_identity: EscrowIdentity, usufructuary: address, ctx: &mut TxContext): UsufructCap` — mints a new cap bound to `escrow_identity`; emits `UsufructCapMinted`.

**Accessors** (package)
- `usufruct_cap::identity(&UsufructCap): UsufructCapIdentity`
- `usufruct_cap::proj_escrow_id(&UsufructCap): ID` — the escrow this cap is bound to. Re-exported publicly as `cap::usufruct_cap_escrow_id` for off-chain clients to route the cap.
- `usufruct_cap::proj_escrow_identity(&UsufructCap): EscrowIdentity`
- `usufruct_cap::proj_id(UsufructCapIdentity): ID`
- `usufruct_cap::from_id(id: ID): UsufructCapIdentity` — constructs a `UsufructCapIdentity` from a raw ID; used when checking stale caps by ID only.

**Mutations** (package)
- `usufruct_cap::burn(UsufructCap, ctx: &TxContext)` — destroys the cap; reads the usufructuary address from `ctx.sender()`; emits `UsufructCapBurned`.

## § INVARIANTS

- A new `UsufructCap` is minted on every successful `rent` call; each usufructuary in the system holds exactly one cap.
- Binding is validated by comparing `cap.escrow_identity == escrow.escrow_identity`; a mismatch aborts.
- A cap is stale if its identity matches neither the current nor the pending usufructuary slot; stale caps can be burned without governor or usufructuary cooperation via `soft_burn_usufruct_cap`.

## § EVENTS

```
UsufructCapMinted { usufruct_cap_id: ID, escrow_id: ID, usufructuary: address }
```
Emitted when a `UsufructCap` is created. `usufructuary` is the transaction sender at rent time.

```
UsufructCapBurned { usufruct_cap_id: ID, escrow_id: ID, usufructuary: address }
```
Emitted when a `UsufructCap` is destroyed. `usufructuary` is read from the transaction context at burn time.
