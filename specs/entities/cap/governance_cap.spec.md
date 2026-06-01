# governance_cap

## § OVERVIEW

The governor's bearer credential. Holding an `GovernanceCap` is the proof of governorship of a specific escrow; every governor-gated operation validates the cap's `escrow_identity` against the escrow being acted on. Because the cap is a Sui object (`key, store`), governorship transfers simply by transferring the object — no protocol field update is needed. `GovernanceCapIdentity` is the copy-safe handle used in stored identity structures.

## § TYPES

```
GovernanceCap { id: UID, escrow_identity: EscrowIdentity }   has key, store
```
The bearer credential. One per escrow; transferable.

```
GovernanceCapIdentity { id: ID }   has copy, drop, store
```
Copy-safe reference to an `GovernanceCap`. Stored in `GovernorIdentity` and compared against the presented cap at every governor operation.

## § API

**Public**
- `governance_cap::proj_escrow_id(&GovernanceCap): ID` — the escrow this cap is bound to; used by off-chain clients to route the cap.

**Constructors** (package)
- `governance_cap::new(escrow_identity: EscrowIdentity, governor: address, ctx: &mut TxContext): GovernanceCap` — mints a new cap bound to `escrow_identity`; emits `GovernanceCapMinted`.

**Accessors** (package)
- `governance_cap::identity(&GovernanceCap): GovernanceCapIdentity`
- `governance_cap::proj_escrow_identity(&GovernanceCap): EscrowIdentity`
- `governance_cap::proj_id(GovernanceCapIdentity): ID`

**Mutations** (package)
- `governance_cap::burn(GovernanceCap, governor: address)` — destroys the cap; emits `GovernanceCapBurned`. Called on `claim_asset` when the escrow is fully retired.

## § INVARIANTS

- One `GovernanceCap` is minted per `integrate` call and burned on `claim_asset`; no duplication path exists.
- Binding is validated at every operation by comparing `cap.escrow_identity == escrow.escrow_identity`; a mismatch aborts.

## § EVENTS

```
GovernanceCapMinted { governance_cap_id: ID, escrow_id: ID, governor: address }
```
Emitted when an `GovernanceCap` is created. `governor` is the transaction sender at integration time.

```
GovernanceCapBurned { governance_cap_id: ID, escrow_id: ID, governor: address }
```
Emitted when an `GovernanceCap` is destroyed. `governor` is passed explicitly by the caller (the address receiving the claimed asset).
