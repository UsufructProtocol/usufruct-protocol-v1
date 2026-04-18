TENANT CAP MODULE — SPECIFICATION
===================================

Module: `tenant_cap`
Design reference: design-compact.md §2 (access model — TenantCap)
Module map reference: module-map.spec.md §6
Depends on: nothing (`sui::object` only)


0. MODULE RESPONSIBILITY
------------------------

`tenant_cap` owns the `TenantCap` object type and all operations on it.

**Owns:**
- `TenantCap` — `key` only. One minted per tenant transition event
  (not per bid). Non-transferable by type. Can become stale after
  displacement — inert, failing the ID check in `rental_escrow`.
- `new(escrow_id, ctx): TenantCap` — `public(package)`. Mint. Called
  by `rental_escrow::rent` (from Idle, AtDutchAuction) and by
  `rental_escrow::do_handover` (handover completion).
- `burn(cap)` — `public`. Voluntary destroy by cap holder for gas
  recovery. No state mutation. The protocol never forces this.
- `escrow_id(cap): ID` — `public`. Getter.

**Does not own:**
- Staleness enforcement — a stale cap is inert because its ID no longer
  matches `escrow.current_tenant_cap_id`. That check lives in
  `rental_escrow::borrow_asset`, not here.
- Asset access or fund flows — those live in `rental_escrow`.
- `AssetReceipt` — hot potato defined inline in `rental_escrow`.

**Key design properties:**
- `key` only, no `store`: non-transferable at the type level. No
  module-level transfer function exists. The cap can never leave the
  holder's wallet except via `burn`.
  **Deliberate asymmetry with `OwnerCap` (`key + store`):**
  `OwnerCap` is `key + store` because owners need operational
  composability — custody, multisig, secondary markets — and selling
  ownership is a first-class feature.
  `TenantCap` is non-transferable for two compounding reasons:
  1. `current_tenant_address` is registered at mint and has no update
     mechanism. If the cap were transferred externally, `remain_credit`
     would be pushed to the original address — not the new holder.
     Fund flows would be broken by design.
  2. `key + store` would enable a secondary market for caps, including
     stale ones. A seller could list a stale cap as valid; the buyer
     would not discover it until `borrow_asset` rejects it. `key` only
     closes this attack surface at the type level — no secondary market
     is possible. The only path to tenancy is through the protocol:
     paying `next_rent_price` and displacing the current tenant.
- **Lazy minting:** a bid during a Rented state does not mint a cap.
  `rental_escrow` stores `pending_tenant_address` and mints the cap
  only when the bidder actually becomes the current tenant — either at
  `rent()` (Idle, AtDutchAuction) or at handover completion inside
  `do_handover()`.
  This avoids creating an object for every bid: in a competitive
  handover window multiple bidders may supersede each other in rapid
  succession. Minting a cap per bid would produce many short-lived
  objects, each paying creation gas and leaving an orphaned stale cap
  in a wallet that never held actual tenancy. Lazy minting ensures that
  in practice only identities that were current tenant ever hold a cap
  — one object, one tenure, no pollution.
- **Staleness:** at handover, the displaced tenant's cap becomes stale
  — its object ID no longer matches `escrow.current_tenant_cap_id`.
  Stale caps are inert: `borrow_asset` rejects them via the ID check.
  `burn` is the sole exit path, available at the holder's discretion.
- **All TenantCap deliveries are pushes:**
  `rent()` has a single signature across all states. In Rented states
  no cap is minted — returning `Option<TenantCap>` would be required
  for a return-based design, which is inconsistent and awkward.
  Instead, all deliveries use `transfer::transfer`:
  - `rent()` from Idle/AtDutchAuction → pushes to `tx_context::sender(ctx)`.
  - `do_handover()` → pushes to `pending_tenant_address` (not
    `tx.sender()`; push is the only viable mechanism here).
  Uniform push across all mint sites keeps the delivery model simple
  and consistent.
- **TenantCap as signal:** the cap appearing in the wallet is the
  clearest notification of tenancy. No indexer query or event
  subscription needed.


1. ERROR CONSTANTS
------------------

None. No function in this module has validatable preconditions that
require named abort codes. `burn` is unconditional; `new` has no
preconditions.


2. TYPE
-------

### TenantCap — struct

Authorization object for tenant-privileged operations (`borrow_asset`)
on a single `RentalEscrow`. Minted at each tenant transition event.
Becomes stale (inert) when the holder is displaced.

```move
public struct TenantCap has key {
    id:        UID,
    escrow_id: ID,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required for `transfer::transfer` (push to
  tenant address) and for the ID-based staleness check in
  `rental_escrow`.
- No `store` — non-transferable. Cannot be wrapped or moved by external
  code. The holder's only exit is `burn`.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. Used by `rental_escrow` to check `object::id(cap) == escrow.current_tenant_cap_id`. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` this cap was minted for. |

**Staleness:** a `TenantCap` becomes stale when a handover completes
and `escrow.current_tenant_cap_id` is updated to the new tenant's cap.
The stale cap is not destroyed by the protocol — it remains in the
displaced tenant's wallet, inert. `borrow_asset` rejects it via:
```
object::id(cap) == escrow.current_tenant_cap_id   // fails for stale cap
```

**Multiple live caps per escrow:** at any moment, one current cap
exists plus zero or more stale caps from prior tenants. Only the
current one passes the ID check.


3. FUNCTIONS
------------

### `new`

    public(package) fun new(escrow_id: ID, ctx: &mut TxContext): TenantCap

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** mints a `TenantCap` bound to a specific escrow.

**Behavior:**
Creates `TenantCap { id: object::new(ctx), escrow_id }` and returns it.

**Call sites:**
- `rental_escrow::rent` (from Idle, AtDutchAuction) — pushed via
  `transfer::transfer` to `tx_context::sender(ctx)`.
- `rental_escrow::do_handover` — pushed via `transfer::transfer` to
  `pending_tenant_address` (not `tx.sender()`).

---

### `burn`

    public fun burn(cap: TenantCap)

**Visibility:** `public` — callable by any holder (current or displaced
tenant).

**Purpose:** voluntary destruction of a `TenantCap` for gas recovery.
Serves both current tenants (end of use) and displaced tenants (stale
cap cleanup). Has no effect on escrow state.

**Behavior:**
1. Destructures: `TenantCap { id, escrow_id: _ } = cap`
2. Calls `object::delete(id)`.

**No state mutation:** burning a cap does not affect
`escrow.current_tenant_cap_id`. The escrow is not notified. A burned
current cap does not revoke access — but `borrow_asset` would then
fail because the cap no longer exists to be presented.

---

### `escrow_id`

    public fun escrow_id(cap: &TenantCap): ID

**Visibility:** `public` — readable by any caller. Useful for
off-chain code and for `rental_escrow`'s first-pass escrow check.

**Purpose:** returns the `ID` of the `RentalEscrow` this cap was
minted for.

**Behavior:** returns `cap.escrow_id`.

**Note:** `rental_escrow::borrow_asset` performs two checks in
sequence — escrow match and ID match:
```
cap.escrow_id == object::id(escrow)                // first: correct escrow
object::id(cap) == escrow.current_tenant_cap_id    // second: not stale
```
Both checks live in `rental_escrow`, not here.


4. PROPERTIES
-------------

**P1 — Minted only at tenant transition:**
    `new` is `public(package)` and called only at `rent()` (Idle,
    AtDutchAuction) and `do_handover()`. Bids during Rented states do
    not mint a cap. No orphaned caps from superseded bidders.

**P2 — Non-transferable by type:**
    `key` only, no `store`. No transfer function exists in this module.
    The Sui type system enforces this — no external code can move the
    cap between addresses.

**P3 — Staleness is inert, not destructive:**
    A displaced tenant's cap remains in their wallet but fails the ID
    check in `borrow_asset`. The protocol never forcibly burns it.
    `burn` is the holder's opt-in exit for gas recovery.

**P4 — burn has no escrow side-effects:**
    Burning a cap does not update any escrow field. The escrow is
    unaware. The only consequence is that the object ceases to exist —
    it can no longer be presented to `borrow_asset`.

**P5 — All deliveries are pushes:**
    `rent()` has a single signature and does not mint a cap in Rented
    states. A return-based design would require `Option<TenantCap>`,
    which is inconsistent. All mint sites use `transfer::transfer`:
    `rent()` pushes to `tx_context::sender(ctx)`; `do_handover()`
    pushes to `pending_tenant_address`. Uniform mechanism across all
    delivery paths.


5. TEST CASES
-------------

### 5.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `new(escrow_id, ctx)` | Returns `TenantCap` with `cap.escrow_id == escrow_id`. Object has a fresh UID. |
| N2 | Two calls with same `escrow_id` | Two distinct `TenantCap` objects (distinct UIDs), both bound to the same escrow_id. |
| N3 | Two calls with distinct `escrow_id`s | Two caps with distinct `escrow_id` fields. |

### 5.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `burn(cap)` on a current cap | UID deleted. No abort. No escrow state change. |
| B2 | `burn(cap)` on a stale cap | UID deleted. No abort. Identical behavior — module is unaware of staleness. |
| B3 | `burn` consumes by value | Compiler enforces — no double-burn. |

### 5.3 `escrow_id`

| # | Description | Expected |
|---|---|---|
| G1 | `escrow_id(&cap)` after `new(id, ctx)` | Returns `id`. |

### 5.4 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `new` → `escrow_id` check → `burn` | Full lifecycle. No abort. |
| L2 | `new` (cap A) → `new` (cap B, same escrow) → both have distinct `object::id` | Staleness mechanic relies on distinct IDs — confirmed at mint. |
| L3 | Stale cap: `burn` available after displacement | Holder can clean up regardless of escrow state. |


6. MODULE BOUNDARY
------------------

`tenant_cap.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `TenantCap` (type) | `public` | `key` only. Non-transferable. One per tenant transition event. |
| `new(escrow_id, ctx): TenantCap` | `public(package)` | Mint. Called by `rental_escrow::rent` and `rental_escrow::do_handover`. |
| `burn(cap)` | `public` | Voluntary destroy for gas recovery. No state mutation. |
| `escrow_id(cap): ID` | `public` | Getter. |

No error constants.

**Depends on:** nothing (`sui::object` only).


7. OBJECT DISPLAY
-----------------

![TenantCap](../../media/object-display/tenant-cap.png)

`Display<TenantCap>` gives every cap a visual identity in wallets and explorers.
Created once post-deployment via a PTB presenting `&Publisher` for the package
and `&mut DisplayRegistry` (Sui framework shared object).

### Fields

| Key | Value | Notes |
|---|---|---|
| `name` | `Tenant Cap` | Static. |
| `description` | `Grants temporary access to a rented asset in the Liquid Renting Protocol. Becomes stale when displaced by a new tenant.` | Static. |
| `image_url` | `{IMAGE_BASE_URL}/tenant-cap.png` | Hosted URL. Source: `media/object-display/tenant-cap.png`. |
| `project_url` | `https://liquidrenting.com` | Static. |
| `creator` | `Liquid Renting Protocol` | Static. |

`{IMAGE_BASE_URL}` is set at deployment time to the protocol's media hosting base URL.

### Creation

```move
use sui::display_registry;

let mut display = display_registry::new<TenantCap>(&publisher, registry);
display.add(b"name".to_string(),        b"Tenant Cap".to_string());
display.add(b"description".to_string(), b"Grants temporary access to a rented asset in the Liquid Renting Protocol. Becomes stale when displaced by a new tenant.".to_string());
display.add(b"image_url".to_string(),   b"{IMAGE_BASE_URL}/tenant-cap.png".to_string());
display.add(b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display.add(b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::commit(display);
```

One `Display<TenantCap>` per package deployment. ID is deterministic from
`DisplayRegistry` + type — no event scanning required.

**Status:** [ ] `Display<TenantCap>` created and committed.
