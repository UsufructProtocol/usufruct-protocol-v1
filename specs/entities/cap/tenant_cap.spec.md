# tenant_cap

## § OVERVIEW

The tenant's bearer credential. Holding a `TenantCap` is the proof of tenancy for a specific escrow; it authorises `borrow_asset`, `return_asset`, and cap-related operations. Like `OwnerCap`, it is a Sui object and transfers by object transfer. A tenant can hold at most one active cap per escrow; a superseded tenant's cap becomes stale and can be burned via `soft_burn_tenant_cap` once they are no longer current or pending. `TenantCapIdentity` is the copy-safe handle stored in `TenantIdentity`.

## § TYPES

```
TenantCap { id: UID, escrow_identity: EscrowIdentity }   has key, store
```
The bearer credential. One active cap per escrow tenant slot; transferable.

```
TenantCapIdentity { id: ID }   has copy, drop, store
```
Copy-safe reference to a `TenantCap`. Stored in `TenantIdentity` and compared against the presented cap at every tenant operation.

## § API

**Public**
- `tenant_cap::proj_escrow_id(&TenantCap): ID` — the escrow this cap is bound to; used by off-chain clients to route the cap.

**Constructors** (package)
- `tenant_cap::new(escrow_identity: EscrowIdentity, tenant: address, ctx: &mut TxContext): TenantCap` — mints a new cap bound to `escrow_identity`; emits `TenantCapMinted`.

**Accessors** (package)
- `tenant_cap::identity(&TenantCap): TenantCapIdentity`
- `tenant_cap::proj_escrow_identity(&TenantCap): EscrowIdentity`
- `tenant_cap::proj_id(TenantCapIdentity): ID`
- `tenant_cap::from_id(id: ID): TenantCapIdentity` — constructs a `TenantCapIdentity` from a raw ID; used when checking stale caps by ID only.

**Mutations** (package)
- `tenant_cap::burn(TenantCap, ctx: &TxContext)` — destroys the cap; reads the tenant address from `ctx.sender()`; emits `TenantCapBurned`.

## § INVARIANTS

- A new `TenantCap` is minted on every successful `rent` call; each tenant in the system holds exactly one cap.
- Binding is validated by comparing `cap.escrow_identity == escrow.escrow_identity`; a mismatch aborts.
- A cap is stale if its identity matches neither the current nor the pending tenant slot; stale caps can be burned without owner or tenant cooperation via `soft_burn_tenant_cap`.

## § EVENTS

```
TenantCapMinted { tenant_cap_id: ID, escrow_id: ID, tenant: address }
```
Emitted when a `TenantCap` is created. `tenant` is the transaction sender at rent time.

```
TenantCapBurned { tenant_cap_id: ID, escrow_id: ID, tenant: address }
```
Emitted when a `TenantCap` is destroyed. `tenant` is read from the transaction context at burn time.
