OWNER CAP MODULE — SPECIFICATION
==================================

Module: `owner_cap`
Design reference: design-compact.md §2 (access model — OwnerCap)
Module map reference: module-map.spec.md §5
Depends on: nothing (`sui::object` only)


0. MODULE RESPONSIBILITY
------------------------

`owner_cap` owns the `OwnerCap` object type and all operations on it.

**Owns:**
- `OwnerCap` — `key + store`. One per integration instance. Proves
  authority for `retire()`, `claim_asset()`, and `withdraw_earnings()`
  in `rental_escrow`. Transferable — the protocol never tracks who holds
  the cap.
- `new(escrow_id, owner, ctx): OwnerCap` — `public(package)`. Mint.
  Called only by `rental_escrow::integrate`. `owner` is the recipient
  address, recorded in the `OwnerCapMinted` event.
- `burn(cap, owner)` — `public(package)`. Destroy. Called only by
  `rental_escrow::claim_asset`. `owner` is the cap holder at burn time
  (typically `tx_context::sender(ctx)` hoisted at the call site),
  recorded in the `OwnerCapBurned` event.
- `escrow_id(cap): ID` — `public`. Getter.
- `assert_escrow(cap, escrow_id)` — `public(package)`. Aborts if
  `cap.escrow_id != escrow_id`. Used by `rental_escrow` to verify the
  presented cap belongs to the escrow being operated on.
- Lifecycle events: `OwnerCapMinted`, `OwnerCapBurned`. Emitted from
  inside this module (Sui Verifier requires the emitted type to be
  internal to the emitting module).

**Does not own:**
- Any escrow state or fund balances — those live in `RentalEscrow`.
- Tracking of the cap holder — the protocol is cap-holder-agnostic.

**Key design properties:**
- `key + store`: transferable and composable. `store` is chosen for
  operational composability — custody, multisig, secondary markets —
  all of which require wrapping the cap inside external objects.
  Integrability as an `Asset` in another escrow is an emergent
  consequence of the same abilities, not an independent goal. The
  ownership-chain opacity this introduces is inherent to any
  `key + store` object in Sui and is no worse than the opacity of
  the rented asset itself.
- Mutual exclusivity: `OwnerCap` exists ↔ the underlying asset is held
  in its `RentalEscrow`. `burn` is called atomically with asset
  extraction in `claim_asset` — no `OwnerCap` outlives its escrow.
- Authorization is cap-based, not address-based. `rental_escrow` calls
  `assert_escrow` rather than checking `tx_context::sender`.


1. ERROR CONSTANTS
------------------

| Constant | Value | Abort site |
|---|---|---|
| `E_ESCROW_MISMATCH` | `0` | `assert_escrow` — presented cap does not belong to the target escrow |


2. TYPE
-------

### OwnerCap — struct

Authorization object for owner-privileged operations on a single
`RentalEscrow`. One minted per `integrate` call; burned at `claim_asset`.

```move
public struct OwnerCap has key, store {
    id:        UID,
    escrow_id: ID,
}
```

**Abilities:** `key + store`.
- `key` — object identity. Required for `transfer::transfer` at mint.
- `store` — composability with external objects: custody, multisig,
  secondary markets. As a side effect, satisfies the `Asset: key +
  store` bound of `RentalEscrow<Asset, _>` and lets the cap itself
  be rented.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` this cap authorizes. |

**Invariant:** exactly one live `OwnerCap` with a given `escrow_id`
exists at any time. Enforced structurally — `new` is `public(package)`
and called only once per escrow (at `integrate`); `burn` is
`public(package)` and called only at `claim_asset` which deletes the
escrow in the same call.


3. EVENTS
---------

All events are defined inline and emitted from this module. The Sui
Move event verifier requires the emitted type to be internal to the
calling module — this is why the cap lifecycle events live here rather
than in `rental_escrow`.

```move
public struct OwnerCapMinted has copy, drop {
    owner_cap_id: ID,
    escrow_id:    ID,
    owner:        address,
}

public struct OwnerCapBurned has copy, drop {
    owner_cap_id: ID,
    escrow_id:    ID,
    owner:        address,
}
```

**Sui Verifier constraint:** every event struct has `copy + drop` and
is internal to this module. `event::emit` requires these abilities.

**Field selection:**
- `owner_cap_id` — the `ID` of the cap itself. Primary key for any
  consumer indexing cap objects by identity.
- `escrow_id` — the `ID` of the `RentalEscrow` the cap authorizes. A
  cap has no meaning independent of its escrow; every cap-level
  consumer needs the pair.
- `owner` — the recipient of the cap at mint (passed in by
  `rental_escrow::integrate`, typically `tx_context::sender(ctx)`) and
  the holder presenting the cap at burn (`tx_context::sender(ctx)` in
  `rental_escrow::claim_asset`). Distinct semantics per event but the
  same column name so an indexer can treat the two tables uniformly.

**Design intent — events as SQL rows keyed by `escrow_id`:** the
protocol's event layer is meant to be ingested by an off-chain
indexer into a relational database where `escrow_id` is the natural
primary / foreign key joining cap lifecycle, fee movement, and
escrow state-machine events into a single schema. Each event is a
flat row that must answer natural analytical questions on its own —
*"how many times has address X been owner of escrow Y?"*, *"who held
cap C at burn time?"* — without joining against other modules'
events or against Sui envelope metadata (transfer events, tx
sender). Including `owner` in both Minted and Burned honors this:
`OwnerCap` has `key + store` (it can be wrapped, composed, embedded
as a recursive asset), so the holder at burn may differ from the
recipient at mint — the Burned event captures that distinct fact
rather than forcing the indexer to guess from a chain of transfers.
Downstream, this lets off-chain tooling learn ownership patterns
from the event stream alone.

**No `timestamp_ms` field.** The module has no authoritative time to
report: the call-site wall-clock is not necessarily the logical moment
the event belongs to, and threading `&Clock` would only record call
time. Consumers order events by checkpoint timestamp + tx position,
both of which Sui attaches to the event envelope for free. The module
emits identity and the holder address only.


4. FUNCTIONS
------------

### `new`

    public(package) fun new(
        escrow_id: ID,
        owner:     address,
        ctx:       &mut TxContext,
    ): OwnerCap

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** mints an `OwnerCap` bound to a specific escrow and records
the intended recipient in the event stream.

**Behavior:**
1. Construct `cap = OwnerCap { id: object::new(ctx), escrow_id }`.
2. `let owner_cap_id = object::uid_to_inner(&cap.id);`
3. Emit `OwnerCapMinted { owner_cap_id, escrow_id, owner }`.
4. Return `cap`. The caller (`rental_escrow::integrate`) is responsible
   for delivering it to `owner` — typically via `transfer::transfer(cap,
   owner)` in the same call or further up the PTB. The module does not
   perform the transfer itself; the `owner` argument is a declarative
   annotation for the indexer, not a runtime check.

**Call site:** `rental_escrow::integrate` — once per integration.
Passes `tx_context::sender(ctx)` as `owner` in the typical flow;
custody integrations pass the final beneficiary address.

---

### `burn`

    public(package) fun burn(cap: OwnerCap, owner: address)

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** destroys an `OwnerCap` at retirement, preventing any
further owner-privileged operations on the (now-deleted) escrow.
Records the `owner` argument in the event stream as the holder at burn
time — declarative, like `owner` in `new`.

**Behavior:**
1. Destructure: `let OwnerCap { id, escrow_id } = cap;`.
2. Capture `owner_cap_id = object::uid_to_inner(&id);` — must be read
   before `object::delete` consumes the `UID`.
3. Call `object::delete(id);`.
4. Emit `OwnerCapBurned { owner_cap_id, escrow_id, owner }` — emission
   runs last, after the cap is actually destroyed.

**Signature rationale:** `owner: address` is passed in rather than
derived from `&TxContext` inside the body. The signature advertises
the exact datum the function records — parallel to
`new(escrow_id, owner, ctx)` which also takes `owner` declaratively.
`burn` no longer needs `&TxContext` at all: all it does is consume the
cap, destroy the `UID`, and emit.

**Call site:** `rental_escrow::claim_asset` — once per escrow lifetime,
atomically with asset extraction and escrow deletion. `claim_asset`
already gates on `owner_cap::assert_escrow(cap, escrow_id)` and then
binds `let owner = tx_context::sender(ctx);` once, passing it to
`burn`. Since the cap is presented by value and the escrow is deleted
in the same call, `owner` at this boundary is the legitimate holder at
burn time; since `OwnerCap` has `key + store`, that may differ from
the mint-time recipient recorded in `OwnerCapMinted`.

---

### `escrow_id`

    public fun escrow_id(cap: &OwnerCap): ID

**Visibility:** `public` — readable by any caller, including external
integrations that need to know which escrow a cap authorizes.

**Purpose:** returns the `ID` of the `RentalEscrow` this cap was minted
for.

**Behavior:** returns `cap.escrow_id`.

---

### `assert_escrow`

    public(package) fun assert_escrow(cap: &OwnerCap, escrow_id: ID)

**Visibility:** `public(package)` — called only by `rental_escrow`.

**Purpose:** asserts the presented cap belongs to the target escrow.
Aborts with `E_ESCROW_MISMATCH` if it does not.

**Behavior:**
```
assert!(cap.escrow_id == escrow_id, E_ESCROW_MISMATCH)
```

**Call sites:** `rental_escrow::retire`, `rental_escrow::claim_asset`,
`rental_escrow::withdraw_earnings` — once per call, immediately after
the cap is presented.


5. PROPERTIES
-------------

**P1 — One cap per escrow:**
    `new` is `public(package)` and called exactly once per escrow at
    `integrate`. No other creation path exists. Structural guarantee,
    not a runtime check.

**P2 — Cap lifetime bounded by escrow lifetime:**
    `burn` is called atomically with `object::delete` on the escrow UID
    inside `claim_asset`. No `OwnerCap` with escrow_id `X` can exist
    after the escrow `X` is deleted.

**P3 — Authorization is cap-bound, not address-bound:**
    `assert_escrow` checks `cap.escrow_id`. The protocol does not record
    or check the address of whoever holds the cap. Transferring the cap
    transfers authority unconditionally.

**P4 — Composability with operational intent:**
    `store` is chosen for custody, multisig, and secondary-market
    composition. Recursive integration as an `Asset` in another escrow
    is an emergent consequence of `key + store`, not an independent
    goal. `rental_escrow::integrate` imposes no restriction on this
    composition.

**P5 — No zero-state objects:**
    Every `OwnerCap` has a non-zero `escrow_id` (set at mint from a
    live `RentalEscrow` UID). `burn` deletes the object entirely —
    no inert shells remain.


6. TEST CASES
-------------

### 6.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `new(escrow_id, owner, ctx)` | Returns `OwnerCap` with `cap.escrow_id == escrow_id`. Object has a fresh UID. One `OwnerCapMinted { owner_cap_id, escrow_id, owner }` event emitted with `owner_cap_id == object::id(&cap)`, matching `escrow_id`, and `owner` equal to the argument. |
| N2 | Two calls with distinct `escrow_id`s and distinct `owner`s | Two distinct `OwnerCap` objects, each bound to its own escrow_id. Two `OwnerCapMinted` events, one per call, each carrying the matching triple. |
| N3 | `new` passing an `owner` different from `tx_context::sender(ctx)` (e.g. custody integration) | Event `owner` field equals the argument, not the tx sender. Asserts the field is declarative, not a runtime echo of sender. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `burn(cap, owner)` | Cap's UID deleted. No abort. One `OwnerCapBurned { owner_cap_id, escrow_id, owner }` event emitted with `(owner_cap_id, escrow_id)` the cap carried and `owner` equal to the argument. |
| B2 | `burn` consumes the cap (by value) | Compiler enforces — no double-burn possible. |
| B3 | Cap originally minted with `owner = A`, burned with `owner = B` (legal because `OwnerCap` has `store` and can be moved between mint and burn) | Event's `owner` field equals B, not A. Asserts Burned captures the **burn-time** holder as declared by the caller, distinct from Minted's recipient. |

### 6.3 `escrow_id`

| # | Description | Expected |
|---|---|---|
| G1 | `escrow_id(&cap)` after `new(id, ctx)` | Returns `id`. |

### 6.4 `assert_escrow`

| # | Description | Expected |
|---|---|---|
| A1 | `assert_escrow(&cap, cap.escrow_id)` | No abort. |
| A2 | `assert_escrow(&cap, different_id)` | Aborts with `E_ESCROW_MISMATCH`. |
| A3 | Cap minted for escrow A, asserted against escrow B | Aborts with `E_ESCROW_MISMATCH`. |

### 6.5 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `new` → `assert_escrow` (matching) → `burn` | Full lifecycle completes. No abort. One `OwnerCapMinted` and one `OwnerCapBurned` event, both carrying the same `(owner_cap_id, escrow_id)` pair. `owner` fields reflect the declared mint recipient and the burn-time sender respectively. |
| L2 | `new` → `assert_escrow` (mismatched) | Aborts before burn. Cap not consumed. `OwnerCapMinted` emitted at `new`; no `OwnerCapBurned` (burn never ran). |


7. MODULE BOUNDARY
------------------

`owner_cap.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `OwnerCap` (type) | `public` | `key + store`. One per escrow. Transferable. |
| `E_ESCROW_MISMATCH` | `public` | Abort code for cap/escrow mismatch in `assert_escrow`. |
| `OwnerCapMinted` (event) | `public` | `copy + drop`. Emitted by `new`. |
| `OwnerCapBurned` (event) | `public` | `copy + drop`. Emitted by `burn`. |
| `new(escrow_id, owner, ctx): OwnerCap` | `public(package)` | Mint. Called only by `rental_escrow::integrate`. Emits `OwnerCapMinted { owner_cap_id, escrow_id, owner }`. |
| `burn(cap, owner)` | `public(package)` | Destroy. Called only by `rental_escrow::claim_asset`. Emits `OwnerCapBurned { owner_cap_id, escrow_id, owner }` with `owner` from the caller (the binding of `tx_context::sender(ctx)` hoisted at the call site). |
| `escrow_id(cap): ID` | `public` | Getter. |
| `assert_escrow(cap, escrow_id)` | `public(package)` | Aborts with `E_ESCROW_MISMATCH` if mismatch. |

**Depends on:** `sui::object`, `sui::event`.


8. OBJECT DISPLAY
-----------------

![OwnerCap](../../media/object-display/owner-cap.png)

`Display<OwnerCap>` gives every cap a visual identity in wallets and explorers.
Created once post-deployment via a PTB presenting `&mut Publisher` for the
package and `&mut DisplayRegistry` (Sui framework shared object at `0xd`).

### Fields

| Key | Value | Notes |
|---|---|---|
| `name` | `Owner Cap` | Static. |
| `description` | `Grants owner authority over a RentalEscrow. Authorizes withdraw_earnings, retire, and claim_asset. Transferable — whoever holds this cap holds full ownership authority.` | Static. |
| `image_url` | `{IMAGE_BASE_URL}/owner-cap.png` | Hosted URL. Source: `media/object-display/owner-cap.png`. |
| `project_url` | `https://liquidrenting.com` | Static. |
| `creator` | `Liquid Renting Protocol` | Static. |

`{IMAGE_BASE_URL}` is set at deployment time to the protocol's media hosting base URL.

### Creation

```move
use sui::display_registry;

let (mut display, cap) = display_registry::new_with_publisher<OwnerCap>(
    registry,   // &mut DisplayRegistry (shared object 0xd)
    publisher,  // &mut Publisher
    ctx,
);
display_registry::set(&mut display, &cap, b"name".to_string(),        b"Owner Cap".to_string());
display_registry::set(&mut display, &cap, b"description".to_string(), b"Grants owner authority over a RentalEscrow. Authorizes withdraw_earnings, retire, and claim_asset. Transferable — whoever holds this cap holds full ownership authority.".to_string());
display_registry::set(&mut display, &cap, b"image_url".to_string(),   b"{IMAGE_BASE_URL}/owner-cap.png".to_string());
display_registry::set(&mut display, &cap, b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display_registry::set(&mut display, &cap, b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::share(display);
transfer::public_transfer(cap, ctx.sender());  // cap retained by deployer for future edits
```

One `Display<OwnerCap>` per package deployment — enforced by `DisplayRegistry`.
ID is deterministic from `DisplayRegistry` + type — no event scanning required.
The returned `DisplayCap<OwnerCap>` is required to call `set` / `unset` / `clear`
later; keeping it with the deployer preserves the ability to edit the Display
post-deployment.

**Status:** [ ] `Display<OwnerCap>` created and committed.
